import Foundation
import Testing
import simd
import VRMTestSupport
@testable import VRMKit

/// Writing an animation, and the humanoid skeleton a `.vrma` animates, into a document.
@Suite
struct GLTFAnimationAuthoringTests {
    // MARK: - Animation

    /// What `addAnimation` writes has to read back as what it was given: a sampler and
    /// channel per track, over accessors holding the keyframes.
    @Test
    func testTracksRoundTripThroughAGLB() throws {
        var document = GLTFEditableDocument()
        let node = try document.addNode(name: "bone")
        let turned = simd_quatf(angle: .pi / 2, axis: SIMD3<Float>(0, 1, 0))

        let index = try document.addAnimation(name: "wave", tracks: [
            GLTFAnimationTrack(node: node, times: [0, 0.5], values: .rotation([quat_identity_float, turned])),
            GLTFAnimationTrack(node: node, times: [0, 1], values: .translation([.zero, SIMD3(0, 1, 0)]),
                               interpolation: .STEP),
        ])

        #expect(index == 0)
        let saved = try GLTFDocument(data: try document.serialize())
        let animation = try #require(saved.gltf.animations[safe: 0])
        #expect(animation.name == "wave")
        #expect(animation.channels.count == 2)
        #expect(animation.samplers.count == 2)
        #expect(animation.channels[0].target.node == node.rawValue)
        #expect(animation.channels[0].target.targetPath == .rotation)
        #expect(animation.channels[1].target.targetPath == .translation)
        #expect(animation.samplers[0].interpolation == .LINEAR)
        #expect(animation.samplers[1].interpolation == .STEP)

        let rotations = try saved.floats(accessorAt: animation.samplers[0].output)
        #expect(rotations.count == 8)
        #expect(SIMD4(rotations[4], rotations[5], rotations[6], rotations[7]).isApproximatelyEqual(to: turned.vector))
        #expect(try saved.floats(accessorAt: animation.samplers[1].input) == [0, 1])
        #expect(try saved.floats(accessorAt: animation.samplers[1].output) == [0, 0, 0, 0, 1, 0])
    }

    /// glTF requires the bounds of a sampler input, and forbids a GPU target on data
    /// that is not vertex data.
    @Test
    func testTheInputAccessorCarriesItsBoundsAndNoTarget() throws {
        var document = GLTFEditableDocument()
        let node = try document.addNode()

        try document.addAnimation(tracks: [
            GLTFAnimationTrack(node: node, times: [0.25, 2], values: .scale([.one, .one * 2])),
        ])

        let saved = try GLTFDocument(data: try document.serialize())
        let sampler = try #require(saved.gltf.animations.first?.samplers.first)
        let input = try #require(saved.gltf.accessors[safe: sampler.input])
        #expect(input.min == [0.25])
        #expect(input.max == [2])
        #expect(saved.gltf.bufferViews.allSatisfy { $0.target == nil })
    }

    /// Only interpolation other than the default is written; a sampler naming none
    /// reads as LINEAR.
    @Test
    func testLinearInterpolationIsLeftUnwritten() throws {
        var document = GLTFEditableDocument()
        let node = try document.addNode()

        try document.addAnimation(tracks: [
            GLTFAnimationTrack(node: node, times: [0], values: .rotation([quat_identity_float])),
        ])

        let json = try #require(try JSONValue(parsing: JSONValue.object(document.json).serialized()).objectValue)
        let sampler = try #require(json.objects(.animations).first?.objects("samplers").first)
        #expect(sampler["interpolation"] == nil)
    }

