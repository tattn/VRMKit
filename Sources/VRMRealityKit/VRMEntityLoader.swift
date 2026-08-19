#if canImport(RealityKit)
import CoreGraphics
import Foundation
import RealityKit
import Metal
import OSLog
import VRMKit
import VRMKitRuntime

@available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
@MainActor
open class VRMEntityLoader {
    public let vrm: VRM
    private let gltf: GLTF
    private let entityData: EntityData

    private var rootDirectory: URL? = nil
    private let entityName: String?
    private weak var currentEntity: VRMEntity?
    private static let logger = Logger(subsystem: "dev.tattn.VRMKit", category: "MToon")
    private var textureCacheBySemantic: [TextureResource.Semantic: [Int: TextureResource]] = [:]
    private var metallicRoughnessCache: [Int: (metal: TextureResource, rough: TextureResource)] = [:]
    private var samplerCache: [Int: MaterialParameters.Texture.Sampler] = [:]
    private var fallbackTextureCache: [MToonTextureSlot.Fallback: TextureResource] = [:]
    private var mtoonDescriptorCache: [Int: MToonMaterialDescriptor?] = [:]
#if !os(visionOS)
    /// Everything the RealityKit adapter derives from one MToon material. A
    /// non-nil state is what "this material renders as MToon" means, and it is
    /// shared by the surface material, the outline material and the parameters.
    private struct MToonState {
        let descriptor: MToonMaterialDescriptor
        let parameters: MToonMaterialParameters
        let parameterTexture: CustomMaterial.Texture
        let library: MTLLibrary
    }

    private var mtoonStateCache: [Int: MToonState?] = [:]
    private var mtoonOutlineMaterialCache: [Int: Material?] = [:]
#endif
    private var loggedMToonUVLimitations: Set<Int> = []
    private var loggedMToonLibraryError = false
    /// When `false`, MToon materials are not created and the loader falls back to Unlit / PBR materials.
    /// visionOS always uses the fallback because `CustomMaterial` is unavailable there.
    public let isMToonEnabled: Bool
    /// Controls creation of MToon's inverted-hull outline entities.
    /// visionOS does not create MToon outlines because `CustomMaterial` is unavailable there.
    public let isOutlineEnabled: Bool
    public init(vrm: VRM,
                rootDirectory: URL? = nil,
                isMToonEnabled: Bool = true,
                isOutlineEnabled: Bool = true) {
        self.vrm = vrm
        self.gltf = vrm.gltf.jsonData
        self.rootDirectory = rootDirectory
        self.entityName = vrm.meta.title
        self.entityData = EntityData(vrm: gltf)
        self.isMToonEnabled = isMToonEnabled
        self.isOutlineEnabled = isOutlineEnabled
    }

    public func loadEntity() throws -> VRMEntity {
        return try loadEntity(withSceneIndex: gltf.scene)
    }

    /// Loads one scene of the glTF as its own entity graph.
    ///
    /// Each scene builds its own entities, so a node shared by two scenes becomes
    /// a separate `Entity` in each. Buffers, materials and textures are reused.
    public func loadEntity(withSceneIndex index: Int) throws -> VRMEntity {
        if let cache = try entityData.load(\.entities, index: index) { return cache }
        let gltfScene = try gltf.load(\.scenes, at: index)
        entityData.beginScene()

        let vrmEntity = VRMEntity(vrm: vrm)
        if let entityName {
            vrmEntity.name = entityName
        }
        currentEntity = vrmEntity
        defer { currentEntity = nil }
        for node in gltfScene.nodes ?? [] {
            vrmEntity.addChild(try self.node(withNodeIndex: node))
        }
        vrmEntity.setUpHumanoid(nodes: entityData.nodes)
        try vrmEntity.setUpBlendShapes(nodes: entityData.nodes, meshes: entityData.meshes, loader: self)
        vrmEntity.setUpFirstPerson(nodes: entityData.nodes, meshes: entityData.meshes)
        try vrmEntity.setUpNodeConstraints(gltfNodes: try gltf.load(\.nodes), loader: self)
        try vrmEntity.setUpSpringBones(loader: self)
        // TODO: animations.

        entityData.entities[index] = vrmEntity
        return vrmEntity
    }

    public func loadThumbnail() throws -> VRMImage {
        let imageIndex = try vrm.thumbnailImageIndex
        if let cache = try entityData.load(\.images, index: imageIndex) { return cache }
        return try image(withImageIndex: imageIndex)
    }

    func node(withNodeIndex index: Int) throws -> Entity {
        if let cache = try entityData.load(\.nodes, index: index) { return cache }
        let gltfNode = try gltf.load(\.nodes, at: index)

        let entity = Entity()
        entity.name = gltfNode.name ?? "node_\(index)"

        if let cameraIndex = gltfNode.camera {
            try applyCamera(withCameraIndex: cameraIndex, to: entity)
        }

        if let meshIndex = gltfNode.mesh {
            let meshEntity = try mesh(withMeshIndex: meshIndex, skinIndex: gltfNode.skin)
            entity.addChild(meshEntity)
        }

        if let matrix = gltfNode._matrix {
            entity.transform = Transform(matrix: matrix.simdMatrix)
        } else {
            entity.transform.translation = gltfNode.translation.simd
            entity.transform.rotation = gltfNode.rotation.simdQuat
            entity.transform.scale = gltfNode.scale.simd
        }

        for child in gltfNode.children ?? [] {
            entity.addChild(try node(withNodeIndex: child))
        }

        entityData.nodes[index] = entity
        return entity
    }

    private func applyCamera(withCameraIndex index: Int, to entity: Entity) throws {
        let gltfCamera = try gltf.load(\.cameras, at: index)
        switch gltfCamera.type {
        case .perspective:
            let perspective = try gltfCamera.perspective ??? .keyNotFound("perspective")
            let fovDegrees: Float
            let fovOrientation: CameraFieldOfViewOrientation
            if let aspectRatio = perspective.aspectRatio, aspectRatio > 0 {
                let yFov = perspective.yfov
                let xFov = 2 * atan(tan(yFov * 0.5) * aspectRatio)
                fovDegrees = xFov * 180 / .pi
                fovOrientation = .horizontal
            } else {
                fovDegrees = perspective.yfov * 180 / .pi
                fovOrientation = .vertical
            }
            var component = PerspectiveCameraComponent(near: perspective.znear,
                                                       far: perspective.zfar ?? .infinity,
                                                       fieldOfViewInDegrees: fovDegrees)
            component.fieldOfViewOrientation = fovOrientation
            entity.components.set(component)
        case .orthographic:
            let orthographic = try gltfCamera.orthographic ??? .keyNotFound("orthographic")
            var component = OrthographicCameraComponent()
            component.near = orthographic.znear
            component.far = orthographic.zfar
            component.scale = orthographic.ymag
            component.scaleDirection = .vertical
            entity.components.set(component)
        }
    }

    func mesh(withMeshIndex index: Int, skinIndex: Int?) throws -> Entity {
        if skinIndex == nil, let cache = try entityData.load(\.meshes, index: index) {
            let clone = cache.clone(recursive: true)
            registerMaterialBindings(in: clone)
            return clone
        }

        let gltfMesh = try gltf.load(\.meshes, at: index)
        let meshEntity = Entity()
        meshEntity.name = gltfMesh.name ?? "mesh_\(index)"

        // Some VRM meshes split primitives by indices but share the same POSITION accessor.
        // SceneKit reuses the morpher across such primitives, so mimic that by sharing targets.
        let targetsByPositionAccessor: [Int: [[GLTF.Mesh.Primitive.AttributeKey: Int]]] = {
            var result: [Int: [[GLTF.Mesh.Primitive.AttributeKey: Int]]] = [:]
            for primitive in gltfMesh.primitives {
                guard let targets = primitive.targets, !targets.isEmpty else { continue }
                if let positionAccessor = primitive.attributes.rawValue[.POSITION],
                   result[positionAccessor] == nil {
                    result[positionAccessor] = targets
                }
            }
            return result
        }()

        for primitive in gltfMesh.primitives {
            var resolvedPrimitive = primitive
            if (resolvedPrimitive.targets?.isEmpty ?? true),
               let positionAccessor = resolvedPrimitive.attributes.rawValue[.POSITION],
               let sharedTargets = targetsByPositionAccessor[positionAccessor] {
                resolvedPrimitive.targets = sharedTargets
            }
            if let primitiveEntity = try modelEntity(withPrimitive: resolvedPrimitive, skinIndex: skinIndex) {
                meshEntity.addChild(primitiveEntity)
            }
        }

        if skinIndex == nil {
            entityData.meshes[index] = meshEntity
            let clone = meshEntity.clone(recursive: true)
            registerMaterialBindings(in: clone)
            return clone
        }
        if entityData.meshes.indices.contains(index), entityData.meshes[index] == nil {
            entityData.meshes[index] = meshEntity
        }
        registerMaterialBindings(in: meshEntity)
        return meshEntity
    }

