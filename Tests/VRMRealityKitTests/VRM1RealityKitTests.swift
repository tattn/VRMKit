#if canImport(RealityKit)
import CryptoKit
import Foundation
import Metal
import RealityKit
import Testing
import VRMKit
@testable import VRMRealityKit

@Suite
@MainActor
struct VRM1RealityKitTests {

#if !os(visionOS)
    @Test
    func testVRM1MToonCustomMaterialUsesParameterTexture() throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let url = try #require(Bundle.module.url(forResource: "Seed-san", withExtension: "vrm"), "Failed to load Seed-san.vrm resource from test bundle.")
        let vrmLoader = try VRMEntityLoader(withURL: url)
        let material = try vrmLoader.material(withMaterialIndex: 0)
        let customMaterial = try #require(material as? CustomMaterial,
                                          "Expected default MToon rendering to load a CustomMaterial. Run Scripts/build-mtoon-metallibs.sh and verify the package resources.")

        #expect(customMaterial.custom.texture != nil)
        #expect(customMaterial.normal.texture != nil)
        #expect(customMaterial.roughness.texture != nil)
        #expect(customMaterial.emissiveColor.texture != nil)
        #expect(customMaterial.clearcoat.texture != nil)
        #expect(customMaterial.clearcoatRoughness.texture != nil)

        let direction = MToonMaterialParameters.defaultLightDirection
        #expect(abs(customMaterial.custom.value.x - direction.x) < 0.0001)
        #expect(abs(customMaterial.custom.value.y - direction.y) < 0.0001)
        #expect(abs(customMaterial.custom.value.z - direction.z) < 0.0001)
    }

    @Test
    func testVRM1MToonRenderingCanBeDisabled() throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let url = try #require(Bundle.module.url(forResource: "Seed-san", withExtension: "vrm"), "Failed to load Seed-san.vrm resource from test bundle.")
        let defaultLoader = try VRMEntityLoader(withURL: url)
        let defaultMaterial = try defaultLoader.material(withMaterialIndex: 0)
        _ = try #require(defaultMaterial as? CustomMaterial,
                         "Expected default MToon rendering to load a CustomMaterial. Run Scripts/build-mtoon-metallibs.sh and verify the package resources.")

        let disabledLoader = try VRMEntityLoader(withURL: url, isMToonEnabled: false)
        let disabledMaterial = try disabledLoader.material(withMaterialIndex: 0)
        #expect(!(disabledMaterial is CustomMaterial))
        #expect(disabledMaterial is UnlitMaterial)

        let disabledEntity = try disabledLoader.loadEntity()
        let disabledModels = modelEntities(in: disabledEntity.entity)
        let hasCustomMaterial = disabledModels.contains { modelEntity in
            guard let model = modelEntity.components[ModelComponent.self] else { return false }
            return model.materials.contains { $0 is CustomMaterial }
        }
        let hasMToonParameters = disabledModels.contains {
            $0.components[MToonMaterialParametersComponent.self] != nil
        }
        #expect(!hasCustomMaterial)
        #expect(!hasMToonParameters)
    }

    @Test
    func testVRM1MToonShaderUsesSingleUnlitOutput() throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let shader = try mtoonShaderSource()

        #expect(shader.contains("surface.set_base_color(half3(0.0h));\n    surface.set_emissive_color(half3(color));"))
        #expect(shader.contains("surface.set_base_color(half3(0.0h));\n    surface.set_emissive_color(half3(finalColor));"))
    }

    @Test
    func testVRM1MToonShaderUsesPackedMaskChannels() throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let shader = try mtoonShaderSource()
        let packedMaskSample = SIMD4<Float>(0.125, 0.5, 0.875, 1.0)

        #expect(try sampledChannelValue(in: shader,
                                        marker: "mtoonSample(textures.specular(), uv, shadingShiftSampler)",
                                        sample: packedMaskSample) == packedMaskSample.x)
        #expect(try sampledChannelValue(in: shader,
                                        marker: "mtoonSample(params.textures().clearcoat(), widthUV, outlineWidthSampler)",
                                        sample: packedMaskSample) == packedMaskSample.y)
        #expect(try sampledChannelValue(in: shader,
                                        marker: "mtoonSample(params.textures().ambient_occlusion(), maskUV, uvAnimationMaskSampler)",
                                        sample: packedMaskSample) == packedMaskSample.z)
    }

    @Test
    func testMToonParameterTextureRowsMatchMetalConstant() throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let url = try #require(Bundle.module.url(forResource: "Seed-san", withExtension: "vrm"), "Failed to load Seed-san.vrm resource from test bundle.")
        let vrmLoader = try VRMEntityLoader(withURL: url)
        let vrmEntity = try vrmLoader.loadEntity()
        let parameters = try firstMToonParameters(in: vrmEntity.entity)
        let texture = try parameters.textureResource()
        let shader = try mtoonShaderSource()

        #expect(MToonMaterialParameters.baseParameterRowCount == 14)
        #expect(MToonMaterialParameters.samplerRowCount == MToonTextureSlot.allCases.count)
        #expect(MToonMaterialParameters.textureRowCount == 23)
        #expect(parameters.samplers.count == MToonMaterialParameters.samplerRowCount)
        #expect(texture.width == MToonMaterialParameters.textureRowCount)
        #expect(texture.height == 1)
        #expect(shader.contains("constant float mtoonParameterTextureWidth = 23.0;"))
        #expect(shader.contains("constant float mtoonSamplerParameterStart = 14.0;"))
    }

    @Test
    func testMToonEmissiveFlagFactorAndEmissionColorBind() throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let url = try #require(Bundle.module.url(forResource: "Seed-san", withExtension: "vrm"), "Failed to load Seed-san.vrm resource from test bundle.")
        let vrmLoader = try VRMEntityLoader(withURL: url)
        let vrmEntity = try vrmLoader.loadEntity()
        var parameters = try firstMToonParameters(in: vrmEntity.entity)
        let boundColor = SIMD4<Float>(0.25, 0.5, 0.75, 0.2)

        #expect(parameters.extraFlags.z == 0 || parameters.extraFlags.z == 1)
        #expect(parameters.color(for: .emissionColor)?.isApproximatelyEqual(to: parameters.emissiveFactor) == true)
        let didSetEmissionColor = parameters.setColor(boundColor, for: .emissionColor)
        #expect(didSetEmissionColor)
        #expect(parameters.emissiveFactor.isApproximatelyEqual(to: SIMD4<Float>(0.25, 0.5, 0.75, 1)))
        #expect(parameters.color(for: .emissionColor)?.isApproximatelyEqual(to: parameters.emissiveFactor) == true)
    }

    @Test
    func testSetMToonLightAndAmbientColorUpdateParameterRows() throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let url = try #require(Bundle.module.url(forResource: "Seed-san", withExtension: "vrm"), "Failed to load Seed-san.vrm resource from test bundle.")
        let vrmLoader = try VRMEntityLoader(withURL: url)
        let vrmEntity = try vrmLoader.loadEntity()
        let lightColor = SIMD3<Float>(0.8, 0.7, 0.6)
        let ambientColor = SIMD3<Float>(0.05, 0.1, 0.15)

        vrmEntity.setMToonLightColor(lightColor)
        vrmEntity.setMToonAmbientColor(ambientColor)

        let parameters = try firstMToonParameters(in: vrmEntity.entity)
        #expect(parameters.lightColor.isApproximatelyEqual(to: SIMD4<Float>(0.8, 0.7, 0.6, 1)))
        #expect(parameters.ambientColor.isApproximatelyEqual(to: SIMD4<Float>(0.05, 0.1, 0.15, 1)))
        let material = try firstCustomMaterial(in: vrmEntity.entity)
        #expect(material.custom.texture != nil)
    }

    @Test
    func testMToonShaderUsesMToon10LightingAndTextureSlots() throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let shader = try mtoonShaderSource()

        #expect(shader.contains("mtoonLinearstep(-1.0 + shadingToony"))
        #expect(shader.contains("shift += float(shadingShift) * float(uvAnimation.w);"))
        #expect(shader.contains("mtoonSample(textures.clearcoat_roughness(), uv, rimSampler)"))
        #expect(shader.contains("mtoonSample(textures.emissive_color(), uv, emissiveSampler)"))
        #expect(shader.contains("float3 direct = mix(shadeColor, litColor, shading) * lightColor;"))
        #expect(shader.contains("float3 indirect = litColor * giColor;"))
        #expect(!shader.contains("* 2.0 - 1.0) * float(uvAnimation.w)"))
        #expect(!shader.contains("dot(normal, lightDirection) * 0.5 + 0.5"))
    }

    @Test
    func testMToonShaderUsesPrecompiledSafeSamplerParameters() throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let shader = try mtoonShaderSource()

        #expect(shader.contains("mtoonLinearClampSampler"))
        #expect(shader.contains("mtoonNearestClampSampler"))
        #expect(shader.contains("mtoonWrappedCoordinate"))
        #expect(shader.contains("mtoonSamplerParameter(textures, 0.0)"))
        #expect(!shader.contains("mtoonBaseSampler"))
        #expect(!shader.contains("mtoonShadeSampler"))
    }

    @Test
    func testMToonLoaderUsesBundledPrecompiledLibraryOnly() throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let source = try realityKitLoaderSource()

        #expect(source.contains("makeLibrary(URL: libraryURL)"))
        #expect(source.contains("requiredMToonFunctionNames.isSubset"))
        #expect(!source.contains("makeLibrary(source:"))
        #expect(!source.contains("makeDefaultLibrary"))
        #expect(!source.contains("SDKROOT"))
        #expect(!source.contains("DEVELOPER_DIR"))
        #expect(!source.contains("/usr/bin/xcrun"))
    }

    @Test
    func testMToonPackageResourcesKeepShaderSourceOutOfBundleResources() throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let manifest = try packageManifestSource()

        #expect(manifest.range(of: #"exclude:\s*\[[^\]]*"Shaders"[^\]]*\]"#,
                               options: .regularExpression) != nil)
        #expect(manifest.range(of: #"resources:\s*\[[^\]]*\.process\s*\(\s*"Resources"\s*\)[^\]]*\]"#,
                               options: .regularExpression) != nil)
        #expect(manifest.range(of: #"\.copy\s*\(\s*"Shaders"\s*\)"#,
                               options: .regularExpression) == nil)
    }

    @Test
    func testBundledMToonMetallibsExistAndMatchShaderSource() throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let bundle = try #require(vrmRealityKitResourceBundle(), "Failed to locate VRMRealityKit resource bundle.")

        for resourceName in ["MToon-macos", "MToon-ios", "MToon-iossim"] {
            #expect(bundle.url(forResource: resourceName, withExtension: "metallib") != nil,
                    "Missing bundled metallib: \(resourceName).metallib. Run Scripts/build-mtoon-metallibs.sh.")
        }

        // Detect stale metallibs: the hash recorded at metallib build time must
        // match the current shader source. If this fails, re-run
        // Scripts/build-mtoon-metallibs.sh and commit the regenerated resources.
        let hashURL = try #require(bundle.url(forResource: "MToonShaderSource", withExtension: "sha256"),
                                   "Missing MToonShaderSource.sha256. Run Scripts/build-mtoon-metallibs.sh.")
        let recordedHash = try String(contentsOf: hashURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let shaderData = try Data(contentsOf: mtoonShaderSourceURL())
        let currentHash = SHA256.hash(data: shaderData).map { String(format: "%02x", $0) }.joined()
        #expect(recordedHash == currentHash,
                "Bundled MToon metallibs are stale. Run Scripts/build-mtoon-metallibs.sh and commit the regenerated resources.")
    }

    @Test
    func testMToonShadeColorBindDoesNotOverwriteCustomLightDirection() throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let url = try #require(Bundle.module.url(forResource: "Seed-san", withExtension: "vrm"), "Failed to load Seed-san.vrm resource from test bundle.")
        let vrmLoader = try VRMEntityLoader(withURL: url)
        let material = try vrmLoader.material(withMaterialIndex: 0)
        let customMaterial = try #require(material as? CustomMaterial,
                                          "Expected default MToon rendering to load a CustomMaterial. Run Scripts/build-mtoon-metallibs.sh and verify the package resources.")
        let initialValue = customMaterial.custom.value

        let updatedMaterial = customMaterial.settingColor(VRMColor(red: 0.2, green: 0.3, blue: 0.4, alpha: 1),
                                                          for: .shadeColor)
        let updatedCustomMaterial = try #require(updatedMaterial as? CustomMaterial)

        #expect(updatedCustomMaterial.custom.value == initialValue)
    }