    @Test
    func testATrackGLTFCannotDescribeIsRefused() throws {
        var document = GLTFEditableDocument()
        let node = try document.addNode()
        let before = document

        #expect(throws: VRMError.self) {
            try document.addAnimation(tracks: [])
        }
        #expect(throws: VRMError.self) {
            try document.addAnimation(tracks: [
                GLTFAnimationTrack(node: node, times: [0, 1], values: .rotation([quat_identity_float])),
            ])
        }
        #expect(throws: VRMError.self) {
            try document.addAnimation(tracks: [
                GLTFAnimationTrack(node: node, times: [1, 1], values: .translation([.zero, .zero])),
            ])
        }
        #expect(throws: VRMError.self) {
            try document.addAnimation(tracks: [
                GLTFAnimationTrack(node: node, times: [0, 1], values: .translation([.zero, .zero]),
                                   interpolation: .CUBICSPLINE),
            ])
        }
        #expect(throws: VRMError.self) {
            try document.addAnimation(tracks: [
                GLTFAnimationTrack(node: 5, times: [0], values: .translation([.zero])),
            ])
        }
        #expect(throws: VRMError.self) {
            try document.addAnimation(tracks: [
                GLTFAnimationTrack(node: node, times: [0], values: .translation([SIMD3(.nan, 0, 0)])),
            ])
        }
        #expect(document.json == before.json)
        #expect(document.binary == before.binary)
    }

    // MARK: - Rest skeleton

    /// The copy keeps the bones' names and local transforms, so it rests where the
    /// model does, and hangs them under one root the model did not have.
    @Test
    func testTheRestSkeletonCopiesTheHumanoidNodesOfAVRM1Model() throws {
        let vrm = try VRM(data: VRMSampleAsset.seedSan.data)
        var document = GLTFEditableDocument()

        let skeleton = try document.addRestSkeleton(of: vrm)

        #expect(skeleton.bones.count == vrm.boneNodes.count)
        let saved = try GLTFDocument(data: try document.serialize())
        let nodes = saved.gltf.nodes
        let source = vrm.document.gltf.nodes
        for (bone, index) in skeleton.bones {
            let sourceNode = try #require(vrm.boneNodes[bone].map { source[$0] })
            let node = try #require(nodes[safe: index.rawValue])
            #expect(node.name == sourceNode.name)
            #expect(node.translation.isApproximatelyEqual(to: sourceNode.translation))
            #expect(node.rotation.isApproximatelyEqual(to: sourceNode.rotation))
            #expect(node.mesh == nil)
            #expect(node.skin == nil)
        }
        // A 1.0 model already faces the way a `.vrma` is authored in.
        let root = try #require(nodes[safe: skeleton.root.rawValue])
        #expect(root.rotation == SIMD4(0, 0, 0, 1))
        #expect(saved.gltf.scenes.first?.nodes == [skeleton.root.rawValue])
        // Bones, their ancestors and the root: nothing else.
        let hierarchy = try GLTFNodeHierarchy(nodes: source)
        let kept = Set(vrm.boneNodes.values.flatMap(hierarchy.lineage(of:)))
        #expect(nodes.count == kept.count + 1)
    }

    /// The hips rest above the root in world space where they rest in the model, so
    /// every node between the two came along with its transform.
    @Test
    func testTheRestSkeletonRestsWhereTheModelDoes() throws {
        let vrm = try VRM(data: VRMSampleAsset.seedSan.data)
        var document = GLTFEditableDocument()

        let skeleton = try document.addRestSkeleton(of: vrm)

        let saved = try GLTFDocument(data: try document.serialize())
        let hips = try #require(skeleton.bones[.hips])
        let copied = try saved.gltf.worldMatrix(at: hips.rawValue)
        let original = try vrm.document.gltf.worldMatrix(at: try #require(vrm.boneNodes[.hips]))
        #expect(copied.isApproximatelyEqual(to: original))
    }

    /// A 0.x model faces -Z, the other way than a `.vrma` is authored in, so its copy
    /// is turned about at the root while the bones keep their own local transforms.
    @Test
    func testTheRestSkeletonOfAVRM0ModelIsTurnedToFacePlusZ() throws {
        let vrm = try VRM(data: VRMSampleAsset.aliciaSolid.data)
        var document = GLTFEditableDocument()

        let skeleton = try document.addRestSkeleton(of: vrm)

        let saved = try GLTFDocument(data: try document.serialize())
        let root = try #require(saved.gltf.nodes[safe: skeleton.root.rawValue])
        let facing = simd_quatf(angle: .pi, axis: SIMD3<Float>(0, 1, 0))
        #expect(abs(simd_dot(simd_quatf(vector: root.rotation), facing)) > 0.9999)
        let hips = try #require(skeleton.bones[.hips])
        let sourceHips = try #require(vrm.boneNodes[.hips].map { vrm.document.gltf.nodes[$0] })
        let copiedHips = try #require(saved.gltf.nodes[safe: hips.rawValue])
        #expect(copiedHips.rotation.isApproximatelyEqual(to: sourceHips.rotation))
        // Turned about Y, the hips stand at the same height and mirrored in X and Z.
        let copied = try saved.gltf.worldMatrix(at: hips.rawValue).translation
        let original = try vrm.document.gltf.worldMatrix(at: try #require(vrm.boneNodes[.hips])).translation
        #expect(copied.isApproximatelyEqual(to: SIMD3(-original.x, original.y, -original.z)))
    }

    // MARK: - VRMC_vrm_animation

    /// The extension written reads back through the same parser any `.vrma` does.
    @Test
    func testTheHumanoidIsDeclaredAsAVRMAnimation() throws {
        let vrm = try VRM(data: VRMSampleAsset.seedSan.data)
        var document = GLTFEditableDocument()
        let skeleton = try document.addRestSkeleton(of: vrm)
        try document.addAnimation(tracks: [
            GLTFAnimationTrack(node: try #require(skeleton.bones[.hips]), times: [0],
                               values: .rotation([quat_identity_float])),
        ])

        try document.setVRMAnimationHumanoid(skeleton.bones)

        let animation = try VRMAnimation(data: try document.serialize())
        #expect(animation.specVersion == "1.0")
        #expect(animation.humanoid?.humanBones.count == skeleton.bones.count)
        #expect(animation.humanoid?.humanBones["hips"]?.node == skeleton.bones[.hips]?.rawValue)
        #expect(animation.humanoid?.humanBones["leftThumbMetacarpal"]?.node == skeleton.bones[.leftThumbMetacarpal]?.rawValue)
        #expect(animation.document.gltf.extensionsUsed.contains("VRMC_vrm_animation"))
    }

    /// Each expression gets a node named as it is, and the extension names them by
    /// preset and custom name, which is how a reader finds the weight tracks.
    @Test
    func testExpressionNodesAreDeclaredAsVRMAnimationExpressions() throws {
        let vrm = try VRM(data: VRMSampleAsset.seedSan.data)
        var document = GLTFEditableDocument()
        let skeleton = try document.addRestSkeleton(of: vrm)

        let nodes = try document.addExpressionNodes(preset: ["happy", "blink"], custom: ["Wink"])
        try document.addAnimation(tracks: [
            GLTFAnimationTrack(node: try #require(nodes.preset["happy"]), times: [0],
                               values: .translation([SIMD3(0.75, 0, 0)])),
        ])
        try document.setVRMAnimationHumanoid(skeleton.bones)
        try document.setVRMAnimationExpressions(nodes)

        let animation = try VRMAnimation(data: try document.serialize())
        #expect(animation.humanoid?.humanBones.count == skeleton.bones.count)
        let expressions = try #require(animation.expressions)
        #expect(expressions.preset?["happy"]?.node == nodes.preset["happy"]?.rawValue)
        #expect(expressions.preset?["blink"]?.node == nodes.preset["blink"]?.rawValue)
        #expect(expressions.custom?["Wink"]?.node == nodes.custom["Wink"]?.rawValue)
        let gltfNodes = animation.document.gltf.nodes
        #expect(gltfNodes[safe: try #require(nodes.custom["Wink"]).rawValue]?.name == "Wink")
        // The three hang under one node of their own, apart from the skeleton.
        let holder = try #require(gltfNodes.first { $0.name == "expressions" })
        #expect(Set(holder.children ?? []) == Set((Array(nodes.preset.values) + Array(nodes.custom.values)).map(\.rawValue)))
        #expect(animation.document.gltf.scenes.first?.nodes?.count == 2)
    }

    /// Two expressions cannot share a name, an expression cannot go nameless, and a
    /// node has to exist to be declared.
    @Test
    func testMalformedExpressionsAreRefused() throws {
        var document = GLTFEditableDocument()
        let node = try document.addNode()
        let before = document

        #expect(throws: VRMError.self) {
            try document.addExpressionNodes(preset: ["happy"], custom: ["happy"])
        }
        #expect(throws: VRMError.self) {
            try document.addExpressionNodes(preset: [""], custom: [])
        }
        #expect(throws: VRMError.self) {
            try document.setVRMAnimationExpressions(GLTFExpressionNodes(preset: ["happy": 7], custom: [:]))
        }
        #expect(document.json == before.json)
        _ = node
    }

    @Test
    func testAHumanoidWithoutHipsOrWithAMissingNodeIsRefused() throws {
        var document = GLTFEditableDocument()
        let node = try document.addNode()
        let before = document

        #expect(throws: VRMError.self) {
            try document.setVRMAnimationHumanoid([.spine: node])
        }
        #expect(throws: VRMError.self) {
            try document.setVRMAnimationHumanoid([.hips: 3])
        }
        #expect(document.json == before.json)
    }
}

// MARK: - Reading back

private extension GLTFDocument {
    func floats(accessorAt index: Int) throws -> [Float] {
        let accessor = try #require(gltf.accessors[safe: index])
        let packed = try PackedAccessor(accessor: accessor) { index in
            let view = try bufferViewData(at: index)
            return (view.data, view.stride)
        }
        return packed.floatComponents()
    }
}

private extension GLTF {
    /// A node's rest transform in world space, its parents' folded in.
    func worldMatrix(at index: Int) throws -> simd_float4x4 {
        let hierarchy = try GLTFNodeHierarchy(nodes: nodes)
        return hierarchy.lineage(of: index).reversed().reduce(matrix_identity_float4x4) { world, node in
            world * GLTFNodeTransform(node: nodes[node]).matrix
        }
    }
}
