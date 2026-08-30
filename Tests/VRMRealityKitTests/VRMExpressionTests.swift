#if canImport(RealityKit)
import Foundation
import RealityKit
import Testing
import VRMKit
import VRMTestSupport
@testable import VRMRealityKit

/// Driving a model's expressions: the weights they accumulate, how one
/// overrides another, and the morph targets, colours and UV transforms they reach.
@Suite
@MainActor
struct VRMExpressionTests {
    @Test
    func testBlockingExpressionOverrideSuppressesBlinkAndLookAtWeights() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        // Seed-san's `relaxed` declares overrideBlink / overrideLookAt = block.
        let vrmEntity = try await VRMEntityLoader(withData: TestSupport.seedSanData,
                                            shaders: TestSupport.noOutlineShaders).loadEntity()

        vrmEntity.setExpression(value: 1, for: .preset(.blink))
        vrmEntity.setExpression(value: 1, for: .preset(.lookUp))
        vrmEntity.setExpression(value: 1, for: .preset(.aa))
        #expect(TestSupport.morphWeight(in: vrmEntity, targetIndex: 1) == 1)
        #expect(TestSupport.morphWeight(in: vrmEntity, targetIndex: 39) == 1)
        #expect(TestSupport.morphWeight(in: vrmEntity, targetIndex: 25) == 1)

        vrmEntity.setExpression(value: 1, for: .preset(.relaxed))
        #expect(TestSupport.morphWeight(in: vrmEntity, targetIndex: 1) == 0)
        #expect(TestSupport.morphWeight(in: vrmEntity, targetIndex: 39) == 0)
        // overrideMouth is `none`, so mouth expressions keep their weight.
        #expect(TestSupport.morphWeight(in: vrmEntity, targetIndex: 25) == 1)
        // The input weights themselves are untouched by the override.
        #expect(vrmEntity.expression(for: .preset(.blink)) == 1)