#endif

    @Test
    func testFallbackShadeAndOutlineColorBindsDoNotOverwriteBaseColor() throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let baseColor = VRMColor(red: 0.1, green: 0.2, blue: 0.3, alpha: 1)
        let boundColor = VRMColor(red: 0.8, green: 0.7, blue: 0.6, alpha: 1)

        var pbr = PhysicallyBasedMaterial()
        pbr.baseColor.tint = baseColor
        let shadeUpdatedPBR = try #require(pbr.settingColor(boundColor, for: .shadeColor) as? PhysicallyBasedMaterial)
        let outlineUpdatedPBR = try #require(pbr.settingColor(boundColor, for: .outlineColor) as? PhysicallyBasedMaterial)
        let colorUpdatedPBR = try #require(pbr.settingColor(boundColor, for: .color) as? PhysicallyBasedMaterial)

        #expect(shadeUpdatedPBR.baseColor.tint.isApproximatelyEqual(to: baseColor))
        #expect(outlineUpdatedPBR.baseColor.tint.isApproximatelyEqual(to: baseColor))
        #expect(colorUpdatedPBR.baseColor.tint.isApproximatelyEqual(to: boundColor))
        #expect(pbr.currentColor(for: .shadeColor).isApproximatelyEqual(to: SIMD4<Float>(1, 1, 1, 1)))
        #expect(pbr.currentColor(for: .outlineColor).isApproximatelyEqual(to: SIMD4<Float>(1, 1, 1, 1)))

        var unlit = UnlitMaterial()
        unlit.color.tint = baseColor
        let shadeUpdatedUnlit = try #require(unlit.settingColor(boundColor, for: .shadeColor) as? UnlitMaterial)
        let colorUpdatedUnlit = try #require(unlit.settingColor(boundColor, for: .color) as? UnlitMaterial)

        #expect(shadeUpdatedUnlit.color.tint.isApproximatelyEqual(to: baseColor))
        #expect(colorUpdatedUnlit.color.tint.isApproximatelyEqual(to: boundColor))
        #expect(unlit.currentColor(for: .shadeColor).isApproximatelyEqual(to: SIMD4<Float>(1, 1, 1, 1)))
    }

    @Test
    func testVRM1FirstPersonAutoHidesHeadDescendants() throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let url = try #require(Bundle.module.url(forResource: "Seed-san", withExtension: "vrm"), "Failed to load Seed-san.vrm resource from test bundle.")
        let vrmLoader = try VRMEntityLoader(withURL: url)
        let vrmEntity = try vrmLoader.loadEntity()
        let annotatedEntity = try vrmLoader.node(withNodeIndex: 0)

        #expect(annotatedEntity.isEnabled == true)
        vrmEntity.setFirstPersonRenderMode(.firstPerson)
        #expect(annotatedEntity.isEnabled == false)
        vrmEntity.setFirstPersonRenderMode(.thirdPerson)
        #expect(annotatedEntity.isEnabled == true)
    }

