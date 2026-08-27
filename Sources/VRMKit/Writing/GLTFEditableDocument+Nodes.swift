import Foundation

extension GLTFEditableDocument {
    /// Adds a node and returns its index.
    ///
    /// With no `parent` the node becomes a root of the document's default scene.
    /// A document holding no scene at all is given one.
    @discardableResult
    public mutating func addNode(name: String? = nil,
                        parent: GLTFNodeIndex? = nil,
                        transform: GLTFNodeTransform = .identity) throws -> GLTFNodeIndex {
        try transform.validate()
        let placement = try resolveNodePlacement(under: parent?.rawValue)

        var node = JSONObject()
        node.set("name", name)
        transform.write(into: &node)
        return GLTFNodeIndex(appendNode(node, at: placement))
    }

    public mutating func setTransform(_ transform: GLTFNodeTransform, nodeAt index: GLTFNodeIndex) throws {
        try transform.validate()
        try updateNode(at: index.rawValue) { transform.write(into: &$0) }
    }

    public mutating func setName(_ name: String?, nodeAt index: GLTFNodeIndex) throws {
        try updateNode(at: index.rawValue) { $0.set("name", name) }
    }

    /// The transform a node has, with a `matrix` node decomposed into TRS.
    public func transform(nodeAt index: GLTFNodeIndex) throws -> GLTFNodeTransform {
        GLTFNodeTransform(node: try node(at: index.rawValue))
    }

    /// Moves a node, and everything below it, under `parent`, or to the default scene's
    /// roots when there is none. Only its links change, so the extensions naming it keep
    /// pointing where they did, and a rejected move changes nothing.
    public mutating func moveNode(at index: GLTFNodeIndex, to newParent: GLTFNodeIndex?) throws {
        let index = index.rawValue
        let parent = newParent?.rawValue
        try requireNode(at: index)
        guard let parent else {
            _ = try sceneIndexForRoots()
            try detachNodeLinks(at: index)
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
        try detachNodeLinks(at: index)
        try addChild(index, to: parent)
    }

    /// Detaches a node, and everything below it, from its parent and from the scenes that
    /// draw it. Only the links are cut: the nodes keep their contents and indices, so what
    /// was detached can be drawn again with ``moveNode(at:to:)``.
    public mutating func detachNode(at index: GLTFNodeIndex) throws {
        try detachNodeLinks(at: index.rawValue)
    }

    private mutating func detachNodeLinks(at index: Int) throws {
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

    /// Who the document's nodes hang off, validated as it is built, so an edit reads
    /// the hierarchy a loader would and refuses the ones it would.
    func nodeHierarchy() throws -> GLTFNodeHierarchy {
        try GLTFNodeHierarchy(childIndices: json.objects(.nodes).map { $0.ints("children") ?? [] })
    }

    mutating func appendNode(_ node: JSONObject) -> Int {
        json.appendObject(node, to: .nodes)
    }

    enum NodePlacement {
        case child(of: Int)
        case sceneRoot(in: Int)
    }

    /// Resolves every fallible placement rule before an edit starts writing its payload.
    /// The returned indices stay valid because edits only append.
    mutating func resolveNodePlacement(under parent: Int?) throws -> NodePlacement {
        if let parent {
            try requireNode(at: parent)
            return .child(of: parent)
        }
        return .sceneRoot(in: try sceneIndexForRoots())
    }

    /// Appends and attaches a node whose placement has already been validated.
    mutating func appendNode(_ node: JSONObject, at placement: NodePlacement) -> Int {
        let index = appendNode(node)
        attachNode(index, at: placement)
        return index
    }

    func node(at index: Int) throws -> JSONObject {
        try requireNode(at: index)
        return try json[.nodes]?.arrayValue?[safe: index]?.objectValue
            ??? ._dataInconsistent("node \(index) is not a JSON object")
    }

    mutating func updateNode(at index: Int, _ body: (inout JSONObject) throws -> Void) throws {
        try requireNode(at: index)
        try json.updateObject(at: index, in: .nodes, body)
    }

    /// Checks that the document holds a node at `index`.
    func requireNode(at index: Int) throws {
        let count = json.count(.nodes)
        guard index >= 0, index < count else {
            throw VRMError._invalidArgument(
                "node index \(index) is out of range for the \(count) nodes of the document"
            )
        }
    }

    mutating func addChild(_ child: Int, to parent: Int) throws {
        guard child != parent else {
            throw VRMError._dataInconsistent("node \(child) cannot be its own parent")
        }
        try requireNode(at: parent)
        attachNode(child, at: .child(of: parent))
    }

    /// Adds a root to the document's default scene: a node no scene reaches is not drawn.
    mutating func addSceneRoot(_ index: Int) throws {
        attachNode(index, at: .sceneRoot(in: try sceneIndexForRoots()))
    }

    private mutating func attachNode(_ index: Int, at placement: NodePlacement) {
        switch placement {
        case .child(let parent):
            json.updateObject(at: parent, in: .nodes) { $0.appendIndex(index, to: "children") }
        case .sceneRoot(let sceneIndex):
            json.updateObject(at: sceneIndex, in: .scenes) { $0.appendIndex(index, to: "nodes") }
        }
    }

    /// The scene an edit puts a root in. A document holding none is given one, named
    /// as the default so a loader knows which scene to draw.
    private mutating func sceneIndexForRoots() throws -> Int {
        guard json.count(.scenes) == 0, json["scene"] == nil else {
            return try defaultSceneIndex()
        }
        json.setObjects([JSONObject()], for: .scenes)
        json["scene"] = 0
        return 0
    }

    /// The scene the document draws, which is the one an edit adds roots to.
    func defaultSceneIndex() throws -> Int {
        try Self.defaultSceneIndex(of: json, of: "document")
    }

    /// The scene a document draws, by the rule every renderer resolves it with.
    static func defaultSceneIndex(of json: JSONObject, of subject: String) throws -> Int {
        try GLTF.defaultSceneIndex(json.index("scene"), among: json.count(.scenes), of: subject)
    }
}
