#if canImport(RealityKit)
import Foundation
import simd
import VRMKit
import VRMKitRuntime

/// A value a glTF animation channel can interpolate.
protocol GLTFAnimatableValue {
    static func lerp(_ from: Self, to: Self, fraction: Float) -> Self
    /// glTF's cubic Hermite spline, where `duration` is the time between the
    /// surrounding keyframes (the spec's `t_k+1 - t_k`).
    static func cubic(value0: Self,
                      outTangent0: Self,
                      value1: Self,
                      inTangent1: Self,
                      fraction: Float,
                      duration: Float) -> Self
}

/// The four scalar weights of glTF's cubic Hermite basis.
struct GLTFCubicWeights {
    let value0: Float
    let outTangent0: Float
    let value1: Float
    let inTangent1: Float

    init(fraction t: Float, duration: Float) {
        let t2 = t * t
        let t3 = t2 * t
        value0 = 2 * t3 - 3 * t2 + 1
        outTangent0 = duration * (t3 - 2 * t2 + t)
        value1 = -2 * t3 + 3 * t2
        inTangent1 = duration * (t3 - t2)
    }
}

/// Every float SIMD interpolates the same way, so one extension serves both the
/// vector channels and the quaternion's component-wise spline below.
extension SIMD where Scalar == Float {
    static func lerp(_ from: Self, to: Self, fraction: Float) -> Self {
        from + (to - from) * Self(repeating: fraction)
    }

    static func cubic(value0: Self, outTangent0: Self, value1: Self, inTangent1: Self,
                      fraction: Float, duration: Float) -> Self {
        let w = GLTFCubicWeights(fraction: fraction, duration: duration)
        return value0 * Self(repeating: w.value0) + outTangent0 * Self(repeating: w.outTangent0)
            + value1 * Self(repeating: w.value1) + inTangent1 * Self(repeating: w.inTangent1)
    }
}

extension SIMD3<Float>: GLTFAnimatableValue {}

extension simd_quatf: GLTFAnimatableValue {
    static func lerp(_ from: Self, to: Self, fraction: Float) -> Self {
        // The spec asks for spherical linear interpolation, shortest path.
        simd_slerp(from, to, fraction)
    }

    static func cubic(value0: Self, outTangent0: Self, value1: Self, inTangent1: Self,
                      fraction: Float, duration: Float) -> Self {
        // Per spec, the spline runs on the raw components and the result is normalized.
        simd_quatf(vector: SIMD4<Float>.cubic(value0: value0.vector,
                                              outTangent0: outTangent0.vector,
                                              value1: value1.vector,
                                              inTangent1: inTangent1.vector,
                                              fraction: fraction,
                                              duration: duration)).safelyNormalized
    }
}

/// Morph target weights: one Float per target, interpolated element-wise.
extension Array: GLTFAnimatableValue where Element == Float {
    static func lerp(_ from: Self, to: Self, fraction: Float) -> Self {
        zip(from, to).map { $0 + ($1 - $0) * fraction }
    }

    static func cubic(value0: Self, outTangent0: Self, value1: Self, inTangent1: Self,
                      fraction: Float, duration: Float) -> Self {
        let w = GLTFCubicWeights(fraction: fraction, duration: duration)
        let count = Swift.min(value0.count, outTangent0.count, value1.count, inTangent1.count)
        return (0..<count).map {
            w.value0 * value0[$0] + w.outTangent0 * outTangent0[$0]
                + w.value1 * value1[$0] + w.inTangent1 * inTangent1[$0]
        }
    }
}

/// One decoded glTF animation sampler: keyframe times and values, evaluated at
/// an arbitrary time. Inputs outside the keyframe range clamp to the first /
/// last keyframe, as the spec prescribes, and its invariants are checked once
/// at construction rather than on every evaluation.
struct GLTFKeyframeTrack<Value: GLTFAnimatableValue> {
    let times: [Float]
    let interpolation: GLTF.Animation.Sampler.Interpolation
    /// LINEAR / STEP: one element per keyframe. CUBICSPLINE: in-tangent, value,
    /// out-tangent per keyframe, in that order.
    let values: [Value]

    var duration: Float { times[times.count - 1] }

    init(times: [Float],
         interpolation: GLTF.Animation.Sampler.Interpolation,
         values: [Value]) throws {
        // CUBICSPLINE interpolates between two keyframes, so one is not enough.
        let minimumKeyframes = interpolation == .CUBICSPLINE ? 2 : 1
        guard times.count >= minimumKeyframes else {
            throw VRMError._dataInconsistent(
                "a \(interpolation) animation sampler needs at least \(minimumKeyframes) keyframes, but has \(times.count)"
            )
        }
        guard zip(times, times.dropFirst()).allSatisfy({ $0 < $1 }) else {
            throw VRMError._dataInconsistent("animation sampler input times must be strictly increasing")
        }
        let valuesPerKeyframe = interpolation == .CUBICSPLINE ? 3 : 1
        guard values.count == times.count * valuesPerKeyframe else {
            throw VRMError._dataInconsistent(
                "a \(interpolation) animation sampler with \(times.count) keyframes needs \(times.count * valuesPerKeyframe) output elements, but has \(values.count)"
            )
        }
        self.times = times
        self.interpolation = interpolation
        self.values = values
    }

    private func keyframeValue(at index: Int) -> Value {
        interpolation == .CUBICSPLINE ? values[index * 3 + 1] : values[index]
    }

    func value(at time: Float) -> Value {
        if times.count == 1 || time <= times[0] { return keyframeValue(at: 0) }
        if time >= duration { return keyframeValue(at: times.count - 1) }

        // The largest keyframe k with times[k] <= time.
        var low = 0
        var high = times.count - 1
        while low + 1 < high {
            let mid = (low + high) / 2
            if times[mid] <= time { low = mid } else { high = mid }
        }
        let span = times[low + 1] - times[low]
        let fraction = (time - times[low]) / span

        switch interpolation {
        case .STEP:
            return keyframeValue(at: low)
        case .LINEAR:
            return Value.lerp(keyframeValue(at: low), to: keyframeValue(at: low + 1), fraction: fraction)
        case .CUBICSPLINE:
            return Value.cubic(value0: values[low * 3 + 1],
                               outTangent0: values[low * 3 + 2],
                               value1: values[(low + 1) * 3 + 1],
                               inTangent1: values[(low + 1) * 3],
                               fraction: fraction,
                               duration: span)
        }
    }
}
#endif
