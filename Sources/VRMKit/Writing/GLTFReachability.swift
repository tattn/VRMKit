import Foundation

/// Which of a glTF document's entries are still there for a reason, which tells
/// ``GLTFEditableDocument/prune()`` what it may throw away.
///
/// An entry is drawn when a scene reaches it, which is what keeps bytes in the BIN buffer.
/// A node is merely named when something points at it without drawing it, as a skin's
/// joints or a humanoid bone are: naming keeps the node's entry and its transform, not the
/// mesh it used to draw. References are read through ``GLTFReferences``, so the walk cannot
/// fall behind what rewriting knows.
struct GLTFReachability {
    /// The entries the document still has a use for, by array.
    let live: [GLTFArray: Set<Int>]
    /// The nodes a scene reaches, which are the only ones still drawing.
    let drawn: Set<Int>

    static func of(_ json: JSONObject) -> GLTFReachability {
        var walk = Walk(json: json)
        // Drained whole first, so that what follows can tell a node it merely names
        // from one already being drawn.
        walk.markDrawnRoots()
        walk.follow()
        walk.markNamed()
        walk.follow()
        return GLTFReachability(live: walk.live, drawn: walk.drawn)
    }

    func contains(_ index: Int, in array: GLTFArray) -> Bool {
        live[array]?.contains(index) ?? false
    }
}

private struct Walk {
    // Bridged out of the JSON once rather than per step.
    private let json: JSONObject
    private let entries: [GLTFArray: [JSONObject]]
    /// VRM 0.x's per-material shading, an array parallel to `materials` at the
    /// root of the document rather than part of them.
    private let vrm0MaterialProperties: [JSONObject]

    private(set) var live: [GLTFArray: Set<Int>] = [:]
    private(set) var drawn: Set<Int> = []
    private var pending: [(array: GLTFArray, index: Int)] = []

    init(json: JSONObject) {
        self.json = json
        entries = Dictionary(uniqueKeysWithValues: GLTFArray.allCases.map { ($0, json.objects($0)) })
        vrm0MaterialProperties = (json.object("extensions")?.object(GLTFExtension.vrm0.rawValue) ?? [:])
            .objects("materialProperties")
    }

    // MARK: - Roots

    mutating func markDrawnRoots() {
        for index in indices(of: .scenes) {
            mark(index, in: .scenes)
        }
        // A `VRMC_vrm_animation` document is not a model: what it describes is the
        // humanoid it drives, so that is its hierarchy the way a scene is a model's.
        guard let vrma = json.object("extensions")?[GLTFExtension.vrmAnimation.rawValue] else { return }
        for (array, index, _) in references(of: [GLTFExtension.vrmAnimation.rawValue: vrma],
                                            GLTFReferences.rewritingRootExtensions) where array == .nodes {
            draw(index)
            mark(index, in: .nodes)
        }
    }

    mutating func markNamed() {
        // An animation is played by name rather than reached through a scene, so
        // it is kept unless every channel drives a node no scene draws.
        for index in indices(of: .animations) where drivesSomethingDrawn(entries[.animations]?[index]) {
            mark(index, in: .animations)
        }
        let extensions = json.object("extensions") ?? [:]
        // The thumbnail is the one resource of a VRM that no scene draws.
        mark(extensions.object(GLTFExtension.vrm0.rawValue)?.object("meta")?.index("texture"), in: .textures)
        mark(extensions.object(GLTFExtension.vrm1.rawValue)?.object("meta")?.index("thumbnailImage"), in: .images)
        // The rest of what they name is a node, kept for its entry alone.
        for (array, index, _) in references(of: extensions, GLTFReferences.rewritingRootExtensions)
        where array == .nodes {
            mark(index, in: .nodes)
        }
    }

    private func drivesSomethingDrawn(_ animation: JSONObject?) -> Bool {
        (animation ?? [:]).objects("channels").contains { channel in
            channel.object("target")?.index("node").map(drawn.contains) ?? false
        }
    }

    // MARK: - Walking

    mutating func follow() {
        while let next = pending.popLast() {
            guard let entry = entries[next.array]?[safe: next.index] else { continue }
            // A node the scenes never reached keeps its transform and nothing else,
            // which the rewrite says by dropping what it hung together.
            let drawing = next.array != .nodes || drawn.contains(next.index)
            for (array, index, kind) in references(of: entry, { entry, map in
                GLTFReferences.rewriting(entry, of: next.array, drawing: drawing, with: map)
            }) {
                if kind == .hierarchy {
                    draw(index)
                }
                mark(index, in: array)
            }
            if next.array == .materials {
                markVRM0MaterialTextures(at: next.index)
            }
        }
    }

    /// VRM 0.x describes a material's MToon shading in the root extension entry
    /// beside it, textures and all.
    private mutating func markVRM0MaterialTextures(at index: Int) {
        for (_, texture) in vrm0MaterialProperties[safe: index]?.object("textureProperties") ?? [:] {
            mark(texture.indexValue, in: .textures)
        }
    }

    // MARK: - Marking

    /// Whether a reference is one to follow at all. What names a node for its
    /// drawing is answered by the hierarchy rather than by the reference.
    private static func keeps(_ index: Int, as kind: GLTFReferenceKind, drawn: Set<Int>) -> Bool {
        switch kind {
        case .drawnSubject: drawn.contains(index)
        case .hierarchy, .plain: true
        }
    }

    /// The references worth following out of `object`, collected by running the
    /// rewrite and throwing its copy away, so the walk cannot disagree with it.
    private func references(
        of object: JSONObject,
        _ rewrite: (JSONObject, @escaping GLTFIndexMap) -> JSONObject
    ) -> [(array: GLTFArray, index: Int, kind: GLTFReferenceKind)] {
        var found: [(array: GLTFArray, index: Int, kind: GLTFReferenceKind)] = []
        let drawn = drawn
        _ = rewrite(object) { array, index, kind in
            guard Self.keeps(index, as: kind, drawn: drawn) else { return nil }
            found.append((array, index, kind))
            return index
        }
        return found
    }

    /// Puts a node in the hierarchy a scene draws. A node already walked as one
    /// something merely named is queued again, that walk having stopped short of
    /// what it draws.
    private mutating func draw(_ index: Int) {
        guard drawn.insert(index).inserted else { return }
        guard live[.nodes]?.contains(index) == true else { return }
        pending.append((.nodes, index))
    }

    private mutating func mark(_ index: Int?, in array: GLTFArray) {
        guard let index, index >= 0, index < entries[array]?.count ?? 0 else { return }
        guard live[array, default: []].insert(index).inserted else { return }
        pending.append((array, index))
    }

    private func indices(of array: GLTFArray) -> Range<Int> {
        0 ..< (entries[array]?.count ?? 0)
    }
}
