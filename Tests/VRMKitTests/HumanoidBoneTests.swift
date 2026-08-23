import Testing
@testable import VRMKit
import VRMTestSupport

/// ``HumanoidBone`` names one joint one way, so that resolving a bone means the
/// same anatomy whichever version the model is. Only the thumb needs the two
/// spellings reconciled: VRM 0.x counts its joints proximal / intermediate /
/// distal where VRM 1.0 counts the same three metacarpal / proximal / distal.
@Suite
struct HumanoidBoneTests {
    @Test
    func testTheVRM0ThumbNamesReadAsTheJointsTheyAre() {
        #expect(HumanoidBone(vrm0Name: "leftThumbProximal") == .leftThumbMetacarpal)
        #expect(HumanoidBone(vrm0Name: "leftThumbIntermediate") == .leftThumbProximal)
        #expect(HumanoidBone(vrm0Name: "leftThumbDistal") == .leftThumbDistal)
        #expect(HumanoidBone(vrm0Name: "rightThumbProximal") == .rightThumbMetacarpal)
        #expect(HumanoidBone(vrm0Name: "rightThumbIntermediate") == .rightThumbProximal)
        // A VRM 1.0 spelling is not one VRM 0.x writes.
        #expect(HumanoidBone(vrm0Name: "leftThumbMetacarpal") == nil)
        #expect(HumanoidBone(vrm0Name: "notABone") == nil)
    }

    @Test
    func testEveryBoneRoundTripsThroughItsVRM0Name() {
        for bone in HumanoidBone.allCases {
            #expect(HumanoidBone(vrm0Name: bone.vrm0Name) == bone)
        }
    }

    /// The thumb chain of a VRM 0.x model resolves in order, and to the bones
    /// VRM 1.0 would have named, not to the ones 0.x spelled.
    @Test
    func testAVRM0ModelResolvesItsThumbAsVRM10NamesIt() throws {
        let vrm = try VRM(data: VRMSampleAsset.aliciaSolid.data)
        let humanBones = try #require({ if case .v0(let vrm0) = vrm { vrm0.humanoid.humanBones } else { nil } }())

        for (name, bone) in [("leftThumbProximal", HumanoidBone.leftThumbMetacarpal),
                             ("leftThumbIntermediate", .leftThumbProximal),
                             ("leftThumbDistal", .leftThumbDistal)] {
            #expect(vrm.nodeIndex(of: bone) == humanBones.first { $0.bone == name }?.node, "\(name)")
        }
    }

    /// Both versions read as one mapping.
    @Test
    func testBothVersionsReadAsTheSameKindOfRig() throws {
        for asset in [VRMSampleAsset.aliciaSolid, .seedSan] {
            let nodes = try VRM(data: asset.data).boneNodes
            #expect(nodes[.hips] != nil, "\(asset.rawValue)")
            #expect(nodes[.head] != nil, "\(asset.rawValue)")
            #expect(nodes[.leftHand] != nil, "\(asset.rawValue)")
            // A rig names each bone once, so no two share a node.
            #expect(Set(nodes.values).count == nodes.count, "\(asset.rawValue)")
        }
    }

    /// VRM 1.0 requires fifteen bones of every humanoid.
    @Test
    func testAVRM1RigMissingARequiredBoneIsRejected() throws {
        let missingHips = try VRMSampleAsset.seedSan.rewritingJSON { json in
            json.withObject("extensions") { extensions in
                extensions.withObject(GLTFExtension.vrm1.rawValue) { vrm in
                    vrm.withObject("humanoid") { humanoid in
                        humanoid.withObject("humanBones") { $0.removeValue(forKey: "hips") }
                    }
                }
            }
        }

        #expect(throws: VRMError.self) { try VRM1(data: missingHips) }
    }

    /// A property VRM does not define is not a reason to fail the parse.
    @Test
    func testAnUnknownBoneNameIsIgnored() throws {
        let extraBone = try VRMSampleAsset.seedSan.rewritingJSON { json in
            json.withObject("extensions") { extensions in
                extensions.withObject(GLTFExtension.vrm1.rawValue) { vrm in
                    vrm.withObject("humanoid") { humanoid in
                        humanoid.withObject("humanBones") { $0["tail"] = ["node": 0] }
                    }
                }
            }
        }

        let vrm1 = try VRM1(data: extraBone)
        #expect(vrm1.humanoid.humanBones[.hips] != nil)
    }

    /// The same three bones of a VRM 1.0 model, read straight off the rig.
    @Test
    func testAVRM1ModelResolvesItsThumbFromItsOwnProperties() throws {
        let vrm1 = try VRM1(data: VRMSampleAsset.seedSan.data)

        #expect(vrm1.nodeIndex(of: .leftThumbMetacarpal) == vrm1.humanoid.humanBones[.leftThumbMetacarpal]?.node)
        #expect(vrm1.nodeIndex(of: .leftThumbProximal) == vrm1.humanoid.humanBones[.leftThumbProximal]?.node)
        #expect(vrm1.nodeIndex(of: .leftThumbDistal) == vrm1.humanoid.humanBones[.leftThumbDistal]?.node)
    }
}
