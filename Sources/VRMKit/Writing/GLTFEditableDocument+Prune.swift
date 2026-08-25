import Foundation

extension GLTFEditableDocument {
    /// Takes out everything the document has stopped drawing and returns how
    /// many BIN bytes that reclaimed.
    ///
    /// ``detachNode(at:)`` leaves the meshes and textures a subtree drew where
    /// they were, so a document edited and saved repeatedly grows while looking the
    /// same. This takes those bytes back, and only when asked, since keeping
    /// unreachable data can be the point of an edit.
    ///
    /// The entries go with the bytes and every index is remapped, so the result is
    /// an ordinary glTF document. ``GLTFReachability`` decides what stays: a node
    /// something still names keeps its transform without the mesh it drew, so a
    /// humanoid bone stays where it was, but a pruned detached subtree can no
    /// longer be drawn again with ``moveNode(at:to:)``.
    ///
    /// A document declaring an extension this package cannot follow the references
    /// of is refused rather than pruned.
    @discardableResult
    public func prune() throws -> Int {
        try validatePrunable()
        let compaction = GLTFCompaction(of: json, keeping: GLTFReachability.of(json))
        let (views, compacted) = try prunedBufferViews(compaction)

        var pruned = json
        for array in GLTFArray.allCases where array != .buffers && array != .bufferViews {
            let entries = json.objects(array)
            pruned[array] = nonEmpty(compaction.kept(array).map {
                GLTFReferences.rewriting(entries[$0],
                                         of: array,
                                         drawing: array != .nodes || compaction.draws($0),
                                         with: compaction.map)
            })
        }
        pruned[.bufferViews] = nonEmpty(views)
        pruned.withObject("extensions") { extensions in
            extensions.withObject(GLTFExtension.vrm0.rawValue) { compaction.filterMaterialProperties(of: &$0) }
            extensions = GLTFReferences.rewritingRootExtensions(extensions, with: compaction.map)
        }

        // Everything that could fail is behind us, so the document changes in one
        // go rather than through `atomicallyAppendingBinary`, which covers only an
        // edit that appends.
        let reclaimed = binary.count - compacted.count
        binary = compacted
        json = pruned
        return reclaimed
    }

    /// glTF gives its top-level arrays a minimum of one entry.
    private func nonEmpty(_ entries: [JSONObject]) -> [JSONObject]? {
        entries.isEmpty ? nil : entries
    }

    /// What the walk cannot follow is what pruning would erase, so a document
    /// carrying it is refused, as one spread over several buffers is.
    private func validatePrunable() throws {
        let unsupported = json.carriedExtensions().subtracting(GLTFExtension.prunable)
        guard unsupported.isEmpty else {
            throw VRMError._notSupported(
                "the document carries \(unsupported.sorted().joined(separator: ", ")), "
                + "whose references pruning cannot follow"
            )
        }
        // A document naming no scene draws nothing, so pruning it would take
        // everything: it is refused rather than emptied. A `VRMC_vrm_animation`
        // is the exception, since what it drives stands in for a scene.
        guard json.count(.scenes) != 0
            || json.count(.nodes) == 0
            || json.object("extensions")?[GLTFExtension.vrmAnimation.rawValue] != nil else {
            throw VRMError._notSupported(
                "the document holds \(json.count(.nodes)) nodes and names no scene, "
                + "so pruning cannot tell what it draws from what it has stopped drawing"
            )
        }
    }

    // MARK: - Compaction

    /// The buffer views that are still read, and the BIN buffer holding just
    /// their bytes.
    private func prunedBufferViews(_ compaction: GLTFCompaction) throws -> (views: [JSONObject], binary: Data) {
        let entries = json.objects(.bufferViews)
        let kept = compaction.kept(.bufferViews)
        var slices: [BinarySlice] = []
        for view in kept {
            if let slice = try binarySlice(of: entries[view], at: view, compressed: false) {
                slices.append(slice)
            }
            // A meshopt view carries a second slice, the compressed bytes its own
            // are the decoded fallback for.
            if let meshopt = entries[view].object("extensions")?.object(GLTFExtension.meshoptCompression.rawValue),
               let slice = try binarySlice(of: meshopt, at: view, compressed: true) {
                slices.append(slice)
            }
        }
        let (compacted, placements) = relocating(slices)
        let views = kept.map { view in
            Self.relocated(GLTFReferences.rewriting(entries[view], of: .bufferViews, with: compaction.map),
                           at: view,
                           to: placements)
        }
        return (views, compacted)
    }

    /// The range a buffer view, or the meshopt slice shaped like one, reads.
    private func binarySlice(of object: JSONObject, at view: Int, compressed: Bool) throws -> BinarySlice? {
        let offset = object.int("byteOffset") ?? 0
        let length = object.int("byteLength") ?? 0
        guard length > 0 else { return nil }
        let end = offset.addingReportingOverflow(length)
        guard offset >= 0, !end.overflow, end.partialValue <= binary.count else {
            throw VRMError._dataInconsistent(
                "buffer view \(view) (offset: \(offset), length: \(length)) overruns "
                + "the \(binary.count) byte buffer"
            )
        }
        return BinarySlice(key: BinarySliceKey(view: view, isCompressed: compressed),
                           start: offset,
                           length: length)
    }

