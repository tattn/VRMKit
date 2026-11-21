#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import SIMDCompat
import VRMKit

/// What changed in an instance since one renderer last read it, for that renderer to draw
/// (``GLTFOutputReader``).
public struct GLTFFrameOutput: Sendable {
    /// The skin one node draws its mesh through, as posed: per joint, in the asset skin's
    /// order, the joint's transform in the space of the node drawing the mesh times its
    /// inverse bind matrix, which is what glTF skins a vertex with.
    public struct SkinPose: Sendable {
        public let nodeIndex: Int
        public let skinIndex: Int
        public let jointMatrices: [simd_float4x4]
    }

    /// How a node draws its mesh.
    public enum Visibility: Sendable, Equatable {
        case shown
        case hidden
        /// Drawn without the head: each slot draws its first-person triangles
        /// (``GLTFMeshGeometry/Slot/indexRange(isFirstPerson:)``).
        case firstPersonCut
    }

    /// The values an expression drives on one material.
    public struct MaterialValues: Sendable, Equatable {
        public var colors: [VRM1.Expressions.Expression.MaterialColorBind.MaterialColorType: SIMD4<Float>] = [:]
        public var uvTransform: (scale: SIMD2<Float>, offset: SIMD2<Float>, rotation: Float)?

        public static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.colors == rhs.colors && lhs.uvTransform?.scale == rhs.uvTransform?.scale
                && lhs.uvTransform?.offset == rhs.uvTransform?.offset
                && lhs.uvTransform?.rotation == rhs.uvTransform?.rotation
        }
    }

    public var skins: [SkinPose] = []
    /// glTF node → the weights of every morph target of the mesh it draws.
    public var morphWeights: [Int: [Float]] = [:]
    /// glTF material → the values expressions set on it.
    public var materialValues: [Int: MaterialValues] = [:]
    /// glTF node → how it draws its mesh.
    public var visibility: [Int: Visibility] = [:]

    public init() {}
}

/// One model built from an asset, moving on its own: its pose, its animations and the
/// morph weights its nodes draw with. It holds no renderer type and is bound to no actor:
/// one owner drives it, from whichever thread that owner runs on.
///
/// A renderer reads what moved through a reader of its own (``makeOutputReader(solvesSkins:)``),
/// so any number of renderers can draw one instance.
public class GLTFInstance {
    public let asset: GLTFAsset
    public let pose: GLTFPose

    package let animationPlayer: GLTFAnimationPlayer
    private lazy var animationDecoder = GLTFAnimationDecoder(document: asset.document)
    private var animationRuntimes: [Int: GLTFAnimationRuntime] = [:]
    /// Every node drawing a mesh with morph targets, in node order, and per node its slot
    /// among them, -1 for the others: a frame writes weights hundreds of times.
    private let morphNodes: [Int]
    private let morphSlotsByNode: [Int]
    private var morphWeightsBySlot: [[Float]]
    private var morphChangesBySlot: [UInt64]
    private var lastMorphChange: UInt64 = 1

    /// What a change is stamped with. A reader taking what changed closes it, so whatever
    /// changes after is stamped later than anything that reader has read.
    private(set) var changeStamp: UInt64 = 1
    /// How deep the public calls changing what readers read are nested, so that only the
    /// outermost one says so.
    private var changeDepth = 0
    /// Called once a call from outside has changed what readers read, after an update
    /// included, for a renderer showing the instance as it stands.
    package var didChange: (() -> Void)?

    public convenience init(asset: GLTFAsset) throws {
        self.init(asset: asset, pose: asset.makePose())
    }

    /// - Parameter pose: a pose of the asset's nodes, such as one a renderer keeps its own
    ///   node objects a copy of.
    package init(asset: GLTFAsset, pose: GLTFPose) {
        self.asset = asset
        self.pose = pose
        animationPlayer = GLTFAnimationPlayer(pose: pose)
        var morphNodes: [Int] = []
        var morphWeights: [[Float]] = []
        var morphSlots = [Int](repeating: -1, count: asset.nodes.count)
        for (node, mesh) in asset.meshIndicesByNode.sorted(by: { $0.key < $1.key }) {
            let count = asset.meshes[mesh].geometry.blendShapeTargetCount
            guard count > 0 else { continue }
            morphSlots[node] = morphNodes.count
            morphNodes.append(node)
            morphWeights.append(asset.nodes[node].initialMorphWeights ?? Array(repeating: 0, count: count))
        }
        self.morphNodes = morphNodes
        morphSlotsByNode = morphSlots
        morphWeightsBySlot = morphWeights
        morphChangesBySlot = Array(repeating: changeStamp, count: morphNodes.count)
        animationPlayer.didApply = { [unowned self] output in
            didAnimate(output)
        }
    }