#if !os(visionOS)
    @Test
    func testUpdateAtUsesDeltaTimeForMToonRuntime() throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let url = try #require(Bundle.module.url(forResource: "Seed-san", withExtension: "vrm"), "Failed to load Seed-san.vrm resource from test bundle.")
        let vrmLoader = try VRMEntityLoader(withURL: url)
        let vrmEntity = try vrmLoader.loadEntity()

        vrmEntity.update(at: 10.0)
        let firstFrameMaterial = try firstCustomMaterial(in: vrmEntity.entity)
        #expect(abs(firstFrameMaterial.custom.value.w) < 0.0001)

        vrmEntity.update(at: 10.5)
        let secondFrameMaterial = try firstCustomMaterial(in: vrmEntity.entity)
        #expect(abs(secondFrameMaterial.custom.value.w - 0.5) < 0.0001)
    }

    @Test
    func testVRM1MToonOutlineEntityIsCreated() throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let url = try #require(Bundle.module.url(forResource: "Seed-san", withExtension: "vrm"), "Failed to load Seed-san.vrm resource from test bundle.")
        let vrmLoader = try VRMEntityLoader(withURL: url)
        let vrmEntity = try vrmLoader.loadEntity()
        let outlineEntities = modelEntities(in: vrmEntity.entity).filter { modelEntity in
            guard let model = modelEntity.components[ModelComponent.self],
                  let material = model.materials.first as? CustomMaterial else {
                return false
            }
            return material.faceCulling == .front
        }

        #expect(!outlineEntities.isEmpty)
    }