    /// Lays the slices out from the start of the buffer and says where each landed.
    ///
    /// Slices that touch or overlap move together, so views over the same bytes go
    /// on sharing them rather than each getting a copy. A cluster only ever moves
    /// earlier and only by a multiple of four, which keeps every view on the
    /// boundary its component type needs.
    private func relocating(_ slices: [BinarySlice]) -> (binary: Data, placements: [BinarySliceKey: Int]) {
        var compacted = Data(capacity: binary.count)
        var placements: [BinarySliceKey: Int] = [:]
        var clusterEnd = Int.min
        var shift = 0
        for slice in slices.sorted(by: { $0.start < $1.start }) {
            if slice.start > clusterEnd {
                let start = Self.offset(atLeast: compacted.count, onTheBoundaryOf: slice.start)
                compacted.append(contentsOf: repeatElement(0, count: start - compacted.count))
                shift = slice.start - start
                clusterEnd = slice.start
            }
            if slice.end > clusterEnd {
                let base = binary.startIndex
                compacted.append(binary[base + clusterEnd ..< base + slice.end])
                clusterEnd = slice.end
            }
            placements[slice.key] = slice.start - shift
        }
        return (compacted, placements)
    }

    /// The first offset at or after `offset` on the four byte boundary
    /// `original` sits on, which is never past `original` itself.
    private static func offset(atLeast offset: Int, onTheBoundaryOf original: Int) -> Int {
        offset + (((original - offset) % 4) + 4) % 4
    }

    private static func relocated(_ view: JSONObject,
                                  at index: Int,
                                  to placements: [BinarySliceKey: Int]) -> JSONObject {
        var view = view
        view.relocateSlice(to: placements[BinarySliceKey(view: index, isCompressed: false)])
        view.withObject("extensions") { extensions in
            extensions.withObject(GLTFExtension.meshoptCompression.rawValue) {
                $0.relocateSlice(to: placements[BinarySliceKey(view: index, isCompressed: true)])
            }
        }
        return view
    }
}

/// Where each entry a document keeps lands once the ones it has stopped using
/// are taken out of the arrays.
private struct GLTFCompaction {
    /// The old indices each array keeps, in order.
    private var keeping: [GLTFArray: [Int]] = [:]
    /// The new index of each old one, and no entry at all for what went.
    private var moved: [GLTFArray: [Int: Int]] = [:]
    /// The nodes still drawing, which is what a binding to what a node draws asks
    /// about rather than whether the node itself survived.
    private let drawn: Set<Int>

    init(of json: JSONObject, keeping reachability: GLTFReachability) {
        drawn = reachability.drawn
        // The one buffer a GLB holds is written from the BIN buffer's length
        // rather than indexed through this.
        for array in GLTFArray.allCases where array != .buffers {
            let kept = (0 ..< json.count(array)).filter { reachability.contains($0, in: array) }
            keeping[array] = kept
            moved[array] = Dictionary(uniqueKeysWithValues: kept.enumerated().map { ($1, $0) })
        }
    }

    func kept(_ array: GLTFArray) -> [Int] { keeping[array] ?? [] }

    /// Whether the node at an old index is one the scenes still reach.
    func draws(_ node: Int) -> Bool { drawn.contains(node) }

    /// Where a reference lands, or nothing when what it named is gone.
    var map: GLTFIndexMap {
        { [moved, drawn] array, index, kind in
            switch kind {
            case .drawnSubject: drawn.contains(index) ? moved[array]?[index] : nil
            case .hierarchy, .plain: moved[array]?[index]
            }
        }
    }

    /// VRM 0.x keeps a shading entry per material, in the same order, so the
    /// array is filtered alongside the materials rather than by a reference.
    func filterMaterialProperties(of vrm0: inout JSONObject) {
        guard let properties = vrm0["materialProperties"] as? [JSONObject] else { return }
        let kept = kept(.materials).compactMap { properties[safe: $0] }
        vrm0.set("materialProperties", kept.isEmpty ? nil : kept)
    }
}

/// One of the two slices of the BIN buffer a buffer view can hold bytes in: its
/// own, and the compressed one `EXT_meshopt_compression` adds to it.
private struct BinarySliceKey: Hashable {
    let view: Int
    let isCompressed: Bool
}

private struct BinarySlice {
    let key: BinarySliceKey
    let start: Int
    let length: Int
    var end: Int { start + length }
}

private extension JSONObject {
    /// Rewrites where a slice starts. One that did not move is left as it was
    /// written, so a document with nothing to reclaim comes out of ``prune()``
    /// unchanged.
    mutating func relocateSlice(to offset: Int?) {
        guard let offset else {
            removeValue(forKey: "byteOffset")
            return
        }
        guard offset != int("byteOffset") ?? 0 else { return }
        setNonZero("byteOffset", offset)
    }
}
