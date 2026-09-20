#if canImport(RealityKit)
import CryptoKit
import Foundation
import RealityKit
import simd
import Testing
import VRMKit
import VRMRealityKit
import VRMTestSupport

/// Differential comparison of `AvatarSample_M.vrm` against a UniVRM v0.131.2 reference
/// captured on macOS ARM64 (see `scripts/capture-reference-output/README.md`).
///
/// Unity's captured coordinates and RealityKit's are not reconciled by an axis conversion here,
/// so this suite compares only quantities that do not depend on one: bone-to-bone distances
/// (invariant under any rigid or mirrored transform), and expression/constraint names, counts,
/// and scalar weights. Absolute positions, rotations, and spring-bone positions are out of scope
/// until a verified axis conversion is documented.
@Suite
@MainActor
struct VRM1DifferentialTests {
    private struct ReferenceOutput: Decodable {
        struct Fixture: Decodable { let sha256: String }
        struct Tolerances: Decodable { let translation: Double; let scalar: Double }
        struct Vector3: Decodable { let x: Double, y: Double, z: Double }
        struct Values: Decodable { let names: [String], scalars: [Double], positions: [Vector3] }
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

    // Unity's Mecanim thumb naming (proximal/intermediate/distal) differs from VRM 1.0's
    // (metacarpal/proximal/distal); every other bone name matches by capitalizing the first letter.
    private static let unityBoneNames: [HumanoidBone: String] = {
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

    private func decodeReference() throws -> ReferenceOutput {
        try JSONDecoder().decode(ReferenceOutput.self, from: ReferenceOutputAsset.univrmAvatarSampleM.data)
    }

    /// The reference is only meaningful if it was captured from the exact fixture bytes this
    /// test loads.
    @Test
    func testTheFixtureBytesMatchTheCapturedReference() throws {
        let reference = try decodeReference()
        let digest = SHA256.hash(data: VRMSampleAsset.avatarSampleM.data)
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        #expect(hex == reference.fixture.sha256)
    }

    @Test
    func testHumanoidBoneToBoneDistancesMatchTheReference() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let reference = try decodeReference()
        let entity = try await VRMEntityLoader(withData: VRMSampleAsset.avatarSampleM.data, shaders: []).loadEntity()
        let hips = try #require(entity.humanoid.node(for: .hips))

        let unityPositions = Dictionary(uniqueKeysWithValues:
            zip(reference.samples.bones[0].values.names, reference.samples.bones[0].values.positions))
        let unityHips = try #require(unityPositions["Hips"])

        for bone in [HumanoidBone.head, .leftHand, .rightHand, .leftFoot, .rightFoot, .leftLowerArm] {
            guard let node = entity.humanoid.node(for: bone),
                  let unityName = Self.unityBoneNames[bone],
                  let unityPosition = unityPositions[unityName] else {
                Issue.record("missing bone \(bone) on one side of the comparison")
                continue
            }

            let vrmKitDistance = simd_distance(node.position(relativeTo: entity), hips.position(relativeTo: entity))
            let dx = unityPosition.x - unityHips.x
            let dy = unityPosition.y - unityHips.y
            let dz = unityPosition.z - unityHips.z
            let unityDistance = Float((dx * dx + dy * dy + dz * dz).squareRoot())

            #expect(abs(vrmKitDistance - unityDistance) < Float(reference.tolerances.translation),
                     "\(bone) sits a different distance from the hips than UniVRM measured")
        }
    }

    /// UniVRM enumerates all 18 standard VRM 1.0 expression presets regardless of whether the
    /// model authors a clip for them; VRMKit only reports presets the model actually binds. This
    /// fixture authors no look-expression clips (it drives look-at through eye bones instead), so
    /// UniVRM's four look presets are an expected, documented gap rather than a missing feature.
    private static let presetsUniVRMListsWithoutAnAuthoredClip: Set<String> =
        ["lookUp", "lookDown", "lookLeft", "lookRight"]

    @Test
    func testExpressionNamesAndRestWeightsMatchTheReference() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let reference = try decodeReference()
        let entity = try await VRMEntityLoader(withData: VRMSampleAsset.avatarSampleM.data, shaders: []).loadEntity()

        let referenceNames = Set(reference.samples.expressions[0].values.names)
        let vrmKitNames = Set(entity.availableExpressions.compactMap { $0.key.preset?.rawValue })
        #expect(vrmKitNames == referenceNames.subtracting(Self.presetsUniVRMListsWithoutAnAuthoredClip))

        for (name, weight) in zip(reference.samples.expressions[0].values.names,
                                   reference.samples.expressions[0].values.scalars) {
            guard vrmKitNames.contains(name), let preset = ExpressionPreset(name: name) else { continue }
            let actual = Double(entity.expression(for: .preset(preset)))
            #expect(abs(actual - weight) < reference.tolerances.scalar, "\(name) rest weight differs")
        }
    }

    @Test
    func testNodeConstraintCountMatchesTheReference() throws {
        let reference = try decodeReference()
        let vrm = try VRM1(data: VRMSampleAsset.avatarSampleM.data)
        let constrainedNodeCount = vrm.document.gltf.nodes.filter { $0.extensions?.nodeConstraint != nil }.count
        #expect(constrainedNodeCount == reference.samples.constraints[0].values.names.count)
    }
}
#endif
