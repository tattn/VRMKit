public protocol UnityTransformCompatible {
    associatedtype CompatibleType
    var utx: CompatibleType { get }
}

public final class UnityTransform<Base> {
    package let base: Base

    public init(_ base: Base) {
        self.base = base
    }
}

public extension UnityTransformCompatible {
    var utx: UnityTransform<Self> {
        UnityTransform(self)
    }
}
