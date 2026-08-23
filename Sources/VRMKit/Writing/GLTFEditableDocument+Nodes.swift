import Foundation

extension GLTFEditableDocument {
    /// Adds a node and returns its index.
    ///
    /// With no `parent` the node becomes a root of the document's default
    /// scene, which ``defaultSceneIndex()`` resolves.
    @discardableResult
    public func addNode(name: String? = nil,
                        parent: Int? = nil,
                        transform: GLTFNodeTransform = .identity) throws -> Int {
        // Checked before the node is appended, so a failure leaves the
        // document as it was rather than one orphan larger.
        if let parent {
            try requireNode(at: parent)
        } else {
            _ = try defaultSceneIndex()
        }

        var node = JSONObject()
        node.set("name", name)
        transform.write(into: &node)

        let index = appendNode(node)

        if let parent {
            try addChild(index, to: parent)
        } else {
            try addSceneRoot(index)
        }
        return index
    }

    public func setTransform(_ transform: GLTFNodeTransform, nodeAt index: Int) throws {
        try updateNode(at: index) { transform.write(into: &$0) }
    }

    public func setName(_ name: String?, nodeAt index: Int) throws {
        try updateNode(at: index) { $0.set("name", name) }
    }

    /// The transform a node has, with a `matrix` node decomposed into TRS.
    public func transform(nodeAt index: Int) throws -> GLTFNodeTransform {
        GLTFNodeTransform(node: try node(at: index))
    }

    /// Moves a node, and everything below it, under `parent`, or to the
    /// default scene's roots when there is none.
    ///
    /// The node keeps the index it had, so the extensions naming it keep
    /// pointing at what they used to; only its links change.
    public func moveNode(at index: Int, to parent: Int?) throws {
        // Checked before anything is cut, so a rejected move changes nothing.
        try requireNode(at: index)
        guard let parent else {
            _ = try defaultSceneIndex()
            try detachNode(at: index)
            try addSceneRoot(index)
            return
        }
        try requireNode(at: parent)
        guard parent != index else {
            throw VRMError._dataInconsistent("node \(index) cannot be its own parent")
        }
        guard !descendants(of: index).contains(parent) else {
            throw VRMError._dataInconsistent(
                "node \(parent) is below node \(index), so moving it there would close a cycle"
            )
        }
        try detachNode(at: index)
        try addChild(index, to: parent)
    }

    /// Detaches a node from its parent and from the scenes that draw it, and
    /// with it everything below it.
    ///
    /// Only the links are cut: the nodes keep what they held and the indices
    /// they had, so the extensions naming them keep pointing at what they used
    /// to and what was detached can be drawn again with ``moveNode(at:to:)``.
    public func detachNode(at index: Int) throws {
        try requireNode(at: index)
        json.mapObjects(.nodes) { node in
            var node = node
            node.removeIndex(index, from: "children", dropWhenEmpty: true)
            return node
        }
        json.mapObjects(.scenes) { scene in
            var scene = scene
            scene.removeIndex(index, from: "nodes", dropWhenEmpty: false)
            return scene
        }
    }

    /// Every node below `index`, each visited once so that a cycle already in
    /// the document does not loop here.
    private func descendants(of index: Int) -> Set<Int> {
        let nodes = json.objects(.nodes)
        var visited: Set<Int> = []
        var pending = nodes[safe: index]?.ints("children") ?? []
        while let next = pending.popLast() {
            guard visited.insert(next).inserted else { continue }
            pending.append(contentsOf: nodes[safe: next]?.ints("children") ?? [])
        }
        return visited
    }

    func appendNode(_ node: JSONObject) -> Int {
        var nodes = json.objects(.nodes)
        nodes.append(node)
        json[.nodes] = nodes
        return nodes.count - 1
    }

    func node(at index: Int) throws -> JSONObject {
        try requireNode(at: index)
        // Bridges the one element rather than the whole array.
        return try (json[.nodes] as? [Any])?[safe: index] as? JSONObject
            ??? ._dataInconsistent("node \(index) is not a JSON object")
    }

    func updateNode(at index: Int, _ body: (inout JSONObject) throws -> Void) throws {
        var nodes = try nodes(holding: index)
        try body(&nodes[index])
        json[.nodes] = nodes
    }

    private func nodes(holding index: Int) throws -> [JSONObject] {
        try requireNode(at: index)
        return json.objects(.nodes)
    }

    /// Checks the index without building the array `nodes(holding:)` returns.
    func requireNode(at index: Int) throws {
        let count = json.count(.nodes)
        guard index >= 0, index < count else {
            throw VRMError._dataInconsistent(
                "node index \(index) is out of range for the \(count) nodes of the document"
            )
        }
    }

    func addChild(_ child: Int, to parent: Int) throws {
        guard child != parent else {
            throw VRMError._dataInconsistent("node \(child) cannot be its own parent")
        }
        try updateNode(at: parent) { $0["children"] = ($0.ints("children") ?? []) + [child] }
    }

    /// Adds a root to the document's default scene: a node no scene reaches is
    /// one no renderer draws.
    func addSceneRoot(_ index: Int) throws {
        let sceneIndex = try defaultSceneIndex()
        var scenes = json.objects(.scenes)
        scenes[sceneIndex]["nodes"] = (scenes[sceneIndex].ints("nodes") ?? []) + [index]
        json[.scenes] = scenes
    }

    /// The scene the document draws, which is the one an edit adds roots to.
    func defaultSceneIndex() throws -> Int {
        try Self.defaultSceneIndex(of: json, of: "document")
    }

    /// The scene a document draws.
    ///
    /// glTF leaves `scene` optional, and a document that names none is not
    /// naming its first. A document of one scene has nothing to name, which is
    /// how UniVRM 0.x writes its models, but one holding several and pointing
    /// at none says nothing about which to draw, and that is not this to decide.
    static func defaultSceneIndex(of json: JSONObject, of subject: String) throws -> Int {
        let scenes = json.count(.scenes)
        guard let index = json.index("scene") else {
            guard scenes == 1 else {
                throw VRMError._dataInconsistent(
                    "the \(subject) names no default scene among the \(scenes) it holds"
                )
            }
            return 0
        }
        guard index >= 0, index < scenes else {
            throw VRMError._dataInconsistent(
                "the \(subject)'s default scene \(index) is out of range for its \(scenes) scenes"
            )
        }
        return index
    }
}
