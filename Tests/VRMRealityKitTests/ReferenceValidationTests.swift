#if canImport(RealityKit)
import Foundation
import RealityKit
import Testing
import VRMKit
import VRMTestSupport
@testable import VRMRealityKit

/// Missing, duplicate, self-referencing, and out-of-range references a VRM 1.0 extension
/// can name, none of which may crash the load: every one is refused with a typed error.
@Suite
struct ReferenceValidationTests {
    @Test
    func testANodeConstraintSourceOutOfRangeFailsTheLoad() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        // Node 14 is rotation-constrained by node 82 in the fixture (see VRM1Tests).
        let modified = try TestSupport.modifiedSeedSanData(name: "constraint source out of range") { json in
            var nodes = json.objects("nodes")
            var constraint = nodes[14].object("extensions")!.object("VRMC_node_constraint")!
            var rotation = constraint.object("constraint")!.object("rotation")!
            rotation.set("source", 999_999)
            var inner = constraint.object("constraint")!
            inner.set("rotation", rotation)
            constraint.set("constraint", inner)
            var extensions = nodes[14].object("extensions")!
            extensions.set("VRMC_node_constraint", constraint)
            nodes[14].set("extensions", extensions)
            json.set("nodes", nodes)
        }

        await #expect(throws: VRMError.self) {
            _ = try await VRMEntityLoader(withData: modified).loadEntity()
        }
    }

    @Test
    func testANodeConstraintNamingItselfAsItsSourceFailsTheLoad() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let modified = try TestSupport.modifiedSeedSanData(name: "constraint self-reference") { json in
            var nodes = json.objects("nodes")
            var constraint = nodes[14].object("extensions")!.object("VRMC_node_constraint")!
            var rotation = constraint.object("constraint")!.object("rotation")!
            rotation.set("source", 14)
            var inner = constraint.object("constraint")!
            inner.set("rotation", rotation)
            constraint.set("constraint", inner)
            var extensions = nodes[14].object("extensions")!
            extensions.set("VRMC_node_constraint", constraint)
            nodes[14].set("extensions", extensions)
            json.set("nodes", nodes)
        }

        await #expect(throws: VRMError.self) {
            _ = try await VRMEntityLoader(withData: modified).loadEntity()
        }
    }

    @Test
    func testAHumanoidBoneNodeOutOfRangeFailsTheLoad() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let modified = try TestSupport.modifiedSeedSanData(name: "humanoid node out of range") { json in
            json.withObject("extensions") { extensions in
                extensions.withObject(GLTFExtension.vrm1.rawValue) { vrm in
                    vrm.withObject("humanoid") { humanoid in
                        humanoid.withObject("humanBones") { bones in
                            bones.withObject("hips") { $0.set("node", 999_999) }
                        }
                    }
                }
            }
        }

        await #expect(throws: VRMError.self) {
            _ = try await VRMEntityLoader(withData: modified).loadEntity()
        }
    }

    @Test
    func testASpringBoneJointNodeOutOfRangeFailsTheLoad() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let modified = try TestSupport.modifiedSeedSanData(name: "spring joint node out of range") { json in
            json.withObject("extensions") { extensions in
                extensions.withObject("VRMC_springBone") { springBone in
                    var springs = springBone.objects("springs")
                    var joints = springs[0].objects("joints")
                    joints[0].set("node", 999_999)
                    springs[0].set("joints", joints)
                    springBone.set("springs", springs)
                }
            }
        }

        await #expect(throws: VRMError.self) {
            _ = try await VRMEntityLoader(withData: modified).loadEntity()
        }
    }

    /// A node claimed as a child of two different parents is a broken hierarchy, whichever
    /// VRM extension happens to name it.
    @Test
    func testANodeClaimedByTwoParentsFailsTheLoad() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let modified = try TestSupport.modifiedSeedSanData(name: "node with two parents") { json in
            var nodes = json.objects("nodes")
            // Node 0 already has children; add node 1 (already a child elsewhere) as an
            // additional child of node 0, so it claims two parents.
            var zero = nodes[0]
            var children = zero.ints("children") ?? []
            children.append(1)
            zero.set("children", .array(children.map { .int($0) }))
            nodes[0] = zero
            json.set("nodes", nodes)
        }

        await #expect(throws: VRMError.self) {
            _ = try await VRMEntityLoader(withData: modified).loadEntity()
        }
    }
}
#endif
