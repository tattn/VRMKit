import Foundation
import simd

/// The VRM 0.x MToon material property and ``MToonMaterialDescriptor``, mapped
/// onto each other in both directions, following UniVRM's `MToon10Migrator`
/// for reading and its inverse for writing.
///
/// Both directions live here so that a value gaining a reading rule needs a
/// writing rule in the same file; `MToonWritingTests` fails until it has one.
package enum VRM0MToonProperty {
    package static func descriptor(property: VRM0.MaterialProperty,
                                   material: GLTF.Material) -> MToonMaterialDescriptor {
        let floats = property.floatProperties.dictionaryValue
        let textures = property.textureProperties
        let vectors = property.vectorProperties.dictionaryValue
        let pbr = material.pbrMetallicRoughness

        // VRM 0.x stores Lit / Shade / Rim / Outline colors as sRGB, while
        // MToon 1.0 factors are linear. UniVRM treats emission and the glTF
        // baseColorFactor fallback as already linear.
        let baseColor = vectors.simd4("_Color").map(srgbToLinear)
            ?? (pbr?.baseColorFactor).map(SIMD4<Float>.init)
            ?? SIMD4<Float>(1, 1, 1, 1)
        let emissiveColor = vectors.simd3("_EmissionColor") ?? SIMD3<Float>(0, 0, 0)
        let shadeColor = srgbToLinear(vectors.simd4("_ShadeColor") ?? SIMD4<Float>(0.97, 0.81, 0.86, 1))
        let rimColor = srgbToLinear(vectors.simd4("_RimColor") ?? SIMD4<Float>(0, 0, 0, 1))
        let outlineColor = srgbToLinear(vectors.simd4("_OutlineColor") ?? SIMD4<Float>(0, 0, 0, 1))

        let alphaMode = GLTF.Material.AlphaMode(vrm0: property, fallback: material.alphaMode)
        // MToon 0.x has no `_ZWRITE_ON` shader keyword: the render mode lives in
        // `_BlendMode` (3 = TransparentWithZWrite), which is what MToon10Migrator
        // reads. `_ZWrite` is derived state, so it only separates the two
        // transparent modes -- opaque materials write depth as well.
        let transparentWithZWrite: Bool
        switch floats.float("_BlendMode") {
        case .some(3):
            transparentWithZWrite = true
        case .some:
            transparentWithZWrite = false
        default:
            transparentWithZWrite = alphaMode == .BLEND && floats.float("_ZWrite") == 1
        }
        let cullMode = MToonMaterialDescriptor.CullMode(vrm0: floats.float("_CullMode"))
            ?? (material.doubleSided ? .none : .back)
        let hasMToonNormalTexture = textures["_BumpMap"] != nil
        let shadeShift0 = floats.float("_ShadeShift") ?? 0
        let shadeToony0 = floats.float("_ShadeToony") ?? 0.9
        let rangeMin = shadeShift0
        let rangeMax = simd_mix(Float(1), shadeShift0, shadeToony0)

        let outlineWidthMode = MToonMaterialDescriptor.OutlineWidthMode(vrm0: floats.float("_OutlineWidthMode") ?? 0)
        let outlineWidthFactor = (floats.float("_OutlineWidth") ?? 0) * outlineWidthMode.vrm0WidthScale
        let outlineLightingMixFactor: Float
        switch floats.float("_OutlineColorMode") ?? 0 {
        case 0: // FixedColor renders the outline unlit.
            outlineLightingMixFactor = 0
        default: // MixedLighting keeps the source mix value.
            outlineLightingMixFactor = floats.float("_OutlineLightingMix") ?? 1
        }

        // UniVRM keeps the _MainTex scale/offset as the material's texture
        // transform during migration; MToon 0.x applied it to every texture.
        let mainTransform = mainTextureTransform(vectors: vectors)
        func texture(_ index: Int?) -> MToonMaterialDescriptor.Texture? {
            index.map { .init(index: $0, texCoord: 0, transform: mainTransform) }
        }

        return MToonMaterialDescriptor(
            baseColorFactor: baseColor,
            emissiveFactor: emissiveColor,
            shadeColorFactor: shadeColor,
            shadingShiftFactor: (-(rangeMax + rangeMin) / 2).clamped(to: -1 ... 1),
            shadingShiftTextureScale: 1,
            shadingToonyFactor: ((2 - (rangeMax - rangeMin)) / 2).clamped(to: 0 ... 1),
            giEqualizationFactor: (1 - (floats.float("_IndirectLightIntensity") ?? 0.1)).clamped(to: 0 ... 1),
            matcapFactor: SIMD3<Float>(1, 1, 1),
            parametricRimColorFactor: rimColor,
            // UniVRM migrates rim lighting mix destructively to 1.0 for
            // visual compatibility; the 0.x source value is intentionally dropped.
            rimLightingMixFactor: 1,
            parametricRimFresnelPowerFactor: floats.float("_RimFresnelPower") ?? 1,
            parametricRimLiftFactor: floats.float("_RimLift") ?? 0,
            outlineWidthMode: outlineWidthMode,
            outlineWidthFactor: outlineWidthFactor,
            outlineColorFactor: outlineColor,
            outlineLightingMixFactor: outlineLightingMixFactor,
            uvAnimationScrollXSpeedFactor: floats.float("_UvAnimScrollX") ?? 0,
            // UniVRM inverts the Y scroll direction during migration.
            uvAnimationScrollYSpeedFactor: -(floats.float("_UvAnimScrollY") ?? 0),
            uvAnimationRotationSpeedFactor: (floats.float("_UvAnimRotation") ?? 0) * 2 * Float.pi,
            transparentWithZWrite: transparentWithZWrite,
            // renderQueueOffsetNumber is a *relative* order among a model's
            // transparent materials; a single material carries no such ordering,
            // so Unity's absolute renderQueue cannot be migrated here.
            renderQueueOffsetNumber: 0,
            alphaMode: alphaMode,
            alphaCutoff: floats.float("_Cutoff") ?? material.alphaCutoff,
            cullMode: cullMode,
            normalScale: hasMToonNormalTexture
                ? (floats.float("_BumpScale") ?? 1)
                : Float(material.normalTexture?.scale ?? 1),
            baseColorTexture: texture(textures["_MainTex"]),
            emissiveTexture: texture(textures["_EmissionMap"]),
            shadeMultiplyTexture: texture(textures["_ShadeTexture"] ?? textures["_MainTex"]),
            shadingShiftTexture: nil,
            normalTexture: texture(textures["_BumpMap"])
                ?? material.normalTexture.map { .init(index: $0.index, texCoord: $0.texCoord) },
            matcapTexture: texture(textures["_SphereAdd"]),
            rimMultiplyTexture: texture(textures["_RimTexture"]),
            outlineWidthMultiplyTexture: texture(textures["_OutlineWidthTexture"]),
            uvAnimationMaskTexture: texture(textures["_UvAnimMaskTexture"])
        )
    }

    /// Converts Unity `_MainTex` scale/offset (bottom-left UV origin) into
    /// KHR_texture_transform semantics (top-left origin). Returns nil for the
    /// identity transform.
    static func mainTextureTransform(vectors: [String: Any]) -> MToonMaterialDescriptor.UVTransform? {
        guard let values = vectors["_MainTex"] as? [Any], values.count >= 4 else {
            return nil
        }
        let offsetX = values.float(at: 0, default: 0)
        let offsetY = values.float(at: 1, default: 0)
        let scaleX = values.float(at: 2, default: 1)
        let scaleY = values.float(at: 3, default: 1)
        guard offsetX != 0 || offsetY != 0 || scaleX != 1 || scaleY != 1 else {
            return nil
        }
        return .init(scale: SIMD2<Float>(scaleX, scaleY),
                     offset: SIMD2<Float>(offsetX, 1 - offsetY - scaleY),
                     rotation: 0)
    }

    static func srgbToLinear(_ value: SIMD4<Float>) -> SIMD4<Float> {
        SIMD4<Float>(SRGB.toLinear(value.x),
                     SRGB.toLinear(value.y),
                     SRGB.toLinear(value.z),
                     value.w)
    }

    static func linearToSRGB(_ value: SIMD4<Float>) -> [Float] {
        [SRGB.fromLinear(value.x), SRGB.fromLinear(value.y), SRGB.fromLinear(value.z), value.w]
    }
}