    // MARK: - Animations

    /// Metadata of the document's animations. Keyframe data stays untouched until
    /// ``playAnimation(at:loops:speed:)``.
    public private(set) lazy var animations: [GLTFAnimation] = asset.document.gltf.animations.enumerated().map { index, animation in
        GLTFAnimation(index: index, name: animation.name, duration: animationDecoder.duration(of: animation))
    }

    /// Starts playing the glTF animation at `index` and returns its controller. Several
    /// can run at once; what they share applies in the order they started.
    @discardableResult
    public func playAnimation(at index: Int, loops: Bool = false, speed: Float = 1) throws -> GLTFAnimationPlaybackController {
        guard animations.indices.contains(index) else {
            throw VRMError._dataInconsistent("animation index \(index) is out of range for \(animations.count) animations")
        }
        let runtime = try animationRuntime(at: index)
        return change {
            animationPlayer.start(animations[index], runtime: runtime, ownsRuntime: false, loops: loops, speed: speed)
        }
    }

    private func animationRuntime(at index: Int) throws -> GLTFAnimationRuntime {
        if let cached = animationRuntimes[index] { return cached }
        var morphTargetCounts: [Int: Int] = [:]
        for (slot, node) in morphNodes.enumerated() {
            morphTargetCounts[node] = morphWeightsBySlot[slot].count
        }
        let runtime = try GLTFAnimationRuntime(animation: try asset.document.gltf.load(\.animations, at: index),
                                               decoder: animationDecoder,
                                               posedNodes: Set(asset.nodes.indices),
                                               morphTargetCounts: morphTargetCounts)
        animationRuntimes[index] = runtime
        return runtime
    }

    /// Passes on what the animations set beyond the pose.
    func didAnimate(_ output: GLTFAnimationOutput) {
        for (node, weights) in output.morphWeights {
            writeMorphWeights(weights, ofNode: node)
        }
    }

    // MARK: - Morph weights

    /// The weights of every morph target of the mesh the node draws. Nil for a node drawing
    /// no mesh with morph targets.
    public func morphWeights(ofNode node: Int) -> [Float]? {
        morphSlot(ofNode: node).map { morphWeightsBySlot[$0] }
    }

    /// Sets the weights of every morph target of the mesh the node draws.
    public func setMorphWeights(_ weights: [Float], ofNode node: Int) {
        change { writeMorphWeights(weights, ofNode: node) }
    }

    private func writeMorphWeights(_ weights: [Float], ofNode node: Int) {
        guard let slot = morphSlot(ofNode: node), morphWeightsBySlot[slot].count == weights.count,
              morphWeightsBySlot[slot] != weights else { return }
        morphWeightsBySlot[slot] = weights
        stampMorph(slot)
    }

    func setMorphWeight(_ weight: Float, forTarget target: Int, ofNode node: Int) {
        guard let slot = morphSlot(ofNode: node), morphWeightsBySlot[slot].indices.contains(target),
              morphWeightsBySlot[slot][target] != weight else { return }
        morphWeightsBySlot[slot][target] = weight
        stampMorph(slot)
    }

    private func morphSlot(ofNode node: Int) -> Int? {
        guard morphSlotsByNode.indices.contains(node) else { return nil }
        let slot = morphSlotsByNode[node]
        return slot < 0 ? nil : slot
    }

    private func stampMorph(_ slot: Int) {
        morphChangesBySlot[slot] = changeStamp
        lastMorphChange = changeStamp
    }

    // MARK: - A frame

    /// Advances the running animations by `deltaTime`. What moved is read through a reader.
    public func update(deltaTime: TimeInterval) {
        advanceAnimations(deltaTime: deltaTime)
    }

    /// Advances the running animations alone, whatever else an update of a subclass moves.
    package func advanceAnimations(deltaTime: TimeInterval) {
        change { animationPlayer.advance(deltaTime: max(0, deltaTime)) }
    }