        vrmEntity.setExpression(value: 0, for: .preset(.relaxed))
        #expect(TestSupport.morphWeight(in: vrmEntity, targetIndex: 1) == 1)
        #expect(TestSupport.morphWeight(in: vrmEntity, targetIndex: 39) == 1)
    }

    @Test
    func testBlendingExpressionOverrideScalesBlinkWeights() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        // Seed-san's `happy` declares overrideBlink = blend, but is binary; a
        // non-binary variant makes the partial blend observable.
        let modified = try TestSupport.modifiedSeedSanExpressions(name: "non-binary-happy") { preset in
            guard var happy = preset.object("happy") else {
                throw VRMError.dataInconsistent("Missing Seed-san happy expression")
            }
            happy["isBinary"] = false
            preset["happy"] = .object(happy)
        }
        let vrmEntity = try await VRMEntityLoader(withData: modified, shaders: TestSupport.noOutlineShaders).loadEntity()

        vrmEntity.setExpressions([.preset(.blink): 1, .preset(.happy): 0.25])

        let blinkWeight = try #require(TestSupport.morphWeight(in: vrmEntity, targetIndex: 1))
        #expect(blinkWeight.isApproximatelyEqual(to: 0.75))
    }

    /// Alicia's `Joy` and `Fun` groups both bind face target 38, and VRM 0.x blend
    /// shape groups load as expressions, so their contributions add up.
    @Test
    func testVRM0BlendShapeGroupsSharingAMorphTargetAccumulate() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let vrmEntity = try await VRMEntityLoader(withData: TestSupport.aliciaSolidData).loadEntity()

        vrmEntity.setExpression(value: 0.25, for: .preset(.happy))
        #expect(try #require(TestSupport.morphWeight(in: vrmEntity, targetIndex: 38)).isApproximatelyEqual(to: 0.25))

        vrmEntity.setExpression(value: 0.5, for: .preset(.relaxed))
        #expect(try #require(TestSupport.morphWeight(in: vrmEntity, targetIndex: 38)).isApproximatelyEqual(to: 0.75))
        // Joy's own targets keep the weight Joy gave them.
        #expect(try #require(TestSupport.morphWeight(in: vrmEntity, targetIndex: 14)).isApproximatelyEqual(to: 0.25))

        // Releasing one group takes back its share alone.
        vrmEntity.setExpression(value: 0, for: .preset(.happy))
        #expect(try #require(TestSupport.morphWeight(in: vrmEntity, targetIndex: 38)).isApproximatelyEqual(to: 0.5))
        #expect(try #require(TestSupport.morphWeight(in: vrmEntity, targetIndex: 14)).isApproximatelyEqual(to: 0))
    }

    @Test
    func testSimultaneousBlendOverridesAccumulateBeforeSaturating() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        // Two non-binary expressions that each blend-override blink. VRM sums
        // their weights and saturates, so 0.5 + 0.5 fully suppresses blink.
        let modified = try TestSupport.modifiedSeedSanExpressions(name: "two-blend-overrides") { preset in
            for name in ["happy", "sad"] {
                guard var expression = preset.object(name) else {
                    throw VRMError.dataInconsistent("Missing Seed-san \(name) expression")
                }
                expression["isBinary"] = false
                expression["overrideBlink"] = "blend"
                preset[name] = .object(expression)
            }
        }
        let vrmEntity = try await VRMEntityLoader(withData: modified, shaders: TestSupport.noOutlineShaders).loadEntity()

        vrmEntity.setExpressions([.preset(.blink): 1, .preset(.happy): 0.5])
        #expect(try #require(TestSupport.morphWeight(in: vrmEntity, targetIndex: 1)).isApproximatelyEqual(to: 0.5))

        vrmEntity.setExpression(value: 0.5, for: .preset(.sad))
        #expect(TestSupport.morphWeight(in: vrmEntity, targetIndex: 1) == 0)

        // Past saturation the weight stays at 0 rather than going negative.
        vrmEntity.setExpressions([.preset(.happy): 1, .preset(.sad): 1])
        #expect(TestSupport.morphWeight(in: vrmEntity, targetIndex: 1) == 0)
    }

    @Test
    func testOverriddenBinaryExpressionIsSuppressedEntirely() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        // A binary expression has no partial state, so *any* override effect
        // must zero it rather than scale it.
        let modified = try TestSupport.modifiedSeedSanExpressions(name: "binary-blink") { preset in
            guard var blink = preset.object("blink"),
                  var happy = preset.object("happy") else {
                throw VRMError.dataInconsistent("Missing Seed-san blink/happy expressions")
            }
            blink["isBinary"] = true
            happy["isBinary"] = false
            happy["overrideBlink"] = "blend"
            preset["blink"] = .object(blink)
            preset["happy"] = .object(happy)
        }
        let vrmEntity = try await VRMEntityLoader(withData: modified, shaders: TestSupport.noOutlineShaders).loadEntity()

        vrmEntity.setExpression(value: 1, for: .preset(.blink))
        #expect(TestSupport.morphWeight(in: vrmEntity, targetIndex: 1) == 1)

        // A 0.25 blend would leave 0.75 on a non-binary expression.
        vrmEntity.setExpression(value: 0.25, for: .preset(.happy))
        #expect(TestSupport.morphWeight(in: vrmEntity, targetIndex: 1) == 0)
    }

    @Test
    func testExpressionDoesNotOverrideItsOwnKind() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        // "Like overrideBlink for blink, settings for the same kind are treated
        // as invalid": blink must not suppress itself or its own group.
        let modified = try TestSupport.modifiedSeedSanExpressions(name: "self-overriding-blink") { preset in
            guard var blink = preset.object("blink") else {
                throw VRMError.dataInconsistent("Missing Seed-san blink expression")
            }
            blink["overrideBlink"] = "block"
            preset["blink"] = .object(blink)
        }
        let vrmEntity = try await VRMEntityLoader(withData: modified, shaders: TestSupport.noOutlineShaders).loadEntity()

        vrmEntity.setExpressions([.preset(.blink): 1, .preset(.blinkLeft): 1])

        #expect(TestSupport.morphWeight(in: vrmEntity, targetIndex: 2) == 1)
    }

