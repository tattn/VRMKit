import Foundation

extension GLTFEditableDocument {
    /// Adds a VRM 0.x bone group, so that everything below its root bones swings,
    /// and returns the index of the group. Nothing already in the document moves,
    /// and a model whose bone groups are not an array to append to is refused
    /// rather than written over.
    @discardableResult
    public mutating func addVRM0SpringBone(_ group: VRM0SpringBoneGroup) throws -> Int {
        try requireVRMSpecVersion(.v0, forWriting: "a secondaryAnimation bone group")
        let colliderGroupCount = try existingVRM0ColliderGroupCount()
        guard !group.rootBones.isEmpty else {
            throw VRMError._dataInconsistent("a VRM 0.x bone group swings what hangs below its bones, "
                                             + "so it needs at least one of them")
        }
        for bone in group.rootBones {
            try requireNode(at: bone)
        }
        try VRMSpringBoneParameters.requireFiniteNonnegative(group.stiffness, named: "stiffness")
        try VRMSpringBoneParameters.requireFiniteNonnegative(group.gravityPower, named: "gravity power")
        try VRMSpringBoneParameters.requireFiniteNonnegative(group.hitRadius, named: "hit radius")
        try VRMSpringBoneParameters.requireDragForce(group.dragForce)
        try VRMSpringBoneParameters.requireFinite(group.gravityDirection, named: "gravity direction")
        if let center = group.center {
            try requireNode(at: center)
        }
        try requireColliderGroups(group.colliderGroups, available: colliderGroupCount)

        return try updateRootExtension(GLTFExtension.vrm0.rawValue) { vrm in
            var secondaryAnimation = vrm.object(Self.vrm0SpringBonesKey) ?? [:]
            let index = secondaryAnimation.appendObject(group.json(), to: "boneGroups")
            vrm[Self.vrm0SpringBonesKey] = .object(secondaryAnimation)
            return index
        }
    }

    /// Adds a `VRMC_springBone` spring and returns its index. What a spring may
    /// swing is decided against the springs already there, so a model whose own
    /// springs cannot be read is refused rather than added to.
    @discardableResult
    public mutating func addVRM1SpringBone(_ spring: VRM1Spring) throws -> Int {
        try requireVRMSpecVersion(.v1, forWriting: "a VRMC_springBone spring")
        let existing = try existingVRM1Springs()
        for joint in spring.joints {
            for parameter in joint.statedParameters {
                try VRMSpringBoneParameters.requireFiniteNonnegative(parameter.value, named: parameter.name)
            }
            if let dragForce = joint.dragForce {
                try VRMSpringBoneParameters.requireDragForce(dragForce)
            }
            if let gravityDirection = joint.gravityDirection {
                try VRMSpringBoneParameters.requireFinite(gravityDirection, named: "gravity direction")
            }
        }
        try requireColliderGroups(spring.colliderGroups, available: existing.colliderGroups)
        try validateChain(of: spring, against: existing.springs)

        return try updateRootExtension(GLTFExtension.springBone.rawValue) { springBone in
            springBone["specVersion"] = .string(Self.writableSpecVersion)
            return springBone.appendObject(spring.json(), to: "springs")
        }
    }

    /// Where a VRM 0.x model keeps its spring bones, inside its own extension.
    /// A VRM 1.0 model keeps them in ``GLTFExtension/springBone`` beside it.
    private static let vrm0SpringBonesKey = "secondaryAnimation"

    private mutating func requireVRMSpecVersion(_ required: VRMSpecVersion, forWriting subject: String) throws {
        let version = try vrmSpecVersion()
        guard version == required else {
            throw VRMError._notSupported(
                "\(subject) belongs to a \(required.displayName) model, and this document is \(version.displayName)"
            )
        }
    }

    // MARK: - What the document already swings

    /// What adding a spring has to know about the ones already there: the nodes
    /// each swings, so that no two claim one, and how many collider groups a new
    /// spring may name.
    private mutating func existingVRM1Springs() throws -> (springs: [[Int]], colliderGroups: Int) {
        let name = GLTFExtension.springBone.rawValue
        guard let object = try rootExtensionObject(name) else { return ([], 0) }
        // The extension carries its own version rather than the model's.
        try requireWritableSpecVersion(of: object, named: name)
        let springs = try (object.requiredObjects("springs", of: name) ?? []).map { spring in
            try (spring.requiredObjects("joints", of: "\(name).springs") ?? []).map { joint in
                try joint.index("node") ??? ._dataInconsistent("\(name) has a spring joint naming no node")
            }
        }
        return (springs, try object.requiredObjects("colliderGroups", of: name)?.count ?? 0)
    }

