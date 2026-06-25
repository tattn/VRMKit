import VRMKit

package extension VRM1.Expressions {
    var runtimeClips: [(name: String, preset: BlendShapePreset, expression: VRM1.Expressions.Expression)] {
        var clips: [(String, BlendShapePreset, VRM1.Expressions.Expression)] = [
            ("Happy", .happy, preset.happy),
            ("Angry", .angry, preset.angry),
            ("Sad", .sad, preset.sad),
            ("Relaxed", .relaxed, preset.relaxed),
            ("Surprised", .surprised, preset.surprised),
            ("Aa", .aa, preset.aa),
            ("Ih", .ih, preset.ih),
            ("Ou", .ou, preset.ou),
            ("Ee", .ee, preset.ee),
            ("Oh", .oh, preset.oh),
            ("Blink", .blink, preset.blink),
            ("BlinkLeft", .blinkLeft, preset.blinkLeft),
            ("BlinkRight", .blinkRight, preset.blinkRight),
            ("LookUp", .lookUp, preset.lookUp),
            ("LookDown", .lookDown, preset.lookDown),
            ("LookLeft", .lookLeft, preset.lookLeft),
            ("LookRight", .lookRight, preset.lookRight),
            ("Neutral", .neutral, preset.neutral)
        ]

        guard let customMap = custom?.value as? [String: Any] else {
            return clips
        }

        let decoder = DictionaryDecoder()
        for name in customMap.keys.sorted() {
            guard let raw = customMap[name] as? [String: Any],
                  let expression = try? decoder.decode(VRM1.Expressions.Expression.self, from: raw) else {
                continue
            }
            clips.append((name, .unknown, expression))
        }
        return clips
    }
}
