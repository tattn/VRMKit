/// Unity-shaped transform accessors for a scene graph node, so that the spring
/// bone and constraint runtimes can be written once against either renderer.
/// Each renderer defines `utx` on its own node type and extends this with the
/// accessors that type provides.
package struct UnityTransform<Base> {
    package let base: Base

    package init(_ base: Base) {
        self.base = base
    }
}
