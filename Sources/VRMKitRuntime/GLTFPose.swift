import simd
import VRMKit

/// Every node transform of one loaded model, held in arrays rather than in a renderer's
/// scene graph: the runtimes that pose a model (animation, constraints, look-at, spring
/// bones) read and write it, and skinning reads it.
///
/// A renderer's scene graph is then a copy of the pose, kept only where something reads
/// it: a renderer such as RealityKit costs far more per node written than the arrays do,
/// since each scene graph write records a change and publishes an event. Writing here also
/// notes which nodes moved, so nothing has to be told a node was posed.
///
/// Model space is the space of the model's root, above its scene's root nodes; world space
/// puts the model where ``rootMatrix`` says it stands.
public final class GLTFPose {
    public let nodeCount: Int
    private let parents: [Int]
    private let childIndices: [[Int]]

    private var locals: [GLTFNodeTransform]
    private var modelMatrices: [simd_float4x4]
    private var modelRotations: [simd_quatf]
    private var isModelValid: [Bool]

    /// Where the model's root stands in the world, which the world-space reads fold in.
    public var rootMatrix = matrix_identity_float4x4
    public var rootRotation = quat_identity_float

    private var invalidationStack: [Int] = []
    private var movedForSkinning: [Bool]
    private var movedForSkinningList: [Int] = []
    private var takenMovedForSkinningList: [Int] = []

    /// Called with every local transform a runtime writes, for a renderer keeping its scene
    /// graph a copy of the pose. Not called for ``adoptLocalTransform(_:ofNode:)``.
    package var didWriteLocalTransform: ((Int, GLTFNodeTransform) -> Void)?
    /// The nodes whose writes go to ``didWriteLocalTransform``, nil for every node: a renderer
    /// keeping only some of its scene graph a copy is not called for the rest, which a
    /// runtime writes hundreds of times a frame.
    package var handedBackNodes: [Bool]?

    /// The nodes as the runtimes generic over ``VRMRuntimeNode`` take them.
    package private(set) lazy var nodes: [GLTFPoseNode] = (0..<nodeCount).map { GLTFPoseNode(pose: self, index: $0) }

    /// - Parameters:
    ///   - children: each node's children, in the order the document lists them. They have to
    ///     describe a forest, which a validated glTF node hierarchy does.
    ///   - locals: each node's rest transform in its parent's space.
    public init(children: [[Int]], locals: [GLTFNodeTransform]) {
        precondition(children.count == locals.count, "a pose needs one children entry per node")
        nodeCount = locals.count
        var parents = [Int](repeating: -1, count: locals.count)
        for (index, nodeChildren) in children.enumerated() {
            for child in nodeChildren { parents[child] = index }
        }
        self.parents = parents
        childIndices = children
        self.locals = locals
        modelMatrices = Array(repeating: matrix_identity_float4x4, count: locals.count)
        modelRotations = Array(repeating: quat_identity_float, count: locals.count)
        isModelValid = Array(repeating: false, count: locals.count)
        movedForSkinning = Array(repeating: false, count: locals.count)
    }

    public func parent(ofNode index: Int) -> Int? {
        let parent = parents[index]
        return parent < 0 ? nil : parent
    }

    public func children(ofNode index: Int) -> [Int] {
        childIndices[index]
    }

    // MARK: - Local transforms

    public func localTransform(ofNode index: Int) -> GLTFNodeTransform {
        locals[index]
    }

    public func localMatrix(ofNode index: Int) -> simd_float4x4 {
        locals[index].matrix
    }

    /// Writes the node's transform, doing nothing when it already holds it: a held pose
    /// then moves nothing downstream.
    public func setLocalTransform(_ transform: GLTFNodeTransform, ofNode index: Int) {
        guard locals[index] != transform else { return }
        locals[index] = transform
        noteMoved(index)
        handBack(index)
    }

    /// Writes the rotation, leaving the translation and the scale alone.
    public func setLocalRotation(_ rotation: simd_quatf, ofNode index: Int) {
        guard locals[index].rotation != rotation else { return }
        locals[index].rotation = rotation
        noteMoved(index)
        handBack(index)
    }

    public func setLocalTranslation(_ translation: SIMD3<Float>, ofNode index: Int) {
        guard locals[index].translation != translation else { return }
        locals[index].translation = translation
        noteMoved(index)
        handBack(index)
    }

    private func handBack(_ index: Int) {
        guard let didWriteLocalTransform, handedBackNodes?[index] ?? true else { return }
        didWriteLocalTransform(index, locals[index])
    }

    // MARK: - Model and world space

