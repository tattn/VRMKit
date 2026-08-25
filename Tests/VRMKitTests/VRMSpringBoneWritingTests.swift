import Foundation
import Testing
import simd
import VRMTestSupport
@testable import VRMKit

/// Giving a merged prop its swing. The two VRM versions describe one at
/// different grains, so each is written through its own entry point and read
/// back through the typed model the runtime is built on.
@Suite
struct VRMSpringBoneWritingTests {
    // MARK: - Round trip

    /// VRM 1.0 states the parameters per joint. The values are ones a `Float`
    /// holds exactly, since they are read back as the `Double` the JSON carries.
    @Test
    func testAVRM1SpringIsWrittenWithItsJoints() throws {
        let document = try GLTFEditableDocument(data: VRMSampleAsset.seedSan.data)
        let ornament = try document.addOrnamentChain(under: VRMSampleAsset.seedSan.headNode)
        let spring = VRM1Spring(joints: ornament,
                                stiffness: 0.75,
                                gravityPower: 0.25,
                                gravityDirection: SIMD3(0, -1, 0),
                                dragForce: 0.375,
                                hitRadius: 0.03125,
                                name: "charm",
                                center: ornament[0],
                                colliderGroups: [0])

        let index = try document.addVRM1SpringBone(spring)

        let written = try #require(try vrm1(of: document).springBone?.springs?[index])
        #expect(written.name == "charm")
        #expect(written.center == ornament[0])
        #expect(written.colliderGroups == [0])
        #expect(written.joints.map(\.node) == ornament)
        for joint in written.joints.dropLast() {
            #expect(joint.stiffness == 0.75)
            #expect(joint.gravityPower == 0.25)
            #expect(joint.gravityDir == [0, -1, 0])
            #expect(joint.dragForce == 0.375)
            #expect(joint.hitRadius == 0.03125)
        }
    }

    /// A chain may stiffen towards its root, which is what states the
    /// parameters per joint rather than per spring.
    @Test
    func testAVRM1SpringCanGiveEachJointItsOwnSettings() throws {
        let document = try GLTFEditableDocument(data: VRMSampleAsset.seedSan.data)
        let ornament = try document.addOrnamentChain(under: VRMSampleAsset.seedSan.headNode)

        let index = try document.addVRM1SpringBone(VRM1Spring(joints: [
            VRM1SpringJoint(node: ornament[0], stiffness: 1),
            VRM1SpringJoint(node: ornament[1], stiffness: 0.25),
            VRM1SpringJoint(node: ornament[2])
        ]))

        let spring = try #require(try vrm1(of: document).springBone?.springs?[index])
        #expect(spring.joints.map(\.stiffness) == [1, 0.25, nil])
    }

    /// The last joint is a tail to swing towards rather than one that swings,
    /// so nothing is written for it, and a joint at the default states nothing
    /// either: reading fills both in.
    @Test
    func testAVRM1SpringWritesNoParameterItDoesNotNeedTo() throws {
        let document = try GLTFEditableDocument(data: VRMSampleAsset.seedSan.data)
        let ornament = try document.addOrnamentChain(under: VRMSampleAsset.seedSan.headNode)

        let index = try document.addVRM1SpringBone(VRM1Spring(joints: ornament, stiffness: 0.5))

        let joints = try #require(springBoneJSON(of: document)[safe: index]).objects("joints")
        #expect(joints.map { Set($0.keys) } == [["node", "stiffness"], ["node", "stiffness"], ["node"]])
    }

    /// VRM 0.x names the nodes a swing starts at and swings what hangs below
    /// them, so a group may name several roots and swings their side branches.
    @Test
    func testAVRM0BoneGroupIsWrittenWithItsRootBones() throws {
        let document = try GLTFEditableDocument(data: VRMSampleAsset.aliciaSolid.data)
        let head = try VRMSampleAsset.aliciaSolid.headNode
        let left = try document.addOrnamentChain(under: head)
        let right = try document.addOrnamentChain(under: head)
        let group = VRM0SpringBoneGroup(rootBones: [left[0], right[0]],
                                        stiffness: 0.75,
                                        gravityPower: 0.25,
                                        gravityDirection: SIMD3(1, 0, 0),
                                        dragForce: 0.375,
                                        hitRadius: 0.03125,
                                        colliderGroups: [1],
                                        comment: "charm")

        let index = try document.addVRM0SpringBone(group)

        let written = try #require(try vrm0(of: document).secondaryAnimation.boneGroups[safe: index])
        #expect(written.bones == [left[0], right[0]])
        #expect(written.comment == "charm")
        #expect(written.colliderGroups == [1])
        #expect(written.stiffiness == 0.75)
        #expect(written.gravityPower == 0.25)
        #expect([written.gravityDir.x, written.gravityDir.y, written.gravityDir.z] == [1, 0, 0])
        #expect(written.dragForce == 0.375)
        #expect(written.hitRadius == 0.03125)
        // 0.x always writes a center, and -1 is how it says there is none.
        #expect(written.center == -1)
    }

