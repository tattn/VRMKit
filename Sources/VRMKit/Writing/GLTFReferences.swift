import Foundation

/// What a reference wants with the entry it names, which is what decides
/// whether the entry outlives what draws it.
enum GLTFReferenceKind {
    /// A scene's `nodes` or a node's `children`: the hierarchy a renderer draws.
    case hierarchy
    /// Names an entry for itself, the way a skin names its joints, a humanoid
    /// its bones or a mesh its material.
    case plain
    /// Names a node for what it draws rather than for itself: a VRM 1.0
    /// expression's morph bind, a first-person annotation, an animation
    /// channel's target. Worth nothing once the node has stopped drawing, so
    /// it goes when the drawing does.
    case drawnSubject
}

/// The index to write in place of one the document holds, or nil when what it
/// named is gone. Reading a document's references is the same walk with a map
/// that records the index and keeps it.
typealias GLTFIndexMap = (GLTFArray, Int, GLTFReferenceKind) -> Int?

/// Every index a glTF or VRM document holds into its top-level arrays, written
/// down once so that merging, pruning and reachability cannot disagree about
/// what a reference is: teaching this file about an extension teaches all three.
///
/// A buffer view's `buffer` is not here. Both editing paths put every view on
/// the one buffer a GLB holds, rebasing it by byte offset instead.
enum GLTFReferences {
    /// Rewrites the references one entry of `array` holds. A node the scenes
    /// no longer reach is `drawing: false`, and keeps its transform alone.
    static func rewriting(_ entry: JSONObject,
                          of array: GLTFArray,
                          drawing: Bool = true,
                          with map: GLTFIndexMap) -> JSONObject {
        switch array {
        case .scenes: scene(entry, map)
        case .nodes: node(entry, drawing: drawing, map)
        case .meshes: mesh(entry, map)
        case .skins: skin(entry, map)
        case .materials: material(entry, map)
        case .textures: texture(entry, map)
        case .images: image(entry, map)
        case .accessors: accessor(entry, map)
        case .animations: animation(entry, map)
        // Buffers, buffer views, cameras and samplers name nothing.
        default: entry
        }
    }

    // MARK: - glTF

    private static func scene(_ scene: JSONObject, _ map: GLTFIndexMap) -> JSONObject {
        var scene = scene
        scene.mapIndices("nodes", to: .nodes, as: .hierarchy, map)
        return scene
    }

    private static func node(_ node: JSONObject, drawing: Bool, _ map: GLTFIndexMap) -> JSONObject {
        var node = node
        if drawing {
            node.mapIndices("children", to: .nodes, as: .hierarchy, map)
            node.mapIndex("mesh", to: .meshes, map)
            node.mapIndex("skin", to: .skins, map)
            node.mapIndex("camera", to: .cameras, map)
            // EXT_mesh_gpu_instancing keeps one accessor per instanced attribute.
            node.withObject("extensions") { extensions in
                extensions.withObject(GLTFExtension.meshGPUInstancing.rawValue) {
                    $0.withObject("attributes") { $0.mapIndexValues(to: .accessors, map) }
                }
                extensions.removeEmpty(GLTFExtension.meshGPUInstancing.rawValue, keyedBy: "attributes")
            }
        } else {
            // Nothing this node hung together outlives the drawing of it, and
            // glTF has no node weighting or skinning a mesh it does not draw.
            for key in ["children", "mesh", "skin", "camera", "weights"] {
                node.removeValue(forKey: key)
            }
            node.withObject("extensions") {
                $0.removeValue(forKey: GLTFExtension.meshGPUInstancing.rawValue)
            }
        }
        // A constraint drives this node from another one's transform, which it
        // goes on doing whether or not either of them is drawn.
        node.withObject("extensions") { extensions in
            extensions.withObject(GLTFExtension.nodeConstraint.rawValue) { constraint in
                constraint.withObject("constraint") { sources in
                    for key in Array(sources.keys) {
                        sources.withObject(key) { $0.mapIndex("source", to: .nodes, map) }
                    }
                }
            }
        }
        node.removeEmpty("extensions")
        return node
    }

