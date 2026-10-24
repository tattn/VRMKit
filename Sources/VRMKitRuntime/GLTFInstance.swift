import Foundation
import SIMDCompat
import VRMKit

/// What one update of an instance changed, for a renderer to draw: only what moved since
/// the update before.
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
public class GLTFInstance {
    public let asset: GLTFAsset
    public let pose: GLTFPose
    /// Whether an update solves the skins into its output. A renderer skinning from
    /// ``pose`` itself turns it off and takes the moved nodes from the pose instead.
    public var outputsSkins = true

    package let animationPlayer: GLTFAnimationPlayer
    private lazy var animationDecoder = GLTFAnimationDecoder(document: asset.document)
    private var animationRuntimes: [Int: GLTFAnimationRuntime] = [:]
    private var morphWeights: [Int: [Float]] = [:]
    private var changedMorphNodes: Set<Int> = []
    private var hasOutputSkins = false

    public convenience init(asset: GLTFAsset) throws {
        self.init(asset: asset, pose: asset.makePose())
    }

    /// - Parameter pose: a pose of the asset's nodes, such as one a renderer keeps its own
    ///   node objects a copy of.
    package init(asset: GLTFAsset, pose: GLTFPose) {
        self.asset = asset
        self.pose = pose
        animationPlayer = GLTFAnimationPlayer(pose: pose)
        for (node, mesh) in asset.meshIndicesByNode {
            let count = asset.meshes[mesh].geometry.blendShapeTargetCount
            guard count > 0 else { continue }
            morphWeights[node] = asset.nodes[node].initialMorphWeights ?? Array(repeating: 0, count: count)
            changedMorphNodes.insert(node)
        }
        animationPlayer.didApply = { [unowned self] output in
            didAnimate(output)
        }
    }

    // MARK: - Animations

    /// Metadata of the document's animations.
    public var animations: [GLTFAnimation] {
        asset.document.gltf.animations.enumerated().map { index, animation in
            GLTFAnimation(index: index, name: animation.name, duration: animationDecoder.duration(of: animation))
        }
    }

    /// Starts playing the glTF animation at `index` and returns its controller. Several
    /// can run at once; what they share applies in the order they started.
    @discardableResult
    public func playAnimation(at index: Int, loops: Bool = false, speed: Float = 1) throws -> GLTFAnimationPlaybackController {
        let metadata = animations
        guard metadata.indices.contains(index) else {
            throw VRMError._dataInconsistent("animation index \(index) is out of range for \(metadata.count) animations")
        }
        return animationPlayer.start(metadata[index],
                                     runtime: try animationRuntime(at: index),
                                     ownsRuntime: false,
                                     loops: loops,
                                     speed: speed)
    }

    /// Stops every running animation, holding the current pose.
    public func stopAnimations() {
        animationPlayer.stopAll()
    }

    private func animationRuntime(at index: Int) throws -> GLTFAnimationRuntime {
        if let cached = animationRuntimes[index] { return cached }
        let runtime = try GLTFAnimationRuntime(animation: try asset.document.gltf.load(\.animations, at: index),
                                               decoder: animationDecoder,
                                               posedNodes: Set(asset.nodes.indices),
                                               morphTargetCounts: morphWeights.mapValues(\.count))
        animationRuntimes[index] = runtime
        return runtime
    }

    /// Passes on what the animations set beyond the pose.
    func didAnimate(_ output: GLTFAnimationOutput) {
        for (node, weights) in output.morphWeights {
            setMorphWeights(weights, ofNode: node)
        }
    }

    // MARK: - Morph weights

    /// The weights of every morph target of the mesh the node draws. Nil for a node drawing
    /// no mesh with morph targets.
    public func morphWeights(ofNode node: Int) -> [Float]? {
        morphWeights[node]
    }

    /// Sets the weights of every morph target of the mesh the node draws.
    public func setMorphWeights(_ weights: [Float], ofNode node: Int) {
        guard let current = morphWeights[node], current.count == weights.count, current != weights else { return }
        morphWeights[node] = weights
        changedMorphNodes.insert(node)
    }

    func setMorphWeight(_ weight: Float, forTarget target: Int, ofNode node: Int) {
        guard let current = morphWeights[node], current.indices.contains(target), current[target] != weight else { return }
        morphWeights[node]?[target] = weight
        changedMorphNodes.insert(node)
    }

    // MARK: - A frame

    /// Advances the running animations by `deltaTime` and returns what moved.
    public func update(deltaTime: TimeInterval) -> GLTFFrameOutput {
        animationPlayer.advance(deltaTime: max(0, deltaTime))
        return takeOutput()
    }

    /// What changed since the last output, which this then forgets.
    public func takeOutput() -> GLTFFrameOutput {
        var output = GLTFFrameOutput()
        for node in changedMorphNodes {
            output.morphWeights[node] = morphWeights[node]
        }
        changedMorphNodes.removeAll(keepingCapacity: true)
        if outputsSkins {
            // A moved node moves every joint below it, so any move solves every skin: a
            // model's skins hold a few hundred joints at most.
            let moved = !pose.takeNodesMovedForSkinning().isEmpty
            if moved || !hasOutputSkins {
                output.skins = skinPoses()
                hasOutputSkins = true
            }
        }
        addOutput(to: &output)
        return output
    }

    /// Adds what a subclass drives to an output.
    func addOutput(to output: inout GLTFFrameOutput) {}

    /// The skin of every node drawing a skinned mesh, as posed.
    public func skinPoses() -> [GLTFFrameOutput.SkinPose] {
        asset.meshIndicesByNode.sorted { $0.key < $1.key }.compactMap { node, mesh in
            guard let skinIndex = asset.meshes[mesh].skinIndex else { return nil }
            let skin = asset.skins[skinIndex]
            let meshSpace = pose.modelMatrix(ofNode: node).inverse
            return GLTFFrameOutput.SkinPose(nodeIndex: node,
                                            skinIndex: skinIndex,
                                            jointMatrices: zip(skin.joints, skin.inverseBindMatrices).map {
                                                meshSpace * pose.modelMatrix(ofNode: $0) * $1
                                            })
        }
    }
}