    private func modelEntity(withPrimitive primitive: GLTF.Mesh.Primitive, skinIndex: Int?) throws -> Entity? {
        guard supportsTriangles(primitive.mode) else { return nil }

        let attributes = primitive.attributes.rawValue
        guard let positionIndex = attributes[.POSITION] else {
            throw VRMError._dataInconsistent("POSITION attribute is missing")
        }

        let positions = try vector3s(positionIndex)

        // glTF requires every vertex attribute of a primitive to hold as many
        // elements as POSITION, and nothing downstream re-checks it.
        func vertexAttribute<Element>(_ key: GLTF.Mesh.Primitive.AttributeKey,
                                      _ read: (Int) throws -> [Element]) throws -> [Element]? {
            guard let accessorIndex = attributes[key] else { return nil }
            let values = try read(accessorIndex)
            guard values.count == positions.count else {
                throw VRMError._dataInconsistent(
                    "\(key) has \(values.count) elements but POSITION has \(positions.count)"
                )
            }
            return values
        }

        let normals = try vertexAttribute(.NORMAL, vector3s)
        let rawTangents = try vertexAttribute(.TANGENT, vector4s)
        let texcoords = try vertexAttribute(.TEXCOORD_0, vector2s)
        let jointRemap: [Int]? = {
            guard let skinIndex else { return nil }
            return try? jointIndexRemap(forSkinIndex: skinIndex)
        }()
        let skinJointInfluences: ([SIMD4<UInt32>], [SIMD4<Float>])? = try {
            guard skinIndex != nil,
                  let joints = try vertexAttribute(.JOINTS_0, jointIndices),
                  let weights = try vertexAttribute(.WEIGHTS_0, jointWeights) else {
                return nil
            }
            return (joints, weights)
        }()
        // Only POSITION morphs are applied: RealityKit blend shapes drive vertex
        // positions, and NORMAL / TANGENT targets have no equivalent channel.
        var targetOffsets: [[SIMD3<Float>]] = []
        if let targets = primitive.targets, !targets.isEmpty {
            targetOffsets.reserveCapacity(targets.count)
            for target in targets {
                if let positionAccessor = target[.POSITION] {
                    let offsets = try vector3s(positionAccessor)
                    guard offsets.count == positions.count else {
                        throw VRMError._dataInconsistent("blend shape target count \(offsets.count) does not match vertex count \(positions.count)")
                    }
                    targetOffsets.append(offsets)
                } else {
                    targetOffsets.append(Array(repeating: .zero, count: positions.count))
                }
            }
        }

        var indexData: [UInt32]
        if let indicesAccessor = primitive.indices {
            indexData = try indexValues(indicesAccessor)
        } else {
            indexData = (0..<positions.count).map { UInt32($0) }
        }
        indexData = try triangulatedIndices(for: primitive.mode, indices: indexData)
        // Validated once here so every consumer below — normal estimation, the
        // mesh resource, blend-shape offsets — can index positions directly.
        if let maxIndex = indexData.max(), Int(maxIndex) >= positions.count {
            throw VRMError._dataInconsistent(
                "triangle index \(maxIndex) is out of range for \(positions.count) vertices"
            )
        }

        // NORMAL is optional in glTF; everything else is used as-is.
        let finalNormals = normals ?? smoothNormals(positions: positions, indices: indexData)
        let finalTexcoords = texcoords ?? []
        let tangentFrame = tangentFrame(rawTangents: rawTangents,
                                        positions: positions,
                                        normals: finalNormals,
                                        texcoords: finalTexcoords,
                                        indices: indexData,
                                        materialIndex: primitive.material)
        let finalJoints = skinJointInfluences?.0 ?? []
        let finalWeights = skinJointInfluences?.1 ?? []

        // One unbuildable material must not fail the whole model: the primitive
        // renders with the default material instead.
        let material = primitive.material.flatMap { materialIndex -> Material? in
            do {
                return try self.material(withMaterialIndex: materialIndex)
            } catch {
                Self.logger.error("Failed to build the material \(materialIndex, privacy: .public); falling back to the default material: \(String(describing: error), privacy: .public)")
                return nil
            }
        } ?? defaultMaterial()

        let hasSkinning = skinIndex != nil && !finalJoints.isEmpty
        let hasBlendShapes = !targetOffsets.isEmpty
        let mesh: MeshResource
        var boundSkeleton: MeshResource.Skeleton?
        if let skinIndex, hasSkinning {
            let influences = try makeJointInfluences(joints: finalJoints,
                                                     weights: finalWeights,
                                                     vertexCount: positions.count,
                                                     jointIndexRemap: jointRemap)
            let skinSkeleton = try skeleton(withSkinIndex: skinIndex)
            mesh = try meshResource(positions: positions,
                                    normals: finalNormals,
                                    tangentFrame: tangentFrame,
                                    texcoords: finalTexcoords,
                                    indices: indexData,
                                    blendShapeOffsets: targetOffsets,
                                    skeleton: skinSkeleton,
                                    jointInfluences: influences)
            boundSkeleton = skinSkeleton
        } else {
            mesh = try meshResource(positions: positions,
                                    normals: finalNormals,
                                    tangentFrame: tangentFrame,
                                    texcoords: finalTexcoords,
                                    indices: indexData,
                                    blendShapeOffsets: targetOffsets,
                                    skeleton: nil,
                                    jointInfluences: nil)
        }

        // The blend-shape mapping is derived from the mesh, so the model entity
        // and its outline twin share one instance.
        let blendShapeMapping = hasBlendShapes ? BlendShapeWeightsMapping(meshResource: mesh) : nil

        func makeEntity(materials: [Material]) throws -> ModelEntity {
            let entity = ModelEntity(mesh: mesh, materials: materials)
            if let materialIndex = primitive.material {
                entity.components.set(VRMMaterialIndexComponent(materialIndex: materialIndex))
            }
            if let blendShapeMapping {
                entity.components.set(BlendShapeWeightsComponent(weightsMapping: blendShapeMapping))
            }
            if let skinIndex, let boundSkeleton {
                try registerSkinBinding(modelEntity: entity, skinIndex: skinIndex, skeleton: boundSkeleton)
            }
            return entity
        }

        let modelEntity = try makeEntity(materials: [material])
        if let materialIndex = primitive.material,
           let outlineMaterial = try mtoonOutlineMaterial(withMaterialIndex: materialIndex) {
            let outlineEntity = try makeEntity(materials: [outlineMaterial])
            outlineEntity.name = "\(modelEntity.name)_outline"
            let container = Entity()
            container.name = "\(modelEntity.name)_container"
            container.addChild(outlineEntity)
            container.addChild(modelEntity)
            return container
        }
        return modelEntity
    }

    private func supportsTriangles(_ mode: GLTF.Mesh.Primitive.Mode) -> Bool {
        switch mode {
        case .TRIANGLES, .TRIANGLE_STRIP, .TRIANGLE_FAN:
            return true
        case .POINTS, .LINES, .LINE_LOOP, .LINE_STRIP:
            return false
        }
    }

    /// glTF requires a TRIANGLES primitive to hold a non-zero multiple of three
    /// indices and a strip / fan to hold at least three, so a primitive that does
    /// not fails the load rather than being quietly trimmed into a valid one.
    private func triangulatedIndices(for mode: GLTF.Mesh.Primitive.Mode,
                                     indices: [UInt32]) throws -> [UInt32] {
        switch mode {
        case .TRIANGLES:
            guard !indices.isEmpty, indices.count.isMultiple(of: 3) else {
                throw VRMError._dataInconsistent(
                    "a TRIANGLES primitive needs a non-zero multiple of 3 indices, but has \(indices.count)"
                )
            }
            return indices
        case .TRIANGLE_STRIP:
            guard indices.count >= 3 else {
                throw VRMError._dataInconsistent(
                    "a TRIANGLE_STRIP primitive needs at least 3 indices, but has \(indices.count)"
                )
            }
            var result: [UInt32] = []
            result.reserveCapacity((indices.count - 2) * 3)
            for i in 0..<(indices.count - 2) {
                let i0 = indices[i]
                let i1 = indices[i + 1]
                let i2 = indices[i + 2]
                if i.isMultiple(of: 2) {
                    result.append(contentsOf: [i0, i1, i2])
                } else {
                    result.append(contentsOf: [i1, i0, i2])
                }
            }
            return result
        case .TRIANGLE_FAN:
            guard indices.count >= 3 else {
                throw VRMError._dataInconsistent(
                    "a TRIANGLE_FAN primitive needs at least 3 indices, but has \(indices.count)"
                )
            }
            let base = indices[0]
            var result: [UInt32] = []
            result.reserveCapacity((indices.count - 2) * 3)
            for i in 1..<(indices.count - 1) {
                result.append(contentsOf: [base, indices[i], indices[i + 1]])
            }
            return result
        case .POINTS, .LINES, .LINE_LOOP, .LINE_STRIP:
            // Filtered out by supportsTriangles() before the indices are read.
            throw VRMError._notSupported("\(mode) primitives have no triangles")
        }
    }

