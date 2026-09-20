#if canImport(RealityKit)
import Foundation
import Metal
import RealityKit
import simd
import VRMKit

/// One drawn copy of a merged mesh: the `LowLevelMesh` it renders from, and the
/// pose and morph weights the vertices in it were last deformed with.
///
/// The loader skins and morphs on the GPU itself rather than through RealityKit's
/// deformation, which on OS 27 allocates and frees GPU buffers every frame for
/// every deformed mesh. A mesh whose joints and weights did not move is not dispatched.
@available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
@MainActor
final class GLTFDeformedMesh {
    let source: GLTFMeshSource
    /// The slots of the source this mesh draws, in the order of the entity's materials.
    /// Every entity drawing one mesh shares its vertex array and draws its own slots.
    let drawnSlots: [Int]
    let lowLevelMesh: LowLevelMesh
    let meshResource: MeshResource

    /// One weight per morph target, positionally as glTF defines them.
    private(set) var blendShapeWeights: [Float]
    /// The skeleton pose the mesh was last solved against, each joint in the space of
    /// the joint above it, as ``GLTFEntity`` solves it.
    private(set) var jointTransforms: JointTransforms?

    /// A copy taken off a live mesh draws what the mesh drew when it was taken, and
    /// never deforms again.
    let isFrozen: Bool

    private var needsDeformation = false
    /// Whether the parts drawn now cover anything. A mesh drawing nothing, such as a
    /// hidden render pass, is not deformed until something of it shows again.
    private var drawsAnything = true
    /// Whether a dispatch would change what the mesh draws.
    var isDeformationPending: Bool { needsDeformation && drawsAnything && !isFrozen && source.isDeformable }
    private let jointMatricesBuffer: MTLBuffer?
    private let morphWeightsBuffer: MTLBuffer?
    private let activeTargetsBuffer: MTLBuffer?

    var geometry: GLTFMeshGeometry { source.geometry }

    /// Whether a first-person camera draws this mesh differently at all.
    var hasFirstPersonCut: Bool {
        drawnSlots.contains { geometry.slots[$0].firstPersonIndexRange != nil }
    }

    init(source: GLTFMeshSource, drawnSlots: [Int], frozen: Bool = false) throws {
        self.source = source
        self.drawnSlots = drawnSlots
        self.isFrozen = frozen
        let geometry = source.geometry
        let device = source.context.device
        lowLevelMesh = try LowLevelMesh(descriptor: source.descriptor)
        lowLevelMesh.withUnsafeMutableIndices { raw in
            geometry.indices.withUnsafeBytes { raw.copyMemory(from: $0) }
        }
        if !geometry.texcoords.isEmpty {
            lowLevelMesh.withUnsafeMutableBytes(bufferIndex: GLTFMeshSource.texcoordBufferIndex) { raw in
                geometry.texcoords.withUnsafeBytes { raw.copyMemory(from: $0) }
            }
        }
        // The rest pose is what the mesh draws until a solve arrives; a static mesh
        // keeps it for good.
        Self.writeRestPose(of: geometry, into: lowLevelMesh)
        blendShapeWeights = Array(repeating: 0, count: geometry.blendShapeTargetCount)
        if let skin = source.skin {
            let identity = Array(repeating: matrix_identity_float4x4, count: max(skin.skeleton.joints.count, 1))
            jointMatricesBuffer = device.makeBuffer(identity)
        } else {
            jointMatricesBuffer = nil
        }
        if geometry.hasBlendShapes {
            morphWeightsBuffer = device.makeBuffer(length: geometry.blendShapeTargetCount * 4, options: .storageModeShared)
            activeTargetsBuffer = device.makeBuffer(length: geometry.blendShapeTargetCount * 4, options: .storageModeShared)
        } else {
            morphWeightsBuffer = nil
            activeTargetsBuffer = nil
        }
        meshResource = try MeshResource(from: lowLevelMesh)
    }

    private static func writeRestPose(of geometry: GLTFMeshGeometry, into mesh: LowLevelMesh) {
        mesh.withUnsafeMutableBytes(bufferIndex: 0) { raw in
            guard let base = raw.baseAddress else { return }
            memset(base, 0, raw.count)
            for index in 0..<geometry.vertexCount {
                let vertex = base.advanced(by: index * GLTFDeformedVertex.stride)
                GLTFDeformationContext.pack(geometry.positions[index], into: vertex.advanced(by: GLTFDeformedVertex.positionOffset))
                if !geometry.normals.isEmpty {
                    GLTFDeformationContext.pack(geometry.normals[index], into: vertex.advanced(by: GLTFDeformedVertex.normalOffset))
                }
                if !geometry.tangents.isEmpty {
                    GLTFDeformationContext.pack(geometry.tangents[index], into: vertex.advanced(by: GLTFDeformedVertex.tangentOffset))
                    GLTFDeformationContext.pack(geometry.bitangents[index], into: vertex.advanced(by: GLTFDeformedVertex.bitangentOffset))
                }
            }
        }
    }

