import simd

/// The ranges a spring bone parameter is read and written in, so that adding a
/// spring and swinging one agree about what the simulation can take.
///
/// VRM 1.0 states them in its schema; VRM 0.x states none, so these are the
/// ranges its runtime behaves in.
package enum VRMSpringBoneParameters {
    /// NaN spreads from one tail to every position it is measured against, and a
    /// negative stiffness or radius pulls the wrong way.
    package static func requireFiniteNonnegative(_ value: Float, named name: String) throws {
        guard value.isFinite, value >= 0 else {
            throw VRMError._dataInconsistent("spring bone \(name) must be finite and nonnegative")
        }
    }

    /// A drag force outside 0...1 grows last frame's move instead of damping it.
    package static func requireDragForce(_ dragForce: Float) throws {
        guard dragForce.isFinite, (0...1).contains(dragForce) else {
            throw VRMError._dataInconsistent("spring bone drag force must be finite and in 0...1")
        }
    }

    package static func requireFinite(_ vector: SIMD3<Float>, named name: String) throws {
        guard vector.x.isFinite, vector.y.isFinite, vector.z.isFinite else {
            throw VRMError._dataInconsistent("spring bone \(name) cannot contain infinity or NaN")
        }
    }
}