    func material(withMaterialIndex index: Int) throws -> Material {
        if let cache = try entityData.load(\.materials, index: index) { return cache }
        let (gltfMaterial, materialProperty) = try materialSource(withMaterialIndex: index)
#if !os(visionOS)
        do {
            // Building the state reads the extension's textures and samplers, so
            // it fails on the same malformed files the material build does.
            if let state = try mtoonState(withMaterialIndex: index) {
                let material = try customMToonMaterial(state)
                entityData.materials[index] = material
                return material
            }
        } catch {
            // The caller falls back to a non-MToon material, so the state has
            // to go with it: otherwise expression binds would keep writing
            // parameter rows that nothing on screen reads.
            discardMToonState(withMaterialIndex: index)
            Self.logger.error("Failed to build the MToon material \(index, privacy: .public); falling back to Unlit / PBR: \(String(describing: error), privacy: .public)")
        }
#endif

        let shaderName = materialProperty?.shader.lowercased()
        let isMToon = try mtoonDescriptor(withMaterialIndex: index) != nil
        // MToon / Unlit variants are not PBR, so use UnlitMaterial for consistent rendering
        // This matches SceneKit's behavior which uses lightingModel = .constant
        let isUnlit = shaderName?.contains("unlit") == true || gltfMaterial.extensions?.materialsUnlit != nil
        let useUnlit = isMToon || isUnlit
        let resolvedAlphaMode = GLTF.Material.AlphaMode(vrm0: materialProperty,
                                                        fallback: gltfMaterial.alphaMode)
        let tint = gltfMaterial.pbrMetallicRoughness
            .map { VRMColor(simd: SIMD4<Float>($0.baseColorFactor)) } ?? .white

        if useUnlit {
            // RealityKit tone maps everything it draws, and that curve visibly
            // darkens flat art, so the unlit path opts out of it.
            var material = UnlitMaterial(applyPostProcessToneMap: false)
            if let pbr = gltfMaterial.pbrMetallicRoughness,
               let baseTexture = pbr.baseColorTexture {
                let textureParam = try materialTexture(withTextureIndex: baseTexture.index, semantic: .color)
                material.color = .init(tint: tint, texture: textureParam)
            } else {
                material.color = .init(tint: tint)
            }
            applyAlphaMode(resolvedAlphaMode, alphaCutoff: gltfMaterial.alphaCutoff, to: &material)
            if gltfMaterial.doubleSided {
                material.faceCulling = .none
            }
            entityData.materials[index] = material
            return material
        }

        var material = PhysicallyBasedMaterial()
        if let pbr = gltfMaterial.pbrMetallicRoughness {
            if let baseTexture = pbr.baseColorTexture {
                let textureParam = try materialTexture(withTextureIndex: baseTexture.index, semantic: .color)
                material.baseColor = .init(tint: tint, texture: textureParam)
            } else {
                material.baseColor = .init(tint: tint)
            }

            if let metallicTexture = pbr.metallicRoughnessTexture {
                let textures = try metallicRoughnessTextures(withTextureIndex: metallicTexture.index)
                material.metallic.texture = textures.metal
                material.roughness.texture = textures.rough
            } else {
                material.metallic = .init(floatLiteral: pbr.metallicFactor)
                material.roughness = .init(floatLiteral: pbr.roughnessFactor)
            }
        } else {
            material.baseColor = .init(tint: tint)
            material.metallic = .init(floatLiteral: 1.0)
            material.roughness = .init(floatLiteral: 1.0)
        }

        if let normalTexture = gltfMaterial.normalTexture {
            material.normal.texture = try materialTexture(withTextureIndex: normalTexture.index, semantic: .normal)
        }

        if let occlusionTexture = gltfMaterial.occlusionTexture {
            material.ambientOcclusion.texture = try materialTexture(withTextureIndex: occlusionTexture.index, semantic: .color)
        }

        let emissiveFactor = gltfMaterial.emissiveFactor
        let emissiveTint = VRMColor(red: CGFloat(emissiveFactor.r),
                                   green: CGFloat(emissiveFactor.g),
                                   blue: CGFloat(emissiveFactor.b),
                                   alpha: 1)
        let hasEmissiveTint = emissiveFactor.r != 0 || emissiveFactor.g != 0 || emissiveFactor.b != 0
        if let emissiveTexture = gltfMaterial.emissiveTexture {
            let textureParam = try materialTexture(withTextureIndex: emissiveTexture.index, semantic: .color)
            material.emissiveColor = .init(color: emissiveTint,
                                           texture: textureParam)
        } else if hasEmissiveTint {
            material.emissiveColor = .init(color: emissiveTint)
        }

        applyAlphaMode(resolvedAlphaMode, alphaCutoff: gltfMaterial.alphaCutoff, to: &material)
        if gltfMaterial.doubleSided {
            material.faceCulling = .none
        }

        entityData.materials[index] = material
        return material
    }

#if !os(visionOS)
    private func customMToonMaterial(_ state: MToonState) throws -> Material {
        // RealityKit has no material-level draw-order hook, so MToon's
        // renderQueueOffsetNumber is not honored here.
        let mtoon = state.descriptor
        let surface = CustomMaterial.SurfaceShader(named: "mtoonSurface", in: state.library)
        var material = try CustomMaterial(surfaceShader: surface, lightingModel: .unlit)
        // MToon needs more textures than CustomMaterial has semantic channels,
        // so the extra slots ride on unrelated channels; MToon.metal reads them
        // back through the same mapping.
        material.baseColor = .init(tint: .white, texture: try mtoonTexture(mtoon, slot: .base))
        material.roughness.texture = try mtoonTexture(mtoon, slot: .shade)
        material.specular.texture = try mtoonTexture(mtoon, slot: .shadingShift)
        material.metallic.texture = try mtoonTexture(mtoon, slot: .matcap)
        material.normal.texture = try mtoonTexture(mtoon, slot: .normal)
        material.emissiveColor = .init(color: .white, texture: try mtoonTexture(mtoon, slot: .emissive))
        material.clearcoatRoughness.texture = try mtoonTexture(mtoon, slot: .rim)
        material.clearcoat.texture = try mtoonTexture(mtoon, slot: .outlineWidth)
        material.ambientOcclusion.texture = try mtoonTexture(mtoon, slot: .uvAnimationMask)

        applyAlphaMode(mtoon.alphaMode, alphaCutoff: mtoon.alphaCutoff, to: &material)
        applyDepthWrite(mtoon, to: &material)
        material.faceCulling = mtoon.cullMode.faceCulling
        applyMToonParameters(state, to: &material)
        return material
    }

    private func customMToonOutlineMaterial(_ state: MToonState) throws -> Material {
        let mtoon = state.descriptor
        let surface = CustomMaterial.SurfaceShader(named: "mtoonOutlineSurface", in: state.library)
        let geometry = CustomMaterial.GeometryModifier(named: "mtoonOutlineGeometry", in: state.library)
        var material = try CustomMaterial(surfaceShader: surface,
                                          geometryModifier: geometry,
                                          lightingModel: .unlit)
        // The inverted hull is rendered with front faces culled.
        material.faceCulling = .front
        material.baseColor = .init(tint: .white, texture: try mtoonTexture(mtoon, slot: .base))
        material.clearcoat.texture = try mtoonTexture(mtoon, slot: .outlineWidth)
        material.ambientOcclusion.texture = try mtoonTexture(mtoon, slot: .uvAnimationMask)
        applyAlphaMode(mtoon.alphaMode, alphaCutoff: mtoon.alphaCutoff, to: &material)
        applyDepthWrite(mtoon, to: &material)
        applyMToonParameters(state, to: &material)
        return material
    }

    /// MToon.metal applies the UV transform from the parameter rows, so
    /// `textureCoordinateTransform` is deliberately left at identity here:
    /// setting it too would transform the primary UV a second time.
    private func applyMToonParameters(_ state: MToonState, to material: inout CustomMaterial) {
        material.custom.value = state.parameters.customValue
        material.custom.texture = state.parameterTexture
    }

    /// Resolves the descriptor's texture for `slot`, falling back to the slot's
    /// neutral texture when the material does not provide one.
    private func mtoonTexture(_ descriptor: MToonMaterialDescriptor,
                              slot: MToonTextureSlot) throws -> CustomMaterial.Texture {
        guard let texture = descriptor.texture(for: slot) else {
            return CustomMaterial.Texture(try fallbackTextureResource(slot.fallback))
        }
        return CustomMaterial.Texture(try self.texture(withTextureIndex: texture.index, semantic: slot.semantic))
    }
#endif

    func currentMaterialColor(withMaterialIndex index: Int,
                              type: VRM1.Expressions.Expression.MaterialColorBind.MaterialColorType) throws -> SIMD4<Float> {
        if let color = try mtoonParameters(withMaterialIndex: index)?.color(for: type) {
            return color
        }
        return try material(withMaterialIndex: index).currentColor(for: type)
    }

    /// The UV transform a `textureTransformBind` starts from. MToon keeps it in
    /// its parameter rows, everything else in the RealityKit material.
    func currentTextureTransform(withMaterialIndex index: Int) throws -> MaterialParameterTypes.TextureCoordinateTransform {
        if let transform = try mtoonParameters(withMaterialIndex: index)?.textureTransform {
            return transform
        }
        return try material(withMaterialIndex: index).currentTextureTransform
    }

    func mtoonParameters(withMaterialIndex index: Int) throws -> MToonMaterialParameters? {
#if os(visionOS)
        return nil
#else
        // A nil state means the material does not render as MToon (disabled,
        // no metallib, or not an MToon material).
        return try mtoonState(withMaterialIndex: index)?.parameters
#endif
    }

#if !os(visionOS)
    private func mtoonState(withMaterialIndex index: Int) throws -> MToonState? {
        if let cached = mtoonStateCache[index] {
            return cached
        }
        let state = try makeMToonState(withMaterialIndex: index)
        mtoonStateCache[index] = state
        return state
    }

