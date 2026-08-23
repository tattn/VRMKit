package extension Comparable {
    /// The value held to `range`, which is how a factor with a range in the
    /// specification stays inside it.
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
