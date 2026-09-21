#if canImport(RealityKit)
import CryptoKit
import Foundation
import RealityKit
import simd
import Testing
import VRMKit
import VRMRealityKit
import VRMTestSupport

/// Differential comparison of `AvatarSample_M.vrm` against UniVRM v0.131.2 and three-vrm v3.5.5
/// references captured on macOS ARM64 (see `scripts/capture-reference-output/README.md`).
///
/// Neither reference's captured coordinates are reconciled with RealityKit's by an axis
/// conversion here, so this suite compares only quantities that do not depend on one:
/// bone-to-bone distances (invariant under any rigid or mirrored transform), and expression/
/// constraint names, counts, and scalar weights. Absolute positions, rotations, and spring-bone
/// positions are out of scope until a verified axis conversion is documented.
@Suite
@MainActor
struct VRM1DifferentialTests {
    private struct ReferenceOutput: Decodable {
        struct Fixture: Decodable { let sha256: String }
        struct Tolerances: Decodable {
            let translation: Double
            let rotation: Double
            let scalar: Double
        }
        struct Vector3: Decodable { let x: Double, y: Double, z: Double }
        struct Quaternion: Decodable { let x: Double, y: Double, z: Double, w: Double }
        struct Values: Decodable {
            let names: [String]
            let scalars: [Double]
            let positions: [Vector3]
            let rotations: [Quaternion]
        }
        struct Sample: Decodable { let values: Values }
        struct Samples: Decodable {
            let bones: [Sample]
            let expressions: [Sample]
            let constraints: [Sample]
        }
        let fixture: Fixture
        let tolerances: Tolerances
        let samples: Samples
    }

    /// One reference implementation's naming convention and the expression presets it lists
    /// without an authored clip, so the same checks run against every reference.
    struct ReferenceCase: CustomStringConvertible, Sendable {
        let asset: ReferenceOutputAsset
        let description: String
        let boneName: @Sendable (HumanoidBone) -> String?
        let presetsListedWithoutAnAuthoredClip: Set<String>
    }

    // Unity's Mecanim thumb naming (proximal/intermediate/distal) differs from VRM 1.0's
    // (metacarpal/proximal/distal); every other bone name matches by capitalizing the first letter.
    private static nonisolated let unityBoneNames: [HumanoidBone: String] = {
        var names = [HumanoidBone: String](minimumCapacity: HumanoidBone.allCases.count)
        for bone in HumanoidBone.allCases {
            names[bone] = bone.rawValue.prefix(1).uppercased() + bone.rawValue.dropFirst()
        }
        names[.leftThumbMetacarpal] = "LeftThumbProximal"
        names[.leftThumbProximal] = "LeftThumbIntermediate"
        names[.rightThumbMetacarpal] = "RightThumbProximal"
        names[.rightThumbProximal] = "RightThumbIntermediate"
        return names
    }()

    static nonisolated let referenceCases: [ReferenceCase] = [
        ReferenceCase(
            asset: .univrmAvatarSampleM,
            description: "UniVRM",
            boneName: { unityBoneNames[$0] },
            // UniVRM enumerates all 18 standard VRM 1.0 expression presets regardless of whether
            // the model authors a clip; this fixture authors no look-expression clips (it drives
            // look-at through eye bones instead).
            presetsListedWithoutAnAuthoredClip: ["lookUp", "lookDown", "lookLeft", "lookRight"]
        ),
        ReferenceCase(
            asset: .threeVrmAvatarSampleM,
            description: "three-vrm",
            // three-vrm's VRMHumanBoneName values match VRMKit's HumanoidBone raw values directly.
            boneName: { $0.rawValue },
            presetsListedWithoutAnAuthoredClip: []
        )
    ]

    private func decodeReference(_ referenceCase: ReferenceCase) throws -> ReferenceOutput {
        try JSONDecoder().decode(ReferenceOutput.self, from: referenceCase.asset.data)
    }

    /// Each reference is only meaningful if it was captured from the exact fixture bytes this
    /// test loads.
    @Test(arguments: referenceCases)
    func testTheFixtureBytesMatchTheCapturedReference(referenceCase: ReferenceCase) throws {
        let reference = try decodeReference(referenceCase)
        let digest = SHA256.hash(data: VRMSampleAsset.avatarSampleM.data)
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        #expect(hex == reference.fixture.sha256, "\(referenceCase.description) fixture checksum differs")
    }

