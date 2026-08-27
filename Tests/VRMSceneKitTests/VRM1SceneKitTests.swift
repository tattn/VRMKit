import VRMKit
import VRMTestSupport
@testable import VRMSceneKit
import SceneKit
import simd
import Testing

@Suite
struct VRM1SceneLoaderTests {

    func vrmLoader() throws -> VRMSceneLoader {
        try VRMSceneLoader(withURL: VRMSampleAsset.seedSan.url)
    }

    @Test
    func testLoadVRM1() throws {
        let vrmLoader = try vrmLoader()
        let vrm = vrmLoader.vrm
        guard case .v1(let vrm1) = vrm else {
            throw VRMError.dataInconsistent("Expected VRM1")
        }
        let gltf = vrm1.document.gltf

        #expect(vrm1.meta.name == "Seed-san")
        #expect(gltf.asset.version == "2.0")
        let buffers = gltf.buffers
        #expect(buffers.map(\.byteLength) == [10783033])
        let bufferViews = gltf.bufferViews
        #expect(bufferViews.count == 404)
        #expect(gltf.scene == 0)
        let scenes = gltf.scenes
        #expect(scenes.map(\.nodes).map(\.?.count) == [7])

        let thumbnail = try vrmLoader.loadThumbnail()
        #expect(thumbnail.size == CGSize(width: 512, height: 512))
    }

    @Test
    func testBufferAccess() throws {
        let vrmLoader = try vrmLoader()
        let result = try vrmLoader.document.bufferViewData(at: 0)
        #expect(result.data.count == 93840)
    }

    @Test
    func testVRM1NativeExpressionBindingsUseNodes() throws {
        let vrmLoader = try vrmLoader()
        let scene = try vrmLoader.loadScene()
        let vrmNode = scene.vrmNode

        #expect(vrmNode.expressionClips.count == 18)
        #expect(vrmNode.expressionClips[.preset(.happy)]?.values.isEmpty == false)
        #expect(vrmNode.expressionClips[.preset(.aa)]?.values.first?.index == 25)

        vrmNode.setExpression(value: 0.42, for: .preset(.aa))
        #expect(abs(vrmNode.expression(for: .preset(.aa)) - 0.42) < 0.001)
    }

    @Test
    func testExpressionReturnsInputWeightRatherThanScaledMorphWeight() throws {
        let data = try VRMSampleAsset.seedSan.rewritingJSON { json in
            guard var extensions = json.object("extensions"),
                  var vrm = extensions.object("VRMC_vrm"),
                  var expressions = vrm.object("expressions"),
                  var preset = expressions.object("preset"),
                  var aa = preset.object("aa"),
                  case var binds = aa.objects("morphTargetBinds"),
                  !binds.isEmpty else {
                throw VRMError.dataInconsistent("Missing Seed-san expression fixture data")
            }
            binds[0]["weight"] = 0.25
            aa["morphTargetBinds"] = .objects(binds)
            preset["aa"] = .object(aa)
            expressions["preset"] = .object(preset)
            vrm["expressions"] = .object(expressions)
            extensions["VRMC_vrm"] = .object(vrm)
            json["extensions"] = .object(extensions)
        }
        let loader = try VRMSceneLoader(withData: data)
        let vrmNode = try loader.loadScene().vrmNode
        let binding = try #require(vrmNode.expressionClips[.preset(.aa)]?.values.first)

        vrmNode.setExpression(value: 0.8, for: .preset(.aa))

        #expect(abs(vrmNode.expression(for: .preset(.aa)) - 0.8) < 0.001)
        #expect(abs(binding.mesh.weight(forTargetAt: binding.index) - 0.2) < 0.001)
    }

    /// A `thirdPersonOnly` mesh goes in first person. What goes is the mesh, not the node
    /// drawing it, so the nodes hanging off that one keep drawing.
    @Test
    func testVRM1ThirdPersonOnlyMeshIsHiddenInFirstPerson() throws {
        let vrmLoader = try vrmLoader()
        let scene = try vrmLoader.loadScene()
        let annotatedNode = try vrmLoader.node(withNodeIndex: 0)
        let mesh = try #require(annotatedNode.childNodes.first)

        #expect(mesh.isHidden == false)
        scene.vrmNode.setFirstPersonRenderMode(.firstPerson)
        #expect(mesh.isHidden == true)
        #expect(annotatedNode.isHidden == false)
        scene.vrmNode.setFirstPersonRenderMode(.thirdPerson)
        #expect(mesh.isHidden == false)
    }

    @Test
    func testVRM1MToonMaterialIsLoadedFromExtension() throws {
        let vrmLoader = try vrmLoader()
        let material = try vrmLoader.material(withMaterialIndex: 0)
        let gltfMaterial = try #require(vrmLoader.vrm.document.gltf.materials[safe: 0])

        #expect(material.name == gltfMaterial.name)
        #expect(material.lightingModel == .constant)
        #expect(material.isLitPerPixel == false)
        #expect(material.writesToDepthBuffer == true)
    }

    @Test
    func testVRM1NodeConstraintRotationIsApplied() throws {
        let vrmLoader = try vrmLoader()
        let scene = try vrmLoader.loadScene()
        let target = try vrmLoader.node(withNodeIndex: 14)
        let source = try vrmLoader.node(withNodeIndex: 82)

        let targetRest = target.simdOrientation
        let sourceRest = source.simdOrientation
        let sourceDelta = simd_quatf(angle: 0.35, axis: simd_normalize(SIMD3<Float>(0.2, 0.9, 0.3)))
        source.simdOrientation = sourceRest * sourceDelta

        scene.vrmNode.update(at: 0)

        let expected = targetRest * (simd_inverse(sourceRest) * source.simdOrientation)
        #expect(target.simdOrientation.isApproximatelyEqual(to: expected))
    }
}

private extension simd_quatf {
    func isApproximatelyEqual(to other: simd_quatf, tolerance: Float = 0.0001) -> Bool {
        abs(simd_dot(vector, other.vector)) > 1.0 - tolerance
    }
}
