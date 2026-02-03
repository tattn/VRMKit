#if canImport(RealityKit)
import CoreGraphics
import RealityKit
import Metal
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
    private var textureCacheBySemantic: [TextureResource.Semantic: [Int: TextureResource]] = [:]
    private var metallicRoughnessCache: [Int: (metal: TextureResource, rough: TextureResource)] = [:]
    private var samplerCache: [Int: MaterialParameters.Texture.Sampler] = [:]
    private var enableNormalTangentBlendShape = false // NOTE: Setting this to true currently has no effect

    public init(vrm: VRM, rootDirectory: URL? = nil) {
        self.vrm = vrm
        self.gltf = vrm.gltf.jsonData
        self.rootDirectory = rootDirectory
        self.entityName = vrm.meta.title
        self.entityData = EntityData(vrm: gltf)
    }

    public func loadEntity() throws -> VRMEntity {
        return try loadEntity(withSceneIndex: gltf.scene)
    }

    public func loadEntity(withSceneIndex index: Int) throws -> VRMEntity {
        if let cache = try entityData.load(\.entities, index: index) { return cache }
        let gltfScene = try gltf.load(\.scenes)[index]

        let vrmEntity = VRMEntity(vrm: vrm)
        if let entityName {
            vrmEntity.entity.name = entityName
        }
        currentEntity = vrmEntity
        defer { currentEntity = nil }
        for node in gltfScene.nodes ?? [] {
            vrmEntity.entity.addChild(try self.node(withNodeIndex: node))
        }
        vrmEntity.setUpHumanoid(nodes: entityData.nodes)
        vrmEntity.setUpBlendShapes(meshes: entityData.meshes)
        try vrmEntity.setUpSpringBones(loader: self)
        // TODO: Constraints, animations.

        entityData.entities[index] = vrmEntity
        return vrmEntity
    }

    public func loadThumbnail() throws -> VRMImage {
        guard let textureIndex = vrm.meta.texture, textureIndex >= 0 else {
            throw VRMError.thumbnailNotFound
        }
        if let cache = try entityData.load(\.images, index: textureIndex) { return cache }
        return try image(withImageIndex: textureIndex)
    }

    func node(withNodeIndex index: Int) throws -> Entity {
        if let cache = try entityData.load(\.nodes, index: index) { return cache }
        let gltfNode = try gltf.load(\.nodes)[index]

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
        let gltfCamera = try gltf.load(\.cameras)[index]
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
            return cache.clone(recursive: true)
        }

        let gltfMesh = try gltf.load(\.meshes)[index]
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
            if let modelEntity = try modelEntity(withPrimitive: resolvedPrimitive, skinIndex: skinIndex) {
                meshEntity.addChild(modelEntity)
            }
        }

        if skinIndex == nil {
            entityData.meshes[index] = meshEntity
            return meshEntity.clone(recursive: true)
        }
        if entityData.meshes.indices.contains(index), entityData.meshes[index] == nil {
            entityData.meshes[index] = meshEntity
        }
        return meshEntity
    }

    private func modelEntity(withPrimitive primitive: GLTF.Mesh.Primitive, skinIndex: Int?) throws -> ModelEntity? {
        guard supportsTriangles(primitive.mode) else { return nil }

        let attributes = primitive.attributes.rawValue
        guard let positionIndex = attributes[.POSITION] else {
            throw VRMError._dataInconsistent("POSITION attribute is missing")
        }

        let positions = try vector3s(positionIndex)

        var normals: [SIMD3<Float>]?
        if let normalIndex = attributes[.NORMAL] {
            normals = try vector3s(normalIndex)
        }
        var tangents: [SIMD3<Float>]?
        if enableNormalTangentBlendShape, let tangentIndex = attributes[.TANGENT] {
            let rawTangents = try vector4s(tangentIndex)
            tangents = rawTangents.map { SIMD3<Float>($0.x, $0.y, $0.z) }
        }
        let texcoords: [SIMD2<Float>]? = {
            if let uvIndex = attributes[.TEXCOORD_0] {
                return try? vector2s(uvIndex)
            }
            return nil
        }()
        let jointRemap: [Int]? = {
            guard let skinIndex else { return nil }
            return try? jointIndexRemap(forSkinIndex: skinIndex)
        }()
        let skinJointInfluences: ([SIMD4<UInt32>], [SIMD4<Float>])? = {
            guard skinIndex != nil,
                  let jointsIndex = attributes[.JOINTS_0],
                  let weightsIndex = attributes[.WEIGHTS_0] else {
                return nil
            }
            guard let joints = try? vector4UInts(jointsIndex),
                  let weights = try? vector4s(weightsIndex) else {
                return nil
            }
            return (joints, weights)
        }()
        var targetOffsets: [[SIMD3<Float>]] = []
        var normalOffsets: [[SIMD3<Float>]] = []
        var tangentOffsets: [[SIMD3<Float>]] = []
        if let targets = primitive.targets, !targets.isEmpty {
            let hasNormalTargets = enableNormalTangentBlendShape && targets.contains { $0[.NORMAL] != nil }
            let hasTangentTargets = enableNormalTangentBlendShape && targets.contains { $0[.TANGENT] != nil }
            targetOffsets.reserveCapacity(targets.count)
            if hasNormalTargets {
                normalOffsets.reserveCapacity(targets.count)
            }
            if hasTangentTargets {
                tangentOffsets.reserveCapacity(targets.count)
            }
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
                if hasNormalTargets {
                    if let normalAccessor = target[.NORMAL] {
                        let offsets = try vector3s(normalAccessor)
                        guard offsets.count == positions.count else {
                            throw VRMError._dataInconsistent("blend shape normal target count \(offsets.count) does not match vertex count \(positions.count)")
                        }
                        normalOffsets.append(offsets)
                    } else {
                        normalOffsets.append(Array(repeating: .zero, count: positions.count))
                    }
                }
                if hasTangentTargets {
                    if let tangentAccessor = target[.TANGENT] {
                        let offsets = try vector3s(tangentAccessor)
                        guard offsets.count == positions.count else {
                            throw VRMError._dataInconsistent("blend shape tangent target count \(offsets.count) does not match vertex count \(positions.count)")
                        }
                        tangentOffsets.append(offsets)
                    } else {
                        tangentOffsets.append(Array(repeating: .zero, count: positions.count))
                    }
                }
            }
        }

        var indexData: [UInt32]
        if let indicesAccessor = primitive.indices {
            indexData = try indexValues(indicesAccessor)
        } else {
            indexData = (0..<positions.count).map { UInt32($0) }
        }
        indexData = triangulatedIndices(for: primitive.mode, indices: indexData)
        guard !indexData.isEmpty else { return nil }

        let prepared = prepareVertexData(positions: positions,
                                                normals: normals,
                                                tangents: tangents,
                                                texcoords: texcoords,
                                                joints: skinJointInfluences?.0,
                                                weights: skinJointInfluences?.1,
                                                targetOffsets: targetOffsets,
                                                normalOffsets: normalOffsets,
                                                tangentOffsets: tangentOffsets,
                                                indexData: indexData)

        let finalPositions = prepared.positions
        let finalNormals = prepared.normals
        let finalTangents = prepared.tangents
        let finalTexcoords = prepared.texcoords
        let finalJoints = prepared.joints
        let finalWeights = prepared.weights
        let finalTargetOffsets = prepared.targetOffsets
        let finalNormalOffsets = prepared.normalOffsets
        let finalTangentOffsets = prepared.tangentOffsets
        let finalIndexData = prepared.indexData

        let material: Material = {
            if let materialIndex = primitive.material {
                return (try? self.material(withMaterialIndex: materialIndex)) ?? defaultMaterial()
            }
            return defaultMaterial()
        }()

        let hasSkinning = skinIndex != nil && !finalJoints.isEmpty
        let hasBlendShapes = !finalTargetOffsets.isEmpty
        let mesh: MeshResource
        var boundSkeleton: MeshResource.Skeleton?
        if let skinIndex, hasSkinning {
            let influences = try makeJointInfluences(joints: finalJoints,
                                                     weights: finalWeights,
                                                     vertexCount: finalPositions.count,
                                                     jointIndexRemap: jointRemap)
            let skinSkeleton = try skeleton(withSkinIndex: skinIndex)
            mesh = try meshResource(positions: finalPositions,
                                    normals: finalNormals,
                                    tangents: finalTangents,
                                    texcoords: finalTexcoords,
                                    indices: finalIndexData,
                                    blendShapeOffsets: finalTargetOffsets,
                                    skeleton: skinSkeleton,
                                    jointInfluences: influences)
            boundSkeleton = skinSkeleton
        } else {
            mesh = try meshResource(positions: finalPositions,
                                    normals: finalNormals,
                                    tangents: finalTangents,
                                    texcoords: finalTexcoords,
                                    indices: finalIndexData,
                                    blendShapeOffsets: finalTargetOffsets,
                                    skeleton: nil,
                                    jointInfluences: nil)
        }

        let modelEntity = ModelEntity(mesh: mesh, materials: [material])
        if hasBlendShapes {
            let mapping = BlendShapeWeightsMapping(meshResource: mesh)
            modelEntity.components.set(BlendShapeWeightsComponent(weightsMapping: mapping))
        }
        if enableNormalTangentBlendShape,
           !finalNormalOffsets.isEmpty || !finalTangentOffsets.isEmpty {
            let component = BlendShapeNormalTangentComponent(baseNormals: finalNormals,
                                                             baseTangents: finalTangents,
                                                             normalOffsets: finalNormalOffsets,
                                                             tangentOffsets: finalTangentOffsets)
            modelEntity.components.set(component)
        }
        if let skinIndex, let boundSkeleton {
            try registerSkinBinding(modelEntity: modelEntity, skinIndex: skinIndex, skeleton: boundSkeleton)
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

    private func triangulatedIndices(for mode: GLTF.Mesh.Primitive.Mode,
                                     indices: [UInt32]) -> [UInt32] {
        switch mode {
        case .TRIANGLES:
            let count = indices.count / 3 * 3
            return Array(indices.prefix(count))
        case .TRIANGLE_STRIP:
            guard indices.count >= 3 else { return [] }
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
            guard indices.count >= 3 else { return [] }
            let base = indices[0]
            var result: [UInt32] = []
            result.reserveCapacity((indices.count - 2) * 3)
            for i in 1..<(indices.count - 1) {
                result.append(contentsOf: [base, indices[i], indices[i + 1]])
            }
            return result
        case .POINTS, .LINES, .LINE_LOOP, .LINE_STRIP:
            return []
        }
    }

    func material(withMaterialIndex index: Int) throws -> Material {
        if let cache = try entityData.load(\.materials, index: index) { return cache }
        let gltfMaterial = try gltf.load(\.materials)[index]

        let materialProperty: VRM0.MaterialProperty? = {
            guard let name = gltfMaterial.name else { return nil }
            return vrm.materialPropertyNameMap[name]
        }()
        let shaderName = materialProperty?.shader.lowercased()
        // MToon / Unlit variants are not PBR, so use UnlitMaterial for consistent rendering
        // This matches SceneKit's behavior which uses lightingModel = .constant
        let isMToon = shaderName?.contains("mtoon") == true || gltfMaterial.extensions?.materialsMToon != nil
        let isUnlit = shaderName?.contains("unlit") == true || gltfMaterial.extensions?.materialsUnlit != nil
        let useUnlit = isMToon || isUnlit
        let hasAlphaPremultiply = materialProperty?.keywordMap["_ALPHAPREMULTIPLY_ON"] == true
        let hasAlphaBlend = materialProperty?.keywordMap["_ALPHABLEND_ON"] == true
        let hasAlphaTest = materialProperty?.keywordMap["_ALPHATEST_ON"] == true
        let forceBlend = materialProperty?.vrmShader == .unlitTransparent || hasAlphaPremultiply || hasAlphaBlend
        let resolvedAlphaMode: GLTF.Material.AlphaMode = {
            if let renderType = materialProperty?.tagMap["RenderType"]?.lowercased() {
                switch renderType {
                case "opaque":
                    return .OPAQUE
                case "transparentcutout", "cutout":
                    return .MASK
                case "transparent":
                    return .BLEND
                default:
                    break
                }
            }
            if forceBlend { return .BLEND }
            if hasAlphaTest { return .MASK }
            return gltfMaterial.alphaMode
        }()

        let tint: VRMColor = {
            guard let pbr = gltfMaterial.pbrMetallicRoughness else {
                return .white
            }
            let factor = pbr.baseColorFactor
            let hasExplicitFactor = !(factor.r == 0 && factor.g == 0 && factor.b == 0 && factor.a == 0)
            if !hasExplicitFactor {
                return .white
            }
            return VRMColor(red: CGFloat(factor.r),
                           green: CGFloat(factor.g),
                           blue: CGFloat(factor.b),
                           alpha: CGFloat(factor.a))
        }()

        if useUnlit {
            var material = UnlitMaterial()
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

    func texture(withTextureIndex index: Int, semantic: TextureResource.Semantic = .color) throws -> TextureResource {
        if semantic == .color, let cache = try entityData.load(\.textures, index: index) {
            return cache
        }
        if semantic != .color, let cache = textureCacheBySemantic[semantic]?[index] {
            return cache
        }
        let gltfTexture = try gltf.load(\.textures)[index]
        let image = try image(withImageIndex: gltfTexture.source)
        let cgImage = try image.cgImage ??? .dataInconsistent("failed to load cgImage")
        let texture = try TextureResource(image: cgImage, options: .init(semantic: semantic))
        if semantic == .color {
            entityData.textures[index] = texture
        } else {
            var cache = textureCacheBySemantic[semantic] ?? [:]
            cache[index] = texture
            textureCacheBySemantic[semantic] = cache
        }
        return texture
    }

    private func materialTexture(withTextureIndex index: Int,
                                 semantic: TextureResource.Semantic = .color) throws -> MaterialParameters.Texture {
        let texture = try texture(withTextureIndex: index, semantic: semantic)
        let sampler = try sampler(withTextureIndex: index)
        return MaterialParameters.Texture(texture, sampler: sampler)
    }

    private func sampler(withTextureIndex index: Int) throws -> MaterialParameters.Texture.Sampler {
        if let cache = samplerCache[index] {
            return cache
        }
        let gltfTexture = try gltf.load(\.textures)[index]
        let descriptor = MTLSamplerDescriptor()
        if let samplerIndex = gltfTexture.sampler {
            let sampler = try gltf.load(\.samplers)[samplerIndex]
            applySampler(sampler, to: descriptor)
        } else {
            applyDefaultSampler(to: descriptor)
        }
        let sampler = MaterialParameters.Texture.Sampler(descriptor)
        samplerCache[index] = sampler
        return sampler
    }

    private func applySampler(_ sampler: GLTF.Sampler, to descriptor: MTLSamplerDescriptor) {
        let magFilter = sampler.magFilter ?? .LINEAR
        let minFilter = sampler.minFilter ?? .LINEAR_MIPMAP_LINEAR
        descriptor.magFilter = metalFilter(magFilter)
        let (min, mip) = metalFilters(minFilter)
        descriptor.minFilter = min
        descriptor.mipFilter = mip
        descriptor.sAddressMode = metalWrap(sampler.wrapS)
        descriptor.tAddressMode = metalWrap(sampler.wrapT)
    }

    private func applyDefaultSampler(to descriptor: MTLSamplerDescriptor) {
        descriptor.magFilter = metalFilter(.LINEAR)
        let (min, mip) = metalFilters(.LINEAR_MIPMAP_LINEAR)
        descriptor.minFilter = min
        descriptor.mipFilter = mip
        descriptor.sAddressMode = metalWrap(.REPEAT)
        descriptor.tAddressMode = metalWrap(.REPEAT)
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
        let gltfImage = try gltf.load(\.images)[index]
        let image = try VRMImage.from(gltfImage, relativeTo: rootDirectory, loader: self)
        entityData.images[index] = image
        return image
    }

    func bufferView(withBufferViewIndex index: Int) throws -> (bufferView: Data, stride: Int?) {
        if let cache = try entityData.load(\.bufferViews, index: index) {
            let gltfBufferView = try gltf.load(\.bufferViews)[index]
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
            let gltfTexture = try gltf.load(\.textures)[index]
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

    private func applyAlphaMode(_ mode: GLTF.Material.AlphaMode,
                                alphaCutoff: Float,
                                to material: inout UnlitMaterial) {
        switch mode {
        case .OPAQUE:
            material.blending = .opaque
            material.opacityThreshold = nil
        case .MASK:
            material.blending = .opaque
            material.opacityThreshold = alphaCutoff
        case .BLEND:
            material.blending = .transparent(opacity: .init(scale: 1.0))
            material.opacityThreshold = nil
        }
    }

    private func applyAlphaMode(_ mode: GLTF.Material.AlphaMode,
                                alphaCutoff: Float,
                                to material: inout PhysicallyBasedMaterial) {
        switch mode {
        case .OPAQUE:
            material.blending = .opaque
            material.opacityThreshold = nil
        case .MASK:
            material.blending = .opaque
            material.opacityThreshold = alphaCutoff
        case .BLEND:
            material.blending = .transparent(opacity: .init(scale: 1.0))
            material.opacityThreshold = nil
        }
    }

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
        let accessor = try gltf.load(\.accessors)[index]
        let (componentsPerVector, bytesPerComponent, vectorSize) = accessor.components()

        let baseData: Data = try {
            if let bufferViewIndex = accessor.bufferView {
                let bufferView = try self.bufferView(withBufferViewIndex: bufferViewIndex)
                let dataStride = bufferView.stride ?? vectorSize
                return bufferView.bufferView.subdata(offset: accessor.byteOffset,
                                                     size: vectorSize,
                                                     stride: dataStride,
                                                     count: accessor.count)
            }
            return Data(count: vectorSize * accessor.count)
        }()

        var data = baseData
        if let sparse = accessor.sparse {
            try applySparse(sparse: sparse,
                            accessorCount: accessor.count,
                            vectorSize: vectorSize,
                            data: &data)
        }

        let slice = AccessorSlice(
            data: data,
            componentsPerVector: componentsPerVector,
            bytesPerComponent: bytesPerComponent,
            count: accessor.count,
            componentType: accessor.componentType,
            normalized: accessor.normalized
        )
        entityData.accessors[index] = slice
        return slice
    }

    private func applySparse(sparse: GLTF.Accessor.Sparse,
                             accessorCount: Int,
                             vectorSize: Int,
                             data: inout Data) throws {
        guard sparse.count > 0 else { return }
        let indices = try sparseIndices(sparse: sparse)
        let values = try sparseValues(sparse: sparse, vectorSize: vectorSize)
        let count = min(indices.count, sparse.count)
        data.withUnsafeMutableBytes { rawDst in
            guard let dst = rawDst.bindMemory(to: UInt8.self).baseAddress else { return }
            values.withUnsafeBytes { rawSrc in
                guard let src = rawSrc.bindMemory(to: UInt8.self).baseAddress else { return }
                for i in 0..<count {
                    let index = indices[i]
                    guard index >= 0, index < accessorCount else { continue }
                    let dstPos = index * vectorSize
                    let srcPos = i * vectorSize
                    memcpy(dst.advanced(by: dstPos), src.advanced(by: srcPos), vectorSize)
                }
            }
        }
    }

    private func sparseIndices(sparse: GLTF.Accessor.Sparse) throws -> [Int] {
        let bufferView = try self.bufferView(withBufferViewIndex: sparse.indices.bufferView)
        let bytesPerIndex = bytes(of: sparse.indices.componentType)
        let stride = bufferView.stride ?? bytesPerIndex
        let indexData = bufferView.bufferView.subdata(offset: sparse.indices.byteOffset,
                                                      size: bytesPerIndex,
                                                      stride: stride,
                                                      count: sparse.count)
        var indices: [Int] = []
        indices.reserveCapacity(sparse.count)
        indexData.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            for i in 0..<sparse.count {
                let offset = i * bytesPerIndex
                switch sparse.indices.componentType {
                case .unsignedByte:
                    indices.append(Int(base.load(fromByteOffset: offset, as: UInt8.self)))
                case .unsignedShort:
                    indices.append(Int(base.load(fromByteOffset: offset, as: UInt16.self)))
                case .unsignedInt:
                    indices.append(Int(base.load(fromByteOffset: offset, as: UInt32.self)))
                default:
                    break
                }
            }
        }
        return indices
    }

    private func sparseValues(sparse: GLTF.Accessor.Sparse,
                              vectorSize: Int) throws -> Data {
        let bufferView = try self.bufferView(withBufferViewIndex: sparse.values.bufferView)
        let stride = bufferView.stride ?? vectorSize
        return bufferView.bufferView.subdata(offset: sparse.values.byteOffset,
                                             size: vectorSize,
                                             stride: stride,
                                             count: sparse.count)
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
                let baseOffset = i * slice.bytesPerComponent
                let value: UInt32
                switch slice.componentType {
                case .unsignedByte:
                    value = UInt32(base.load(fromByteOffset: baseOffset, as: UInt8.self))
                case .unsignedShort:
                    value = UInt32(base.load(fromByteOffset: baseOffset, as: UInt16.self))
                case .unsignedInt:
                    value = UInt32(base.load(fromByteOffset: baseOffset, as: UInt32.self))
                case .byte, .short, .float:
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

    private func readIndexComponent(base: UnsafeRawPointer,
                                    offset: Int,
                                    componentType: GLTF.Accessor.ComponentType) -> UInt32 {
        switch componentType {
        case .unsignedByte:
            return UInt32(base.load(fromByteOffset: offset, as: UInt8.self))
        case .unsignedShort:
            return UInt32(base.load(fromByteOffset: offset, as: UInt16.self))
        case .unsignedInt:
            return base.load(fromByteOffset: offset, as: UInt32.self)
        case .byte:
            return UInt32(Int32(base.load(fromByteOffset: offset, as: Int8.self)))
        case .short:
            return UInt32(Int32(base.load(fromByteOffset: offset, as: Int16.self)))
        case .float:
            return UInt32(base.load(fromByteOffset: offset, as: Float.self))
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
                let x = readIndexComponent(base: base,
                                           offset: baseOffset,
                                           componentType: slice.componentType)
                let y = readIndexComponent(base: base,
                                           offset: baseOffset + slice.bytesPerComponent,
                                           componentType: slice.componentType)
                let z = readIndexComponent(base: base,
                                           offset: baseOffset + slice.bytesPerComponent * 2,
                                           componentType: slice.componentType)
                let w = readIndexComponent(base: base,
                                           offset: baseOffset + slice.bytesPerComponent * 3,
                                           componentType: slice.componentType)
                result.append(SIMD4<UInt32>(x, y, z, w))
            }
        }
        if result.count != slice.count {
            throw VRMError._dataInconsistent("failed to read joint indices")
        }
        return result
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
            let j0 = remap.map { $0[Int(joint.x)] } ?? Int(joint.x)
            let j1 = remap.map { $0[Int(joint.y)] } ?? Int(joint.y)
            let j2 = remap.map { $0[Int(joint.z)] } ?? Int(joint.z)
            let j3 = remap.map { $0[Int(joint.w)] } ?? Int(joint.w)
            influences.append(MeshJointInfluence(jointIndex: j0, weight: w0))
            influences.append(MeshJointInfluence(jointIndex: j1, weight: w1))
            influences.append(MeshJointInfluence(jointIndex: j2, weight: w2))
            influences.append(MeshJointInfluence(jointIndex: j3, weight: w3))
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
        let skin = try gltf.load(\.skins)[index]
        let nodes = try gltf.load(\.nodes)
        let (parentIndices, order, remap) = computeSkinJointOrdering(skin: skin, nodes: nodes)
        entityData.skinJointRemaps[index] = remap

        let inverseBindMatrices: [simd_float4x4] = {
            guard let accessorIndex = skin.inverseBindMatrices else {
                return Array(repeating: matrix_identity_float4x4, count: skin.joints.count)
            }
            return (try? matrix4s(accessorIndex)) ?? Array(repeating: matrix_identity_float4x4, count: skin.joints.count)
        }()

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
            let ibm = oldIndex < inverseBindMatrices.count ? inverseBindMatrices[oldIndex] : matrix_identity_float4x4
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
        let skin = try gltf.load(\.skins)[index]
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

    private func applySkinning(to mesh: MeshResource,
                               skinIndex: Int,
                               jointInfluences: MeshResource.JointInfluences) throws -> MeshResource.Skeleton {
        let skeleton = try skeleton(withSkinIndex: skinIndex)
        var contents = mesh.contents
        var skeletons = contents.skeletons
        _ = skeletons.insert(skeleton)
        contents.skeletons = skeletons

        var updatedModels = MeshModelCollection()
        for model in contents.models {
            var model = model
            var updatedParts = MeshPartCollection()
            for part in model.parts {
                var part = part
                part.skeletonID = skeleton.id
                part.jointInfluences = jointInfluences
                updatedParts.insert(part)
            }
            model.parts = updatedParts
            updatedModels.insert(model)
        }
        contents.models = updatedModels
        try mesh.replace(with: contents)
        return skeleton
    }

    private func meshResource(positions: [SIMD3<Float>],
                              normals: [SIMD3<Float>],
                              tangents: [SIMD3<Float>],
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
        if !tangents.isEmpty {
            part.tangents = MeshBuffer(tangents)
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
        let skin = try gltf.load(\.skins)[skinIndex]
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

    private func transform(from node: GLTF.Node) -> Transform {
        if let matrix = node._matrix {
            return Transform(matrix: matrix.simdMatrix)
        }
        return Transform(scale: node.scale.simd,
                         rotation: node.rotation.simdQuat,
                         translation: node.translation.simd)
    }

    private func estimateNormals(positions: [SIMD3<Float>], indices: [UInt32]) -> [SIMD3<Float>] {
        var normals = [SIMD3<Float>](repeating: .zero, count: positions.count)
        let triangleCount = indices.count / 3
        for i in 0..<triangleCount {
            let base = i * 3
            let i0 = Int(indices[base])
            let i1 = Int(indices[base + 1])
            let i2 = Int(indices[base + 2])

            let v0 = positions[i0]
            let v1 = positions[i1]
            let v2 = positions[i2]

            let n = normal(v0, v1, v2)
            normals[i0] += n
            normals[i1] += n
            normals[i2] += n
        }
        for i in 0..<normals.count {
            normals[i].normalize()
        }
        return normals
    }

    private func defaultMaterial() -> Material {
        var material = UnlitMaterial()
        material.color = .init(tint: .white)
        return material
    }

    private struct PreparedMeshBuffers {
        let positions: [SIMD3<Float>]
        let normals: [SIMD3<Float>]
        let tangents: [SIMD3<Float>]
        let texcoords: [SIMD2<Float>]
        let joints: [SIMD4<UInt32>]
        let weights: [SIMD4<Float>]
        let targetOffsets: [[SIMD3<Float>]]
        let normalOffsets: [[SIMD3<Float>]]
        let tangentOffsets: [[SIMD3<Float>]]
        let indexData: [UInt32]
    }

    private func prepareVertexData(positions: [SIMD3<Float>],
                                         normals: [SIMD3<Float>]?,
                                         tangents: [SIMD3<Float>]?,
                                         texcoords: [SIMD2<Float>]?,
                                         joints: [SIMD4<UInt32>]?,
                                         weights: [SIMD4<Float>]?,
                                         targetOffsets: [[SIMD3<Float>]],
                                         normalOffsets: [[SIMD3<Float>]],
                                         tangentOffsets: [[SIMD3<Float>]],
                                         indexData: [UInt32]) -> PreparedMeshBuffers {
        let finalNormals: [SIMD3<Float>]
        if let normals {
            finalNormals = normals
        } else {
            finalNormals = estimateNormals(positions: positions, indices: indexData)
        }
        return PreparedMeshBuffers(positions: positions,
                                    normals: finalNormals,
                                    tangents: tangents ?? [],
                                    texcoords: texcoords ?? [],
                                    joints: joints ?? [],
                                    weights: weights ?? [],
                                    targetOffsets: targetOffsets,
                                    normalOffsets: normalOffsets,
                                    tangentOffsets: tangentOffsets,
                                    indexData: indexData)
    }
}

#endif