    @Test(arguments: referenceCases)
    func testHumanoidBoneToBoneDistancesMatchTheReference(referenceCase: ReferenceCase) async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let reference = try decodeReference(referenceCase)
        let entity = try await VRMEntityLoader(withData: VRMSampleAsset.avatarSampleM.data, shaders: []).loadEntity()
        let hips = try #require(entity.humanoid.node(for: .hips))

        let referencePositions = Dictionary(uniqueKeysWithValues:
            zip(reference.samples.bones[0].values.names, reference.samples.bones[0].values.positions))
        let referenceHips = try #require(referencePositions["Hips"] ?? referencePositions["hips"])

        for bone in [HumanoidBone.head, .leftHand, .rightHand, .leftFoot, .rightFoot, .leftLowerArm] {
            guard let node = entity.humanoid.node(for: bone),
                  let referenceName = referenceCase.boneName(bone),
                  let referencePosition = referencePositions[referenceName] else {
                Issue.record("missing bone \(bone) on one side of the \(referenceCase.description) comparison")
                continue
            }

            let vrmKitDistance = simd_distance(node.position(relativeTo: entity), hips.position(relativeTo: entity))
            let dx = referencePosition.x - referenceHips.x
            let dy = referencePosition.y - referenceHips.y
            let dz = referencePosition.z - referenceHips.z
            let referenceDistance = Float((dx * dx + dy * dy + dz * dz).squareRoot())

            #expect(abs(vrmKitDistance - referenceDistance) < Float(reference.tolerances.translation),
                     "\(bone) sits a different distance from the hips than \(referenceCase.description) measured")
        }
    }

    @Test(arguments: referenceCases)
    func testSampledHumanoidRotationsMatchTheReference(referenceCase: ReferenceCase) async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let reference = try decodeReference(referenceCase)
        let entity = try await VRMEntityLoader(withData: VRMSampleAsset.avatarSampleM.data, shaders: []).loadEntity()
        let values = reference.samples.bones[0].values
        let referenceRotations = Dictionary(uniqueKeysWithValues:
            zip(values.names, values.rotations))

        for bone in [HumanoidBone.hips, .head, .leftHand, .rightHand, .leftFoot, .rightFoot] {
            guard let node = entity.humanoid.node(for: bone),
                  let referenceName = referenceCase.boneName(bone),
                  let expected = referenceRotations[referenceName] else {
                Issue.record("missing rotation for \(bone) in \(referenceCase.description) reference")
                continue
            }

            let actual = Transform(matrix: node.transformMatrix(relativeTo: entity)).rotation
            let expectedQuaternion = simd_quatf(ix: Float(expected.x),
                                                 iy: Float(expected.y),
                                                 iz: Float(expected.z),
                                                 r: Float(expected.w))
            #expect(abs(simd_dot(actual, expectedQuaternion))
                    > 1 - Float(reference.tolerances.rotation),
                    "\(bone) rotation differs from \(referenceCase.description)")
        }
    }

    @Test(arguments: referenceCases)
    func testExpressionNamesAndRestWeightsMatchTheReference(referenceCase: ReferenceCase) async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let reference = try decodeReference(referenceCase)
        let entity = try await VRMEntityLoader(withData: VRMSampleAsset.avatarSampleM.data, shaders: []).loadEntity()

        let referenceNames = Set(reference.samples.expressions[0].values.names)
        let vrmKitNames = Set(entity.availableExpressions.compactMap { $0.key.preset?.rawValue })
        #expect(vrmKitNames == referenceNames.subtracting(referenceCase.presetsListedWithoutAnAuthoredClip),
                 "\(referenceCase.description) expression names differ")

        for (name, weight) in zip(reference.samples.expressions[0].values.names,
                                   reference.samples.expressions[0].values.scalars) {
            guard vrmKitNames.contains(name), let preset = ExpressionPreset(name: name) else { continue }
            let actual = Double(entity.expression(for: .preset(preset)))
            #expect(abs(actual - weight) < reference.tolerances.scalar,
                     "\(name) rest weight differs from \(referenceCase.description)")
        }
    }

    @Test(arguments: referenceCases)
    func testNodeConstraintCountMatchesTheReference(referenceCase: ReferenceCase) throws {
        let reference = try decodeReference(referenceCase)
        let vrm = try VRM1(data: VRMSampleAsset.avatarSampleM.data)
        let constrainedNodeCount = vrm.document.gltf.nodes.filter { $0.extensions?.nodeConstraint != nil }.count
        #expect(constrainedNodeCount == reference.samples.constraints[0].values.names.count,
                 "\(referenceCase.description) constraint count differs")
    }
}
#endif

