#if canImport(RealityKit)
import Foundation
import RealityKit
import VRMKit

/// Which primitive of which mesh, drawn with which skin. A mesh drawn by two nodes with
/// different skins reads the same accessors into different joint influences, so the
/// skin is part of the key.
struct PrimitiveGeometryKey: Hashable, Sendable {
    let meshIndex: Int
    let primitiveIndex: Int
    let skinIndex: Int?
}

@available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
extension GLTFSceneBuilder {
    /// Resolved once, so decoding a primitive needs no material or skin state of its own.
    func makeGeometryDecoder() throws -> GLTFGeometryDecoder {
        var texcoordSelections: [Int: GLTFGeometryDecoder.TexcoordSelection] = [:]
        var samplingNormalTexture: Set<Int> = []
        for index in (gltf.materials).indices {
            let resolved = resolvedTexCoord(withMaterialIndex: index)
            texcoordSelections[index] = .init(selected: resolved.selected, isMixed: resolved.isMixed)
            if materialSamplesNormalTexture(withMaterialIndex: index) {
                samplingNormalTexture.insert(index)
            }
        }
        var remaps: [Int: [Int]] = [:]
        for index in (gltf.skins).indices {
            remaps[index] = try skin(withSkinIndex: index).jointIndexRemap
        }
        return GLTFGeometryDecoder(accessors: accessors,
                                   texcoordSelections: texcoordSelections,
                                   materialsSamplingNormalTexture: samplingNormalTexture,
                                   jointIndexRemaps: remaps)
    }

    /// The geometry of one primitive: what the prepare pass decoded, or a decode on the
    /// spot for one it did not reach. Taken rather than read, since the build turns it
    /// into a `MeshResource` and holding it past that is a second copy of the model.
    func decodedGeometry(forKey key: PrimitiveGeometryKey,
                         primitive: GLTF.Mesh.Primitive) throws -> GLTFPrimitiveGeometry? {
        if let decoded = prepared.geometries.removeValue(forKey: key) { return decoded }
        return try geometryDecoder().decode(primitive, skinIndex: key.skinIndex)
    }

    private func geometryDecoder() throws -> GLTFGeometryDecoder {
        if let cached = resolvedGeometryDecoder { return cached }
        let decoder = try makeGeometryDecoder()
        resolvedGeometryDecoder = decoder
        return decoder
    }

    /// Decodes every primitive of the scene at once, so the build pass finds the vertex
    /// data already conditioned.
    ///
    /// Reading the accessors, triangulating, expanding a flat-shaded primitive and
    /// generating a tangent basis are the bulk of a load and touch neither RealityKit nor
    /// the scene graph, so they run off this actor.
    func prepareGeometry() async throws {
        let work = try geometryWork()
        guard !work.isEmpty else { return }
        let decoder = try geometryDecoder()

        let decoded = try await withThrowingTaskGroup(
            of: (PrimitiveGeometryKey, GLTFPrimitiveGeometry?).self
        ) { group in
            for item in work {
                group.addTask {
                    try Task.checkCancellation()
                    return (item.key, try decoder.decode(item.primitive, skinIndex: item.key.skinIndex))
                }
            }
            var results: [(PrimitiveGeometryKey, GLTFPrimitiveGeometry?)] = []
            results.reserveCapacity(work.count)
            for try await result in group {
                results.append(result)
            }
            return results
        }
        for (key, geometry) in decoded {
            prepared.geometries[key] = geometry
        }
    }

    /// Every primitive the scene has still to build, paired with the skin it is drawn
    /// with. A mesh whose template the loader already holds is left out, since the build
    /// clones the template rather than reading a vertex of it.
    private func geometryWork() throws -> [(key: PrimitiveGeometryKey, primitive: GLTF.Mesh.Primitive)] {
        var work: [(key: PrimitiveGeometryKey, primitive: GLTF.Mesh.Primitive)] = []
        var seen: Set<PrimitiveGeometryKey> = []
        for drawn in try drawnMeshes() {
            let headJoints = try headJoints(ofNodeAt: drawn.nodeIndex,
                                            meshIndex: drawn.meshIndex,
                                            skinIndex: drawn.skinIndex)
            let templateKey = GLTFResourceCache.MeshTemplateKey(meshIndex: drawn.meshIndex,
                                                                skinIndex: drawn.skinIndex,
                                                                cutsHead: !headJoints.isEmpty)
            guard resources.meshTemplates[templateKey] == nil else { continue }
            for (primitiveIndex, primitive) in resolvedPrimitives(of: drawn.mesh).enumerated() {
                let key = PrimitiveGeometryKey(meshIndex: drawn.meshIndex,
                                               primitiveIndex: primitiveIndex,
                                               skinIndex: drawn.skinIndex)
                guard seen.insert(key).inserted else { continue }
                work.append((key, primitive))
            }
        }
        return work
    }

    /// One mesh the scene draws, at the node drawing it: a mesh drawn by two nodes with
    /// different skins is two.
    struct DrawnMesh {
        let nodeIndex: Int
        let meshIndex: Int
        let skinIndex: Int?
        let mesh: GLTF.Mesh
    }

    /// Every mesh this builder's scene draws, which is all a prepare pass has to
    /// condition.
    func drawnMeshes() throws -> [DrawnMesh] {
        let scene = try gltf.load(\.scenes, at: sceneIndex)
        var meshes: [DrawnMesh] = []
        var stack = scene.nodes ?? []
        var visited: Set<Int> = []

        while let nodeIndex = stack.popLast() {
            guard visited.insert(nodeIndex).inserted,
                  let gltfNode = try? gltf.load(\.nodes, at: nodeIndex) else { continue }
            stack.append(contentsOf: gltfNode.children ?? [])
            guard let meshIndex = gltfNode.mesh,
                  let mesh = try? gltf.load(\.meshes, at: meshIndex) else { continue }
            // Building a skinned mesh builds its skin's joints, so whatever hangs off one
            // is drawn whether or not the scene names it.
            if let skinIndex = gltfNode.skin, let skin = try? gltf.load(\.skins, at: skinIndex) {
                stack.append(contentsOf: skin.joints)
            }
            meshes.append(DrawnMesh(nodeIndex: nodeIndex,
                                    meshIndex: meshIndex,
                                    skinIndex: gltfNode.skin,
                                    mesh: mesh))
        }
        return meshes
    }
}
#endif