    /// The node's transform in model space, its parents folded in.
    public func modelMatrix(ofNode index: Int) -> simd_float4x4 {
        resolveModel(index)
        return modelMatrices[index]
    }

    public func modelRotation(ofNode index: Int) -> simd_quatf {
        resolveModel(index)
        return modelRotations[index]
    }

    public func worldMatrix(ofNode index: Int) -> simd_float4x4 {
        rootMatrix * modelMatrix(ofNode: index)
    }

    public func worldRotation(ofNode index: Int) -> simd_quatf {
        rootRotation * modelRotation(ofNode: index)
    }

    public func worldPosition(ofNode index: Int) -> SIMD3<Float> {
        worldMatrix(ofNode: index).translation
    }

    /// Writes the node's rotation so that it faces `rotation` in world space.
    public func setWorldRotation(_ rotation: simd_quatf, ofNode index: Int) {
        let parent = parent(ofNode: index).map { worldRotation(ofNode: $0) } ?? rootRotation
        setLocalRotation(parent.inverse * rotation, ofNode: index)
    }

    /// Writes the node's translation so that it stands at `position` in world space.
    public func setWorldPosition(_ position: SIMD3<Float>, ofNode index: Int) {
        let parent = parent(ofNode: index).map { worldMatrix(ofNode: $0) } ?? rootMatrix
        setLocalTranslation(parent.inverse.multiplyPoint(position), ofNode: index)
    }

    // MARK: - What moved

    /// The nodes written since the last call, for skinning to re-solve only their rows.
    package func takeNodesMovedForSkinning() -> [Int] {
        for index in movedForSkinningList { movedForSkinning[index] = false }
        // Two buffers take turns, so handing the list over allocates nothing frame after frame.
        swap(&takenMovedForSkinningList, &movedForSkinningList)
        movedForSkinningList.removeAll(keepingCapacity: true)
        return takenMovedForSkinningList
    }

    package var hasNodesMovedForSkinning: Bool { !movedForSkinningList.isEmpty }

    /// Takes a transform the renderer's scene graph was given from outside, which the scene
    /// graph already holds and so is not handed back to ``didWriteLocalTransform``.
    package func adoptLocalTransform(_ transform: GLTFNodeTransform, ofNode index: Int) {
        guard locals[index] != transform else { return }
        locals[index] = transform
        noteMoved(index)
    }

    private func noteMoved(_ index: Int) {
        invalidateModel(below: index)
        if !movedForSkinning[index] {
            movedForSkinning[index] = true
            movedForSkinningList.append(index)
        }
    }

    /// A subtree whose model matrices are already invalid stays invalid below, so the walk
    /// stops there: a chain posed root to tip invalidates each node once.
    private func invalidateModel(below index: Int) {
        guard isModelValid[index] else { return }
        invalidationStack.append(index)
        while let node = invalidationStack.popLast() {
            guard isModelValid[node] else { continue }
            isModelValid[node] = false
            invalidationStack.append(contentsOf: childIndices[node])
        }
    }

    private func resolveModel(_ index: Int) {
        guard !isModelValid[index] else { return }
        let parent = parents[index]
        let local = locals[index]
        if parent >= 0 {
            resolveModel(parent)
            modelMatrices[index] = modelMatrices[parent] * local.matrix
            modelRotations[index] = modelRotations[parent] * local.rotation
        } else {
            modelMatrices[index] = local.matrix
            modelRotations[index] = local.rotation
        }
        isModelValid[index] = true
    }
}

/// One node of a ``GLTFPose``, as the runtimes generic over ``VRMRuntimeNode`` pose it.
package final class GLTFPoseNode: VRMRuntimeNode {
    package typealias RuntimeNode = GLTFPoseNode

    package unowned let pose: GLTFPose
    package let index: Int

    init(pose: GLTFPose, index: Int) {
        self.pose = pose
        self.index = index
    }

    package var runtimeParent: GLTFPoseNode? {
        pose.parent(ofNode: index).map { pose.nodes[$0] }
    }

    package var runtimeChildren: [GLTFPoseNode] {
        pose.children(ofNode: index).map { pose.nodes[$0] }
    }

    package var localMatrix: simd_float4x4 { pose.localMatrix(ofNode: index) }

    package var localRotation: simd_quatf { pose.localTransform(ofNode: index).rotation }

    package func setLocalRotation(_ rotation: simd_quatf) {
        pose.setLocalRotation(rotation, ofNode: index)
    }

    package var worldMatrix: simd_float4x4 { pose.worldMatrix(ofNode: index) }

    package var worldRotation: simd_quatf { pose.worldRotation(ofNode: index) }
}
