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

    /// One primitive conditioned for the build: what the prepare pass made of it, or made
    /// on the spot for one it did not reach. Taken rather than read, since the build turns
    /// it into a `MeshResource` and holding it past that is a second copy of the model.
    func preparedPrimitive(forKey key: PrimitiveGeometryKey,
                           primitive: GLTF.Mesh.Primitive,
                           headJoints: Set<UInt32>) throws -> GLTFPreparedPrimitive? {
        if let prepared = prepared.primitives.removeValue(forKey: key) {
            guard let prepared else { return nil }
            if prepared.cutsHead == !headJoints.isEmpty { return prepared }
            // The other template of the same primitive: same vertices, its own cut.
            return GLTFPreparedPrimitive(geometry: prepared.geometry,
                                         cutsHead: !headJoints.isEmpty,
                                         firstPersonMask: Self.firstPersonMask(of: prepared.geometry, headJoints: headJoints),
                                         jointInfluences: prepared.jointInfluences)
        }
        guard let geometry = try geometryDecoder().decode(primitive, skinIndex: key.skinIndex) else { return nil }
        return try Self.conditioned(geometry, headJoints: headJoints)
    }

    /// What the build derives from a decoded primitive, computed off the actor: these
    /// walk every vertex or triangle, which costs as much as the decode itself.
    nonisolated static func conditioned(_ geometry: GLTFPrimitiveGeometry,
                                        headJoints: Set<UInt32>) throws -> GLTFPreparedPrimitive {
        GLTFPreparedPrimitive(geometry: geometry,
                              cutsHead: !headJoints.isEmpty,
                              firstPersonMask: firstPersonMask(of: geometry, headJoints: headJoints),
                              jointInfluences: geometry.isSkinned ? try jointInfluences(of: geometry) : nil)
    }

    private nonisolated static func firstPersonMask(of geometry: GLTFPrimitiveGeometry,
                                                    headJoints: Set<UInt32>) -> FirstPersonPrimitiveMask {
        FirstPersonAutoMask.mask(indices: geometry.indices,
                                 joints: geometry.joints,
                                 weights: geometry.weights,
                                 headJoints: headJoints)
    }

    /// A skinned primitive's vertex influences in the skin's joint order, four per vertex
    /// with the weights renormalized.
    private nonisolated static func jointInfluences(of geometry: GLTFPrimitiveGeometry) throws -> [MeshJointInfluence] {
        let joints = geometry.joints
        let weights = geometry.weights
        let remap = geometry.jointIndexRemap
        guard joints.count == weights.count else {
            throw VRMError._dataInconsistent("JOINTS_0 and WEIGHTS_0 counts do not match")
        }
        guard joints.count == geometry.positions.count else {
            throw VRMError._dataInconsistent("joint influence count \(joints.count) does not match vertex count \(geometry.positions.count)")
        }

        var influences: [MeshJointInfluence] = []
        influences.reserveCapacity(joints.count * 4)
        func remapped(_ jointIndex: UInt32) throws -> Int {
            guard remap.indices.contains(Int(jointIndex)) else {
                throw VRMError._dataInconsistent(
                    "joint index \(jointIndex) is out of range for \(remap.count) skin joints"
                )
            }
            return remap[Int(jointIndex)]
        }
        for i in 0..<joints.count {
            let joint = joints[i]
            var w0 = weights[i].x
            var w1 = weights[i].y
            var w2 = weights[i].z
            var w3 = weights[i].w
            let sum = w0 + w1 + w2 + w3
            if sum > 0 {
                w0 /= sum
                w1 /= sum
                w2 /= sum
                w3 /= sum
            }
            influences.append(MeshJointInfluence(jointIndex: try remapped(joint.x), weight: w0))
            influences.append(MeshJointInfluence(jointIndex: try remapped(joint.y), weight: w1))
            influences.append(MeshJointInfluence(jointIndex: try remapped(joint.z), weight: w2))
            influences.append(MeshJointInfluence(jointIndex: try remapped(joint.w), weight: w3))
        }
        return influences
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
            of: (PrimitiveGeometryKey, GLTFPreparedPrimitive?).self
        ) { group in
            for item in work {
                group.addTask {
                    try Task.checkCancellation()
                    guard let geometry = try decoder.decode(item.primitive, skinIndex: item.key.skinIndex) else {
                        return (item.key, nil)
                    }
                    return (item.key, try Self.conditioned(geometry, headJoints: item.headJoints))
                }
            }
            var results: [(PrimitiveGeometryKey, GLTFPreparedPrimitive?)] = []
            results.reserveCapacity(work.count)
            for try await result in group {
                results.append(result)
            }
            return results
        }
        for (key, primitive) in decoded {
            prepared.primitives[key] = primitive
        }
    }

    /// Every primitive the scene has still to build, paired with the skin it is drawn
    /// with. A mesh whose template the loader already holds is left out, since the build
    /// clones the template rather than reading a vertex of it.
    private func geometryWork() throws -> [(key: PrimitiveGeometryKey, primitive: GLTF.Mesh.Primitive, headJoints: Set<UInt32>)] {
        var work: [(key: PrimitiveGeometryKey, primitive: GLTF.Mesh.Primitive, headJoints: Set<UInt32>)] = []
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
                work.append((key, primitive, headJoints))
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
