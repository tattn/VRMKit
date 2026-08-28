import CoreGraphics
import UIKit
internal import VRMRealityKit

/// A segmented control over the emotions a loaded model offers, each segment
/// titled the way the model itself names the expression.
@MainActor
final class ExampleExpressionControl {
    /// The emotions the example shows, in the order it shows them.
    private static let presets: [ExpressionPreset] = [.neutral, .happy, .angry, .sad, .relaxed]

    let segmentedControl = UISegmentedControl()

    private var expressions: [ExpressionInfo] = []
    private var selected: ExpressionKey?
    private weak var target: VRMEntity?

    init() {
        segmentedControl.addTarget(self, action: #selector(selectionChanged), for: .valueChanged)
    }

    /// Re-titles the segments for a newly loaded model and puts the selected
    /// expression on it, keeping the selection the previous model left.
    func attach(to target: VRMEntity) {
        self.target = target
        let selectedIndex = max(segmentedControl.selectedSegmentIndex, 0)
        let available = target.availableExpressions
        expressions = Self.presets.compactMap { preset in
            available.first { $0.preset == preset }
        }
        segmentedControl.removeAllSegments()
        for (index, expression) in expressions.enumerated() {
            segmentedControl.insertSegment(withTitle: expression.name, at: index, animated: false)
        }
        // The new model carries none of the previous one's weights. An empty
        // segmented control selects nothing, which `selectionChanged` lets be.
        selected = nil
        segmentedControl.selectedSegmentIndex = min(selectedIndex, expressions.count - 1)
        selectionChanged()
    }

    /// Both weights are sent together so the runtime re-applies its bindings once.
    @objc private func selectionChanged() {
        guard expressions.indices.contains(segmentedControl.selectedSegmentIndex) else { return }
        let key = expressions[segmentedControl.selectedSegmentIndex].key
        var weights: [ExpressionKey: CGFloat] = [key: 1.0]
        if let selected, selected != key {
            weights[selected] = 0.0
        }
        selected = key
        target?.setExpressions(weights)
    }
}
