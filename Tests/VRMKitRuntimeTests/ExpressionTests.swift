import Testing
@testable import VRMKitRuntime

/// The two spellings of a preset: what VRM 0.x writes, and what VRM 1.0 calls it.
@Suite
struct ExpressionPresetTests {
    @Test
    func testTheVRM0SpellingsResolveToTheirVRM1Presets() {
        #expect(ExpressionPreset(vrm0PresetName: "joy") == .happy)
        #expect(ExpressionPreset(vrm0PresetName: "sorrow") == .sad)
        #expect(ExpressionPreset(vrm0PresetName: "fun") == .relaxed)
        #expect(ExpressionPreset(vrm0PresetName: "a") == .aa)
        #expect(ExpressionPreset(vrm0PresetName: "blink_l") == .blinkLeft)
        // `unknown` is what 0.x writes for a group standing for no preset at all.
        #expect(ExpressionPreset(vrm0PresetName: "unknown") == nil)
    }

    /// Exporters disagree on the casing, so the spelling is matched either way.
    @Test
    func testAVRM0SpellingIsMatchedWhateverItsCasing() {
        #expect(ExpressionPreset(vrm0PresetName: "Joy") == .happy)
        #expect(ExpressionPreset(vrm0PresetName: "LookUp") == .lookUp)
    }

    @Test
    func testEveryPresetVRM0StatesRoundTripsThroughItsSpelling() {
        for preset in ExpressionPreset.allCases {
            guard let name = preset.vrm0PresetName else { continue }
            #expect(ExpressionPreset(vrm0PresetName: name) == preset)
        }
        #expect(ExpressionPreset.happy.vrm0PresetName == "joy")
        // VRM 1.0 introduced `surprised`, which 0.x has no spelling for.
        #expect(ExpressionPreset.surprised.vrm0PresetName == nil)
    }
}

/// What the runtime makes of the clips a model states.
@Suite
struct ExpressionRuntimeTests {
    private final class Mesh {}

    private func clip(_ name: String, preset: ExpressionPreset? = nil) -> ExpressionClip<Mesh> {
        ExpressionClip(name: name, preset: preset, values: [], isBinary: false)
    }

    /// Two clips under one key is malformed, and whichever wins has to win everywhere:
    /// an expression the model offers that no weight reaches is worse than no duplicate.
    @Test
    func testAKeyStatedTwiceIsOneExpression() {
        let runtime = ExpressionRuntime<Mesh>()
        runtime.setUp(clips: [clip("joy", preset: .happy), clip("wink"), clip("happy", preset: .happy)],
                      materialColorClips: [:],
                      textureTransformClips: [:])

        #expect(runtime.clips.count == runtime.availableExpressions.count)
        #expect(runtime.availableExpressions.map(\.key) == [.preset(.happy), .custom("wink")])
        #expect(runtime.availableExpressions.map(\.name) == ["happy", "wink"])
    }
}
