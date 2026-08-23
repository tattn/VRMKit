package protocol UnityTransformCompatible {
    associatedtype CompatibleType
    var utx: CompatibleType { get }
}

package struct UnityTransform<Base> {
    package let base: Base

    package init(_ base: Base) {
        self.base = base
    }
}

package extension UnityTransformCompatible {
    var utx: UnityTransform<Self> {
        UnityTransform(self)
    }
}