    /// A spring of one joint is one the extension accepts: the last joint is a
    /// tail rather than one that swings, so such a spring swings nothing.
    @Test
    func testAVRM1SpringOfOneJointIsWritten() throws {
        let document = try GLTFEditableDocument(data: VRMSampleAsset.seedSan.data)
        let ornament = try document.addOrnamentChain(under: VRMSampleAsset.seedSan.headNode)

        let index = try document.addVRM1SpringBone(VRM1Spring(joints: [ornament[0]]))

        let spring = try #require(try vrm1(of: document).springBone?.springs?[safe: index])
        #expect(spring.joints.map(\.node) == [ornament[0]])
    }

    /// `VRMC_springBone` asks a joint to be below the one before it, not its
    /// immediate child, so a spring may skip over the nodes between them.
    @Test
    func testAVRM1SpringMaySkipNodesInTheLineItRunsDown() throws {
        let document = try GLTFEditableDocument(data: VRMSampleAsset.seedSan.data)
        let ornament = try document.addOrnamentChain(under: VRMSampleAsset.seedSan.headNode)

        let index = try document.addVRM1SpringBone(VRM1Spring(joints: [ornament[0], ornament[2]]))

        let spring = try #require(try vrm1(of: document).springBone?.springs?[safe: index])
        #expect(spring.joints.map(\.node) == [ornament[0], ornament[2]])
    }

    /// Adding a spring is adding: what the model already swung swings as it did,
    /// through the same nodes and colliders.
    @Test(arguments: [VRMSampleAsset.aliciaSolid, .seedSan])
    func testAddingASpringLeavesTheModelsOwnSpringsAlone(asset: VRMSampleAsset) throws {
        let document = try GLTFEditableDocument(data: asset.data)
        let before = springBoneJSON(of: document)
        let ornament = try document.addOrnamentChain(under: asset.headNode)

        let index = try document.addSpringBone(over: ornament, of: asset)

        let after = springBoneJSON(of: document)
        #expect(index == before.count)
        #expect(after.count == before.count + 1)
        #expect(jsonDifference(before, Array(after.prefix(before.count))) == nil)
    }

    /// A model that swings nothing yet is given what holds the spring: the
    /// declared `VRMC_springBone` of a 1.0 model, the `secondaryAnimation` a
    /// 0.x model is read through.
    @Test(arguments: [VRMSampleAsset.aliciaSolid, .seedSan])
    func testAModelThatSwingsNothingYetIsGivenWhatHoldsASpring(asset: VRMSampleAsset) throws {
        let stripped = try asset.rewritingJSON { json in
            var extensions = json["extensions"] as? [String: Any] ?? [:]
            extensions.removeValue(forKey: "VRMC_springBone")
            if var vrm0 = extensions["VRM"] as? [String: Any] {
                vrm0.removeValue(forKey: "secondaryAnimation")
                extensions["VRM"] = vrm0
            }
            json["extensions"] = extensions
            json["extensionsUsed"] = (json["extensionsUsed"] as? [String] ?? [])
                .filter { $0 != "VRMC_springBone" }
        }
        let document = try GLTFEditableDocument(data: stripped)
        let ornament = try document.addOrnamentChain(under: asset.headNode)

        try document.addSpringBone(over: ornament, of: asset, name: "charm")

        switch try VRM(data: try document.serialize()) {
        case .v0(let vrm0):
            #expect(vrm0.secondaryAnimation.colliderGroups.isEmpty)
            #expect(vrm0.secondaryAnimation.boneGroups.map(\.bones) == [[ornament[0]]])
        case .v1(let vrm1):
            let springBone = try #require(vrm1.springBone)
            #expect(springBone.specVersion == "1.0")
            #expect(springBone.springs?.map { $0.joints.map(\.node) } == [ornament])
            #expect(try document.typed().extensionsUsed?.contains("VRMC_springBone") == true)
        }
    }

