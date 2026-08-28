import Testing
@testable import VRMKitRuntime

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