    // MARK: - Parts

    /// Draws the drawn slots `visibleSlots` says, cut for a first-person camera when
    /// asked, and returns whether anything is left to draw. A mesh with nothing to
    /// draw keeps its last parts: the entity hides instead.
    func setParts(visibleSlots: [Bool], isFirstPerson: Bool) -> Bool {
        var parts: [LowLevelMesh.Part] = []
        for (materialIndex, slot) in drawnSlots.enumerated() where visibleSlots[safe: materialIndex] ?? true {
            let slot = geometry.slots[slot]
            let range = slot.indexRange(isFirstPerson: isFirstPerson)
            guard !range.isEmpty else { continue }
            parts.append(LowLevelMesh.Part(indexOffset: range.lowerBound * MemoryLayout<UInt32>.stride,
                                           indexCount: range.count,
                                           topology: .triangle,
                                           materialIndex: materialIndex,
                                           bounds: slot.bounds))
        }
        // A mesh shown again after a hidden stretch has missed the poses written meanwhile.
        if !drawsAnything, !parts.isEmpty { needsDeformation = true }
        drawsAnything = !parts.isEmpty
        guard drawsAnything else { return false }
        lowLevelMesh.parts.replaceAll(parts)
        return true
    }

    /// The number of indices the parts drawn now cover.
    var drawnIndexCount: Int {
        lowLevelMesh.parts.reduce(0) { $0 + $1.indexCount }
    }

    // MARK: - Pose and weights

    /// Writes `weights` onto the morph targets positionally, as glTF defines for
    /// `mesh.weights`, `node.weights` and `weights` channels alike.
    func setBlendShapeWeights(_ weights: [Float]) {
        for (target, weight) in weights.enumerated() {
            setBlendShapeWeight(weight, forTarget: target)
        }
    }

    func setBlendShapeWeight(_ weight: Float, forTarget target: Int) {
        guard blendShapeWeights.indices.contains(target), blendShapeWeights[target] != weight else { return }
        blendShapeWeights[target] = weight
        needsDeformation = true
    }

    /// Takes the solved skeleton pose, each joint in its skeleton parent's space. The
    /// skinning matrices are made from it when the mesh is dispatched, so a mesh that
    /// copies a sibling's result never makes them.
    func setJointTransforms(_ transforms: JointTransforms) {
        guard source.skin != nil else { return }
        jointTransforms = transforms
        needsDeformation = true
    }

    // MARK: - Deformation

    /// The buffer this submit's vertices go to, taken from RealityKit before anything is
    /// encoded on `commandBuffer`. Nil when the mesh has nothing to deform.
    func beginDeformation(using commandBuffer: MTLCommandBuffer) -> MTLBuffer? {
        guard isDeformationPending else { return nil }
        needsDeformation = false
        return lowLevelMesh.replace(bufferIndex: 0, using: commandBuffer)
    }

    /// Encodes this mesh's skinning and morphing into `output`, which
    /// ``beginDeformation(using:)`` handed out, on an encoder that already holds the
    /// context's pipeline.
    func encodeDeformation(into output: MTLBuffer, with encoder: MTLComputeCommandEncoder) {
        let context = source.context
        let geometry = source.geometry

        var activeTargetCount = 0
        if let morphWeightsBuffer, let activeTargetsBuffer {
            let weights = morphWeightsBuffer.contents().assumingMemoryBound(to: Float.self)
            let active = activeTargetsBuffer.contents().assumingMemoryBound(to: UInt32.self)
            for (target, weight) in blendShapeWeights.enumerated() {
                weights[target] = weight
                if weight != 0 {
                    active[activeTargetCount] = UInt32(target)
                    activeTargetCount += 1
                }
            }
        }
        if let skin = source.skin, let jointMatricesBuffer, let jointTransforms {
            Self.writeJointMatrices(of: jointTransforms, for: skin.skeleton, into: jointMatricesBuffer)
        }

        var uniforms = GLTFDeformationUniforms(vertexCount: UInt32(geometry.vertexCount),
                                               activeTargetCount: UInt32(activeTargetCount),
                                               hasNormals: geometry.normals.isEmpty ? 0 : 1,
                                               hasTangents: geometry.tangents.isEmpty ? 0 : 1,
                                               isSkinned: source.skin == nil ? 0 : 1)
        let empty = context.emptyBuffer
        encoder.setBuffer(source.basePositions, offset: 0, index: 0)
        encoder.setBuffer(source.baseNormals ?? empty, offset: 0, index: 1)
        encoder.setBuffer(source.baseTangents ?? empty, offset: 0, index: 2)
        encoder.setBuffer(source.baseBitangents ?? empty, offset: 0, index: 3)
        encoder.setBuffer(source.skin?.joints ?? empty, offset: 0, index: 4)
        encoder.setBuffer(source.skin?.weights ?? empty, offset: 0, index: 5)
        encoder.setBuffer(jointMatricesBuffer ?? empty, offset: 0, index: 6)
        encoder.setBuffer(geometry.blendShapeOffsetStorage ?? empty, offset: 0, index: 7)
        encoder.setBuffer(morphWeightsBuffer ?? empty, offset: 0, index: 8)
        encoder.setBuffer(activeTargetsBuffer ?? empty, offset: 0, index: 9)
        encoder.setBytes(&uniforms, length: MemoryLayout<GLTFDeformationUniforms>.stride, index: 10)
        encoder.setBuffer(output, offset: 0, index: 11)
        let width = min(context.pipeline.maxTotalThreadsPerThreadgroup, 64)
        encoder.dispatchThreads(MTLSize(width: geometry.vertexCount, height: 1, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: width, height: 1, depth: 1))
    }