private extension MToonMaterialDescriptor.OutlineWidthMode {
    /// The `_OutlineWidthMode` Unity writes, which reading and writing share so
    /// that the two cannot disagree about what a 1 or a 2 means.
    var vrm0Code: Int {
        switch self {
        case .none: 0
        case .worldCoordinates: 1
        case .screenCoordinates: 2
        }
    }

    /// How far VRM 0.x `_OutlineWidth` is from the MToon 1.0 factor: 0.x
    /// measures world space in centimeters, and UniVRM halves screen space on
    /// the way to 1.0.
    var vrm0WidthScale: Float {
        switch self {
        case .none: 0
        case .worldCoordinates: 0.01
        case .screenCoordinates: 0.01 * 0.5
        }
    }

    init(vrm0 mode: Float) {
        self = [Self.worldCoordinates, .screenCoordinates].first { Float($0.vrm0Code) == mode } ?? .none
    }
}

private extension MToonMaterialDescriptor.CullMode {
    /// The `_CullMode` Unity writes, shared by reading and writing.
    var vrm0Code: Int {
        switch self {
        case .none: 0
        case .front: 1
        case .back: 2
        }
    }

    init?(vrm0 mode: Float?) {
        guard let match = [Self.none, .front, .back].first(where: { Float($0.vrm0Code) == mode }) else {
            return nil
        }
        self = match
    }
}

