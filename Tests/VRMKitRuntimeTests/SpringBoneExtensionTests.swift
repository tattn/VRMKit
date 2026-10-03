import Foundation
import Testing
import simd
@testable import VRMKit
@testable import VRMKitRuntime

/// `VRMC_springBone_extended_collider` and `VRMC_springBone_limit`, the extensions a
/// `VRMC_springBone` collider and joint carry.
@Suite
struct SpringBoneExtensionTests {
    // MARK: - Reading

    /// The extended shape replaces the fallback `VRMC_springBone` states, which exporters
    /// write for readers without the extension: a far sphere for an inside collider and a
    /// huge one for a plane.
    @Test
    func testAnExtendedColliderReplacesItsFallbackShape() throws {
        let collider = try Self.collider(extension: #"{"specVersion": "1.0", "shape": {"plane": {"offset": [0, 1, 0], "normal": [0, 2, 0]}}}"#)

        #expect(try SpringBoneColliderShape(vrm1Collider: collider) == .plane(offset: SIMD3(0, 1, 0), normal: SIMD3(0, 1, 0)))
    }

    @Test
    func testInsideSpheresAndCapsulesAreRead() throws {
        let sphere = try Self.collider(extension: #"{"specVersion": "1.0", "shape": {"sphere": {"radius": 0.5, "inside": true}}}"#)
        let capsule = try Self.collider(
            extension: #"{"specVersion": "1.0", "shape": {"capsule": {"radius": 0.5, "tail": [0, 1, 0], "inside": true}}}"#
        )

        #expect(try SpringBoneColliderShape(vrm1Collider: sphere) == .sphere(offset: .zero, radius: 0.5, inside: true))
        #expect(try SpringBoneColliderShape(vrm1Collider: capsule)
            == .capsule(offset: .zero, tail: SIMD3(0, 1, 0), radius: 0.5, inside: true))
    }

    /// A version this reader does not model may shape the data differently, so the
    /// collider keeps the fallback, as a reader without the extension would.
    @Test
    func testAnExtendedColliderOfAnotherVersionKeepsTheFallback() throws {
        let collider = try Self.collider(extension: #"{"specVersion": "2.0", "shape": {"plane": {"normal": [0, 1, 0]}}}"#)

        #expect(try SpringBoneColliderShape(vrm1Collider: collider) == .sphere(offset: SIMD3(0, -10000, 0), radius: 0))
    }

    @Test(arguments: [#"{"specVersion": "1.0", "shape": {}}"#,
                      #"{"specVersion": "1.0", "shape": {"sphere": {}, "plane": {}}}"#])
    func testAnExtendedShapeIsExactlyOneShape(json: String) throws {
        let collider = try Self.collider(extension: json)

        #expect(throws: (any Error).self) { try SpringBoneColliderShape(vrm1Collider: collider) }
    }

    @Test
    func testLimitsAreReadAndClampedToTheRangesTheSpecStates() throws {
        let cone = try Self.limit(#"{"specVersion": "1.0", "limit": {"cone": {"angle": 4}}}"#)
        let spherical = try Self.limit(#"{"specVersion": "1.0", "limit": {"spherical": {"pitch": 0.5, "yaw": 3}}}"#)

        #expect(cone == SpringBoneLimit(shape: .cone(angle: .pi)))
        #expect(spherical == SpringBoneLimit(shape: .spherical(pitch: 0.5, yaw: .pi / 2)))
    }

    @Test(arguments: [#"{"specVersion": "1.0", "limit": {"cone": {"angle": -1}}}"#,
                      #"{"specVersion": "1.0", "limit": {"cone": {"angle": 1}, "hinge": {"angle": 1}}}"#,
                      #"{"specVersion": "1.0", "limit": {"cone": {"angle": 1, "rotation": [0, 0, 0, 0]}}}"#])
    func testALimitOutsideTheSpecIsRefused(json: String) throws {
        #expect(throws: (any Error).self) { try Self.limit(json) }
    }

    /// UniVRM writes the limit without a specVersion, and those files are read as 1.0.
    @Test
    func testALimitWithoutASpecVersionIsReadAsTheFirstVersion() throws {
        #expect(try Self.limit(#"{"limit": {"hinge": {"angle": 1}}}"#) == SpringBoneLimit(shape: .hinge(angle: 1)))
    }

    @Test
    func testALimitOfAnotherVersionIsIgnored() throws {
        #expect(try Self.limit(#"{"specVersion": "2.0", "limit": {"cone": {"angle": 1}}}"#) == nil)
    }

    // MARK: - Colliding

    /// A plane through the head keeps a tail that gravity pulls down level with it.
    @Test
    func testAPlaneKeepsTheTailOnTheSideItsNormalPointsTo() throws {
        let plane = SpringBoneColliderShape.plane(offset: .zero, normal: SIMD3(0, 1, 0)).world(in: matrix_identity_float4x4)

        let tail = try Self.swing(colliders: [plane])

        #expect(tail.y > -1e-3, "tail: \(tail)")
    }

    /// The plane's normal turns with the node it hangs off.
    @Test
    func testAPlaneNormalTurnsWithItsNode() {
        let rotated = simd_float4x4(simd_quatf(angle: .pi / 2, axis: SIMD3(0, 0, 1)))

        let plane = SpringBoneColliderShape.plane(offset: .zero, normal: SIMD3(0, 1, 0)).world(in: rotated)

        guard case .plane(let normal) = plane.kind else { Issue.record("not a plane"); return }
        #expect(simd_distance(normal, SIMD3(-1, 0, 0)) < 1e-5)
    }

    /// An inside sphere keeps the tail in, where gravity would pull it a whole bone length down.
    @Test
    func testAnInsideSphereKeepsTheTailIn() throws {
        let center = SIMD3<Float>(0, 0, 1)
        let sphere = SpringBoneColliderShape.sphere(offset: center, radius: 0.3, inside: true).world(in: matrix_identity_float4x4)

        let tail = try Self.swing(colliders: [sphere])

        // Holding the bone at its length after the push moves the tail a hair back out,
        // as in the reference implementation.
        #expect(simd_distance(tail, center) < 0.3 + 0.01, "tail: \(tail)")
    }

    @Test
    func testAnInsideCapsuleKeepsTheTailIn() throws {
        let capsule = SpringBoneColliderShape.capsule(offset: SIMD3(-1, 0, 1), tail: SIMD3(1, 0, 1), radius: 0.3, inside: true)
            .world(in: matrix_identity_float4x4)

        let tail = try Self.swing(colliders: [capsule])

        #expect(abs(tail.y) < 0.3 + 0.01 && abs(tail.z - 1) < 0.3 + 0.01, "tail: \(tail)")
    }

    // MARK: - Limiting

    /// A cone keeps the tail within its angle of the rest direction, which gravity pulls it far past.
    @Test
    func testAConeKeepsTheTailWithinItsAngle() throws {
        let tail = try Self.swing(limit: SpringBoneLimit(shape: .cone(angle: .pi / 6)))

        let angle = acos(min(1, simd_dot(simd_normalize(tail), SIMD3(0, 0, 1))))
        #expect(angle < .pi / 6 + 1e-3, "angle: \(angle)")
        #expect(angle > .pi / 6 - 1e-2, "gravity still swings it to the edge")
    }

    /// A hinge lets the tail swing only about the hinge's x-axis, which for a bone pointing
    /// along +z is the world x-axis: a sideways pull moves it nowhere.
    @Test
    func testAHingeKeepsTheTailOnItsPlane() throws {
        let tail = try Self.swing(gravity: SIMD3(1, -1, 0), limit: SpringBoneLimit(shape: .hinge(angle: .pi)))

        #expect(abs(tail.x) < 1e-3, "tail: \(tail)")
        #expect(tail.y < -0.5, "the downward pull still swings it")
    }

    /// The spec's reference values: pitch about x and yaw about z, each held to its limit.
    @Test
    func testASphericalLimitHoldsPitchAndYaw() {
        let limit = SpringBoneLimit(shape: .spherical(pitch: .pi / 4, yaw: .pi / 6))

        let pitched = limit.constrained(SIMD3(0, 0, 1))
        let yawed = limit.constrained(SIMD3(1, 0, 0))

        #expect(simd_distance(pitched, SIMD3(0, cos(.pi / 4), sin(.pi / 4))) < 1e-5)
        #expect(simd_distance(yawed, SIMD3(sin(.pi / 6), cos(.pi / 6), 0)) < 1e-5)
    }

    /// Directions the spec calls singular take the side it names.
    @Test
    func testSingularDirectionsTakeTheSideTheSpecNames() {
        let down = SIMD3<Float>(0, -1, 0)
        let cone = SpringBoneLimit(shape: .cone(angle: .pi / 4)).constrained(down)
        let hinge = SpringBoneLimit(shape: .hinge(angle: .pi / 4)).constrained(SIMD3(1, 0, 0))

        #expect(cone.z > 0 && abs(cone.x) < 1e-6)
        #expect(hinge == SIMD3(0, 1, 0))
    }

    // MARK: - Helpers

    private static func collider(extension json: String) throws -> VRM1.SpringBone.Collider {
        let collider = #"{"node": 0, "shape": {"sphere": {"offset": [0, -10000, 0], "radius": 0}}, "#
            + #""extensions": {"VRMC_springBone_extended_collider": "# + json + "}}"
        return try JSONDecoder().decode(VRM1.SpringBone.Collider.self, from: Data(collider.utf8))
    }

    private static func limit(_ json: String) throws -> SpringBoneLimit? {
        let joint = try JSONDecoder().decode(VRM1.SpringBone.Spring.Joint.self,
                                             from: Data((#"{"node": 0, "extensions": {"VRMC_springBone_limit": "# + json + "}}").utf8))
        return try SpringBoneJointSetting(vrm1Joint: joint).limit
    }

    /// Where the tail of a bone of length 1 from the origin along +z settles under `gravity`.
    private static func swing(gravity: SIMD3<Float> = SIMD3(0, -1, 0),
                              limit: SpringBoneLimit? = nil,
                              colliders: [SpringBoneCollider] = []) throws -> SIMD3<Float> {
        var joint = try #require(SpringBoneJoint(head: .zero,
                                                 localTail: SIMD3(0, 0, 1),
                                                 worldTail: SIMD3(0, 0, 1),
                                                 initialLocalRotation: .identity,
                                                 center: nil))
        let setting = SpringBoneJointSetting(stiffnessForce: 0,
                                             gravityPower: simd_length(gravity) * 4,
                                             gravityDir: simd_normalize(gravity),
                                             dragForce: 0.5,
                                             hitRadius: 0,
                                             limit: limit)
        var rotation = simd_quatf.identity
        for _ in 0..<120 {
            rotation = joint.update(deltaTime: 1.0 / 60.0,
                                    setting: setting,
                                    head: .zero,
                                    parentRotation: .identity,
                                    center: nil,
                                    colliders: colliders)
        }
        return rotation.act(SIMD3(0, 0, 1))
    }
}