    /// How many collider groups a VRM 0.x bone group may name. A 0.x group
    /// swings what hangs below its roots, so it has nothing to keep clear of.
    private mutating func existingVRM0ColliderGroupCount() throws -> Int {
        let name = "\(GLTFExtension.vrm0.rawValue).\(Self.vrm0SpringBonesKey)"
        guard let vrm = try rootExtensionObject(GLTFExtension.vrm0.rawValue),
              let secondaryAnimation = try vrm.requiredObject(Self.vrm0SpringBonesKey,
                                                              of: GLTFExtension.vrm0.rawValue) else { return 0 }
        // Read for its shape alone: appending to something that is not an array
        // of groups would throw away whatever it holds.
        _ = try secondaryAnimation.requiredObjects("boneGroups", of: name)
        return try secondaryAnimation.requiredObjects("colliderGroups", of: name)?.count ?? 0
    }

    // MARK: - Parameters

    private mutating func requireColliderGroups(_ groups: [Int], available: Int) throws {
        for group in groups {
            guard group >= 0, group < available else {
                throw VRMError._dataInconsistent(
                    "collider group \(group) is out of range for the \(available) groups of the document, "
                    + "and adding a spring does not author colliders"
                )
            }
        }
    }

    // MARK: - What `VRMC_springBone` says a chain is

    /// Refuses a chain `VRMC_springBone` does not accept: its joints run down
    /// one line of the hierarchy, no two springs swing the same node, and the
    /// center is an ancestor of the first joint that nothing else swings.
    private func validateChain(of spring: VRM1Spring, against existing: [[Int]]) throws {
        let joints = spring.joints.map(\.node)
        guard let root = joints.first else {
            throw VRMError._dataInconsistent("a spring names at least one joint")
        }
        guard Set(joints).count == joints.count else {
            throw VRMError._dataInconsistent(
                "a spring names the same node twice, and its joints run down a line of the hierarchy"
            )
        }
        let hierarchy = try nodeHierarchy()
        let chain = try springChain(joints: joints, in: hierarchy)
        let occupied = try existing.reduce(into: Set<Int>()) { occupied, joints in
            occupied.formUnion(try springChain(joints: joints, in: hierarchy))
        }
        if let shared = chain.first(where: occupied.contains) {
            throw VRMError._dataInconsistent(
                "node \(shared) already swings on a spring of the document, and a node belongs to one spring. "
                + "A node between two joints is part of the chain even where the spring does not name it"
            )
        }
        try validateCenter(spring.center, root: root, in: hierarchy, occupied: occupied)
    }

    /// The nodes a spring occupies: the joints it names, and the ones skipped
    /// between them, which `VRMC_springBone` counts as part of the chain. Throws
    /// when a joint is not a node of the document, or not below the joint before it.
    private func springChain(joints: [Int], in hierarchy: GLTFNodeHierarchy) throws -> Set<Int> {
        guard let root = joints.first else { return [] }
        try requireNode(at: root)
        var chain: Set<Int> = [root]
        for (ancestor, descendant) in zip(joints, joints.dropFirst()) {
            try requireNode(at: descendant)
            guard let path = hierarchy.path(from: ancestor, to: descendant) else {
                throw VRMError._dataInconsistent(
                    "node \(descendant) is not below node \(ancestor), and a spring swings a line of nodes "
                    + "the hierarchy runs down"
                )
            }
            chain.formUnion(path)
        }
        return chain
    }

    /// Refuses a center the extension cannot measure a swing against.
    private func validateCenter(_ center: Int?,
                                root: Int,
                                in hierarchy: GLTFNodeHierarchy,
                                occupied: Set<Int>) throws {
        guard let center else { return }
        try requireNode(at: center)
        guard hierarchy.lineage(of: root).contains(center) else {
            throw VRMError._dataInconsistent(
                "node \(center) is neither node \(root) nor one of its ancestors, and a spring is measured "
                + "against something it hangs off"
            )
        }
        if let swung = hierarchy.lineage(of: center).first(where: occupied.contains) {
            throw VRMError._dataInconsistent(
                "node \(center) is swung by a spring of the document, itself or through node \(swung), "
                + "so it does not stand still enough to measure a swing against"
            )
        }
    }
}
