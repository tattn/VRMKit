#if canImport(RealityKit)
import Foundation
import RealityKit
import VRMKit

/// Which primitive of which mesh, drawn with which skin. A mesh drawn by two
/// nodes with different skins reads the same accessors into different joint
/// influences, so the skin is part of the key.
struct PrimitiveGeometryKey: Hashable, Sendable {
    let meshIndex: Int
    let primitiveIndex: Int
    let skinIndex: Int?
}

@available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
extension GLTFEntityLoader {
    /// Resolved once, so that decoding a primitive needs no material or skin
    /// state of its own.
    func makeGeometryDecoder() throws -> GLTFGeometryDecoder {
        var texcoordSelections: [Int: GLTFGeometryDecoder.TexcoordSelection] = [:]
        var samplingNormalTexture: Set<Int> = []
        for index in (gltf.materials ?? []).indices {
            let resolved = resolvedTexCoord(withMaterialIndex: index)
            texcoordSelections[index] = .init(selected: resolved.selected, isMixed: resolved.isMixed)
            if materialSamplesNormalTexture(withMaterialIndex: index) {
                samplingNormalTexture.insert(index)
            }
        }
        var remaps: [Int: [Int]] = [:]
        for index in (gltf.skins ?? []).indices {
            remaps[index] = try skin(withSkinIndex: index).jointIndexRemap
        }
        return GLTFGeometryDecoder(accessors: accessors,
                                   texcoordSelections: texcoordSelections,
                                   materialsSamplingNormalTexture: samplingNormalTexture,
                                   jointIndexRemaps: remaps)
    }

    /// The geometry of one primitive: what the prepare pass decoded, or a decode
    /// on the spot for a primitive it did not reach. What the prepare pass left
    /// is taken rather than read, since the build turns it into a `MeshResource`
    /// and holding it past that is a second copy of the model.
    func decodedGeometry(forKey key: PrimitiveGeometryKey,
                         primitive: GLTF.Mesh.Primitive) throws -> GLTFPrimitiveGeometry? {
        if let prepared = entityData.primitiveGeometries.removeValue(forKey: key) { return prepared }
        return try geometryDecoder().decode(primitive, skinIndex: key.skinIndex)
    }

    private func geometryDecoder() throws -> GLTFGeometryDecoder {
        if let cached = entityData.geometryDecoder { return cached }
        let decoder = try makeGeometryDecoder()
        entityData.geometryDecoder = decoder
        return decoder
    }

    /// Decodes every primitive of the scene at `index` at once, so the build pass
    /// finds the vertex data already conditioned.
    ///
    /// Reading the accessors, triangulating, expanding a flat-shaded primitive and
    /// generating a tangent basis are the bulk of a load and touch neither
    /// RealityKit nor the scene graph, so they run off this actor. A primitive this
    /// renderer cannot decode fails the load here.
    func prepareGeometry(forSceneIndex index: Int) async throws {
        let work = try geometryWork(forSceneIndex: index)
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
            entityData.primitiveGeometries[key] = geometry
        }
    }

    /// Every primitive the scene has still to build, paired with the skin it is
    /// drawn with. A mesh whose template this loader already holds is left out:
    /// the build clones the template rather than reading a vertex of it.
    private func geometryWork(
        forSceneIndex index: Int
    ) throws -> [(key: PrimitiveGeometryKey, primitive: GLTF.Mesh.Primitive)] {
        let scene = try gltf.load(\.scenes, at: index)
        var work: [(key: PrimitiveGeometryKey, primitive: GLTF.Mesh.Primitive)] = []
        var seen: Set<PrimitiveGeometryKey> = []
        var stack = scene.nodes ?? []
        var visited: Set<Int> = []

        while let nodeIndex = stack.popLast() {
            guard visited.insert(nodeIndex).inserted,
                  let gltfNode = try? gltf.load(\.nodes, at: nodeIndex) else { continue }
            stack.append(contentsOf: gltfNode.children ?? [])
            guard let meshIndex = gltfNode.mesh,
                  let mesh = try? gltf.load(\.meshes, at: meshIndex) else { continue }
            // Building a skinned mesh builds its skin's joints, so whatever
            // hangs off one is drawn whether or not the scene names it.
            if let skinIndex = gltfNode.skin, let skin = try? gltf.load(\.skins, at: skinIndex) {
                stack.append(contentsOf: skin.joints)
            }
            let headJoints = firstPersonHeadJoints(ofNodeAt: nodeIndex,
                                                   meshIndex: meshIndex,
                                                   skinIndex: gltfNode.skin)
            let templateKey = EntityData.MeshTemplateKey(meshIndex: meshIndex,
                                                         skinIndex: gltfNode.skin,
                                                         cutsHead: !headJoints.isEmpty)
            guard entityData.meshTemplates[templateKey] == nil else { continue }
            for (primitiveIndex, primitive) in resolvedPrimitives(of: mesh).enumerated() {
                let key = PrimitiveGeometryKey(meshIndex: meshIndex,
                                               primitiveIndex: primitiveIndex,
                                               skinIndex: gltfNode.skin)
                guard seen.insert(key).inserted else { continue }
                work.append((key, primitive))
            }
        }
        return work
    }
}
#endif