package extension GLTF.Material.AlphaMode {
    /// The Unity `RenderType` tag this mode is written under.
    var vrm0RenderTypeTag: String {
        switch self {
        case .MASK: "TransparentCutout"
        case .BLEND: "Transparent"
        case .OPAQUE: "Opaque"
        }
    }

    /// The Unity render queue this mode is written under.
    ///
    /// MToon draws a depth-writing transparent material before the rest of
    /// them, so the two blend modes share a `RenderType` tag but not a queue:
    /// UniVRM starts the depth-writing ones at 2501 and the others at 3000.
    func vrm0RenderQueue(transparentWithZWrite: Bool) -> Int {
        switch self {
        case .MASK: 2450
        case .BLEND: transparentWithZWrite ? 2501 : 3000
        case .OPAQUE: 2000
        }
    }
}

package extension GLTF.Material.AlphaMode {
    /// Resolves the glTF alpha mode from VRM 0.x Unity shader metadata.
    /// `RenderType` takes priority over the keyword map, matching UniVRM.
    init(vrm0 property: VRM0.MaterialProperty?, fallback: GLTF.Material.AlphaMode) {
        guard let property else {
            self = fallback
            return
        }
        if let renderType = property.tagMap["RenderType"]?.lowercased() {
            switch renderType {
            case "opaque":
                self = .OPAQUE
                return
            case "transparentcutout", "cutout":
                self = .MASK
                return
            case "transparent":
                self = .BLEND
                return
            default:
                break
            }
        }

        if property.vrmShader == .unlitTransparent
            || property.keywordMap["_ALPHAPREMULTIPLY_ON"] == true
            || property.keywordMap["_ALPHABLEND_ON"] == true {
            self = .BLEND
        } else if property.keywordMap["_ALPHATEST_ON"] == true {
            self = .MASK
        } else {
            self = fallback
        }
    }
}

// MARK: - Writing

