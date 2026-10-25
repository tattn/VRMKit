#if canImport(RealityKit)
import Metal
import RealityKit

/// The `LowLevelMesh`es every deformed mesh in the process draws, each lent to one
/// ``GLTFDeformedMesh`` at a time.
///
/// On iOS devices RealityKit never gives the memory of a released `LowLevelMesh` back, so
/// meshes made per load and per snapshot would pile up until the app runs out of memory.
/// A mesh whose lease is gone draws the next mesh of the same layout that fits in it instead.
@available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
@MainActor
final class GLTFLowLevelMeshPool {
    /// One mesh lent out, and the resource entities draw it through. The mesh returns to the
    /// pool once nothing holds the lease.
    final class Lease {
        let mesh: LowLevelMesh
        let resource: MeshResource

        fileprivate init(mesh: LowLevelMesh, resource: MeshResource) {
            self.mesh = mesh
            self.resource = resource
        }
    }

    private struct Entry {
        let mesh: LowLevelMesh
        let resource: MeshResource
        let layout: Layout
        weak var lease: Lease?
    }

    /// What two descriptors must share for a mesh made from one to draw the other.
    private struct Layout: Hashable {
        struct Attribute: Hashable {
            let semantic: LowLevelMesh.VertexSemantic
            let format: MTLVertexFormat
            let layoutIndex: Int
            let offset: Int
        }

        struct Buffer: Hashable {
            let index: Int
            let offset: Int
            let stride: Int
        }

        let attributes: [Attribute]
        let buffers: [Buffer]
        let indexType: MTLIndexType

        init(_ descriptor: LowLevelMesh.Descriptor) {
            attributes = descriptor.vertexAttributes.map {
                Attribute(semantic: $0.semantic, format: $0.format, layoutIndex: $0.layoutIndex, offset: $0.offset)
            }
            buffers = descriptor.vertexLayouts.map {
                Buffer(index: $0.bufferIndex, offset: $0.bufferOffset, stride: $0.bufferStride)
            }
            indexType = descriptor.indexType
        }
    }

    private var entries: [Entry] = []

    /// A mesh laid out as `descriptor` with at least its capacities, the smallest free one
    /// when the pool has any. It has no parts, as a new mesh, but its buffers hold whatever
    /// it last drew.
    func lease(_ descriptor: LowLevelMesh.Descriptor) throws -> Lease {
        let layout = Layout(descriptor)
        let fitting = entries.indices.filter {
            let entry = entries[$0]
            return entry.lease == nil && entry.layout == layout
                && entry.mesh.descriptor.vertexCapacity >= descriptor.vertexCapacity
                && entry.mesh.descriptor.indexCapacity >= descriptor.indexCapacity
        }
        if let index = fitting.min(by: {
            let lhs = entries[$0].mesh.descriptor, rhs = entries[$1].mesh.descriptor
            return (lhs.vertexCapacity, lhs.indexCapacity) < (rhs.vertexCapacity, rhs.indexCapacity)
        }) {
            let lease = Lease(mesh: entries[index].mesh, resource: entries[index].resource)
            lease.mesh.parts.replaceAll([])
            entries[index].lease = lease
            return lease
        }
        let mesh = try LowLevelMesh(descriptor: descriptor)
        let lease = Lease(mesh: mesh, resource: try MeshResource(from: mesh))
        entries.append(Entry(mesh: mesh, resource: lease.resource, layout: layout, lease: lease))
        return lease
    }
}
#endif