    private static func mesh(_ mesh: JSONObject, _ map: GLTFIndexMap) -> JSONObject {
        var mesh = mesh
        mesh.mapObjects("primitives") { primitive in
            var primitive = primitive
            primitive.withObject("attributes") { $0.mapIndexValues(to: .accessors, map) }
            primitive.mapIndex("indices", to: .accessors, map)
            primitive.mapIndex("material", to: .materials, map)
            if let targets = primitive["targets"] as? [JSONObject] {
                primitive["targets"] = targets.map { target in
                    var target = target
                    target.mapIndexValues(to: .accessors, map)
                    return target
                }
            }
            primitive.withObject("extensions") { extensions in
                // Draco keeps the primitive in a view of its own, which its
                // attributes index into rather than the accessors.
                extensions.withObject(GLTFExtension.dracoMeshCompression.rawValue) {
                    $0.mapIndex("bufferView", to: .bufferViews, map)
                }
                extensions.withObject(GLTFExtension.materialsVariants.rawValue) {
                    $0.compactMapObjects("mappings") { $0.mappingSurviving("material", to: .materials, map) }
                }
                extensions.removeEmpty(GLTFExtension.materialsVariants.rawValue, keyedBy: "mappings")
            }
            return primitive
        }
        return mesh
    }

    private static func skin(_ skin: JSONObject, _ map: GLTFIndexMap) -> JSONObject {
        var skin = skin
        skin.mapIndex("inverseBindMatrices", to: .accessors, map)
        skin.mapIndex("skeleton", to: .nodes, map)
        skin.mapIndices("joints", to: .nodes, map)
        return skin
    }

    private static func material(_ material: JSONObject, _ map: GLTFIndexMap) -> JSONObject {
        var material = material
        material.mapTextureSlots(map)
        material.withObject("pbrMetallicRoughness") { $0.mapTextureSlots(map) }
        material.withObject("extensions") { extensions in
            for key in Array(extensions.keys) {
                extensions.withObject(key) { $0.mapTextureSlots(map) }
            }
        }
        return material
    }

    private static func texture(_ texture: JSONObject, _ map: GLTFIndexMap) -> JSONObject {
        var texture = texture
        texture.mapIndex("source", to: .images, map)
        texture.mapIndex("sampler", to: .samplers, map)
        texture.withObject("extensions") { extensions in
            for name in [GLTFExtension.textureBasisu, .textureWebP] {
                extensions.withObject(name.rawValue) { $0.mapIndex("source", to: .images, map) }
            }
        }
        return texture
    }

    private static func image(_ image: JSONObject, _ map: GLTFIndexMap) -> JSONObject {
        var image = image
        image.mapIndex("bufferView", to: .bufferViews, map)
        return image
    }

    private static func accessor(_ accessor: JSONObject, _ map: GLTFIndexMap) -> JSONObject {
        var accessor = accessor
        accessor.mapIndex("bufferView", to: .bufferViews, map)
        accessor.withObject("sparse") { sparse in
            sparse.withObject("indices") { $0.mapIndex("bufferView", to: .bufferViews, map) }
            sparse.withObject("values") { $0.mapIndex("bufferView", to: .bufferViews, map) }
        }
        return accessor
    }

    /// An animation's samplers are indexed by its channels alone, so the ones
    /// left behind when a channel goes are compacted here rather than through
    /// the document's arrays, and the surviving channels renumbered onto them.
    private static func animation(_ animation: JSONObject, _ map: GLTFIndexMap) -> JSONObject {
        var animation = animation
        let samplers = animation.objects("samplers")
        var kept: [Int] = []
        var moved: [Int: Int] = [:]
        animation.compactMapObjects("channels") { channel in
            var channel = channel
            var drives = true
            channel.withObject("target") { target in
                drives = target.mapsSurviving("node", to: .nodes, as: .drawnSubject, map)
            }
            guard drives, let sampler = channel.index("sampler"), samplers.indices.contains(sampler) else {
                return nil
            }
            if moved[sampler] == nil {
                moved[sampler] = kept.count
                kept.append(sampler)
            }
            channel["sampler"] = moved[sampler]
            return channel
        }
        guard animation["channels"] != nil else { return animation }
        animation.set("samplers", kept.map { index in
            var sampler = samplers[index]
            sampler.mapIndex("input", to: .accessors, map)
            sampler.mapIndex("output", to: .accessors, map)
            return sampler
        })
        return animation
    }