// These tests observe MToon runtime state, which visionOS never produces:
// there is no `CustomMaterial`, so MToon falls back to Unlit / PBR materials.
#if !os(visionOS)
    @Test
    func testExpressionTextureTransformsAccumulateAndResetIndependently() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let seedSan = TestSupport.seedSanData
        let loader = try VRMEntityLoader(withData: seedSan, shaders: TestSupport.noOutlineShaders)
        let vrmEntity = try await loader.loadEntity()

        vrmEntity.setExpression(value: 1, for: .preset(.happy))
        vrmEntity.setExpression(value: 1, for: .preset(.angry))
        var parameters = try TestSupport.mtoonParameters(in: vrmEntity, materialIndex: 11)
        #expect(parameters.uvTransform.isApproximatelyEqual(to: SIMD4<Float>(1, 1, 0.75, 0)))
        #expect(vrmEntity.expression(for: .preset(.happy)) == 1)
        #expect(vrmEntity.expression(for: .preset(.angry)) == 1)

        vrmEntity.setExpression(value: 0, for: .preset(.happy))
        parameters = try TestSupport.mtoonParameters(in: vrmEntity, materialIndex: 11)
        #expect(parameters.uvTransform.isApproximatelyEqual(to: SIMD4<Float>(1, 1, 0.5, 0)))
        #expect(vrmEntity.expression(for: .preset(.happy)) == 0)
        #expect(vrmEntity.expression(for: .preset(.angry)) == 1)
    }

    @Test
    func testExpressionMaterialColorsAccumulateAndResetIndependently() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let modified = try TestSupport.modifiedSeedSanData(name: "accumulated-material-colors") { json in
            var materials = json.objects("materials")
            guard materials.indices.contains(0),
                  var pbr = materials[0].object("pbrMetallicRoughness"),
                  var extensions = json.object("extensions"),
                  var vrm = extensions.object("VRMC_vrm"),
                  var expressions = vrm.object("expressions"),
                  var preset = expressions.object("preset"),
                  var happy = preset.object("happy"),
                  var angry = preset.object("angry") else {
                throw VRMError.dataInconsistent("Missing Seed-san expression fixture data")
            }
            pbr["baseColorFactor"] = [1.0, 1.0, 1.0, 1.0]
            materials[0]["pbrMetallicRoughness"] = .object(pbr)
            happy["materialColorBinds"] = [[
                "material": 0,
                "type": "color",
                "targetValue": [0.8, 1.0, 1.0, 1.0]
            ]]
            angry["materialColorBinds"] = [[
                "material": 0,
                "type": "color",
                "targetValue": [1.0, 0.6, 1.0, 1.0]
            ]]
            preset["happy"] = .object(happy)
            preset["angry"] = .object(angry)
            expressions["preset"] = .object(preset)
            vrm["expressions"] = .object(expressions)
            extensions["VRMC_vrm"] = .object(vrm)
            json["extensions"] = .object(extensions)
            json["materials"] = .objects(materials)
        }

        let loader = try VRMEntityLoader(withData: modified, shaders: TestSupport.noOutlineShaders)
        let vrmEntity = try await loader.loadEntity()
        vrmEntity.setExpression(value: 1, for: .preset(.happy))
        vrmEntity.setExpression(value: 1, for: .preset(.angry))
        var parameters = try TestSupport.mtoonParameters(in: vrmEntity, materialIndex: 0)
        #expect(parameters.baseColor.isApproximatelyEqual(to: SIMD4<Float>(0.8, 0.6, 1, 1)))

        vrmEntity.setExpression(value: 0, for: .preset(.happy))
        parameters = try TestSupport.mtoonParameters(in: vrmEntity, materialIndex: 0)
        #expect(parameters.baseColor.isApproximatelyEqual(to: SIMD4<Float>(1, 0.6, 1, 1)))
    }

    @Test
    func testBinaryExpressionIsOnlyActiveAboveHalf() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        // `angry` is binary and carries a textureTransformBind on material 11.
        let vrmEntity = try await VRMEntityLoader(withData: TestSupport.seedSanData,
                                            shaders: TestSupport.noOutlineShaders).loadEntity()

        vrmEntity.setExpression(value: 0.5, for: .preset(.angry))
        var parameters = try TestSupport.mtoonParameters(in: vrmEntity, materialIndex: 11)
        #expect(parameters.uvTransform.isApproximatelyEqual(to: SIMD4<Float>(1, 1, 0, 0)))
        #expect(vrmEntity.expression(for: .preset(.angry)) == 0)

        vrmEntity.setExpression(value: 0.51, for: .preset(.angry))
        parameters = try TestSupport.mtoonParameters(in: vrmEntity, materialIndex: 11)
        #expect(parameters.uvTransform.isApproximatelyEqual(to: SIMD4<Float>(1, 1, 0.5, 0)))
        #expect(vrmEntity.expression(for: .preset(.angry)) == 1)
    }

    @Test
    func testSetExpressionsAppliesEveryWeightAtOnce() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let vrmEntity = try await VRMEntityLoader(withData: TestSupport.seedSanData,
                                            shaders: TestSupport.noOutlineShaders).loadEntity()

        vrmEntity.setExpressions([.preset(.happy): 1, .preset(.angry): 1])

        // Same accumulated result as setting each expression on its own.
        let parameters = try TestSupport.mtoonParameters(in: vrmEntity, materialIndex: 11)
        #expect(parameters.uvTransform.isApproximatelyEqual(to: SIMD4<Float>(1, 1, 0.75, 0)))
        #expect(vrmEntity.expression(for: .preset(.happy)) == 1)
        #expect(vrmEntity.expression(for: .preset(.angry)) == 1)

        vrmEntity.setExpressions([.preset(.happy): 0, .preset(.angry): 0])
        #expect(try TestSupport.mtoonParameters(in: vrmEntity, materialIndex: 11)
            .uvTransform.isApproximatelyEqual(to: SIMD4<Float>(1, 1, 0, 0)))
    }
#endif
}
#endif
