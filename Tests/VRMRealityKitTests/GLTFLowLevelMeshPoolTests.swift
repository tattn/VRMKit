#if canImport(RealityKit)
import Metal
import RealityKit
import Testing
import VRMTestSupport
@testable import VRMRealityKit

/// The pool every deformed mesh borrows its `LowLevelMesh` from, so meshes made per load and
/// per snapshot draw from the same memory rather than piling up.
@Suite
@MainActor
struct GLTFLowLevelMeshPoolTests {
    @available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
    private static func descriptor(vertices: Int, indices: Int, hasTexcoords: Bool = false) -> LowLevelMesh.Descriptor {
        var attributes = [LowLevelMesh.Attribute(semantic: .position, format: .float3, layoutIndex: 0, offset: 0)]
        var layouts = [LowLevelMesh.Layout(bufferIndex: 0, bufferStride: GLTFDeformedVertex.stride)]
        if hasTexcoords {
            attributes.append(.init(semantic: .uv0, format: .float2, layoutIndex: 1, offset: 0))
            layouts.append(.init(bufferIndex: 1, bufferStride: MemoryLayout<SIMD2<Float>>.stride))
        }
        return LowLevelMesh.Descriptor(vertexCapacity: vertices, vertexAttributes: attributes, vertexLayouts: layouts,
                                       indexCapacity: indices, indexType: .uint32)
    }

    @Test
    func testAMeshIsLentAgainOnceItsLeaseIsGone() throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *), MTLCreateSystemDefaultDevice() != nil else { return }
        let pool = GLTFLowLevelMeshPool()
        var first: GLTFLowLevelMeshPool.Lease? = try pool.lease(Self.descriptor(vertices: 100, indices: 300))
        let held = try pool.lease(Self.descriptor(vertices: 100, indices: 300))
        let mesh = try #require(first?.mesh)
        #expect(held.mesh !== mesh)

        first = nil
        let again = try pool.lease(Self.descriptor(vertices: 100, indices: 300))
        #expect(again.mesh === mesh)
        #expect(again.mesh.parts.isEmpty)
    }

    @Test
    func testTheSmallestFreeMeshThatFitsIsLent() throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *), MTLCreateSystemDefaultDevice() != nil else { return }
        let pool = GLTFLowLevelMeshPool()
        var large: GLTFLowLevelMeshPool.Lease? = try pool.lease(Self.descriptor(vertices: 400, indices: 1200))
        var small: GLTFLowLevelMeshPool.Lease? = try pool.lease(Self.descriptor(vertices: 200, indices: 600))
        let largeMesh = try #require(large?.mesh), smallMesh = try #require(small?.mesh)
        large = nil
        small = nil

        let fitting = try pool.lease(Self.descriptor(vertices: 150, indices: 450))
        #expect(fitting.mesh === smallMesh)
        let tooLargeForSmall = try pool.lease(Self.descriptor(vertices: 300, indices: 450))
        #expect(tooLargeForSmall.mesh === largeMesh)
    }

    @Test
    func testAMeshOfAnotherLayoutIsNotLent() throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *), MTLCreateSystemDefaultDevice() != nil else { return }
        let pool = GLTFLowLevelMeshPool()
        var plain: GLTFLowLevelMeshPool.Lease? = try pool.lease(Self.descriptor(vertices: 100, indices: 300))
        let plainMesh = try #require(plain?.mesh)
        plain = nil

        let textured = try pool.lease(Self.descriptor(vertices: 100, indices: 300, hasTexcoords: true))
        #expect(textured.mesh !== plainMesh)
    }

    /// A loader's mesh templates are only cloned from, so a load borrows the meshes its
    /// entity draws and no more: one per model entity, its own for every entity loaded.
    @Test
    func testALoadBorrowsOnlyTheMeshesItsEntityDraws() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let loader = try VRMEntityLoader(withData: VRMSampleAsset.aliciaSolid.data, shaders: [])
        let first = try await loader.loadEntity()
        let second = try await loader.loadEntity()

        #expect(!loader.resources.meshTemplates.isEmpty)
        for template in loader.resources.meshTemplates.values {
            #expect(template.modelEntitiesInHierarchy.allSatisfy { $0.model == nil && $0.deformedMesh == nil })
        }
        let borrowed = [first, second].map { entity in
            entity.modelEntitiesInHierarchy.compactMap { $0.deformedMesh.map { ObjectIdentifier($0.lowLevelMesh) } }
        }
        #expect(!borrowed[0].isEmpty)
        #expect(borrowed[0].count == first.modelEntitiesInHierarchy.count)
        #expect(Set(borrowed[0]).count == borrowed[0].count)
        #expect(borrowed[1].count == borrowed[0].count)
        #expect(Set(borrowed[0]).isDisjoint(with: borrowed[1]))
    }
}
#endif