    // MARK: - VRM

    /// Rewrites what the VRM extensions name from the root of a document. A
    /// binding whose subject is gone goes with it: an expression cannot morph
    /// a mesh the document no longer holds.
    static func rewritingRootExtensions(_ extensions: JSONObject, with map: GLTFIndexMap) -> JSONObject {
        var extensions = extensions
        extensions.withObject(GLTFExtension.vrm0.rawValue) { $0 = vrm0($0, map) }
        extensions.withObject(GLTFExtension.vrm1.rawValue) { $0 = vrm1($0, map) }
        extensions.withObject(GLTFExtension.springBone.rawValue) { $0 = springBone($0, map) }
        extensions.withObject(GLTFExtension.vrmAnimation.rawValue) { $0 = vrmAnimation($0, map) }
        return extensions
    }

    private static func vrm0(_ vrm: JSONObject, _ map: GLTFIndexMap) -> JSONObject {
        var vrm = vrm
        vrm.withObject("meta") { $0.mapIndex("texture", to: .textures, map) }
        // VRM 0.x keeps a material's MToon textures in its own entry beside
        // the material, one slot per Unity property.
        vrm.mapObjects("materialProperties") { property in
            var property = property
            property.withObject("textureProperties") { $0.mapIndexValues(to: .textures, map) }
            return property
        }
        vrm.withObject("humanoid") { $0.mapObjects("humanBones") { $0.mapping("node", to: .nodes, map) } }
        vrm.withObject("blendShapeMaster") {
            $0.mapObjects("blendShapeGroups") { group in
                var group = group
                group.compactMapObjects("binds") { $0.mappingSurviving("mesh", to: .meshes, map) }
                return group
            }
        }
        vrm.withObject("firstPerson") { firstPerson in
            firstPerson.mapIndex("firstPersonBone", to: .nodes, map)
            firstPerson.compactMapObjects("meshAnnotations") { $0.mappingSurviving("mesh", to: .meshes, map) }
        }
        vrm.withObject("secondaryAnimation") { secondary in
            secondary.mapObjects("boneGroups") { group in
                var group = group
                group.mapIndices("bones", to: .nodes, map)
                group.mapIndex("center", to: .nodes, map)
                return group
            }
            secondary.mapObjects("colliderGroups") { $0.mapping("node", to: .nodes, map) }
        }
        return vrm
    }

    private static func vrm1(_ vrm: JSONObject, _ map: GLTFIndexMap) -> JSONObject {
        var vrm = vrm
        vrm.withObject("meta") { $0.mapIndex("thumbnailImage", to: .images, map) }
        vrm.withObject("humanoid") {
            $0.withObject("humanBones") { bones in
                for key in Array(bones.keys) {
                    bones.withObject(key) { $0.mapIndex("node", to: .nodes, map) }
                }
            }
        }
        vrm.withObject("firstPerson") {
            $0.compactMapObjects("meshAnnotations") {
                $0.mappingSurviving("node", to: .nodes, as: .drawnSubject, map)
            }
        }
        vrm.withObject("expressions") { expressions in
            for group in ["preset", "custom"] {
                expressions.withObject(group) { expressions in
                    for key in Array(expressions.keys) {
                        expressions.withObject(key) { $0 = vrm1Expression($0, map) }
                    }
                }
            }
        }
        return vrm
    }

    private static func vrm1Expression(_ expression: JSONObject, _ map: GLTFIndexMap) -> JSONObject {
        var expression = expression
        expression.compactMapObjects("morphTargetBinds") {
            $0.mappingSurviving("node", to: .nodes, as: .drawnSubject, map)
        }
        for key in ["materialColorBinds", "textureTransformBinds"] {
            expression.compactMapObjects(key) { $0.mappingSurviving("material", to: .materials, map) }
        }
        return expression
    }

