#if canImport(RealityKit)
import Foundation
import RealityKit
import Testing
import VRMKit
@testable import VRMKitRuntime
import VRMTestSupport
@testable import VRMRealityKit

/// Driving a model's expressions: the weights they accumulate, how one
/// overrides another, and the morph targets, colours and UV transforms they reach.
@Suite
@MainActor
struct VRMExpressionTests {
    /// Weights set by handle land as the same weights set by key, every expression at once, and a
    /// custom key spelling a preset finds the preset.
    @Test
    func testWeightsSetByHandleMatchWeightsSetByKey() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let byKey = try await TestSupport.sharedLoader(.seedSanStandard).loadEntity()
        let byKeyInstance = try #require(byKey.instance)
        let byHandle = try await TestSupport.sharedLoader(.seedSanStandard).loadEntity()
        let byHandleInstance = try #require(byHandle.instance)
        #expect(byHandleInstance.expressionHandle(for: .custom("happy")) == byHandleInstance.expressionHandle(for: .preset(.happy)))
        #expect(byHandleInstance.expressionHandle(for: .custom("notAnExpression")) == nil)

        var weights = byHandleInstance.makeExpressionWeights()
        for (key, value) in [(ExpressionKey.preset(.aa), Float(0.6)), (.preset(.blink), 1), (.preset(.relaxed), 0.3)] {
            weights[try #require(byHandleInstance.expressionHandle(for: key))] = value
            byKeyInstance.setExpressions([key: value])
        }
        byHandleInstance.setExpressions(weights)
        #expect(TestSupport.morphWeights(in: byHandle) == TestSupport.morphWeights(in: byKey))
        #expect(byHandleInstance.expression(for: .preset(.aa)) == byKeyInstance.expression(for: .preset(.aa)))

        // Only what is set lands: an expression left unset keeps its weight.
        weights.reset()
        weights[try #require(byHandleInstance.expressionHandle(for: .preset(.aa)))] = 0
        byHandleInstance.setExpressions(weights)
        #expect(byHandleInstance.expression(for: .preset(.aa)) == 0)
        #expect(byHandleInstance.expression(for: .preset(.blink)) == 1)
    }

    @Test
    func testBlockingExpressionOverrideSuppressesBlinkAndLookAtWeights() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        // Seed-san's `relaxed` declares overrideBlink / overrideLookAt = block.
        let vrmEntity = try await TestSupport.sharedLoader(.seedSanStandard).loadEntity()
        let instance = try #require(vrmEntity.instance)

        instance.setExpressions([.preset(.blink): 1])
        instance.setExpressions([.preset(.lookUp): 1])
        instance.setExpressions([.preset(.aa): 1])
        #expect(TestSupport.morphWeight(in: vrmEntity, targetIndex: 1) == 1)
        #expect(TestSupport.morphWeight(in: vrmEntity, targetIndex: 39) == 1)
        #expect(TestSupport.morphWeight(in: vrmEntity, targetIndex: 25) == 1)

        instance.setExpressions([.preset(.relaxed): 1])
        #expect(TestSupport.morphWeight(in: vrmEntity, targetIndex: 1) == 0)
        #expect(TestSupport.morphWeight(in: vrmEntity, targetIndex: 39) == 0)
        // overrideMouth is `none`, so mouth expressions keep their weight.
        #expect(TestSupport.morphWeight(in: vrmEntity, targetIndex: 25) == 1)
        // The input weights themselves are untouched by the override.
        #expect(instance.expression(for: .preset(.blink)) == 1)

        instance.setExpressions([.preset(.relaxed): 0])
        #expect(TestSupport.morphWeight(in: vrmEntity, targetIndex: 1) == 1)
        #expect(TestSupport.morphWeight(in: vrmEntity, targetIndex: 39) == 1)
    }