    /// Records that the material does not render as MToon after all, so every
    /// MToon-derived path — surface, outline, runtime parameters — agrees.
    private func discardMToonState(withMaterialIndex index: Int) {
        mtoonStateCache.updateValue(nil, forKey: index)
        mtoonOutlineMaterialCache.updateValue(nil, forKey: index)
    }

    private func makeMToonState(withMaterialIndex index: Int) throws -> MToonState? {
        guard isMToonEnabled,
              let descriptor = try mtoonDescriptor(withMaterialIndex: index),
              let library = mtoonShaderLibrary() else {
            return nil
        }
        let textureTransform = mtoonTextureTransform(withMaterialIndex: index, descriptor: descriptor)
        let parameters = try mtoonParameters(for: descriptor, textureTransform: textureTransform)
        logMToonUnsupportedFeatures(for: descriptor, index: index)
        return MToonState(descriptor: descriptor,
                          parameters: parameters,
                          parameterTexture: CustomMaterial.Texture(try parameters.textureResource()),
                          library: library)
    }

    /// MToon features that this renderer cannot express are reported once per
    /// material instead of being dropped silently.
    private func logMToonUnsupportedFeatures(for descriptor: MToonMaterialDescriptor, index: Int) {
        if descriptor.renderQueueOffsetNumber != 0 {
            Self.logger.warning("MToon material \(index, privacy: .public) requests renderQueueOffsetNumber \(descriptor.renderQueueOffsetNumber); RealityKit has no material-level draw-order hook, so it is ignored.")
        }
    }
#endif

    private func mtoonParameters(for descriptor: MToonMaterialDescriptor,
                                 textureTransform: MaterialParameterTypes.TextureCoordinateTransform) throws -> MToonMaterialParameters {
        var parameters = MToonMaterialParameters(descriptor)
        parameters.setTextureTransform(scale: textureTransform.scale,
                                       offset: textureTransform.offset,
                                       rotation: textureTransform.rotation)
        for slot in MToonTextureSlot.allCases {
            try parameters.setSampler(mtoonSamplerParameters(for: descriptor.texture(for: slot)), for: slot)
        }
        return parameters
    }

    /// Custom meshes expose only TEXCOORD_0 and `CustomMaterial` has a single
    /// material-level UV transform, so the descriptor's first UV-accessed
    /// transform is applied to every MToon texture.
    private func mtoonTextureTransform(withMaterialIndex index: Int,
                                       descriptor: MToonMaterialDescriptor) -> MaterialParameterTypes.TextureCoordinateTransform {
        let textures = descriptor.uvAccessedTextures
        // The first UV-accessed slot wins even when it has no transform of its
        // own; letting a later slot's transform stand in would shift it.
        let selectedTransform = textures.first?.transform
            .map { MaterialParameterTypes.TextureCoordinateTransform(offset: $0.offset,
                                                                     scale: $0.scale,
                                                                     rotation: $0.rotation) }
            ?? MaterialParameterTypes.TextureCoordinateTransform()
        let usesUnsupportedTexCoord = textures.contains { $0.texCoord != 0 }
        let hasDifferentTransforms = textures.contains {
            textureTransform($0.transform ?? .init(), differsFrom: selectedTransform)
        }
        if (usesUnsupportedTexCoord || hasDifferentTransforms),
           loggedMToonUVLimitations.insert(index).inserted {
            if usesUnsupportedTexCoord {
                Self.logger.warning("MToon material \(index, privacy: .public) requests a nonzero texCoord; RealityKit uses TEXCOORD_0 on supported deployment targets.")
            }
            if hasDifferentTransforms {
                Self.logger.warning("MToon material \(index, privacy: .public) has per-texture KHR_texture_transform values; RealityKit uses the first UV-accessed transform for all MToon textures.")
            }
        }
        return selectedTransform
    }

    private func textureTransform(_ lhs: MToonMaterialDescriptor.UVTransform,
                                  differsFrom rhs: MaterialParameterTypes.TextureCoordinateTransform) -> Bool {
        lhs.scale != rhs.scale || lhs.offset != rhs.offset || abs(lhs.rotation - rhs.rotation) > 0.000_001
    }

    private func mtoonOutlineMaterial(withMaterialIndex index: Int) throws -> Material? {
#if os(visionOS)
        return nil
#else
        guard isOutlineEnabled else {
            return nil
        }
        if let cached = mtoonOutlineMaterialCache[index] {
            return cached
        }
        let material: Material?
        if let state = try mtoonState(withMaterialIndex: index), state.descriptor.hasOutline {
            material = try customMToonOutlineMaterial(state)
        } else {
            material = nil
        }
        mtoonOutlineMaterialCache[index] = material
        return material
#endif
    }

    /// Memoized because both the material-type decision and the MToon state
    /// need it, and building it runs the whole VRM 0.x migration.
    private func mtoonDescriptor(withMaterialIndex index: Int) throws -> MToonMaterialDescriptor? {
        if let cached = mtoonDescriptorCache[index] {
            return cached
        }
        let descriptor = try makeMToonDescriptor(withMaterialIndex: index)
        mtoonDescriptorCache[index] = descriptor
        return descriptor
    }

    private func makeMToonDescriptor(withMaterialIndex index: Int) throws -> MToonMaterialDescriptor? {
        let (gltfMaterial, materialProperty) = try materialSource(withMaterialIndex: index)
        return MToonMaterialDescriptor(material: gltfMaterial, materialProperty: materialProperty)
    }

    /// The glTF material and, for VRM 0.x, the Unity material property that
    /// describes it. The VRM 0.x name lookup lives here only.
    private func materialSource(withMaterialIndex index: Int) throws -> (GLTF.Material, VRM0.MaterialProperty?) {
        let gltfMaterial = try gltf.load(\.materials, at: index)
        guard case .v0(let vrm0) = vrm, let name = gltfMaterial.name else {
            return (gltfMaterial, nil)
        }
        return (gltfMaterial, vrm0.materialPropertyNameMap[name])
    }

    private func mtoonShaderLibrary() -> MTLLibrary? {
        do {
            return try MToonShaderLibraryLoader.loadDefault()
        } catch {
            if !loggedMToonLibraryError {
                loggedMToonLibraryError = true
                Self.logger.error("Failed to load bundled MToon shader library: \(String(describing: error), privacy: .public)")
            }
            return nil
        }
    }

    func texture(withTextureIndex index: Int, semantic: TextureResource.Semantic = .color) throws -> TextureResource {
        if semantic == .color, let cache = try entityData.load(\.textures, index: index) {
            return cache
        }
        if semantic != .color, let cache = textureCacheBySemantic[semantic]?[index] {
            return cache
        }
        let gltfTexture = try gltf.load(\.textures, at: index)
        let image = try image(withImageIndex: gltfTexture.source)
        let cgImage = try image.cgImage ??? .dataInconsistent("failed to load cgImage")
        let texture = try TextureResource(image: cgImage, options: .init(semantic: semantic))
        if semantic == .color {
            entityData.textures[index] = texture
        } else {
            textureCacheBySemantic[semantic, default: [:]][index] = texture
        }
        return texture
    }

    private func materialTexture(withTextureIndex index: Int,
                                 semantic: TextureResource.Semantic = .color) throws -> MaterialParameters.Texture {
        let texture = try texture(withTextureIndex: index, semantic: semantic)
        let sampler = try sampler(withTextureIndex: index)
        return MaterialParameters.Texture(texture, sampler: sampler)
    }

    /// The neutral 1x1 texture bound when a material omits an MToon slot.
    private func fallbackTextureResource(_ fallback: MToonTextureSlot.Fallback) throws -> TextureResource {
        if let cached = fallbackTextureCache[fallback] {
            return cached
        }
        let texture: TextureResource
        switch fallback {
        case .white:
            texture = try solidColorTextureResource(rgba: [255, 255, 255, 255], semantic: .color)
        case .neutralNormal:
            texture = try solidColorTextureResource(rgba: [128, 128, 255, 255], semantic: .normal)
        }
        fallbackTextureCache[fallback] = texture
        return texture
    }

    private func solidColorTextureResource(rgba: [UInt8],
                                           semantic: TextureResource.Semantic) throws -> TextureResource {
        guard let provider = CGDataProvider(data: Data(rgba) as CFData),
              let image = CGImage(width: 1,
                                  height: 1,
                                  bitsPerComponent: 8,
                                  bitsPerPixel: 32,
                                  bytesPerRow: 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                  provider: provider,
                                  decode: nil,
                                  shouldInterpolate: false,
                                  intent: .defaultIntent) else {
            throw VRMError._dataInconsistent("failed to create 1x1 \(semantic) texture")
        }
        return try TextureResource(image: image, options: .init(semantic: semantic))
    }

    private func sampler(withTextureIndex index: Int) throws -> MaterialParameters.Texture.Sampler {
        if let cache = samplerCache[index] {
            return cache
        }
        let descriptor = MTLSamplerDescriptor()
        applySampler(try gltfSampler(withTextureIndex: index), to: descriptor)
        let sampler = MaterialParameters.Texture.Sampler(descriptor)
        samplerCache[index] = sampler
        return sampler
    }

