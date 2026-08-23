import VRMKit

package extension VRM1.Expressions {
    var runtimeClips: [(name: String, preset: ExpressionPreset?, expression: VRM1.Expressions.Expression)] {
        let presetClips: [(ExpressionPreset, VRM1.Expressions.Expression?)] = [
            (.happy, preset?.happy),
            (.angry, preset?.angry),
            (.sad, preset?.sad),
            (.relaxed, preset?.relaxed),
            (.surprised, preset?.surprised),
            (.aa, preset?.aa),
            (.ih, preset?.ih),
            (.ou, preset?.ou),
            (.ee, preset?.ee),
            (.oh, preset?.oh),
            (.blink, preset?.blink),
            (.blinkLeft, preset?.blinkLeft),
            (.blinkRight, preset?.blinkRight),
            (.lookUp, preset?.lookUp),
            (.lookDown, preset?.lookDown),
            (.lookLeft, preset?.lookLeft),
            (.lookRight, preset?.lookRight),
            (.neutral, preset?.neutral)
        ]
        var clips: [(String, ExpressionPreset?, VRM1.Expressions.Expression)] = presetClips.compactMap { expressionPreset, expression in
            guard let expression else { return nil }
            return (expressionPreset.rawValue, expressionPreset, expression)
        }

        guard let customMap = custom?.value as? [String: Any] else {
            return clips
        }

        for name in customMap.keys.sorted() {
            guard let expression = try? customMap.decodeJSON(VRM1.Expressions.Expression.self, forKey: name) else {
                continue
            }
            clips.append((name, nil, expression))
        }
        return clips
    }
}