    /// The spring survives pruning, which remaps every index it holds.
    @Test
    func testAnAddedSpringSurvivesPruning() throws {
        let document = try GLTFEditableDocument(data: VRMSampleAsset.seedSan.data)
        let ornament = try document.addOrnamentChain(under: VRMSampleAsset.seedSan.headNode)
        let index = try document.addVRM1SpringBone(VRM1Spring(joints: ornament, name: "charm"))
        let names = try #require(try vrm1(of: document).springBone?.springs).map(\.name)

        try document.prune()

        let springs = try #require(try vrm1(of: document).springBone?.springs)
        #expect(springs.map(\.name) == names)
        // The nodes moved, and the spring moved with them.
        let joints = try #require(springs[safe: index]).joints.map(\.node)
        let nodes = try #require(try document.typed().nodes)
        #expect(joints.allSatisfy { nodes.indices.contains($0) })
        #expect(nodes[joints[0]].children?.contains(joints[1]) == true)
    }

    // MARK: - Parameters a document cannot swing by

    @Test(arguments: [VRMSampleAsset.aliciaSolid, .seedSan])
    func testParametersOutsideWhatTheFormatsAcceptAreRefused(asset: VRMSampleAsset) throws {
        let document = try GLTFEditableDocument(data: asset.data)
        let ornament = try document.addOrnamentChain(under: asset.headNode)
        let nodeCount = try document.typed().nodes?.count ?? 0
        let before = try document.serialize()

        let refused: [(VRM1Spring) -> VRM1Spring] = [
            { var spring = $0; spring.center = nodeCount; return spring },
            { var spring = $0; spring.colliderGroups = [99]; return spring },
            { var spring = $0; spring.joints[0].stiffness = -1; return spring },
            { var spring = $0; spring.joints[0].gravityPower = .nan; return spring },
            { var spring = $0; spring.joints[0].gravityDirection = SIMD3(.infinity, 0, 0); return spring },
            { var spring = $0; spring.joints[0].dragForce = 1.1; return spring },
            { var spring = $0; spring.joints[0].hitRadius = -1; return spring }
        ]
        for change in refused {
            let spring = change(VRM1Spring(joints: ornament))
            #expect(throws: VRMError.self) { try document.addSpringBone(spring, of: asset) }
        }

        #expect(try document.serialize() == before)
    }

    // MARK: - What `VRMC_springBone` says a chain is

    /// A VRM 1.0 spring names a line the hierarchy runs down, and needs a node
    /// past the last joint to swing it towards.
    @Test
    func testAVRM1SpringOverNodesThatAreNotALineIsRefused() throws {
        let document = try GLTFEditableDocument(data: VRMSampleAsset.seedSan.data)
        let head = try VRMSampleAsset.seedSan.headNode
        let ornament = try document.addOrnamentChain(under: head)
        let sibling = try document.addOrnamentChain(under: head)
        let nodeCount = try document.typed().nodes?.count ?? 0
        let before = try document.serialize()

        let refused = [
            [Int](),
            [ornament[0], nodeCount],
            [ornament[0], -1],
            // Two lines off the same parent: neither is below the other.
            [ornament[0], sibling[1]],
            // The line read upwards, which is not the way a spring runs.
            [ornament[2], ornament[0]],
            // One node twice, which is a chain sharing a joint with itself.
            [ornament[0], ornament[0]]
        ]
        for joints in refused {
            #expect(throws: VRMError.self) { try document.addVRM1SpringBone(VRM1Spring(joints: joints)) }
        }

        #expect(try document.serialize() == before)
    }