    /// Alicia's `Joy` and `Fun` groups both bind face target 38, and VRM 0.x blend
    /// shape groups load as expressions, so their contributions add up.
    @Test
    func testVRM0BlendShapeGroupsSharingAMorphTargetAccumulate() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let vrmEntity = try await TestSupport.sharedLoader(.aliciaSolidStandard).loadEntity()
        let instance = try #require(vrmEntity.instance)

        instance.setExpressions([.preset(.happy): 0.25])
        #expect(try #require(TestSupport.morphWeight(in: vrmEntity, targetIndex: 38)).isApproximatelyEqual(to: 0.25))

        instance.setExpressions([.preset(.relaxed): 0.5])
        #expect(try #require(TestSupport.morphWeight(in: vrmEntity, targetIndex: 38)).isApproximatelyEqual(to: 0.75))
        // Joy's own targets keep the weight Joy gave them.
        #expect(try #require(TestSupport.morphWeight(in: vrmEntity, targetIndex: 14)).isApproximatelyEqual(to: 0.25))

        // Releasing one group takes back its share alone.
        instance.setExpressions([.preset(.happy): 0])
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
        let vrmEntity = try await VRMEntityLoader(withData: modified, shaders: []).loadEntity()
        let instance = try #require(vrmEntity.instance)

        instance.setExpressions([.preset(.blink): 1, .preset(.happy): 0.5])
        #expect(try #require(TestSupport.morphWeight(in: vrmEntity, targetIndex: 1)).isApproximatelyEqual(to: 0.5))

        instance.setExpressions([.preset(.sad): 0.5])
        #expect(TestSupport.morphWeight(in: vrmEntity, targetIndex: 1) == 0)

        // Past saturation the weight stays at 0 rather than going negative.
        instance.setExpressions([.preset(.happy): 1, .preset(.sad): 1])
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
        let vrmEntity = try await VRMEntityLoader(withData: modified, shaders: []).loadEntity()
        let instance = try #require(vrmEntity.instance)

        instance.setExpressions([.preset(.blink): 1])
        #expect(TestSupport.morphWeight(in: vrmEntity, targetIndex: 1) == 1)

        // A 0.25 blend would leave 0.75 on a non-binary expression.
        instance.setExpressions([.preset(.happy): 0.25])
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
        let vrmEntity = try await VRMEntityLoader(withData: modified, shaders: []).loadEntity()
        let instance = try #require(vrmEntity.instance)

        instance.setExpressions([.preset(.blink): 1, .preset(.blinkLeft): 1])

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
        let instance = try #require(vrmEntity.instance)

        // `angry` is binary and carries a textureTransformBind on material 11, so it
        // only takes effect above half.
        instance.setExpressions([.preset(.angry): 0.5])
        var parameters = try TestSupport.mtoonParameters(in: vrmEntity, materialIndex: 11)
        #expect(parameters.uvTransform.isApproximatelyEqual(to: SIMD4<Float>(1, 1, 0, 0)))
        #expect(instance.expression(for: .preset(.angry)) == 0)

        instance.setExpressions([.preset(.angry): 0.51])
        parameters = try TestSupport.mtoonParameters(in: vrmEntity, materialIndex: 11)
        #expect(parameters.uvTransform.isApproximatelyEqual(to: SIMD4<Float>(1, 1, 0.5, 0)))
        #expect(instance.expression(for: .preset(.angry)) == 1)

        instance.setExpressions([.preset(.happy): 1, .preset(.angry): 1])
        parameters = try TestSupport.mtoonParameters(in: vrmEntity, materialIndex: 11)
        #expect(parameters.uvTransform.isApproximatelyEqual(to: SIMD4<Float>(1, 1, 0.75, 0)))
        #expect(instance.expression(for: .preset(.happy)) == 1)
        #expect(instance.expression(for: .preset(.angry)) == 1)