    /// The glTF sampler a texture references, or nil when it relies on the
    /// glTF default sampler.
    private func gltfSampler(withTextureIndex index: Int) throws -> GLTF.Sampler? {
        let textures = try gltf.load(\.textures)
        guard textures.indices.contains(index) else {
            throw VRMError._dataInconsistent("Texture index \(index) out of bounds")
        }
        guard let samplerIndex = textures[index].sampler else {
            return nil
        }
        let samplers = try gltf.load(\.samplers)
        guard samplers.indices.contains(samplerIndex) else {
            throw VRMError._dataInconsistent("Sampler index \(samplerIndex) out of bounds")
        }
        return samplers[samplerIndex]
    }

    /// A nil sampler means the texture relies on the glTF defaults.
    private func applySampler(_ sampler: GLTF.Sampler?, to descriptor: MTLSamplerDescriptor) {
        descriptor.magFilter = metalFilter(sampler?.magFilter ?? .LINEAR)
        let (min, mip) = metalFilters(sampler?.minFilter ?? .LINEAR_MIPMAP_LINEAR)
        descriptor.minFilter = min
        descriptor.mipFilter = mip
        descriptor.sAddressMode = metalWrap(sampler?.wrapS ?? .REPEAT)
        descriptor.tAddressMode = metalWrap(sampler?.wrapT ?? .REPEAT)
    }

    private func mtoonSamplerParameters(for texture: MToonMaterialDescriptor.Texture?) throws -> SIMD4<Float> {
        guard let texture,
              let sampler = try gltfSampler(withTextureIndex: texture.index) else {
            return MToonMaterialParameters.defaultSampler
        }
        return mtoonSamplerParameters(sampler)
    }

    /// (wrapS, wrapT, filterIndex, 0), matching the sampler rows `MToon.metal`
    /// selects its samplers with.
    private func mtoonSamplerParameters(_ sampler: GLTF.Sampler) -> SIMD4<Float> {
        let (minFilter, mipFilter) = metalFilters(sampler.minFilter ?? .LINEAR_MIPMAP_LINEAR)
        let filter = MToonSamplerFilter(
            magnification: metalFilter(sampler.magFilter ?? .LINEAR) == .nearest ? .nearest : .linear,
            minification: minFilter == .nearest ? .nearest : .linear,
            mip: MToonSamplerFilter.MipFilter(mipFilter)
        )
        return SIMD4<Float>(mtoonWrapMode(sampler.wrapS),
                            mtoonWrapMode(sampler.wrapT),
                            Float(filter.index),
                            0)
    }

    private func mtoonWrapMode(_ wrap: GLTF.Sampler.Wrap) -> Float {
        switch wrap {
        case .REPEAT: return 0
        case .CLAMP_TO_EDGE: return 1
        case .MIRRORED_REPEAT: return 2
        }
    }

    private func metalFilter(_ filter: GLTF.Sampler.MagFilter) -> MTLSamplerMinMagFilter {
        switch filter {
        case .NEAREST: return .nearest
        case .LINEAR: return .linear
        }
    }

    private func metalFilters(_ filter: GLTF.Sampler.MinFilter) -> (min: MTLSamplerMinMagFilter, mip: MTLSamplerMipFilter) {
        switch filter {
        case .NEAREST:
            return (.nearest, .notMipmapped)
        case .LINEAR:
            return (.linear, .notMipmapped)
        case .NEAREST_MIPMAP_NEAREST:
            return (.nearest, .nearest)
        case .LINEAR_MIPMAP_NEAREST:
            return (.linear, .nearest)
        case .NEAREST_MIPMAP_LINEAR:
            return (.nearest, .linear)
        case .LINEAR_MIPMAP_LINEAR:
            return (.linear, .linear)
        }
    }

    private func metalWrap(_ wrap: GLTF.Sampler.Wrap) -> MTLSamplerAddressMode {
        switch wrap {
        case .CLAMP_TO_EDGE: return .clampToEdge
        case .MIRRORED_REPEAT: return .mirrorRepeat
        case .REPEAT: return .repeat
        }
    }

    func image(withImageIndex index: Int) throws -> VRMImage {
        if let cache = try entityData.load(\.images, index: index) { return cache }
        let gltfImage = try gltf.load(\.images, at: index)
        let image = try VRMImage.from(gltfImage, relativeTo: rootDirectory) { index in
            try self.bufferView(withBufferViewIndex: index).bufferView
        }
        entityData.images[index] = image
        return image
    }

    func bufferView(withBufferViewIndex index: Int) throws -> (bufferView: Data, stride: Int?) {
        if let cache = try entityData.load(\.bufferViews, index: index) {
            let gltfBufferView = try gltf.load(\.bufferViews, at: index)
            return (cache, gltfBufferView.byteStride)
        }
        let result = try vrm.gltf.bufferViewData(at: index, relativeTo: rootDirectory)
        entityData.bufferViews[index] = result.data
        return (result.data, result.stride)
    }

    private func metallicRoughnessTextures(withTextureIndex index: Int) throws -> (metal: MaterialParameters.Texture, rough: MaterialParameters.Texture) {
        let resources: (metal: TextureResource, rough: TextureResource)
        if let cache = metallicRoughnessCache[index] {
            resources = cache
        } else {
            let gltfTexture = try gltf.load(\.textures, at: index)
            let image = try image(withImageIndex: gltfTexture.source)
            let textures = try createMetallicRoughnessTextures(from: image)
            metallicRoughnessCache[index] = textures
            resources = textures
        }
        let sampler = try sampler(withTextureIndex: index)
        return (MaterialParameters.Texture(resources.metal, sampler: sampler),
                MaterialParameters.Texture(resources.rough, sampler: sampler))
    }

    private func createMetallicRoughnessTextures(from uiImage: VRMImage) throws -> (metal: TextureResource, rough: TextureResource) {
        guard let image = uiImage.cgImage else {
            throw VRMError._dataInconsistent("failed to load cgImage")
        }

        let pixelCount = image.width * image.height
        let bitsPerComponent = 8
        let componentsPerPixel = 4
        let srcBytesPerPixel = bitsPerComponent * componentsPerPixel / 8
        let srcDataSize = pixelCount * srcBytesPerPixel

        let ptr = UnsafeMutablePointer<UInt8>.allocate(capacity: srcDataSize)
        let metalPtr = UnsafeMutablePointer<UInt8>.allocate(capacity: pixelCount)
        let roughPtr = UnsafeMutablePointer<UInt8>.allocate(capacity: pixelCount)
        defer {
            ptr.deallocate()
            metalPtr.deallocate()
            roughPtr.deallocate()
        }

        guard let context = CGContext(
            data: UnsafeMutableRawPointer(ptr),
            width: image.width,
            height: image.height,
            bitsPerComponent: bitsPerComponent,
            bytesPerRow: srcBytesPerPixel * image.width,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else {
            throw VRMError._dataInconsistent("failed to create cgcontext")
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))

        for dstPos in 0..<pixelCount {
            let srcPos = dstPos * srcBytesPerPixel
            metalPtr[dstPos] = ptr[srcPos + 2]
            roughPtr[dstPos] = ptr[srcPos + 1]
        }

        let metalImage = try createGraySpaceImage(width: image.width,
                                                  height: image.height,
                                                  dataPointer: metalPtr)
        let roughImage = try createGraySpaceImage(width: image.width,
                                                  height: image.height,
                                                  dataPointer: roughPtr)

        let metalTexture = try TextureResource(image: metalImage, options: .init(semantic: .color))
        let roughTexture = try TextureResource(image: roughImage, options: .init(semantic: .color))
        return (metalTexture, roughTexture)
    }

    private func createGraySpaceImage(width: Int,
                                      height: Int,
                                      dataPointer: UnsafeMutablePointer<UInt8>) throws -> CGImage {
        guard let data = CFDataCreate(nil, dataPointer, width * height),
              let provider = CGDataProvider(data: data) else {
            throw VRMError._dataInconsistent("failed to create image data")
        }
        guard let image = CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 8,
            bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ) else {
            throw VRMError._dataInconsistent("failed to create CGImage")
        }
        return image
    }

    /// The single glTF alpha-mode → RealityKit blending decision, shared by
    /// every material type this loader builds.
    private struct AlphaModeSettings {
        let isTransparent: Bool
        let opacityThreshold: Float?

        init(_ mode: GLTF.Material.AlphaMode, alphaCutoff: Float) {
            switch mode {
            case .OPAQUE:
                (isTransparent, opacityThreshold) = (false, nil)
            case .MASK:
                (isTransparent, opacityThreshold) = (false, alphaCutoff)
            case .BLEND:
                (isTransparent, opacityThreshold) = (true, nil)
            }
        }
    }

    private func applyAlphaMode(_ mode: GLTF.Material.AlphaMode,
                                alphaCutoff: Float,
                                to material: inout UnlitMaterial) {
        let settings = AlphaModeSettings(mode, alphaCutoff: alphaCutoff)
        material.blending = settings.isTransparent ? .transparent(opacity: .init(scale: 1.0)) : .opaque
        material.opacityThreshold = settings.opacityThreshold
    }

    private func applyAlphaMode(_ mode: GLTF.Material.AlphaMode,
                                alphaCutoff: Float,
                                to material: inout PhysicallyBasedMaterial) {
        let settings = AlphaModeSettings(mode, alphaCutoff: alphaCutoff)
        material.blending = settings.isTransparent ? .transparent(opacity: .init(scale: 1.0)) : .opaque
        material.opacityThreshold = settings.opacityThreshold
    }