    /// Writes the matrices the kernel skins with, each joint's model-space pose times
    /// its inverse bind matrix, into `buffer`.
    private static func writeJointMatrices(of transforms: JointTransforms,
                                           for skeleton: MeshResource.Skeleton,
                                           into buffer: MTLBuffer) {
        let joints = skeleton.joints
        let matrices = buffer.contents().assumingMemoryBound(to: simd_float4x4.self)
        // The skeleton lists parents first, so a parent's model-space pose is settled
        // by the time its child reads it.
        for index in joints.indices {
            let local = index < transforms.count ? transforms[index].matrix : matrix_identity_float4x4
            if let parent = joints[index].parentIndex, parent < index {
                matrices[index] = matrices[parent] * local
            } else {
                matrices[index] = local
            }
        }
        for index in joints.indices {
            matrices[index] = matrices[index] * joints[index].inverseBindPoseMatrix
        }
    }

    static func encodeCopy(from: MTLBuffer, to: MTLBuffer, with blit: MTLBlitCommandEncoder) {
        blit.copy(from: from, sourceOffset: 0, to: to, destinationOffset: 0, size: min(from.length, to.length))
    }

    /// A copy drawing what this mesh draws now, which never deforms again. Any
    /// deformation still pending on this mesh must have been submitted first: the
    /// copy is taken on the GPU, behind it.
    func makeFrozenCopy() throws -> GLTFDeformedMesh {
        let copy = try GLTFDeformedMesh(source: source, drawnSlots: drawnSlots, frozen: true)
        copy.blendShapeWeights = blendShapeWeights
        copy.jointTransforms = jointTransforms
        if source.isDeformable {
            guard let commandBuffer = source.context.commandQueue.makeCommandBuffer(),
                  let blit = commandBuffer.makeBlitCommandEncoder() else {
                throw VRMError._notSupported("could not copy a deformed mesh")
            }
            Self.encodeCopy(from: lowLevelMesh.read(bufferIndex: 0, using: commandBuffer),
                            to: copy.lowLevelMesh.replace(bufferIndex: 0, using: commandBuffer),
                            with: blit)
            blit.endEncoding()
            commandBuffer.commit()
        }
        return copy
    }
}

/// The deformed mesh a model entity draws. Shared by a plain `clone(recursive:)`,
/// which therefore keeps drawing what its original does; a copy of its own comes from
/// ``GLTFEntity/cloneWithOwnMaterialParameters()``.
@available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
struct GLTFDeformedMeshComponent: Component {
    let mesh: GLTFDeformedMesh
}

@available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
extension ModelEntity {
    var deformedMesh: GLTFDeformedMesh? {
        components[GLTFDeformedMeshComponent.self]?.mesh
    }

    /// The vertex data this entity was built from, at rest, for an entity a
    /// ``GLTFEntityLoader`` built. Nil on any other model entity.
    public var gltfMeshGeometry: GLTFMeshGeometry? {
        deformedMesh?.geometry
    }

    /// Draws `mesh` from here on, with the parts the merged-mesh state describes.
    func setDeformedMesh(_ mesh: GLTFDeformedMesh) {
        guard var model = components[ModelComponent.self] else { return }
        model.mesh = mesh.meshResource
        components.set(model)
        components.set(GLTFDeformedMeshComponent(mesh: mesh))
        applyMergedMesh()
    }
}
#endif
