#if canImport(RealityKit)
import Foundation
import simd
import Testing
import VRMKit
@testable import VRMRealityKit

/// Pure evaluation tests for the animation sampler, one per interpolation
/// mode, checked against hand-computed values from the glTF spec formulas.
@Suite
struct GLTFKeyframeTrackTests {
    @Test
    func testLinearInterpolatesAndClampsOutsideTheRange() throws {
        let track = try GLTFKeyframeTrack<SIMD3<Float>>(
            times: [1, 3],
            interpolation: .LINEAR,
            values: [SIMD3<Float>(0, 0, 0), SIMD3<Float>(2, 4, 0)])

        #expect(track.duration == 3)
        #expect(track.value(at: 2).isApproximatelyEqual(to: SIMD3<Float>(1, 2, 0)))
        // Inputs outside the keyframe range clamp to the boundary keyframes.
        #expect(track.value(at: 0).isApproximatelyEqual(to: .zero))
        #expect(track.value(at: 99).isApproximatelyEqual(to: SIMD3<Float>(2, 4, 0)))
    }

    @Test
    func testStepHoldsThePreviousKeyframe() throws {
        let track = try GLTFKeyframeTrack<[Float]>(
            times: [0, 1, 2],
            interpolation: .STEP,
            values: [[0], [10], [20]])

        #expect(track.value(at: 0.99) == [0])
        #expect(track.value(at: 1.0) == [10])
        #expect(track.value(at: 1.99) == [10])
        #expect(track.value(at: 2.5) == [20])
    }

    @Test
    func testLinearRotationUsesSphericalInterpolation() throws {
        let quarter = simd_quatf(angle: .pi / 2, axis: SIMD3<Float>(0, 0, 1))
        let track = try GLTFKeyframeTrack<simd_quatf>(
            times: [0, 1],
            interpolation: .LINEAR,
            values: [simd_quatf(ix: 0, iy: 0, iz: 0, r: 1), quarter])

        let mid = track.value(at: 0.5)
        let expected = simd_quatf(angle: .pi / 4, axis: SIMD3<Float>(0, 0, 1))
        #expect(abs(simd_dot(mid, expected)) > 0.9999)
        // Unit length is what downstream Transform assignment relies on.
        #expect(simd_length(mid.vector).isApproximatelyEqual(to: 1))
    }

    @Test
    func testCubicSplineMatchesTheSpecFormula() throws {
        // v0 = 0 (out-tangent 2), v1 = 1 (in-tangent 0), span 0..1.
        // p(0.5) = 0.5·v0 + 0.125·b0 + 0.5·v1 − 0.125·a1 = 0.25 + 0.5 = 0.75.
        let track = try GLTFKeyframeTrack<[Float]>(
            times: [0, 1],
            interpolation: .CUBICSPLINE,
            values: [[0], [0], [2], [0], [1], [0]])

        let value = track.value(at: 0.5)
        #expect(value.count == 1)
        #expect(value[0].isApproximatelyEqual(to: 0.75))
        // Boundaries hit the keyframe values exactly.
        #expect(track.value(at: 0) == [0])
        #expect(track.value(at: 1) == [1])
    }

    @Test
    func testCubicSplineWithZeroTangentsEasesBetweenValues() throws {
        let track = try GLTFKeyframeTrack<SIMD3<Float>>(
            times: [0, 2],
            interpolation: .CUBICSPLINE,
            values: [.zero, SIMD3<Float>(0, 0, 0), .zero,
                     .zero, SIMD3<Float>(4, 0, 0), .zero])

        // With zero tangents the Hermite basis reduces to smoothstep: 0.5 at
        // the midpoint, but steeper than linear at 1/4 of the way.
        #expect(track.value(at: 1).x.isApproximatelyEqual(to: 2))
        #expect(track.value(at: 0.5).x.isApproximatelyEqual(to: 4 * 0.15625))
    }

    /// The spec's sampler invariants are checked once when the track is built, so
    /// a malformed file fails the load instead of animating a prefix of itself.
    @Test
    func testMalformedSamplersAreRejectedAtConstruction() {
        #expect(throws: VRMError.self) {
            try GLTFKeyframeTrack<[Float]>(times: [], interpolation: .LINEAR, values: [])
        }
        // More times than values.
        #expect(throws: VRMError.self) {
            try GLTFKeyframeTrack<[Float]>(times: [0, 1, 2], interpolation: .LINEAR, values: [[0], [2]])
        }
        // Times must be strictly increasing.
        #expect(throws: VRMError.self) {
            try GLTFKeyframeTrack<[Float]>(times: [0, 1, 1], interpolation: .LINEAR, values: [[0], [1], [2]])
        }
        #expect(throws: VRMError.self) {
            try GLTFKeyframeTrack<[Float]>(times: [1, 0], interpolation: .LINEAR, values: [[0], [1]])
        }
        // CUBICSPLINE needs two keyframes to interpolate between...
        #expect(throws: VRMError.self) {
            try GLTFKeyframeTrack<[Float]>(times: [0], interpolation: .CUBICSPLINE, values: [[0], [1], [0]])
        }
        // ...and three output elements per keyframe.
        #expect(throws: VRMError.self) {
            try GLTFKeyframeTrack<[Float]>(times: [0, 1], interpolation: .CUBICSPLINE, values: [[0], [1]])
        }
    }

    @Test
    func testSingleKeyframeHoldsItsValue() throws {
        let track = try GLTFKeyframeTrack<[Float]>(times: [3], interpolation: .LINEAR, values: [[7]])
        #expect(track.value(at: 0) == [7])
        #expect(track.value(at: 9) == [7])
    }
}
#endif
