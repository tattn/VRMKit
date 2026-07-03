#if canImport(RealityKit)
import Foundation
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
        let customMaterial = try #require(material as? CustomMaterial)

        #expect(customMaterial.custom.texture != nil)
        #expect(customMaterial.normal.texture != nil)
        #expect(customMaterial.roughness.texture != nil)
        #expect(customMaterial.clearcoat.texture != nil)

        let direction = MToonMaterialParameters.defaultLightDirection
        #expect(abs(customMaterial.custom.value.x - direction.x) < 0.0001)
        #expect(abs(customMaterial.custom.value.y - direction.y) < 0.0001)
        #expect(abs(customMaterial.custom.value.z - direction.z) < 0.0001)
    }

    @Test
    func testVRM1MToonShaderUsesSingleUnlitOutput() throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let shader = try mtoonShaderSource()

        #expect(shader.contains("surface.set_base_color(half3(0.0h));\n    surface.set_emissive_color(finalColor);"))
        #expect(shader.contains("surface.set_base_color(half3(0.0h));\n    surface.set_emissive_color(outlineColor.rgb);"))
    }

    @Test
    func testVRM1MToonShaderUsesPackedMaskChannels() throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let shader = try mtoonShaderSource()

        #expect(shader.contains("mtoonUvAnimationMaskSampler, maskUV).b"))
        #expect(shader.contains("mtoonOutlineWidthSampler, widthUV).g"))
        #expect(!shader.contains("mtoonUvAnimationMaskSampler, maskUV).r"))
        #expect(!shader.contains("mtoonOutlineWidthSampler, widthUV).r"))
    }

    @Test
    func testMToonShadeColorBindDoesNotOverwriteCustomLightDirection() throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let url = try #require(Bundle.module.url(forResource: "Seed-san", withExtension: "vrm"), "Failed to load Seed-san.vrm resource from test bundle.")
        let vrmLoader = try VRMEntityLoader(withURL: url)
        let material = try #require(try vrmLoader.material(withMaterialIndex: 0) as? CustomMaterial)
        let initialValue = material.custom.value

        let updatedMaterial = material.settingColor(VRMColor(red: 0.2, green: 0.3, blue: 0.4, alpha: 1),
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
        let testFile = URL(fileURLWithPath: #filePath)
        let packageRoot = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let shaderURL = packageRoot
            .appendingPathComponent("Sources")
            .appendingPathComponent("VRMRealityKit")
            .appendingPathComponent("Shaders")
            .appendingPathComponent("MToon.metal")
        return try String(contentsOf: shaderURL, encoding: .utf8)
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

private extension SIMD4 where Scalar == Float {
    func isApproximatelyEqual(to other: SIMD4<Float>, tolerance: Float = 0.0001) -> Bool {
        abs(x - other.x) < tolerance &&
        abs(y - other.y) < tolerance &&
        abs(z - other.z) < tolerance &&
        abs(w - other.w) < tolerance
    }
}
#endif