        instance.setExpressions([.preset(.happy): 0])
        parameters = try TestSupport.mtoonParameters(in: vrmEntity, materialIndex: 11)
        #expect(parameters.uvTransform.isApproximatelyEqual(to: SIMD4<Float>(1, 1, 0.5, 0)))
        #expect(instance.expression(for: .preset(.happy)) == 0)
        #expect(instance.expression(for: .preset(.angry)) == 1)

        instance.setExpressions([.preset(.angry): 0])
        parameters = try TestSupport.mtoonParameters(in: vrmEntity, materialIndex: 11)
        #expect(parameters.uvTransform.isApproximatelyEqual(to: SIMD4<Float>(1, 1, 0, 0)))
    }

    @Test
    func testExpressionMaterialColorsAccumulateAndResetIndependently() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let modified = try TestSupport.modifiedSeedSanData(name: "accumulated-material-colors") { json in
            var materials = json.objects("materials")
            guard materials.indices.contains(0),
                  var pbr = materials[0].object("pbrMetallicRoughness") else {
                throw VRMError.dataInconsistent("Missing Seed-san material fixture data")
            }
            pbr["baseColorFactor"] = [1.0, 1.0, 1.0, 1.0]
            materials[0]["pbrMetallicRoughness"] = .object(pbr)
            json["materials"] = .objects(materials)
            try TestSupport.modifyExpressionPresets(in: &json) { preset in
                guard var happy = preset.object("happy"),
                      var angry = preset.object("angry") else {
                    throw VRMError.dataInconsistent("Missing Seed-san expression fixture data")
                }
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
            }
        }

        let loader = try VRMEntityLoader(withData: modified, shaders: TestSupport.noOutlineShaders)
        let vrmEntity = try await loader.loadEntity()
        let instance = try #require(vrmEntity.instance)
        instance.setExpressions([.preset(.happy): 1])
        instance.setExpressions([.preset(.angry): 1])
        var parameters = try TestSupport.mtoonParameters(in: vrmEntity, materialIndex: 0)
        #expect(parameters.baseColor.isApproximatelyEqual(to: SIMD4<Float>(0.8, 0.6, 1, 1)))

        instance.setExpressions([.preset(.happy): 0])
        parameters = try TestSupport.mtoonParameters(in: vrmEntity, materialIndex: 0)
        #expect(parameters.baseColor.isApproximatelyEqual(to: SIMD4<Float>(1, 0.6, 1, 1)))
    }
#endif

    /// A mesh variant re-lays the weight sets, so where a morph target lives has to
    /// be resolved again once one is swapped in. Driving an expression across a
    /// first-person switch is what a stale resolution shows up in.
    @Test
    func testExpressionsKeepReachingTheirTargetsAcrossAMeshVariantSwitch() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let vrmEntity = try await TestSupport.sharedLoader(.aliciaSolidStandard).loadEntity()
        let instance = try #require(vrmEntity.instance)
        // An expression whose morph target can be read back, taken in the order the
        // model states its expressions: a dictionary's order differs between runs.
        var driven: (key: ExpressionKey, target: Int)?
        let clips = vrmEntity.vrm.expressionClips
        for expression in instance.availableExpressions {
            guard let clip = clips.last(where: { $0.key == expression.key }),
                  let binding = clip.morphBinds.first(where: { $0.weight == 1 }) else { continue }
            instance.setExpressions([expression.key: 1])
            if TestSupport.morphWeight(in: vrmEntity, targetIndex: binding.index) == 1 {
                driven = (expression.key, binding.index)
                break
            }
            instance.setExpressions([expression.key: 0])
        }
        let (key, target) = try #require(driven)

        instance.firstPersonRenderMode = .firstPerson
        instance.setExpressions([key: 0.5])
        #expect(TestSupport.morphWeight(in: vrmEntity, targetIndex: target) == 0.5)

        instance.firstPersonRenderMode = .thirdPerson
        instance.setExpressions([key: 1])
        #expect(TestSupport.morphWeight(in: vrmEntity, targetIndex: target) == 1)
    }
}
#endif