    /// Runs a call from outside that changes what readers read, then says so once, unless
    /// it runs inside another such call.
    func change<Result>(_ body: () throws -> Result) rethrows -> Result {
        changeDepth += 1
        defer {
            changeDepth -= 1
            if changeDepth == 0 { didChange?() }
        }
        return try body()
    }

    // MARK: - Readers

    /// A reader of what moves in this instance, which takes everything first and then only
    /// what changed since it last took. Each renderer drawing the instance keeps its own.
    ///
    /// - Parameter solvesSkins: whether the reader's outputs carry the skins, for a renderer
    ///   skinning from them rather than from ``pose``. No skin is solved for an instance no
    ///   such reader reads.
    public func makeOutputReader(solvesSkins: Bool) -> GLTFOutputReader {
        GLTFOutputReader(instance: self, solvesSkins: solvesSkins)
    }

    /// What changed since `stamp`, which this moves on to now.
    func takeChanges(since stamp: inout UInt64) -> GLTFFrameOutput {
        var output = GLTFFrameOutput()
        let seen = stamp
        stamp = changeStamp
        changeStamp &+= 1
        if lastMorphChange > seen {
            for slot in morphNodes.indices where morphChangesBySlot[slot] > seen {
                output.morphWeights[morphNodes[slot]] = morphWeightsBySlot[slot]
            }
        }
        addChanges(since: seen, to: &output)
        return output
    }

    /// Adds what a subclass drives and has changed since `stamp` to an output.
    func addChanges(since stamp: UInt64, to output: inout GLTFFrameOutput) {}

    /// Every node drawing a skinned mesh, in node order, with its skin.
    private lazy var skinnedNodes: [(node: Int, skinIndex: Int)] = asset.meshIndicesByNode
        .sorted { $0.key < $1.key }
        .compactMap { node, mesh in asset.meshes[mesh].skinIndex.map { (node, $0) } }

    /// The skin of every node drawing a skinned mesh, as posed.
    func skinPoses() -> [GLTFFrameOutput.SkinPose] {
        skinnedNodes.map { node, skinIndex in
            let skin = asset.skins[skinIndex]
            var matrices: [simd_float4x4] = []
            matrices.reserveCapacity(skin.joints.count)
            // Skinned meshes mostly hang off the model's root untransformed, which spares
            // a product per joint.
            let meshModel = pose.modelMatrix(ofNode: node)
            if meshModel == matrix_identity_float4x4 {
                for (joint, inverseBind) in zip(skin.joints, skin.inverseBindMatrices) {
                    matrices.append(pose.modelMatrix(ofNode: joint) * inverseBind)
                }
            } else {
                let meshSpace = meshModel.inverse
                for (joint, inverseBind) in zip(skin.joints, skin.inverseBindMatrices) {
                    matrices.append(meshSpace * pose.modelMatrix(ofNode: joint) * inverseBind)
                }
            }
            return GLTFFrameOutput.SkinPose(nodeIndex: node, skinIndex: skinIndex, jointMatrices: matrices)
        }
    }
}

/// One renderer's place in what an instance changes: every take hands back what changed
/// since the take before, the first everything, whatever other readers of the instance take.
///
/// It holds its instance, which holds no reader, so a renderer stops reading by dropping it.
public struct GLTFOutputReader {
    public let instance: GLTFInstance
    /// Whether the outputs carry the skins.
    public let solvesSkins: Bool
    private var stamp: UInt64 = 0
    /// The pose's moves the skins were last solved at, nil before the first solve.
    private var solvedPoseMoves: UInt64?

    init(instance: GLTFInstance, solvesSkins: Bool) {
        self.instance = instance
        self.solvesSkins = solvesSkins
    }

    /// What changed since the last take: everything on the first. The skins come only when
    /// ``solvesSkins``, all of them whenever any node has moved, since a moved node moves
    /// every joint below it.
    public mutating func takeChanges() -> GLTFFrameOutput {
        var output = instance.takeChanges(since: &stamp)
        if solvesSkins {
            let moves = instance.pose.moveCount
            if solvedPoseMoves != moves {
                output.skins = instance.skinPoses()
                solvedPoseMoves = moves
            }
        }
        return output
    }
}