    /// One node belongs to one spring. A node the spring skips over is part of
    /// its chain all the same, so it is spoken for too.
    @Test
    func testASpringOverNodesAnotherSpringAlreadySwingsIsRefused() throws {
        let document = try GLTFEditableDocument(data: VRMSampleAsset.seedSan.data)
        let ornament = try document.addOrnamentChain(under: VRMSampleAsset.seedSan.headNode)
        let tail = try document.addOrnamentChain(under: ornament[2])

        // a-(b)-c, which spans all three even though it names two.
        try document.addVRM1SpringBone(VRM1Spring(joints: [ornament[0], ornament[2]]))
        let before = try document.serialize()

        // The joint it names outright.
        #expect(throws: VRMError.self) {
            try document.addVRM1SpringBone(VRM1Spring(joints: [ornament[2], tail[0]]))
        }
        // The joint it only skipped over.
        #expect(throws: VRMError.self) {
            try document.addVRM1SpringBone(VRM1Spring(joints: [ornament[1], tail[0]]))
        }

        #expect(try document.serialize() == before)
        // A line below what it swings is free, and is taken.
        try document.addVRM1SpringBone(VRM1Spring(joints: tail))
    }

    /// A swing is measured against something it hangs off, so the center is the
    /// first joint or one of its ancestors, and neither it nor anything it
    /// hangs off is swung by another spring.
    @Test
    func testACenterThatIsNotAnUnswungAncestorIsRefused() throws {
        let document = try GLTFEditableDocument(data: VRMSampleAsset.seedSan.data)
        let head = try VRMSampleAsset.seedSan.headNode
        let ornament = try document.addOrnamentChain(under: head)
        let below = try document.addOrnamentChain(under: ornament[2])
        let free = try document.addOrnamentChain(under: head)
        try document.addVRM1SpringBone(VRM1Spring(joints: ornament))
        let before = try document.serialize()

        // Neither the first joint nor above it.
        #expect(throws: VRMError.self) {
            try document.addVRM1SpringBone(VRM1Spring(joints: free, center: ornament[0]))
        }
        // Below the first joint rather than above it.
        #expect(throws: VRMError.self) {
            try document.addVRM1SpringBone(VRM1Spring(joints: free, center: free[1]))
        }
        // An ancestor, but one the spring above already swings.
        #expect(throws: VRMError.self) {
            try document.addVRM1SpringBone(VRM1Spring(joints: below, center: ornament[1]))
        }
        // The first joint of a chain that itself hangs off a swung node.
        #expect(throws: VRMError.self) {
            try document.addVRM1SpringBone(VRM1Spring(joints: below, center: below[0]))
        }
        #expect(try document.serialize() == before)

        // The first joint itself, and an ancestor nothing swings, are both taken.
        try document.addVRM1SpringBone(VRM1Spring(joints: free, center: free[0]))
        let another = try document.addOrnamentChain(under: head)
        try document.addVRM1SpringBone(VRM1Spring(joints: another, center: head))
    }

    @Test
    func testAVRM0BoneGroupNamingNoRootIsRefused() throws {
        let document = try GLTFEditableDocument(data: VRMSampleAsset.aliciaSolid.data)
        let before = try document.serialize()

        #expect(throws: VRMError.self) { try document.addVRM0SpringBone(VRM0SpringBoneGroup(rootBones: [])) }

        #expect(try document.serialize() == before)
    }

    // MARK: - Versions this cannot write

    /// The two forms are not interchangeable, so each is refused by the version
    /// that does not keep it.
    @Test
    func testASpringOfTheOtherVersionsFormIsRefused() throws {
        let vrm0 = try GLTFEditableDocument(data: VRMSampleAsset.aliciaSolid.data)
        let vrm0Ornament = try vrm0.addOrnamentChain(under: VRMSampleAsset.aliciaSolid.headNode)
        #expect(throws: VRMError.self) { try vrm0.addVRM1SpringBone(VRM1Spring(joints: vrm0Ornament)) }

        let vrm1 = try GLTFEditableDocument(data: VRMSampleAsset.seedSan.data)
        let vrm1Ornament = try vrm1.addOrnamentChain(under: VRMSampleAsset.seedSan.headNode)
        #expect(throws: VRMError.self) {
            try vrm1.addVRM0SpringBone(VRM0SpringBoneGroup(rootBones: [vrm1Ornament[0]]))
        }
    }

    /// `VRMC_springBone` is versioned on its own, so a document declaring a
    /// version other than the one written is not given springs of that shape.
    /// Reading takes `1.0-beta`, but the two differ in what a spring holds.
    @Test(arguments: ["2.0", "1.0-beta"])
    func testASpringIsNotAddedToASpringBoneExtensionOfAnotherVersion(specVersion: String) throws {
        let rewritten = try VRMSampleAsset.seedSan.rewritingJSON { json in
            var extensions = json["extensions"] as? [String: Any] ?? [:]
            var springBone = extensions["VRMC_springBone"] as? [String: Any] ?? [:]
            springBone["specVersion"] = specVersion
            extensions["VRMC_springBone"] = springBone
            json["extensions"] = extensions
        }
        let document = try GLTFEditableDocument(data: rewritten)
        let ornament = try document.addOrnamentChain(under: VRMSampleAsset.seedSan.headNode)
        let before = try document.serialize()

        #expect(throws: VRMError.self) { try document.addVRM1SpringBone(VRM1Spring(joints: ornament)) }

        #expect(try document.serialize() == before)
    }

    /// What a spring may swing is decided against the springs already there, so
    /// a document whose own springs cannot be read is refused rather than added
    /// to on a guess about what they hold.
    @Test(arguments: [0, 1, 2])
    func testASpringIsNotAddedToSpringsThatCannotBeRead(damage: Int) throws {
        let broken = try VRMSampleAsset.seedSan.rewritingJSON { json in
            var extensions = json["extensions"] as? [String: Any] ?? [:]
            var springBone = try #require(extensions["VRMC_springBone"] as? [String: Any])
            switch damage {
            case 0: springBone["springs"] = "not an array"
            case 1: springBone["springs"] = [["joints": [["hitRadius": 0.1]]]]
            default: springBone["colliderGroups"] = "not an array"
            }
            extensions["VRMC_springBone"] = springBone
            json["extensions"] = extensions
        }
        let document = try GLTFEditableDocument(data: broken)
        let ornament = try document.addOrnamentChain(under: VRMSampleAsset.seedSan.headNode)
        let before = try document.serialize()

        #expect(throws: VRMError.self) { try document.addVRM1SpringBone(VRM1Spring(joints: ornament)) }

        #expect(try document.serialize() == before)
    }

    /// Only what the edit reads has to make sense. A collider the new spring
    /// never names is carried over as it is rather than standing in the way.
    @Test
    func testASpringIsAddedBesideAColliderThisEditNeverReads() throws {
        let odd = try VRMSampleAsset.seedSan.rewritingJSON { json in
            var extensions = json["extensions"] as? [String: Any] ?? [:]
            var springBone = try #require(extensions["VRMC_springBone"] as? [String: Any])
            springBone["colliders"] = [["node": 0, "shape": ["cube": ["size": 1]]]]
            extensions["VRMC_springBone"] = springBone
            json["extensions"] = extensions
        }
        let document = try GLTFEditableDocument(data: odd)
        let ornament = try document.addOrnamentChain(under: VRMSampleAsset.seedSan.headNode)

        let index = try document.addVRM1SpringBone(VRM1Spring(joints: ornament))

        let springs = springBoneJSON(of: document)
        #expect(springs[safe: index]?.objects("joints").compactMap { $0.index("node") } == ornament)
    }

    /// The same for VRM 0.x, whose bone groups live in the model's own extension.
    @Test
    func testAVRM0GroupIsNotAddedToBoneGroupsThatCannotBeRead() throws {
        let broken = try VRMSampleAsset.aliciaSolid.rewritingJSON { json in
            var extensions = json["extensions"] as? [String: Any] ?? [:]
            var vrm = try #require(extensions["VRM"] as? [String: Any])
            var secondary = try #require(vrm["secondaryAnimation"] as? [String: Any])
            secondary["boneGroups"] = "not an array"
            vrm["secondaryAnimation"] = secondary
            extensions["VRM"] = vrm
            json["extensions"] = extensions
        }
        let document = try GLTFEditableDocument(data: broken)
        let ornament = try document.addOrnamentChain(under: VRMSampleAsset.aliciaSolid.headNode)
        let before = try document.serialize()

        #expect(throws: VRMError.self) {
            try document.addVRM0SpringBone(VRM0SpringBoneGroup(rootBones: [ornament[0]]))
        }

        #expect(try document.serialize() == before)
    }

    /// The hierarchy an edit reads is the one a loader reads, so a document a
    /// loader refuses is not one a spring is written into on a different reading.
    @Test
    func testASpringIsNotAddedToADocumentWhoseHierarchyALoaderRefuses() throws {
        let twoParents = try VRMSampleAsset.seedSan.rewritingJSON { json in
            var nodes = json["nodes"] as? [[String: Any]] ?? []
            let head = try #require(try VRM(data: VRMSampleAsset.seedSan.data).nodeIndex(of: .head))
            let hips = try #require(try VRM(data: VRMSampleAsset.seedSan.data).nodeIndex(of: .hips))
            nodes[hips]["children"] = (nodes[hips]["children"] as? [Int] ?? []) + [head]
            json["nodes"] = nodes
        }
        let document = try GLTFEditableDocument(data: twoParents)
        let ornament = try document.addOrnamentChain(under: 0)

        #expect(throws: VRMError.self) { try document.addVRM1SpringBone(VRM1Spring(joints: ornament)) }
    }

    /// A plain glTF has no spring bones and no version to write them in.
    @Test
    func testAddingASpringToAGLTFThatIsNotAVRMIsRefused() throws {
        let document = try GLTFEditableDocument(data: GLTFSampleAsset.boxVertexColors.data)
        let ornament = try document.addOrnamentChain(under: 0)
        let before = try document.serialize()

        #expect(throws: VRMError.self) {
            try document.addVRM0SpringBone(VRM0SpringBoneGroup(rootBones: [ornament[0]]))
        }
        #expect(throws: VRMError.self) { try document.addVRM1SpringBone(VRM1Spring(joints: ornament)) }

        #expect(try document.serialize() == before)
    }
}