package extension VRM0MToonProperty {
    /// The entry a material with no VRM 0.x settings of its own gets, telling
    /// the 0.x runtime to render the glTF material unchanged. Every key
    /// ``VRM0/MaterialProperty`` requires is present, since a missing one fails
    /// the decode of the whole document.
    static func gltfShaderProperty(name: String?) -> JSONObject {
        property(name: name,
                 shader: .gltfShader,
                 renderQueue: GLTF.Material.AlphaMode.OPAQUE.vrm0RenderQueue(transparentWithZWrite: false),
                 floats: [:],
                 textures: [:],
                 vectors: [:],
                 keywordMap: [:],
                 renderType: nil)
    }

    private static func property(name: String?,
                                 shader: VRM0.MaterialProperty.Shader,
                                 renderQueue: Int,
                                 floats: JSONObject,
                                 textures: JSONObject,
                                 vectors: JSONObject,
                                 keywordMap: JSONObject,
                                 renderType: String?) -> JSONObject {
        [
            "name": name ?? "",
            "shader": shader.rawValue,
            "renderQueue": renderQueue,
            "floatProperties": floats,
            "keywordMap": keywordMap,
            "tagMap": renderType.map { ["RenderType": $0] as JSONObject } ?? JSONObject(),
            "textureProperties": textures,
            "vectorProperties": vectors,
        ]
    }

    /// The VRM 0.x `materialProperties` entry, the inverse of
    /// ``descriptor(property:material:)``.
    ///
    /// `renderQueueOffsetNumber` has no Unity counterpart a single material can
    /// carry, and is dropped as reading never produces it. UV state the format
    /// cannot carry is refused, as ``validateVRM0RepresentableUV(of:)`` says.
    static func materialProperty(from descriptor: MToonMaterialDescriptor, name: String?) throws -> JSONObject {
        try validateVRM0RepresentableUV(of: descriptor)
        let shading = shadeShiftAndToony(shadingShiftFactor: descriptor.shadingShiftFactor,
                                         shadingToonyFactor: descriptor.shadingToonyFactor)
        let isBlend = descriptor.alphaMode == .BLEND
        let floats: JSONObject = [
            "_Cutoff": descriptor.alphaCutoff,
            "_BumpScale": descriptor.normalScale,
            "_ShadeShift": shading.shift,
            "_ShadeToony": shading.toony,
            "_IndirectLightIntensity": 1 - descriptor.giEqualizationFactor,
            "_RimFresnelPower": descriptor.parametricRimFresnelPowerFactor,
            "_RimLift": descriptor.parametricRimLiftFactor,
            "_RimLightingMix": descriptor.rimLightingMixFactor,
            "_OutlineWidthMode": descriptor.outlineWidthMode.vrm0Code,
            "_OutlineWidth": descriptor.outlineWidthMode.vrm0WidthScale == 0
                ? 0
                : descriptor.outlineWidthFactor / descriptor.outlineWidthMode.vrm0WidthScale,
            // FixedColor renders the outline unlit, which is the only lighting
            // mix that mode can carry.
            "_OutlineColorMode": descriptor.outlineLightingMixFactor == 0 ? 0 : 1,
            "_OutlineLightingMix": descriptor.outlineLightingMixFactor,
            "_OutlineScaledMaxDistance": 1,
            "_UvAnimScrollX": descriptor.uvAnimationScrollXSpeedFactor,
            // UniVRM inverts the Y scroll direction and reads rotation in turns.
            "_UvAnimScrollY": -descriptor.uvAnimationScrollYSpeedFactor,
            "_UvAnimRotation": descriptor.uvAnimationRotationSpeedFactor / (2 * Float.pi),
            "_BlendMode": blendMode(of: descriptor),
            "_CullMode": descriptor.cullMode.vrm0Code,
            "_OutlineCullMode": 1,
            "_ZWrite": isBlend && !descriptor.transparentWithZWrite ? 0 : 1,
            "_SrcBlend": isBlend ? 5 : 1,
            "_DstBlend": isBlend ? 10 : 0,
            "_LightColorAttenuation": 0,
            "_ReceiveShadowRate": 1,
            "_ShadingGradeRate": 1,
            "_DebugMode": 0,
        ]

        var textures = JSONObject()
        textures.set("_MainTex", descriptor.baseColorTexture?.index)
        textures.set("_ShadeTexture", descriptor.shadeMultiplyTexture?.index)
        textures.set("_BumpMap", descriptor.normalTexture?.index)
        textures.set("_EmissionMap", descriptor.emissiveTexture?.index)
        textures.set("_SphereAdd", descriptor.matcapTexture?.index)
        textures.set("_RimTexture", descriptor.rimMultiplyTexture?.index)
        textures.set("_OutlineWidthTexture", descriptor.outlineWidthMultiplyTexture?.index)
        textures.set("_UvAnimMaskTexture", descriptor.uvAnimationMaskTexture?.index)

        let vectors: JSONObject = [
            "_Color": linearToSRGB(descriptor.baseColorFactor),
            "_ShadeColor": linearToSRGB(descriptor.shadeColorFactor),
            // UniVRM reads emission as linear, unlike the other colors.
            "_EmissionColor": [descriptor.emissiveFactor.x, descriptor.emissiveFactor.y,
                               descriptor.emissiveFactor.z, 1],
            "_RimColor": linearToSRGB(descriptor.parametricRimColorFactor),
            "_OutlineColor": linearToSRGB(descriptor.outlineColorFactor),
            "_MainTex": mainTextureVector(of: descriptor.baseColorTexture?.transform),
        ]

        return property(name: name,
                        shader: .mToon,
                        renderQueue: descriptor.alphaMode
                            .vrm0RenderQueue(transparentWithZWrite: descriptor.transparentWithZWrite),
                        floats: floats,
                        textures: textures,
                        vectors: vectors,
                        keywordMap: keywordMap(of: descriptor),
                        renderType: descriptor.alphaMode.vrm0RenderTypeTag)
    }

    /// The `_ShadeShift` / `_ShadeToony` pair whose migration yields the given
    /// shading factors. Reading turns the pair into the range
    /// `[shift, mix(1, shift, toony)]` and then into its midpoint and width;
    /// this solves that back.
    static func shadeShiftAndToony(shadingShiftFactor: Float,
                                   shadingToonyFactor: Float) -> (shift: Float, toony: Float) {
        let rangeMin = -shadingShiftFactor + shadingToonyFactor - 1
        let rangeMax = -shadingShiftFactor + 1 - shadingToonyFactor
        guard rangeMin != 1 else { return (rangeMin, 1) }
        return (rangeMin, (rangeMax - 1) / (rangeMin - 1))
    }

    /// Checks the material's textures sample the way VRM 0.x can say they do:
    /// MToon 0.x applies one `_MainTex` scale and offset to all of them, samples
    /// UV set 0 only, and has nowhere to put a rotation. Writing more than that
    /// would silently render as something else.
    static func validateVRM0RepresentableUV(of descriptor: MToonMaterialDescriptor) throws {
        let textures = descriptor.uvAccessedTextures
        if let texture = textures.first(where: { $0.texCoord != 0 }) {
            throw VRMError._notSupported(
                "texture \(texture.index) samples UV set \(texture.texCoord), and VRM 0.x samples UV set 0"
            )
        }
        if let texture = textures.first(where: { ($0.transform?.rotation ?? 0) != 0 }) {
            throw VRMError._notSupported(
                "texture \(texture.index) is rotated, and a VRM 0.x _MainTex transform holds no rotation"
            )
        }
        // An absent transform counts as the identity it stands for, and a
        // material with no textures has nothing to disagree about.
        let transforms = textures.map { $0.transform ?? .init() }
        guard let shared = transforms.first else { return }
        guard transforms.allSatisfy({ $0 == shared }) else {
            throw VRMError._notSupported(
                "the material's textures carry different UV transforms, and VRM 0.x carries one for all of them"
            )
        }
    }

    /// The Unity `_MainTex` offset and scale for a UV transform.
    private static func mainTextureVector(of transform: MToonMaterialDescriptor.UVTransform?) -> [Float] {
        guard let transform else { return [0, 0, 1, 1] }
        return [transform.offset.x, 1 - transform.offset.y - transform.scale.y,
                transform.scale.x, transform.scale.y]
    }

    private static func keywordMap(of descriptor: MToonMaterialDescriptor) -> JSONObject {
        [
            "_ALPHABLEND_ON": descriptor.alphaMode == .BLEND,
            "_ALPHAPREMULTIPLY_ON": false,
            "_ALPHATEST_ON": descriptor.alphaMode == .MASK,
            "_NORMALMAP": descriptor.normalTexture != nil,
            "MTOON_OUTLINE_WIDTH_WORLD": descriptor.outlineWidthMode == .worldCoordinates,
            "MTOON_OUTLINE_WIDTH_SCREEN": descriptor.outlineWidthMode == .screenCoordinates,
            "MTOON_OUTLINE_COLOR_FIXED": descriptor.outlineLightingMixFactor == 0,
            "MTOON_OUTLINE_COLOR_MIXED": descriptor.outlineLightingMixFactor != 0,
        ]
    }


    private static func blendMode(of descriptor: MToonMaterialDescriptor) -> Int {
        switch descriptor.alphaMode {
        case .MASK: return 1
        case .BLEND: return descriptor.transparentWithZWrite ? 3 : 2
        case .OPAQUE: return 0
        }
    }

}
