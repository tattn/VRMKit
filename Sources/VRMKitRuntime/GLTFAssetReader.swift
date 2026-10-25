#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import SIMDCompat
import VRMKit

/// Reads a document into ``GLTFAsset``: its structure validated, its skins ordered
/// parents first, and the vertex data of every mesh a scene draws decoded.
///
/// Everything it holds is resolved when it is made, so a read decodes the primitives of
/// a model at once, off whichever actor asked for them.
package struct GLTFAssetReader: Sendable {
    package let document: GLTFDocument
    package let profile: any GLTFAssetProfile
    package let hierarchy: GLTFNodeHierarchy
    package let skins: [GLTFAsset.Skin]
    package let decoder: GLTFGeometryDecoder
    private var gltf: GLTF { document.gltf }

    /// Which glTF mesh one node draws, and through which skin.
    package struct DrawnMesh: Sendable {
        package let nodeIndex: Int
        package let meshIndex: Int
        package let skinIndex: Int?
        package let mesh: GLTF.Mesh
    }

    /// One glTF mesh as rendered through one skin, cut for a first-person camera or not.
    /// A mesh used by both a skinned and an unskinned node, or drawn by two nodes VRM
    /// annotates differently, is one asset mesh each.
    package struct MeshKey: Hashable, Sendable {
        package let meshIndex: Int
        package let skinIndex: Int?
        package let cutsHead: Bool

        package init(meshIndex: Int, skinIndex: Int?, cutsHead: Bool) {
            self.meshIndex = meshIndex
            self.skinIndex = skinIndex
            self.cutsHead = cutsHead
        }
    }

    package init(document: GLTFDocument, profile: any GLTFAssetProfile) throws {
        self.document = document
        self.profile = profile
        let gltf = document.gltf
        let hierarchy = try GLTFNodeHierarchy.validatingStructure(of: gltf)
        self.hierarchy = hierarchy
        let accessors = PackedAccessorCache(document: document)
        skins = try gltf.skins.map { try Self.skin($0, gltf: gltf, accessors: accessors, hierarchy: hierarchy) }

        var texcoordSelections: [Int: GLTFGeometryDecoder.TexcoordSelection] = [:]
        var samplingNormalTexture: Set<Int> = []
        for (index, material) in gltf.materials.enumerated() {
            let resolved = Self.resolvedTexCoord(of: material)
            texcoordSelections[index] = .init(selected: resolved.selected, isMixed: resolved.isMixed)
            if Self.samplesNormalTexture(material,
                                         materialProperty: profile.vrm0MaterialProperty(atMaterialIndex: index)) {
                samplingNormalTexture.insert(index)
            }
        }
        decoder = GLTFGeometryDecoder(accessors: accessors,
                                      texcoordSelections: texcoordSelections,
                                      materialsSamplingNormalTexture: samplingNormalTexture,
                                      jointIndexRemaps: skins.map(\.jointIndexRemap).enumerated()
                                          .reduce(into: [:]) { $0[$1.offset] = $1.element })
    }

    // MARK: - The asset

    /// The scene at `sceneIndex`, every mesh it draws decoded concurrently.
    package func asset(sceneIndex: Int) async throws -> GLTFAsset {
        let decoded = try await meshes(for: try drawnMeshes(sceneIndex: sceneIndex), excluding: [])
        return try asset(sceneIndex: sceneIndex, meshes: decoded)
    }

    /// The scene at `sceneIndex` from meshes decoded before, decoding on the spot any it
    /// draws that `decoded` lacks. `cutoutsDrawnOpaque` holds the MASK materials a reader of
    /// the images found to discard nothing (``GLTFMaterialData/resolvedAlphaMode``).
    package func asset(sceneIndex: Int, meshes decoded: [MeshKey: BuiltMesh],
                       cutoutsDrawnOpaque: Set<Int> = []) throws -> GLTFAsset {
        let scene = try gltf.load(\.scenes, at: sceneIndex)
        let roots = scene.nodes ?? []
        try hierarchy.validateSceneRoots(roots, sceneIndex: sceneIndex)

        var meshes: [GLTFAsset.Mesh] = []
        var indicesByKey: [MeshKey: Int] = [:]
        var meshIndicesByNode: [Int: Int] = [:]
        var warnings: [GLTFGeometryWarning] = []
        for item in try drawnMeshes(sceneIndex: sceneIndex) {
            let key = meshKey(forNodeAt: item.nodeIndex, meshIndex: item.meshIndex, skinIndex: item.skinIndex)
            if indicesByKey[key] == nil {
                let built = try decoded[key] ?? mesh(key, nodeIndex: item.nodeIndex)
                indicesByKey[key] = meshes.count
                meshes.append(built.mesh)
                warnings += built.warnings
            }
            meshIndicesByNode[item.nodeIndex] = indicesByKey[key]
        }
        let materials = materials(cutoutsDrawnOpaque: cutoutsDrawnOpaque)
        return GLTFAsset(document: document,
                         vrm: (profile as? VRMAssetProfile)?.vrm,
                         hierarchy: hierarchy,
                         sceneIndex: sceneIndex,
                         rootNodes: roots,
                         nodes: try nodes(),
                         skins: skins,
                         meshes: meshes,
                         meshIndicesByNode: meshIndicesByNode,
                         materials: materials,
                         images: images(sampledBy: materials),
                         warnings: warnings)
    }

    package func materials(cutoutsDrawnOpaque: Set<Int> = []) -> [GLTFMaterialData] {
        gltf.materials.enumerated().map { index, material in
            GLTFMaterialData(index: index,
                             material: material,
                             materialProperty: profile.vrm0MaterialProperty(atMaterialIndex: index),
                             drawsCutoutOpaque: cutoutsDrawnOpaque.contains(index))
        }
    }

    private func images(sampledBy materials: [GLTFMaterialData]) -> [GLTFImageSource] {
        var usages = [Set<GLTFImageSource.Usage>](repeating: [], count: gltf.images.count)
        for material in materials {
            for (texture, usage) in material.sampledTextures {
                // A texture taking its image from an unread extension draws nothing of it.
                guard let image = try? gltf.imageIndex(ofTextureAt: texture.index),
                      usages.indices.contains(image) else { continue }
                usages[image].insert(usage)
            }
        }
        return usages.indices.map { GLTFImageSource(index: $0, document: document, usages: usages[$0]) }
    }

    private func nodes() throws -> [GLTFAsset.Node] {
        try gltf.nodes.enumerated().map { index, node in
            GLTFAsset.Node(name: node.name ?? "node_\(index)",
                           parent: hierarchy.parent(at: index),
                           children: node.children ?? [],
                           restTransform: GLTFNodeTransform(node: node),
                           mesh: node.mesh,
                           skin: node.skin,
                           initialMorphWeights: try node.mesh.flatMap { try initialMorphWeights(of: node, meshIndex: $0) })
        }
    }

    /// The spec's starting morph state, `node.weights` falling back to `mesh.weights`.
    /// Both must be sized by the mesh's morph target count.
    package func initialMorphWeights(of node: GLTF.Node, meshIndex: Int) throws -> [Float]? {
        let targetCount = try morphTargetCount(ofMeshAt: meshIndex)
        func validated(_ weights: [Float]?, _ source: @autoclosure () -> String) throws -> [Float]? {
            guard let weights else { return nil }
            guard weights.count == targetCount else {
                throw VRMError._dataInconsistent(
                    "\(source()) holds \(weights.count) weights but mesh \(meshIndex) has \(targetCount) morph targets"
                )
            }
            return weights
        }
        let meshWeights = try validated(gltf.load(\.meshes, at: meshIndex).weights, "mesh \(meshIndex)")
        let nodeWeights = try validated(node.weights, "a node rendering mesh \(meshIndex)")
        return nodeWeights ?? meshWeights
    }

    // MARK: - Meshes

    /// Every mesh the scene draws, at the node drawing it: a mesh drawn by two nodes with
    /// different skins is two.
    package func drawnMeshes(sceneIndex: Int) throws -> [DrawnMesh] {
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

    /// The joints of `skinIndex` whose triangles a first-person camera drops from the mesh
    /// the node at `nodeIndex` draws. Empty for a plain glTF.
    package func headJoints(ofNodeAt nodeIndex: Int, meshIndex: Int, skinIndex: Int?) -> Set<UInt32> {
        profile.headJoints(ofNodeAt: nodeIndex, meshIndex: meshIndex, skinIndex: skinIndex, hierarchy: hierarchy)
    }

    package func meshKey(forNodeAt nodeIndex: Int, meshIndex: Int, skinIndex: Int?) -> MeshKey {
        MeshKey(meshIndex: meshIndex,
                skinIndex: skinIndex,
                cutsHead: !headJoints(ofNodeAt: nodeIndex, meshIndex: meshIndex, skinIndex: skinIndex).isEmpty)
    }

    /// A mesh and what decoding it ran into.
    package struct BuiltMesh: Sendable {
        package let mesh: GLTFAsset.Mesh
        package let warnings: [GLTFGeometryWarning]
    }

    /// The meshes `drawn` names but `existing` does not hold, their primitives decoded
    /// concurrently.
    package func meshes(for drawn: [DrawnMesh], excluding existing: Set<MeshKey>) async throws -> [MeshKey: BuiltMesh] {
        var work: [(key: MeshKey, drawn: DrawnMesh, headJoints: Set<UInt32>)] = []
        var seen = existing
        for item in drawn {
            let headJoints = headJoints(ofNodeAt: item.nodeIndex, meshIndex: item.meshIndex, skinIndex: item.skinIndex)
            let key = MeshKey(meshIndex: item.meshIndex, skinIndex: item.skinIndex, cutsHead: !headJoints.isEmpty)
            guard seen.insert(key).inserted else { continue }
            work.append((key, item, headJoints))
        }
        guard !work.isEmpty else { return [:] }

        // Every primitive of every mesh at once: reading the accessors, triangulating and
        // generating a tangent basis are the bulk of a load.
        struct PrimitiveKey: Hashable {
            let mesh: Int
            let primitive: Int
        }
        let decoder = decoder
        let decoded = try await withThrowingTaskGroup(of: (PrimitiveKey, GLTFPreparedPrimitive?).self) { group in
            for (meshOffset, item) in work.enumerated() {
                for (primitiveIndex, primitive) in profile.resolvedPrimitives(of: item.drawn.mesh).enumerated() {
                    let headJoints = item.headJoints
                    let skinIndex = item.key.skinIndex
                    group.addTask {
                        try Task.checkCancellation()
                        let key = PrimitiveKey(mesh: meshOffset, primitive: primitiveIndex)
                        guard let geometry = try decoder.decode(primitive, skinIndex: skinIndex) else { return (key, nil) }
                        return (key, try Self.conditioned(geometry, headJoints: headJoints))
                    }
                }
            }
            var results: [PrimitiveKey: GLTFPreparedPrimitive?] = [:]
            for try await (key, primitive) in group {
                results[key] = primitive
            }
            return results
        }

        var meshes: [MeshKey: BuiltMesh] = [:]
        for (meshOffset, item) in work.enumerated() {
            let primitives = profile.resolvedPrimitives(of: item.drawn.mesh)
            meshes[item.key] = try mesh(item.key,
                                        gltfMesh: item.drawn.mesh,
                                        primitives: primitives.indices.map {
                                            (primitives[$0], decoded[PrimitiveKey(mesh: meshOffset, primitive: $0)] ?? nil)
                                        })
        }
        return meshes
    }

    /// One mesh decoded on the spot, for a node no read reached.
    package func mesh(_ key: MeshKey, nodeIndex: Int) throws -> BuiltMesh {
        let gltfMesh = try gltf.load(\.meshes, at: key.meshIndex)
        let headJoints = headJoints(ofNodeAt: nodeIndex, meshIndex: key.meshIndex, skinIndex: key.skinIndex)
        return try mesh(key, gltfMesh: gltfMesh, primitives: profile.resolvedPrimitives(of: gltfMesh).map { primitive in
            let geometry = try decoder.decode(primitive, skinIndex: key.skinIndex)
            return (primitive, try geometry.map { try Self.conditioned($0, headJoints: headJoints) })
        })
    }

    /// Lays the drawable primitives of a mesh out as one vertex array, one slot each.
    private func mesh(_ key: MeshKey,
                      gltfMesh: GLTF.Mesh,
                      primitives: [(GLTF.Mesh.Primitive, GLTFPreparedPrimitive?)]) throws -> BuiltMesh {
        var drawable: [GLTFPreparedPrimitive] = []
        var materialIndices: [Int?] = []
        var warnings: [GLTFGeometryWarning] = []
        for (primitive, prepared) in primitives {
            guard let prepared else {
                warnings.append(GLTFGeometryWarning(key: "primitiveMode-\(primitive.mode)", message: """
                    A \(primitive.mode) primitive was skipped; only triangles are drawn.
                    """))
                continue
            }
            warnings += prepared.geometry.warnings
            drawable.append(prepared)
            materialIndices.append(primitive.material)
        }
        // A skinned mesh's primitives all bind the one skin the node names, so the
        // merged slots share it.
        let isSkinned = key.skinIndex != nil && drawable.contains { $0.jointInfluences != nil }
        let geometry = GLTFMeshGeometry(primitives: drawable,
                                        isSkinned: isSkinned,
                                        blendShapeTargetCount: try morphTargetCount(ofMeshAt: key.meshIndex))
        return BuiltMesh(mesh: GLTFAsset.Mesh(name: gltfMesh.name ?? "mesh_\(key.meshIndex)",
                                              meshIndex: key.meshIndex,
                                              skinIndex: isSkinned ? key.skinIndex : nil,
                                              cutsHead: key.cutsHead,
                                              geometry: geometry,
                                              materialIndices: materialIndices),
                         warnings: warnings)
    }

    /// The number of morph targets the mesh at `index` renders with, one per weight in
    /// any array driving it. A primitive declaring no target of its own does not take part.
    package func morphTargetCount(ofMeshAt index: Int) throws -> Int {
        var targetCount = 0
        for primitive in profile.resolvedPrimitives(of: try gltf.load(\.meshes, at: index)) {
            let count = primitive.targets?.count ?? 0
            guard count > 0 else { continue }
            guard targetCount == 0 || targetCount == count else {
                throw VRMError._dataInconsistent(
                    "the primitives of mesh \(index) declare \(targetCount) and \(count) morph targets, but a mesh's primitives must all declare the same number"
                )
            }
            targetCount = count
        }
        return targetCount
    }

    /// What a mesh derives from a decoded primitive. These walk every vertex or triangle,
    /// which costs as much as the decode itself.
    package static func conditioned(_ geometry: GLTFPrimitiveGeometry,
                                    headJoints: Set<UInt32>) throws -> GLTFPreparedPrimitive {
        GLTFPreparedPrimitive(geometry: geometry,
                              cutsHead: !headJoints.isEmpty,
                              firstPersonMask: firstPersonMask(of: geometry, headJoints: headJoints),
                              jointInfluences: geometry.isSkinned ? try jointInfluences(of: geometry) : nil)
    }

    package static func firstPersonMask(of geometry: GLTFPrimitiveGeometry,
                                        headJoints: Set<UInt32>) -> FirstPersonPrimitiveMask {
        FirstPersonAutoMask.mask(indices: geometry.indices,
                                 joints: geometry.joints,
                                 weights: geometry.weights,
                                 headJoints: headJoints)
    }

    /// A skinned primitive's vertex influences in the skin's joint order, four per vertex
    /// with the weights renormalized.
    private static func jointInfluences(of geometry: GLTFPrimitiveGeometry) throws -> GLTFJointInfluences {
        let joints = geometry.joints
        let weights = geometry.weights
        let remap = geometry.jointIndexRemap
        guard joints.count == weights.count else {
            throw VRMError._dataInconsistent("JOINTS_0 and WEIGHTS_0 counts do not match")
        }
        guard joints.count == geometry.positions.count else {
            throw VRMError._dataInconsistent("joint influence count \(joints.count) does not match vertex count \(geometry.positions.count)")
        }

        var remappedJoints: [SIMD4<UInt32>] = []
        var normalizedWeights: [SIMD4<Float>] = []
        remappedJoints.reserveCapacity(joints.count)
        normalizedWeights.reserveCapacity(joints.count)
        func remapped(_ jointIndex: UInt32) throws -> UInt32 {
            guard remap.indices.contains(Int(jointIndex)) else {
                throw VRMError._dataInconsistent(
                    "joint index \(jointIndex) is out of range for \(remap.count) skin joints"
                )
            }
            return UInt32(remap[Int(jointIndex)])
        }
        for i in 0..<joints.count {
            let joint = joints[i]
            var weight = weights[i]
            let sum = weight.sum()
            if sum > 0 {
                weight /= sum
            }
            remappedJoints.append(SIMD4(try remapped(joint.x), try remapped(joint.y),
                                        try remapped(joint.z), try remapped(joint.w)))
            normalizedWeights.append(weight)
        }
        return GLTFJointInfluences(joints: remappedJoints, weights: normalizedWeights)
    }

    // MARK: - Skins

    private static func skin(_ skin: GLTF.Skin,
                             gltf: GLTF,
                             accessors: PackedAccessorCache,
                             hierarchy: GLTFNodeHierarchy) throws -> GLTFAsset.Skin {
        let (parentIndices, order, remap) = jointOrdering(of: skin, hierarchy: hierarchy)

        // glTF defines an absent inverseBindMatrices as identity per joint, but a present
        // one has to cover every joint.
        let inverseBindMatrices: [simd_float4x4]
        if let accessorIndex = skin.inverseBindMatrices {
            inverseBindMatrices = try accessors.accessor(at: accessorIndex).float4x4Elements()
            guard inverseBindMatrices.count >= skin.joints.count else {
                throw VRMError._dataInconsistent(
                    "inverseBindMatrices has \(inverseBindMatrices.count) elements for \(skin.joints.count) skin joints"
                )
            }
        } else {
            inverseBindMatrices = Array(repeating: matrix_identity_float4x4, count: skin.joints.count)
        }
        return GLTFAsset.Skin(joints: order.map { skin.joints[$0] },
                              parents: order.map { parentIndices[$0].map { remap[$0] } },
                              inverseBindMatrices: order.map { inverseBindMatrices[$0] },
                              jointIndexRemap: remap)
    }

    /// Orders the joints so every one follows its parent: a joint's parent is the nearest
    /// ancestor node the skin names.
    private static func jointOrdering(of skin: GLTF.Skin,
                                      hierarchy: GLTFNodeHierarchy) -> (parentIndices: [Int?], order: [Int], remap: [Int]) {
        let jointNodeIndices = skin.joints
        // A node the skin names twice hangs its children off its first entry; the other
        // is a leaf under the same parent, so both are posed where the node is.
        let jointIndexMap = Dictionary(jointNodeIndices.enumerated().map { ($0.element, $0.offset) },
                                       uniquingKeysWith: { first, _ in first })
        var parentIndices: [Int?] = Array(repeating: nil, count: jointNodeIndices.count)
        for (i, nodeIndex) in jointNodeIndices.enumerated() {
            // The validated hierarchy is a forest, so walking up terminates.
            var current = nodeIndex
            while let parent = hierarchy.parent(at: current) {
                if let jointIndex = jointIndexMap[parent] {
                    parentIndices[i] = jointIndex
                    break
                }
                current = parent
            }
        }

        var children: [[Int]] = Array(repeating: [], count: jointNodeIndices.count)
        for (i, parent) in parentIndices.enumerated() {
            if let parent = parent {
                children[parent].append(i)
            }
        }

        var order: [Int] = []
        order.reserveCapacity(jointNodeIndices.count)
        func visit(_ index: Int) {
            order.append(index)
            for child in children[index] {
                visit(child)
            }
        }

        // The validated hierarchy is a forest, so visiting every root reaches every joint.
        let roots = parentIndices.enumerated().compactMap { $0.element == nil ? $0.offset : nil }
        for root in roots {
            visit(root)
        }

        var remap: [Int] = Array(repeating: 0, count: jointNodeIndices.count)
        for (newIndex, oldIndex) in order.enumerated() {
            remap[oldIndex] = newIndex
        }

        return (parentIndices, order, remap)
    }

    // MARK: - Materials

    /// The textures a standard material, MToon aside, samples through mesh UVs, in the
    /// order the glTF material declares them.
    package static func sampledTextures(of material: GLTF.Material) -> [GLTFSampledTexture] {
        var textures: [GLTFSampledTexture] = []
        if let pbr = material.pbrMetallicRoughness {
            if let info = pbr.baseColorTexture { textures.append(GLTFSampledTexture(info)) }
            if let info = pbr.metallicRoughnessTexture { textures.append(GLTFSampledTexture(info)) }
        }
        if let info = material.normalTexture { textures.append(GLTFSampledTexture(info)) }
        if let info = material.occlusionTexture { textures.append(GLTFSampledTexture(info)) }
        if let info = material.emissiveTexture { textures.append(GLTFSampledTexture(info)) }
        return textures
    }

    /// The UV set the meshes drawing `material` carry, and whether its textures disagree
    /// about it. A mesh carries a single UV channel, so the first UV-accessed texture
    /// decides it.
    package static func resolvedTexCoord(of material: GLTF.Material) -> (selected: Int, isMixed: Bool) {
        let textures = sampledTextures(of: material)
        return (selected: textures.first?.texCoord ?? 0,
                isMixed: textures.contains { $0.texCoord != textures.first?.texCoord })
    }

    /// Whether the material samples a normal map, which decides whether a primitive without
    /// `TANGENT` needs a tangent basis generating. The MToon descriptor is asked first
    /// because VRM 0.x carries its normal map in Unity's `_BumpMap`.
    package static func samplesNormalTexture(_ material: GLTF.Material,
                                             materialProperty: VRM0.MaterialProperty?) -> Bool {
        let resolution = MToonMaterialDescriptor.resolve(material: material, materialProperty: materialProperty)
        if let descriptor = resolution.descriptor, descriptor.normalTexture != nil {
            return true
        }
        return material.normalTexture != nil
    }
}