// MARK: - Reading back

private func vrm0(of document: GLTFEditableDocument) throws -> VRM0 {
    try VRM0(data: try document.serialize())
}

private func vrm1(of document: GLTFEditableDocument) throws -> VRM1 {
    try VRM1(data: try document.serialize())
}

/// What the model swings, as the JSON of whichever version's array holds it.
private func springBoneJSON(of document: GLTFEditableDocument) -> [[String: Any]] {
    let extensions = document.json.object("extensions") ?? [:]
    if let springBone = extensions.object(GLTFExtension.springBone.rawValue) {
        return springBone.objects("springs")
    }
    return (extensions.object(GLTFExtension.vrm0.rawValue)?.object("secondaryAnimation") ?? [:])
        .objects("boneGroups")
}

// MARK: - Fixtures

private extension GLTFEditableDocument {
    /// The same line of nodes written as whichever form `asset` keeps, for the
    /// assertions that hold whatever version a model is.
    @discardableResult
    func addSpringBone(over ornament: [Int], of asset: VRMSampleAsset, name: String? = nil) throws -> Int {
        try addSpringBone(VRM1Spring(joints: ornament, name: name), of: asset)
    }

    /// `spring` for a VRM 1.0 model, and the 0.x group that stands for it.
    @discardableResult
    func addSpringBone(_ spring: VRM1Spring, of asset: VRMSampleAsset) throws -> Int {
        guard try asset.isVRM0 else { return try addVRM1SpringBone(spring) }
        let joint = spring.joints[0]
        return try addVRM0SpringBone(VRM0SpringBoneGroup(
            rootBones: [joint.node],
            stiffness: joint.stiffness ?? VRMSpringBoneDefaults.stiffness,
            gravityPower: joint.gravityPower ?? VRMSpringBoneDefaults.gravityPower,
            gravityDirection: joint.gravityDirection ?? VRMSpringBoneDefaults.gravityDirection,
            dragForce: joint.dragForce ?? VRMSpringBoneDefaults.dragForce,
            hitRadius: joint.hitRadius ?? VRMSpringBoneDefaults.hitRadius,
            colliderGroups: spring.colliderGroups,
            center: spring.center,
            comment: spring.name
        ))
    }
}

private extension VRMSampleAsset {
    /// The head a hair ornament hangs off.
    var headNode: Int {
        get throws { try #require(try VRM(data: data).nodeIndex(of: .head)) }
    }

    var isVRM0: Bool {
        get throws {
            if case .v0 = try VRM(data: data) { return true }
            return false
        }
    }
}
