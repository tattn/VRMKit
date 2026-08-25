import Foundation
import simd

/// What `VRMC_springBone` reads a joint that states nothing as. Shared so that
/// reading and writing agree on what an unstated parameter means.
public enum VRMSpringBoneDefaults {
    public static let stiffness: Float = 1
    public static let gravityPower: Float = 0
    public static let gravityDirection = SIMD3<Float>(0, -1, 0)
    public static let dragForce: Float = 0.5
    public static let hitRadius: Float = 0
}