#endif

    @available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
    private func firstMToonParameters(in root: Entity) throws -> MToonMaterialParameters {
        for modelEntity in modelEntities(in: root) {
            if let component = modelEntity.components[MToonMaterialParametersComponent.self] {
                return component.parameters
            }
        }
        throw VRMError.dataInconsistent("Expected at least one MToon parameters component")
    }

    private func modelEntities(in root: Entity) -> [ModelEntity] {
        var result: [ModelEntity] = []
        var stack: [Entity] = [root]
        while let entity = stack.popLast() {
            if let modelEntity = entity as? ModelEntity {
                result.append(modelEntity)
            }
            stack.append(contentsOf: entity.children)
        }
        return result
    }

#if !os(visionOS)
    private func vrmRealityKitResourceBundle() -> Bundle? {
        let bundleName = "VRMKit_VRMRealityKit.bundle"
        var baseURLs = [
            Bundle.main.bundleURL,
            Bundle.main.bundleURL.deletingLastPathComponent()
        ]
        if let resourceURL = Bundle.main.resourceURL {
            baseURLs.append(resourceURL)
        }
        baseURLs += Bundle.allBundles.compactMap(\.resourceURL)
        baseURLs += Bundle.allFrameworks.compactMap(\.resourceURL)

        for baseURL in baseURLs {
            let bundleURL = baseURL.appendingPathComponent(bundleName)
            if let bundle = Bundle(url: bundleURL),
               bundle.url(forResource: "MToon-macos", withExtension: "metallib") != nil {
                return bundle
            }
        }

        return (Bundle.allBundles + Bundle.allFrameworks).first {
            $0.url(forResource: "MToon-macos", withExtension: "metallib") != nil
        }
    }

    private func firstCustomMaterial(in root: Entity) throws -> CustomMaterial {
        for modelEntity in modelEntities(in: root) {
            guard let model = modelEntity.components[ModelComponent.self] else { continue }
            if let material = model.materials.first(where: { $0 is CustomMaterial }) as? CustomMaterial {
                return material
            }
        }
        throw VRMError.dataInconsistent("Expected at least one CustomMaterial")
    }