#if !os(visionOS)
    private func applyAlphaMode(_ mode: GLTF.Material.AlphaMode,
                                alphaCutoff: Float,
                                to material: inout CustomMaterial) {
        let settings = AlphaModeSettings(mode, alphaCutoff: alphaCutoff)
        material.blending = settings.isTransparent ? .transparent(opacity: .init(scale: 1.0)) : .opaque
        material.opacityThreshold = settings.opacityThreshold
    }

    /// MToon's `transparentWithZWrite` asks a blended material to still write
    /// depth. Only BLEND materials can turn depth writing off, so every other
    /// alpha mode keeps it on.
    private func applyDepthWrite(_ mtoon: MToonMaterialDescriptor, to material: inout CustomMaterial) {
        material.writesDepth = mtoon.alphaMode != .BLEND || mtoon.transparentWithZWrite
    }
#endif

    private struct AccessorSlice {
        let data: Data
        let componentsPerVector: Int
        let bytesPerComponent: Int
        let count: Int
        let componentType: GLTF.Accessor.ComponentType
        let normalized: Bool
    }

    private func accessorSlice(_ index: Int) throws -> AccessorSlice {
        if let cache = try entityData.load(\.accessors, index: index) as? AccessorSlice {
            return cache
        }
        let accessors = try gltf.load(\.accessors)
        guard accessors.indices.contains(index) else {
            throw VRMError._dataInconsistent("accessor index \(index) is out of range for \(accessors.count) accessors")
        }
        let accessor = accessors[index]
        let (componentsPerVector, bytesPerComponent, _) = accessor.components()
        let slice = AccessorSlice(
            data: try accessor.packedData(bufferView: { try self.bufferView(withBufferViewIndex: $0) }),
            componentsPerVector: componentsPerVector,
            bytesPerComponent: bytesPerComponent,
            count: accessor.count,
            componentType: accessor.componentType,
            normalized: accessor.normalized
        )
        entityData.accessors[index] = slice
        return slice
    }

    private func vector2s(_ accessorIndex: Int) throws -> [SIMD2<Float>] {
        let slice = try accessorSlice(accessorIndex)
        guard slice.componentsPerVector == 2 else {
            throw VRMError._dataInconsistent("expected VEC2 accessor")
        }
        var result: [SIMD2<Float>] = []
        result.reserveCapacity(slice.count)
        slice.data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            for i in 0..<slice.count {
                let baseOffset = i * slice.componentsPerVector * slice.bytesPerComponent
                let x = readComponent(base: base,
                                      offset: baseOffset,
                                      componentType: slice.componentType,
                                      normalized: slice.normalized)
                let y = readComponent(base: base,
                                      offset: baseOffset + slice.bytesPerComponent,
                                      componentType: slice.componentType,
                                      normalized: slice.normalized)
                result.append(SIMD2<Float>(x, 1.0 - y))
            }
        }
        return result
    }

    private func vector3s(_ accessorIndex: Int) throws -> [SIMD3<Float>] {
        let slice = try accessorSlice(accessorIndex)
        guard slice.componentsPerVector == 3 else {
            throw VRMError._dataInconsistent("expected VEC3 accessor")
        }
        var result: [SIMD3<Float>] = []
        result.reserveCapacity(slice.count)
        slice.data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            for i in 0..<slice.count {
                let baseOffset = i * slice.componentsPerVector * slice.bytesPerComponent
                let x = readComponent(base: base,
                                      offset: baseOffset,
                                      componentType: slice.componentType,
                                      normalized: slice.normalized)
                let y = readComponent(base: base,
                                      offset: baseOffset + slice.bytesPerComponent,
                                      componentType: slice.componentType,
                                      normalized: slice.normalized)
                let z = readComponent(base: base,
                                      offset: baseOffset + slice.bytesPerComponent * 2,
                                      componentType: slice.componentType,
                                      normalized: slice.normalized)
                result.append(SIMD3<Float>(x, y, z))
            }
        }
        return result
    }

    private func vector4s(_ accessorIndex: Int) throws -> [SIMD4<Float>] {
        let slice = try accessorSlice(accessorIndex)
        guard slice.componentsPerVector == 4 else {
            throw VRMError._dataInconsistent("expected VEC4 accessor")
        }
        var result: [SIMD4<Float>] = []
        result.reserveCapacity(slice.count)
        slice.data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            for i in 0..<slice.count {
                let baseOffset = i * slice.componentsPerVector * slice.bytesPerComponent
                let x = readComponent(base: base,
                                      offset: baseOffset,
                                      componentType: slice.componentType,
                                      normalized: slice.normalized)
                let y = readComponent(base: base,
                                      offset: baseOffset + slice.bytesPerComponent,
                                      componentType: slice.componentType,
                                      normalized: slice.normalized)
                let z = readComponent(base: base,
                                      offset: baseOffset + slice.bytesPerComponent * 2,
                                      componentType: slice.componentType,
                                      normalized: slice.normalized)
                let w = readComponent(base: base,
                                      offset: baseOffset + slice.bytesPerComponent * 3,
                                      componentType: slice.componentType,
                                      normalized: slice.normalized)
                result.append(SIMD4<Float>(x, y, z, w))
            }
        }
        return result
    }

    private func indexValues(_ accessorIndex: Int) throws -> [UInt32] {
        let slice = try accessorSlice(accessorIndex)
        guard slice.componentsPerVector == 1 else {
            throw VRMError._dataInconsistent("indices accessor must be SCALAR")
        }

        var result: [UInt32] = []
        result.reserveCapacity(slice.count)
        slice.data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            for i in 0..<slice.count {
                guard let value = readIndexComponent(base: base,
                                                     offset: i * slice.bytesPerComponent,
                                                     componentType: slice.componentType) else {
                    return
                }
                result.append(value)
            }
        }
        if result.count != slice.count {
            throw VRMError._dataInconsistent("failed to read indices")
        }
        return result
    }

    private func readComponent(base: UnsafeRawPointer,
                               offset: Int,
                               componentType: GLTF.Accessor.ComponentType,
                               normalized: Bool) -> Float {
        switch componentType {
        case .float:
            return base.load(fromByteOffset: offset, as: Float.self)
        case .unsignedByte:
            let value = Float(base.load(fromByteOffset: offset, as: UInt8.self))
            return normalized ? value / Float(UInt8.max) : value
        case .byte:
            let value = Float(base.load(fromByteOffset: offset, as: Int8.self))
            if normalized {
                return max(-1, value / Float(Int8.max))
            }
            return value
        case .unsignedShort:
            let value = Float(base.load(fromByteOffset: offset, as: UInt16.self))
            return normalized ? value / Float(UInt16.max) : value
        case .short:
            let value = Float(base.load(fromByteOffset: offset, as: Int16.self))
            if normalized {
                return max(-1, value / Float(Int16.max))
            }
            return value
        case .unsignedInt:
            let value = Float(base.load(fromByteOffset: offset, as: UInt32.self))
            return normalized ? value / Float(UInt32.max) : value
        }
    }

    /// One element of an index-valued accessor — mesh indices and `JOINTS_n`.
    /// glTF defines both as unsigned integers, so a signed or floating point
    /// component type is a malformed file and yields nil for the caller to throw on.
    private func readIndexComponent(base: UnsafeRawPointer,
                                    offset: Int,
                                    componentType: GLTF.Accessor.ComponentType) -> UInt32? {
        switch componentType {
        case .unsignedByte:
            return UInt32(base.load(fromByteOffset: offset, as: UInt8.self))
        case .unsignedShort:
            return UInt32(base.load(fromByteOffset: offset, as: UInt16.self))
        case .unsignedInt:
            return base.load(fromByteOffset: offset, as: UInt32.self)
        case .byte, .short, .float:
            return nil
        }
    }

    private func vector4UInts(_ accessorIndex: Int) throws -> [SIMD4<UInt32>] {
        let slice = try accessorSlice(accessorIndex)
        guard slice.componentsPerVector == 4 else {
            throw VRMError._dataInconsistent("expected VEC4 accessor")
        }
        var result: [SIMD4<UInt32>] = []
        result.reserveCapacity(slice.count)
        slice.data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            for i in 0..<slice.count {
                let baseOffset = i * slice.componentsPerVector * slice.bytesPerComponent
                guard let x = readIndexComponent(base: base,
                                                 offset: baseOffset,
                                                 componentType: slice.componentType),
                      let y = readIndexComponent(base: base,
                                                 offset: baseOffset + slice.bytesPerComponent,
                                                 componentType: slice.componentType),
                      let z = readIndexComponent(base: base,
                                                 offset: baseOffset + slice.bytesPerComponent * 2,
                                                 componentType: slice.componentType),
                      let w = readIndexComponent(base: base,
                                                 offset: baseOffset + slice.bytesPerComponent * 3,
                                                 componentType: slice.componentType) else {
                    return
                }
                result.append(SIMD4<UInt32>(x, y, z, w))
            }
        }
        if result.count != slice.count {
            throw VRMError._dataInconsistent("failed to read joint indices")
        }
        return result
    }

    /// JOINTS_n as glTF defines it: unsigned byte or short indices into the skin.
    /// A wider or signed component type means the file indexes joints in a way
    /// its own skin does not describe.
    private func jointIndices(_ accessorIndex: Int) throws -> [SIMD4<UInt32>] {
        let slice = try accessorSlice(accessorIndex)
        switch slice.componentType {
        case .unsignedByte, .unsignedShort:
            return try vector4UInts(accessorIndex)
        case .byte, .short, .unsignedInt, .float:
            throw VRMError._dataInconsistent(
                "JOINTS_0 must use unsigned byte or short components, not \(slice.componentType)"
            )
        }
    }

    /// WEIGHTS_n as glTF defines it: float, or normalized unsigned byte / short.
    /// An unnormalized integer accessor would arrive as raw counts rather than
    /// the 0...1 weights the influences are built from.
    private func jointWeights(_ accessorIndex: Int) throws -> [SIMD4<Float>] {
        let slice = try accessorSlice(accessorIndex)
        switch slice.componentType {
        case .float:
            return try vector4s(accessorIndex)
        case .unsignedByte, .unsignedShort:
            guard slice.normalized else {
                throw VRMError._dataInconsistent(
                    "WEIGHTS_0 with \(slice.componentType) components must be normalized"
                )
            }
            return try vector4s(accessorIndex)
        case .byte, .short, .unsignedInt:
            throw VRMError._dataInconsistent(
                "WEIGHTS_0 must use float or normalized unsigned byte / short components, not \(slice.componentType)"
            )
        }
    }

    private func makeJointInfluences(joints: [SIMD4<UInt32>],
                                     weights: [SIMD4<Float>],
                                     vertexCount: Int,
                                     jointIndexRemap: [Int]?) throws -> MeshResource.JointInfluences {
        guard joints.count == weights.count else {
            throw VRMError._dataInconsistent("JOINTS_0 and WEIGHTS_0 counts do not match")
        }
        guard joints.count == vertexCount else {
            throw VRMError._dataInconsistent("joint influence count \(joints.count) does not match vertex count \(vertexCount)")
        }

        var influences: [MeshJointInfluence] = []
        influences.reserveCapacity(joints.count * 4)
        let remap = jointIndexRemap
        // JOINTS_0 comes straight from the file, so an out-of-range index has to
        // fail the load rather than reach the remap table or the skeleton.
        func remapped(_ jointIndex: UInt32) throws -> Int {
            guard let remap else { return Int(jointIndex) }
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

        let buffer = MeshBuffer(influences)
        return MeshResource.JointInfluences(influences: buffer, influencesPerVertex: 4)
    }

    private func matrix4s(_ accessorIndex: Int) throws -> [simd_float4x4] {
        let slice = try accessorSlice(accessorIndex)
        guard slice.componentsPerVector == 16 else {
            throw VRMError._dataInconsistent("expected MAT4 accessor")
        }
        guard slice.componentType == .float else {
            throw VRMError._dataInconsistent("MAT4 accessor must be float")
        }
        var result: [simd_float4x4] = []
        result.reserveCapacity(slice.count)
        slice.data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            for i in 0..<slice.count {
                let baseOffset = i * slice.componentsPerVector * slice.bytesPerComponent
                var values: [Float] = []
                values.reserveCapacity(16)
                for c in 0..<16 {
                    let value = readComponent(base: base,
                                              offset: baseOffset + slice.bytesPerComponent * c,
                                              componentType: slice.componentType,
                                              normalized: false)
                    values.append(value)
                }
                let matrix = simd_float4x4(columns: (
                    SIMD4<Float>(values[0], values[1], values[2], values[3]),
                    SIMD4<Float>(values[4], values[5], values[6], values[7]),
                    SIMD4<Float>(values[8], values[9], values[10], values[11]),
                    SIMD4<Float>(values[12], values[13], values[14], values[15])
                ))
                result.append(matrix)
            }
        }
        if result.count != slice.count {
            throw VRMError._dataInconsistent("failed to read inverse bind matrices")
        }
        return result
    }

    private func skeleton(withSkinIndex index: Int) throws -> MeshResource.Skeleton {
        if let cache = try entityData.load(\.skins, index: index) { return cache }
        let skin = try gltf.load(\.skins, at: index)
        let nodes = try gltf.load(\.nodes)
        let (parentIndices, order, remap) = computeSkinJointOrdering(skin: skin, nodes: nodes)
        entityData.skinJointRemaps[index] = remap

        // glTF defines an absent inverseBindMatrices as identity per joint, but a
        // present one has to cover every joint: silently substituting identities
        // for a broken accessor would bind the mesh to the wrong rest pose.
        let inverseBindMatrices: [simd_float4x4]
        if let accessorIndex = skin.inverseBindMatrices {
            inverseBindMatrices = try matrix4s(accessorIndex)
            guard inverseBindMatrices.count >= skin.joints.count else {
                throw VRMError._dataInconsistent(
                    "inverseBindMatrices has \(inverseBindMatrices.count) elements for \(skin.joints.count) skin joints"
                )
            }
        } else {
            inverseBindMatrices = Array(repeating: matrix_identity_float4x4, count: skin.joints.count)
        }

        var joints: [MeshResource.Skeleton.Joint] = []
        joints.reserveCapacity(order.count)
        for newIndex in 0..<order.count {
            let oldIndex = order[newIndex]
            let nodeIndex = skin.joints[oldIndex]
            let node = nodes[nodeIndex]
            let name = node.name ?? "joint_\(nodeIndex)"
            let parentOld = parentIndices[oldIndex]
            let parentNew = parentOld.map { remap[$0] }

            let restTransform = transform(from: node)
            let ibm = inverseBindMatrices[oldIndex]
            joints.append(.init(name: name,
                                parentIndex: parentNew,
                                inverseBindPoseMatrix: ibm,
                                restPoseTransform: restTransform))
        }

        let skeleton = MeshResource.Skeleton(id: "skin_\(index)", joints: joints)
        entityData.skins[index] = skeleton
        return skeleton
    }

    private func jointIndexRemap(forSkinIndex index: Int) throws -> [Int] {
        if let cache = try entityData.load(\.skinJointRemaps, index: index) { return cache }
        let skin = try gltf.load(\.skins, at: index)
        let nodes = try gltf.load(\.nodes)
        let (_, _, remap) = computeSkinJointOrdering(skin: skin, nodes: nodes)
        entityData.skinJointRemaps[index] = remap
        return remap
    }

    private func computeSkinJointOrdering(skin: GLTF.Skin,
                                          nodes: [GLTF.Node]) -> (parentIndices: [Int?], order: [Int], remap: [Int]) {
        let jointNodeIndices = skin.joints
        let jointIndexMap = Dictionary(uniqueKeysWithValues: jointNodeIndices.enumerated().map { ($0.element, $0.offset) })

        var parentMap: [Int: Int] = [:]
        for (nodeIndex, node) in nodes.enumerated() {
            for child in node.children ?? [] {
                parentMap[child] = nodeIndex
            }
        }

        var parentIndices: [Int?] = Array(repeating: nil, count: jointNodeIndices.count)
        for (i, nodeIndex) in jointNodeIndices.enumerated() {
            var current = nodeIndex
            while let parent = parentMap[current] {
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

        let roots = parentIndices.enumerated().compactMap { $0.element == nil ? $0.offset : nil }
        for root in roots {
            visit(root)
        }
        if order.count < jointNodeIndices.count {
            for i in 0..<jointNodeIndices.count where !order.contains(i) {
                visit(i)
            }
        }

        var remap: [Int] = Array(repeating: 0, count: jointNodeIndices.count)
        for (newIndex, oldIndex) in order.enumerated() {
            remap[oldIndex] = newIndex
        }

        return (parentIndices, order, remap)
    }

    private func meshResource(positions: [SIMD3<Float>],
                              normals: [SIMD3<Float>],
                              tangentFrame: TangentFrame,
                              texcoords: [SIMD2<Float>],
                              indices: [UInt32],
                              blendShapeOffsets: [[SIMD3<Float>]],
                              skeleton: MeshResource.Skeleton?,
                              jointInfluences: MeshResource.JointInfluences?) throws -> MeshResource {
        var part = MeshResource.Part(id: UUID().uuidString, materialIndex: 0)
        part.positions = MeshBuffer(positions)
        if !normals.isEmpty {
            part.normals = MeshBuffer(normals)
        }
        if !tangentFrame.tangents.isEmpty {
            part.tangents = MeshBuffer(tangentFrame.tangents)
            part.bitangents = MeshBuffer(tangentFrame.bitangents)
        }
        if !texcoords.isEmpty {
            part.textureCoordinates = MeshBuffer(texcoords)
        }
        part.triangleIndices = MeshBuffer(indices)
        if !blendShapeOffsets.isEmpty {
            for (targetIndex, offsets) in blendShapeOffsets.enumerated() {
                let name = "blendShape_\(targetIndex)"
                part.setBlendShapeOffsets(named: name, buffer: MeshBuffer(offsets))
            }
            _ = part.blendShapeNames
        }
        if let skeleton, let jointInfluences {
            part.skeletonID = skeleton.id
            part.jointInfluences = jointInfluences
        }

        let modelID = UUID().uuidString
        let model = MeshResource.Model(id: modelID, parts: [part])

        var models = MeshModelCollection()
        _ = models.insert(model)

        var instances = MeshInstanceCollection()
        _ = instances.insert(MeshResource.Instance(id: modelID, model: modelID))

        var contents = MeshResource.Contents()
        contents.models = models
        contents.instances = instances
        if let skeleton {
            var skeletons = MeshSkeletonCollection()
            _ = skeletons.insert(skeleton)
            contents.skeletons = skeletons
        }

        return try MeshResource.generate(from: contents)
    }

    private func registerSkinBinding(modelEntity: ModelEntity,
                                     skinIndex: Int,
                                     skeleton: MeshResource.Skeleton) throws {
        guard let vrmEntity = currentEntity else { return }
        let skin = try gltf.load(\.skins, at: skinIndex)
        var jointEntities = try skin.joints.map { try node(withNodeIndex: $0) }
        if let remap = try? jointIndexRemap(forSkinIndex: skinIndex), remap.count == jointEntities.count {
            var ordered: [Entity] = Array(repeating: jointEntities[0], count: jointEntities.count)
            for (oldIndex, newIndex) in remap.enumerated() {
                ordered[newIndex] = jointEntities[oldIndex]
            }
            jointEntities = ordered
        }
        vrmEntity.registerSkinBinding(modelEntity: modelEntity,
                                      skeleton: skeleton,
                                      jointEntities: jointEntities)
    }

    private func registerMaterialBindings(in root: Entity) {
        guard let vrmEntity = currentEntity else { return }
        for modelEntity in root.modelEntitiesInHierarchy {
            guard let materialIndex = modelEntity.components[VRMMaterialIndexComponent.self]?.materialIndex else {
                continue
            }
            vrmEntity.registerMaterialBinding(modelEntity: modelEntity,
                                              materialIndex: materialIndex,
                                              loader: self)
        }
    }

    private func transform(from node: GLTF.Node) -> Transform {
        if let matrix = node._matrix {
            return Transform(matrix: matrix.simdMatrix)
        }
        return Transform(scale: node.scale.simd,
                         rotation: node.rotation.simdQuat,
                         translation: node.translation.simd)
    }

    /// A complete tangent basis. RealityKit stores tangents and bitangents as two
    /// independent mesh buffers and derives neither from the other, so both are
    /// filled together or left empty together.
    private struct TangentFrame {
        static let empty = TangentFrame(tangents: [], bitangents: [])

        let tangents: [SIMD3<Float>]
        let bitangents: [SIMD3<Float>]
    }

    /// The tangent basis a normal map needs: taken from glTF `TANGENT` when the
    /// primitive has one, and otherwise derived from the UVs. Meshes whose
    /// material never samples a normal map get no basis, since nothing reads it.
    private func tangentFrame(rawTangents: [SIMD4<Float>]?,
                              positions: [SIMD3<Float>],
                              normals: [SIMD3<Float>],
                              texcoords: [SIMD2<Float>],
                              indices: [UInt32],
                              materialIndex: Int?) -> TangentFrame {
        if let rawTangents {
            // glTF stores handedness in w; the bitangent it selects is what makes
            // the basis match the normal map the asset was authored against.
            var tangents = [SIMD3<Float>](repeating: .zero, count: positions.count)
            var bitangents = tangents
            for i in 0..<positions.count {
                let raw = rawTangents[i]
                let tangent = SIMD3<Float>(raw.x, raw.y, raw.z)
                tangents[i] = tangent
                bitangents[i] = simd_cross(normals[i], tangent) * (raw.w < 0 ? -1 : 1)
            }
            return TangentFrame(tangents: tangents, bitangents: bitangents)
        }
        guard texcoords.count == positions.count,
              let materialIndex,
              materialUsesNormalTexture(withMaterialIndex: materialIndex) else {
            return .empty
        }
        return generatedTangentFrame(positions: positions,
                                     normals: normals,
                                     texcoords: texcoords,
                                     indices: indices)
    }

    /// Whether the material samples a normal map. The MToon descriptor is asked
    /// first because VRM 0.x carries its normal map in Unity's `_BumpMap`, which
    /// the migration surfaces there and not on the glTF material.
    private func materialUsesNormalTexture(withMaterialIndex index: Int) -> Bool {
        if let descriptor = try? mtoonDescriptor(withMaterialIndex: index), descriptor.normalTexture != nil {
            return true
        }
        guard let (gltfMaterial, _) = try? materialSource(withMaterialIndex: index) else { return false }
        return gltfMaterial.normalTexture != nil
    }

    /// Per-triangle UV gradients accumulated per vertex, then orthonormalized
    /// against the normal — the standard basis a normal map is authored against.
    private func generatedTangentFrame(positions: [SIMD3<Float>],
                                       normals: [SIMD3<Float>],
                                       texcoords: [SIMD2<Float>],
                                       indices: [UInt32]) -> TangentFrame {
        var tangentSums = [SIMD3<Float>](repeating: .zero, count: positions.count)
        var bitangentSums = tangentSums
        let triangleCount = indices.count / 3
        for i in 0..<triangleCount {
            let base = i * 3
            let i0 = Int(indices[base])
            let i1 = Int(indices[base + 1])
            let i2 = Int(indices[base + 2])

            let edge1 = positions[i1] - positions[i0]
            let edge2 = positions[i2] - positions[i0]
            // `texcoords` point v up, while the normal map and the shader that
            // samples it work in glTF UV space, where v points down. Negating the
            // v gradients gives the same handedness as a TANGENT accessor's.
            let deltaUV1 = gltfUVDelta(texcoords[i1] - texcoords[i0])
            let deltaUV2 = gltfUVDelta(texcoords[i2] - texcoords[i0])

            // A degenerate UV triangle carries no direction; neighbouring
            // triangles still contribute to these vertices.
            let determinant = deltaUV1.x * deltaUV2.y - deltaUV2.x * deltaUV1.y
            guard abs(determinant) > 1e-12 else { continue }
            let scale = 1 / determinant
            let tangent = (edge1 * deltaUV2.y - edge2 * deltaUV1.y) * scale
            let bitangent = (edge2 * deltaUV1.x - edge1 * deltaUV2.x) * scale
            tangentSums[i0] += tangent
            tangentSums[i1] += tangent
            tangentSums[i2] += tangent
            bitangentSums[i0] += bitangent
            bitangentSums[i1] += bitangent
            bitangentSums[i2] += bitangent
        }

        var tangents = [SIMD3<Float>](repeating: .zero, count: positions.count)
        var bitangents = tangents
        for i in 0..<positions.count {
            let normal = normals[i]
            let tangent = orthonormalizedTangent(tangentSums[i], normal: normal)
            tangents[i] = tangent
            // Mirrored UV islands need the flipped bitangent, which is what the
            // accumulated one indicates.
            let bitangent = simd_cross(normal, tangent)
            bitangents[i] = simd_dot(bitangent, bitangentSums[i]) < 0 ? -bitangent : bitangent
        }
        return TangentFrame(tangents: tangents, bitangents: bitangents)
    }

    /// A UV difference converted from the mesh's v-up texture coordinates back
    /// into glTF UV space.
    private func gltfUVDelta(_ delta: SIMD2<Float>) -> SIMD2<Float> {
        SIMD2<Float>(delta.x, -delta.y)
    }

    /// Gram-Schmidt against the normal, falling back to any perpendicular axis
    /// for vertices no usable triangle reached.
    private func orthonormalizedTangent(_ tangent: SIMD3<Float>, normal: SIMD3<Float>) -> SIMD3<Float> {
        let projected = tangent - normal * simd_dot(normal, tangent)
        if simd_length_squared(projected) > 1e-12 {
            return simd_normalize(projected)
        }
        let axis = abs(normal.x) < 0.9 ? SIMD3<Float>(1, 0, 0) : SIMD3<Float>(0, 1, 0)
        return simd_normalize(simd_cross(normal, axis))
    }

    /// Vertex normals for a primitive that ships none, accumulated from the
    /// unnormalized face normals: their length is twice the triangle area, which
    /// is the weighting a smooth normal wants.
    ///
    /// This is a deliberate departure from glTF, which asks for flat normals —
    /// and for TANGENT to be ignored — when NORMAL is absent. Flat normals need
    /// a vertex per triangle, and splitting the vertices would break the index
    /// buffer that blend-shape targets, joint influences and the outline twin all
    /// address. Every VRM ships NORMAL, so this only ever runs for a plain glTF,
    /// where a smooth-shaded model is the better failure mode than none at all.
    private func smoothNormals(positions: [SIMD3<Float>], indices: [UInt32]) -> [SIMD3<Float>] {
        var normals = [SIMD3<Float>](repeating: .zero, count: positions.count)
        let triangleCount = indices.count / 3
        for i in 0..<triangleCount {
            let base = i * 3
            let i0 = Int(indices[base])
            let i1 = Int(indices[base + 1])
            let i2 = Int(indices[base + 2])

            let faceNormal = simd_cross(positions[i1] - positions[i0], positions[i2] - positions[i0])
            guard simd_length_squared(faceNormal) > 1e-24 else { continue }
            normals[i0] += faceNormal
            normals[i1] += faceNormal
            normals[i2] += faceNormal
        }
        // Vertices no usable triangle reached keep a zero normal rather than a
        // NaN one; RealityKit treats it as unlit, which is the lesser artifact.
        for i in 0..<normals.count where simd_length_squared(normals[i]) > 1e-24 {
            normals[i] = simd_normalize(normals[i])
        }
        return normals
    }

    private func defaultMaterial() -> Material {
        var material = UnlitMaterial()
        material.color = .init(tint: .white)
        return material
    }

}

#endif
