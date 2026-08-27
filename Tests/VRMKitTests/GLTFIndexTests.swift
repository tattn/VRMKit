import Foundation
import Testing
import VRMTestSupport
@testable import VRMKit

/// The indices the authoring API takes, and how one survives a prune.
@Suite
struct GLTFIndexTests {
    /// Pruning renumbers what it keeps, so an index saved before it names a
    /// different entry afterwards. What it answers with is how one is carried
    /// across.
    @Test
    func testPruneSaysWhereTheIndicesItKeptEndedUp() throws {
        var document = GLTFEditableDocument()
        let first = try document.addNode(name: "first")
        let second = try document.addNode(name: "second")
        let third = try document.addNode(name: "third")
        try document.detachNode(at: first)
        try document.detachNode(at: second)

        let result = try document.prune()

        let saved = try GLTFDocument(data: try document.serialize()).gltf
        #expect(saved.nodes?.map(\.name) == ["third"])
        // The two detached nodes went, and the one still drawn moved down to
        // where they used to be.
        #expect(result.newIndex(of: first) == nil)
        #expect(result.newIndex(of: second) == nil)
        let moved = try #require(result.newIndex(of: third))
        #expect(moved != third)
        #expect(saved.nodes?[moved.rawValue].name == "third")
    }

    @Test
    func testPruningNothingLeavesEveryIndexWhereItWas() throws {
        var document = GLTFEditableDocument()
        let node = try document.addNode(name: "kept")

        let result = try document.prune()

        #expect(result.reclaimedByteCount == 0)
        #expect(result.newIndex(of: node) == node)
    }

    /// An index is a name for an entry of one array, and the arrays are not
    /// interchangeable however alike their integers are.
    @Test
    func testAnIndexSaysWhichArrayItPointsInto() {
        #expect(GLTFNodeIndex(3).rawValue == 3)
        #expect(GLTFNodeIndex(3) == 3)
        #expect(GLTFNodeIndex(3) < GLTFNodeIndex(4))
        #expect("\(GLTFNodeIndex(3))" == "nodes[3]")
        #expect("\(GLTFMaterialIndex(0))" == "materials[0]")
    }
}
