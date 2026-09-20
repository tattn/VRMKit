#if canImport(RealityKit)
import Foundation
import Metal
import VRMKit

/// One deformed vertex as the kernel writes it and the `LowLevelMesh` reads it.
struct GLTFDeformedVertex {
    static let stride = 48
    static let positionOffset = 0
    static let normalOffset = 12
    static let tangentOffset = 24
    static let bitangentOffset = 36
}

/// Matches `Uniforms` in ``GLTFDeformationKernel``.
struct GLTFDeformationUniforms {
    var vertexCount: UInt32
    var activeTargetCount: UInt32
    var hasNormals: UInt32
    var hasTangents: UInt32
    var isSkinned: UInt32
}

/// What every deformed mesh in the process shares: the device, the queue the
/// deformation is submitted on, and the compiled kernel.
@available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
@MainActor
final class GLTFDeformationContext {
    let device: MTLDevice
    let commandQueue: MTLCommandQueue
    let pipeline: MTLComputePipelineState
    /// Bound where a mesh has no data for an input, so every buffer slot is filled.
    let emptyBuffer: MTLBuffer

    private static var cached: Result<GLTFDeformationContext, Error>?

    /// The shared context, made on first use. Failing to make one fails the load that
    /// asked, and every load after it, the same way.
    static func shared() throws -> GLTFDeformationContext {
        if let cached { return try cached.get() }
        let result = Result { try GLTFDeformationContext() }
        cached = result
        return try result.get()
    }

    private init() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw VRMError._notSupported("mesh deformation needs a Metal device")
        }
        guard let commandQueue = device.makeCommandQueue(),
              let emptyBuffer = device.makeBuffer(length: 16, options: .storageModeShared) else {
            throw VRMError._notSupported("mesh deformation could not make a Metal command queue")
        }
        let library = try device.makeLibrary(source: GLTFDeformationKernel.source, options: nil)
        guard let function = library.makeFunction(name: GLTFDeformationKernel.functionName) else {
            throw VRMError._notSupported("the mesh deformation kernel is missing from its library")
        }
        self.device = device
        self.commandQueue = commandQueue
        self.pipeline = try device.makeComputePipelineState(function: function)
        self.emptyBuffer = emptyBuffer
    }

    /// A shared-storage buffer of `vectors` packed as the kernel's `packed_float3`.
    func makePackedBuffer(_ vectors: [SIMD3<Float>]) -> MTLBuffer? {
        guard !vectors.isEmpty else { return nil }
        guard let buffer = device.makeBuffer(length: vectors.count * 12, options: .storageModeShared) else {
            return nil
        }
        Self.pack(vectors, into: buffer.contents())
        return buffer
    }

    /// Writes `vectors` at `destination` as consecutive `packed_float3`.
    static func pack(_ vectors: [SIMD3<Float>], into destination: UnsafeMutableRawPointer) {
        for (index, vector) in vectors.enumerated() {
            pack(vector, into: destination.advanced(by: index * 12))
        }
    }

    static func pack(_ vector: SIMD3<Float>, into destination: UnsafeMutableRawPointer) {
        let floats = destination.assumingMemoryBound(to: Float.self)
        floats[0] = vector.x
        floats[1] = vector.y
        floats[2] = vector.z
    }
}
#endif