#endif

    private func mtoonShaderSource() throws -> String {
        return try String(contentsOf: mtoonShaderSourceURL(), encoding: .utf8)
    }

    private func mtoonShaderSourceURL() -> URL {
        let testFile = URL(fileURLWithPath: #filePath)
        let packageRoot = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return packageRoot
            .appendingPathComponent("Sources")
            .appendingPathComponent("VRMRealityKit")
            .appendingPathComponent("Shaders")
            .appendingPathComponent("MToon.metal")
    }

    private func realityKitLoaderSource() throws -> String {
        let testFile = URL(fileURLWithPath: #filePath)
        let packageRoot = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let loaderURL = packageRoot
            .appendingPathComponent("Sources")
            .appendingPathComponent("VRMRealityKit")
            .appendingPathComponent("VRMEntityLoader.swift")
        return try String(contentsOf: loaderURL, encoding: .utf8)
    }

    private func packageManifestSource() throws -> String {
        let testFile = URL(fileURLWithPath: #filePath)
        let packageRoot = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let manifestURL = packageRoot.appendingPathComponent("Package.swift")
        return try String(contentsOf: manifestURL, encoding: .utf8)
    }
}

private extension VRMColor {
    func isApproximatelyEqual(to other: VRMColor, tolerance: Float = 0.0001) -> Bool {
        testSIMD.isApproximatelyEqual(to: other.testSIMD, tolerance: tolerance)
    }

    var testSIMD: SIMD4<Float> {
        #if os(macOS)
        let color = usingColorSpace(.deviceRGB) ?? self
        return SIMD4<Float>(Float(color.redComponent),
                            Float(color.greenComponent),
                            Float(color.blueComponent),
                            Float(color.alphaComponent))
        #else
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return SIMD4<Float>(Float(red), Float(green), Float(blue), Float(alpha))
        #endif
    }
}

private extension SIMD3 where Scalar == Float {
    func isApproximatelyEqual(to other: SIMD3<Float>, tolerance: Float = 0.0001) -> Bool {
        abs(x - other.x) < tolerance &&
        abs(y - other.y) < tolerance &&
        abs(z - other.z) < tolerance
    }
}

private extension SIMD4 where Scalar == Float {
    func isApproximatelyEqual(to other: SIMD4<Float>, tolerance: Float = 0.0001) -> Bool {
        abs(x - other.x) < tolerance &&
        abs(y - other.y) < tolerance &&
        abs(z - other.z) < tolerance &&
        abs(w - other.w) < tolerance
    }
}

private enum ShaderChannel: String {
    case r
    case g
    case b
    case a

    func value(in color: SIMD4<Float>) -> Float {
        switch self {
        case .r: return color.x
        case .g: return color.y
        case .b: return color.z
        case .a: return color.w
        }
    }
}

private func sampledChannelValue(in source: String,
                                 marker: String,
                                 sample: SIMD4<Float>) throws -> Float {
    let channel = try sampledChannel(in: source, marker: marker)
    return channel.value(in: sample)
}

private func sampledChannel(in source: String, marker: String) throws -> ShaderChannel {
    guard let markerRange = source.range(of: marker) else {
        throw VRMError.dataInconsistent("Expected shader sample marker: \(marker)")
    }
    guard let dotIndex = source[markerRange.upperBound...].firstIndex(of: ".") else {
        throw VRMError.dataInconsistent("Expected channel access after shader sample marker: \(marker)")
    }
    let channelIndex = source.index(after: dotIndex)
    guard channelIndex < source.endIndex,
          let channel = ShaderChannel(rawValue: String(source[channelIndex])) else {
        throw VRMError.dataInconsistent("Expected r/g/b/a channel after shader sample marker: \(marker)")
    }
    return channel
}
#endif