    private static func springBone(_ springBone: JSONObject, _ map: GLTFIndexMap) -> JSONObject {
        var springBone = springBone
        springBone.mapObjects("colliders") { $0.mapping("node", to: .nodes, map) }
        springBone.mapObjects("springs") { spring in
            var spring = spring
            spring.mapIndex("center", to: .nodes, map)
            spring.mapObjects("joints") { $0.mapping("node", to: .nodes, map) }
            return spring
        }
        return springBone
    }

    private static func vrmAnimation(_ animation: JSONObject, _ map: GLTFIndexMap) -> JSONObject {
        var animation = animation
        animation.withObject("humanoid") {
            $0.withObject("humanBones") { bones in
                for key in Array(bones.keys) {
                    bones.withObject(key) { $0.mapIndex("node", to: .nodes, map) }
                }
            }
        }
        animation.withObject("expressions") { expressions in
            for group in ["preset", "custom"] {
                expressions.withObject(group) { expressions in
                    for key in Array(expressions.keys) {
                        expressions.withObject(key) { $0.mapIndex("node", to: .nodes, map) }
                    }
                }
            }
        }
        animation.withObject("lookAt") { $0.mapIndex("node", to: .nodes, map) }
        return animation
    }
}

private extension JSONObject {
    mutating func mapIndex(_ key: String,
                           to array: GLTFArray,
                           as kind: GLTFReferenceKind = .plain,
                           _ map: GLTFIndexMap) {
        guard let index = index(key) else { return }
        set(key, map(array, index, kind))
    }

    mutating func mapIndices(_ key: String,
                             to array: GLTFArray,
                             as kind: GLTFReferenceKind = .plain,
                             _ map: GLTFIndexMap) {
        guard let indices = ints(key) else { return }
        let remaining = indices.compactMap { map(array, $0, kind) }
        set(key, remaining.isEmpty ? nil : remaining)
    }

    /// Every value is an index, which is how glTF spells a primitive's
    /// attributes and a morph target's.
    mutating func mapIndexValues(to array: GLTFArray, _ map: GLTFIndexMap) {
        for key in Array(keys) {
            mapIndex(key, to: array, map)
        }
    }

    /// Every `textureInfo` directly under this object.
    mutating func mapTextureSlots(_ map: GLTFIndexMap) {
        for key in textureSlotKeys {
            withObject(key) { $0.mapIndex("index", to: .textures, map) }
        }
    }

    /// The same object with one reference rewritten.
    func mapping(_ key: String, to array: GLTFArray, _ map: GLTFIndexMap) -> JSONObject {
        var object = self
        object.mapIndex(key, to: array, map)
        return object
    }

    /// The same object, or nil when the entry it names is gone and the binding
    /// has nothing left to describe.
    func mappingSurviving(_ key: String,
                          to array: GLTFArray,
                          as kind: GLTFReferenceKind = .plain,
                          _ map: GLTFIndexMap) -> JSONObject? {
        var object = self
        return object.mapsSurviving(key, to: array, as: kind, map) ? object : nil
    }

    /// Rewrites one reference and says whether what it named is still there.
    mutating func mapsSurviving(_ key: String,
                                to array: GLTFArray,
                                as kind: GLTFReferenceKind = .plain,
                                _ map: GLTFIndexMap) -> Bool {
        guard let index = index(key) else { return true }
        guard let mapped = map(array, index, kind) else { return false }
        self[key] = mapped
        return true
    }

    /// Drops an extension whose only content was references that have gone,
    /// rather than leave it holding nothing.
    mutating func removeEmpty(_ name: String, keyedBy key: String) {
        guard let carried = object(name), carried[key] == nil else { return }
        removeValue(forKey: name)
    }

    /// Drops the object at `key` once it holds nothing.
    mutating func removeEmpty(_ key: String) {
        guard object(key)?.isEmpty == true else { return }
        removeValue(forKey: key)
    }

    mutating func compactMapObjects(_ key: String, _ transform: (JSONObject) -> JSONObject?) {
        guard self[key] != nil else { return }
        let remaining = objects(key).compactMap(transform)
        set(key, remaining.isEmpty ? nil : remaining)
    }
}
