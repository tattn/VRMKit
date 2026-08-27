import Testing
import simd
import VRMKit
@testable import VRMKitRuntime

/// The order `VRMC_node_constraint` constraints have to be applied in: a
/// constraint reading a node another constraint poses runs after it.
@Suite
struct NodeConstraintOrderTests {
    private struct Binding {
        let target: Int
        let descriptor: VRMNodeConstraintDescriptor
    }

    /// `children[i]` are the children of node `i`.
    private static func hierarchy(_ children: [[Int]]) throws -> GLTFNodeHierarchy {
        try GLTFNodeHierarchy(childIndices: children)
    }

    private static func ordered(_ bindings: [Binding],
                                _ hierarchy: GLTFNodeHierarchy) throws -> [Int] {
        try orderNodeConstraints(bindings,
                                 targetIndex: { $0.target },
                                 dependencies: { $0.descriptor.dependencies(destination: $0.target,
                                                                            in: hierarchy) })
            .map(\.target)
    }

    private static func aim(_ source: Int) -> VRMNodeConstraintDescriptor {
        .aim(source: source, axis: SIMD3(0, 0, 1), weight: 1)
    }

    private static func rotation(_ source: Int) -> VRMNodeConstraintDescriptor {
        .rotation(source: source, weight: 1)
    }

    /// The dependency every kind of constraint has: it reads its source, so
    /// whatever poses that source runs first.
    @Test
    func testAConstraintRunsAfterWhateverPosesItsSource() throws {
        // 0 -> 1 -> 2, all roots of nothing.
        let hierarchy = try Self.hierarchy([[], [], []])
        let bindings = [Binding(target: 2, descriptor: Self.rotation(1)),
                        Binding(target: 1, descriptor: Self.rotation(0))]

        #expect(try Self.ordered(bindings, hierarchy) == [1, 2])
    }

    /// An aim constraint reads its source's world position, which everything
    /// above the source moves.
    @Test
    func testAnAimConstraintRunsAfterWhateverPosesAnAncestorOfItsSource() throws {
        // node 0 is the parent of node 1, the source of the aim on node 2.
        let hierarchy = try Self.hierarchy([[1], [], []])
        let bindings = [Binding(target: 2, descriptor: Self.aim(1)),
                        Binding(target: 0, descriptor: Self.rotation(3))]

        #expect(try Self.ordered(bindings, hierarchy) == [0, 2])
    }

    /// An aim constraint reads its destination's world position and its
    /// destination parent's world rotation, which everything above the
    /// destination moves.
    @Test
    func testAnAimConstraintRunsAfterWhateverPosesAnAncestorOfItsDestination() throws {
        // node 0 is the parent of node 1, which the aim poses.
        let hierarchy = try Self.hierarchy([[1], [], []])
        let bindings = [Binding(target: 1, descriptor: Self.aim(2)),
                        Binding(target: 0, descriptor: Self.rotation(3))]

        #expect(try Self.ordered(bindings, hierarchy) == [0, 1])
    }

    /// A roll or rotation constraint reads its source's local rotation, which
    /// nothing above the source touches, so an ancestor orders nothing.
    @Test
    func testARotationConstraintDoesNotWaitForAnAncestorOfItsSource() throws {
        let hierarchy = try Self.hierarchy([[1], [], []])
        let bindings = [Binding(target: 2, descriptor: Self.rotation(1)),
                        Binding(target: 0, descriptor: Self.rotation(3))]

        #expect(try Self.ordered(bindings, hierarchy) == [2, 0])
    }

    /// A constraint posing what it reads has no order that satisfies it, so it
    /// is refused rather than applied against a stale pose.
    @Test
    func testACircularDependencyIsRefused() throws {
        let hierarchy = try Self.hierarchy([[], []])
        let bindings = [Binding(target: 0, descriptor: Self.rotation(1)),
                        Binding(target: 1, descriptor: Self.rotation(0))]

        #expect(throws: VRMError.self) { try Self.ordered(bindings, hierarchy) }
    }

    /// An aim constraint whose source hangs off its own destination is circular
    /// too: posing the destination moves the source it aims at.
    @Test
    func testAnAimConstraintAimingBelowItsOwnDestinationIsRefused() throws {
        // node 0 is the parent of node 1.
        let hierarchy = try Self.hierarchy([[1], []])
        let bindings = [Binding(target: 0, descriptor: Self.aim(1)),
                        Binding(target: 1, descriptor: Self.rotation(0))]

        #expect(throws: VRMError.self) { try Self.ordered(bindings, hierarchy) }
    }

    /// Two constraints posing the same node cannot both hold, whichever order
    /// they run in.
    @Test
    func testTwoConstraintsPosingTheSameNodeAreRefused() throws {
        let hierarchy = try Self.hierarchy([[], []])
        let bindings = [Binding(target: 0, descriptor: Self.rotation(1)),
                        Binding(target: 0, descriptor: Self.aim(1))]

        #expect(throws: VRMError.self) { try Self.ordered(bindings, hierarchy) }
    }
}
