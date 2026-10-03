import Foundation
import simd
import VRMKit

/// The range a joint's tail may swing in, from `VRMC_springBone_limit`, following the
/// reference implementation the spec gives.
package struct SpringBoneLimit: Equatable {
    package enum Shape: Equatable {
        case cone(angle: Float)
        case hinge(angle: Float)
        case spherical(pitch: Float, yaw: Float)
    }

    let shape: Shape
    /// From the orientation the joint's rest direction gives the limit.
    let rotation: simd_quatf

    package init(shape: Shape, rotation: simd_quatf = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)) {
        self.shape = shape
        self.rotation = rotation
    }

    /// Angles past the range the spec states read as its end, as the spec has them.
    package init(vrm1Limit limit: VRM1.SpringBone.Spring.Joint.Limit) throws {
        let rotation: simd_quatf
        switch limit {
        case .cone(let angle, let limitRotation):
            try VRMSpringBoneParameters.requireFiniteNonnegative(angle, named: "cone limit angle")
            self.shape = .cone(angle: min(angle, .pi))
            rotation = limitRotation
        case .hinge(let angle, let limitRotation):
            try VRMSpringBoneParameters.requireFiniteNonnegative(angle, named: "hinge limit angle")
            self.shape = .hinge(angle: min(angle, .pi))
            rotation = limitRotation
        case .spherical(let pitch, let yaw, let limitRotation):
            try VRMSpringBoneParameters.requireFiniteNonnegative(pitch, named: "spherical limit pitch")
            try VRMSpringBoneParameters.requireFiniteNonnegative(yaw, named: "spherical limit yaw")
            self.shape = .spherical(pitch: min(pitch, .pi), yaw: min(yaw, .pi / 2))
            rotation = limitRotation
        }
        let length = simd_length(rotation.vector)
        guard length.isFinite, length > Float.ulpOfOne else {
            throw VRMError._dataInconsistent("a VRMC_springBone_limit rotation is not a rotation")
        }
        self.rotation = rotation.normalized
    }

    /// The limit's space in the world: the shortest turn from +y to the joint's rest
    /// direction `boneAxis`, under the joint's rest rotation, then ``rotation``.
    func space(restRotation: simd_quatf, boneAxis: SIMD3<Float>) -> simd_quatf {
        // A half turn about x when the bone points straight down, where the shortest
        // turn is not unique.
        let axisRotation = boneAxis.y <= -1 + 1e-6
            ? simd_quatf(ix: 1, iy: 0, iz: 0, r: 0)
            : simd_quatf(ix: boneAxis.z, iy: 0, iz: -boneAxis.x, r: boneAxis.y + 1).normalized
        return restRotation * axisRotation * rotation
    }

    /// `direction`, a unit vector in the limit's space, moved to the nearest direction the
    /// limit allows. Directions the spec calls singular take the side it names.
    func constrained(_ direction: SIMD3<Float>) -> SIMD3<Float> {
        switch shape {
        case .cone(let angle):
            Self.cone(direction, angle: angle)
        case .hinge(let angle):
            Self.hinge(direction, angle: angle)
        case .spherical(let pitch, let yaw):
            Self.spherical(direction, pitchLimit: pitch, yawLimit: yaw)
        }
    }

    private static let tolerance: Float = 1e-6

    private static func cone(_ direction: SIMD3<Float>, angle: Float) -> SIMD3<Float> {
        let cosAngle = cos(angle)
        guard direction.y < cosAngle else { return direction }
        let sinAngle = (1 - cosAngle * cosAngle).squareRoot()
        let horizontal = SIMD2(direction.x, direction.z)
        let length = simd_length(horizontal)
        guard length > tolerance else { return SIMD3(0, cosAngle, sinAngle) }
        let scaled = horizontal * (sinAngle / length)
        return SIMD3(scaled.x, cosAngle, scaled.y)
    }

    private static func hinge(_ direction: SIMD3<Float>, angle: Float) -> SIMD3<Float> {
        let projected = SIMD2(direction.y, direction.z)
        let length = simd_length(projected)
        guard length > tolerance else { return SIMD3(0, 1, 0) }
        let onPlane = projected / length
        let cosAngle = cos(angle)
        guard onPlane.x < cosAngle else { return SIMD3(0, onPlane.x, onPlane.y) }
        let sinAngle = (1 - cosAngle * cosAngle).squareRoot()
        return SIMD3(0, cosAngle, onPlane.y < 0 ? -sinAngle : sinAngle)
    }

    private static func spherical(_ direction: SIMD3<Float>, pitchLimit: Float, yawLimit: Float) -> SIMD3<Float> {
        let pitch: Float
        if direction.y <= -1 + tolerance {
            pitch = .pi
        } else if abs(direction.x) >= 1 - tolerance {
            pitch = 0
        } else {
            pitch = atan2(direction.z, direction.y)
        }
        let yaw = asin(max(-1, min(1, direction.x)))
        let limitedPitch = abs(pitch) > pitchLimit ? pitchLimit * (pitch < 0 ? -1 : 1) : pitch
        let limitedYaw = abs(yaw) > yawLimit ? yawLimit * (yaw < 0 ? -1 : 1) : yaw
        return SIMD3(sin(limitedYaw), cos(limitedYaw) * cos(limitedPitch), cos(limitedYaw) * sin(limitedPitch))
    }
}
