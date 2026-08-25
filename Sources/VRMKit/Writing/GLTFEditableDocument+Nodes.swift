import Foundation

extension GLTFEditableDocument {
    /// Adds a node and returns its index.
    ///
    /// With no `parent` the node becomes a root of the document's default
    /// scene, which ``defaultSceneIndex()`` resolves. A document holding no
    /// scene at all is given one to be a root of.
    @discardableResult
    public func addNode(name: String? = nil,
                        parent: Int? = nil,
                        transform: GLTFNodeTransform = .identity) throws -> Int {
        try transform.validate()
        let placement = try resolveNodePlacement(under: parent)

        var node = JSONObject()
        node.set("name", name)
        transform.write(into: &node)
        return appendNode(node, at: placement)
    }

    public func setTransform(_ transform: GLTFNodeTransform, nodeAt index: Int) throws {
        try transform.validate()
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
    /// The node keeps the index it had, so the extensions naming it keep pointing
    /// at what they used to; only its links change. Everything is checked before
    /// anything is cut, so a rejected move changes nothing.
    public func moveNode(at index: Int, to parent: Int?) throws {
        try requireNode(at: index)
        guard let parent else {
            _ = try sceneIndexForRoots()
            try detachNode(at: index)
            try addSceneRoot(index)
            return
        }
        try requireNode(at: parent)
        guard parent != index else {
            throw VRMError._dataInconsistent("node \(index) cannot be its own parent")
        }
        guard !(try nodeHierarchy().lineage(of: parent).contains(index)) else {
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
    /// Only the links are cut: the nodes keep what they held and the indices they
    /// had, so the extensions naming them go on pointing at what they used to and
    /// what was detached can be drawn again with ``moveNode(at:to:)``.
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

    /// Who the document's nodes hang off, validated as it is built, so that an
    /// edit reads the hierarchy a loader would and refuses the ones it would.
    func nodeHierarchy() throws -> GLTFNodeHierarchy {
        try GLTFNodeHierarchy(childIndices: json.objects(.nodes).map { $0.ints("children") ?? [] })
    }

    func appendNode(_ node: JSONObject) -> Int {
        json.appendObject(node, to: .nodes)
    }

    enum NodePlacement {
        case child(of: Int)
        case sceneRoot(in: Int)
    }

    /// Resolves every fallible placement rule before an edit starts writing its
    /// payload. The returned indices stay valid because edits only append.
    func resolveNodePlacement(under parent: Int?) throws -> NodePlacement {
        if let parent {
            try requireNode(at: parent)
            return .child(of: parent)
        }
        return .sceneRoot(in: try sceneIndexForRoots())
    }

    /// Appends and attaches a node whose placement has already been validated.
    func appendNode(_ node: JSONObject, at placement: NodePlacement) -> Int {
        let index = appendNode(node)
        attachNode(index, at: placement)
        return index
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
        try requireNode(at: parent)
        attachNode(child, at: .child(of: parent))
    }

    /// Adds a root to the document's default scene: a node no scene reaches is
    /// one no renderer draws.
    func addSceneRoot(_ index: Int) throws {
        attachNode(index, at: .sceneRoot(in: try sceneIndexForRoots()))
    }

    private func attachNode(_ index: Int, at placement: NodePlacement) {
        switch placement {
        case .child(let parent):
            var nodes = json.objects(.nodes)
            nodes[parent]["children"] = (nodes[parent].ints("children") ?? []) + [index]
            json[.nodes] = nodes
        case .sceneRoot(let sceneIndex):
            var scenes = json.objects(.scenes)
            scenes[sceneIndex]["nodes"] = (scenes[sceneIndex].ints("nodes") ?? []) + [index]
            json[.scenes] = scenes
        }
    }

    /// The scene an edit puts a root in. A document holding none is given one, and
    /// named as the default so that a loader asking which scene to draw is answered.
    private func sceneIndexForRoots() throws -> Int {
        guard json.count(.scenes) == 0, json["scene"] == nil else {
            return try defaultSceneIndex()
        }
        json[.scenes] = [JSONObject()]
        json["scene"] = 0
        return 0
    }

    /// The scene the document draws, which is the one an edit adds roots to.
    func defaultSceneIndex() throws -> Int {
        try Self.defaultSceneIndex(of: json, of: "document")
    }

    /// The scene a document draws.
    ///
    /// glTF leaves `scene` optional, and a document that names none is not naming
    /// its first. A document of one scene has nothing to name, which is how UniVRM
    /// 0.x writes its models, but one holding several and naming none says nothing
    /// about which to draw, and that is not this to decide.
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
