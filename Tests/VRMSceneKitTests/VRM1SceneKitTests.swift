import VRMKit
@testable import VRMSceneKit
import SceneKit
import simd
import Testing

@Suite
struct VRM1SceneLoaderTests {

    func vrmLoader() throws -> VRMSceneLoader {
        let url = try #require(Bundle.module.url(forResource: "Seed-san", withExtension: "vrm"), "Failed to load Seed-san.vrm resource from test bundle.")
        return try VRMSceneLoader(withURL: url)
    }

    func constraintTwistSampleLoader() throws -> VRMSceneLoader {
        let url = try #require(Bundle.module.url(forResource: "VRM1_Constraint_Twist_Sample", withExtension: "vrm"), "Failed to load VRM1_Constraint_Twist_Sample.vrm resource from test bundle.")
        return try VRMSceneLoader(withURL: url)
    }

    @Test
    func testLoadVRM1() throws {
        let vrmLoader = try vrmLoader()
        let vrm = vrmLoader.vrm
        guard case .v1(let vrm1) = vrm else {
            throw VRMError.dataInconsistent("Expected VRM1")
        }
        let gltf = vrm1.gltf.jsonData

        #expect(vrm1.meta.name == "Seed-san")
        #expect(gltf.asset.version == "2.0")
        let buffers = try #require(gltf.buffers, "GLTF buffers should not be nil")
        #expect(buffers.map(\.byteLength) == [10783033])
        let bufferViews = try #require(gltf.bufferViews, "GLTF bufferViews should not be nil")
        #expect(bufferViews.count == 404)
        #expect(gltf.scene == 0)
        let scenes = try #require(gltf.scenes, "GLTF scenes should not be nil")
        #expect(scenes.map(\.nodes).map(\.?.count) == [7])

        let loadedThumbnail = try vrmLoader.loadThumbnail()
        let thumbnail = try #require(loadedThumbnail, "Thumbnail should be loadable and not nil.")
        #expect(thumbnail.size == CGSize(width: 512, height: 512))
    }

    @Test
    func testBufferAccess() throws {
        let vrmLoader = try vrmLoader()
        let result = try vrmLoader.bufferView(withBufferViewIndex: 0)
        #expect(result.stride == nil)
        #expect(result.bufferView.count == 93840)
    }

    @Test
    func testVRM1NativeExpressionBindingsUseNodes() throws {
        let vrmLoader = try vrmLoader()
        let scene = try vrmLoader.loadScene()
        let vrmNode = scene.vrmNode

        #expect(vrmNode.expressionClips.count == 18)
        let happyBinding = try #require(vrmNode.expressionClips[.preset(.happy)]?.values.first)
        #expect(happyBinding.mesh === (try vrmLoader.node(withNodeIndex: 2)))
        #expect(vrmNode.expressionClips[.preset(.aa)]?.values.first?.index == 25)

        vrmNode.setExpression(value: 0.42, for: .preset(.aa))
        #expect(abs(vrmNode.expression(for: .preset(.aa)) - 0.42) < 0.001)
        #expect(abs(vrmNode.blendShape(for: .preset(.a)) - 0.42) < 0.001)
    }

    @Test
    func testVRM1FirstPersonAnnotationsUseNodes() throws {
        let vrmLoader = try vrmLoader()
        let scene = try vrmLoader.loadScene()
        let annotatedNode = try vrmLoader.node(withNodeIndex: 0)

        #expect(annotatedNode.isHidden == false)
        scene.vrmNode.setFirstPersonRenderMode(.firstPerson)
        #expect(annotatedNode.isHidden == true)
        scene.vrmNode.setFirstPersonRenderMode(.thirdPerson)
        #expect(annotatedNode.isHidden == false)
    }

    @Test
    func testVRM1MToonMaterialIsLoadedFromExtension() throws {
        let vrmLoader = try vrmLoader()
        let material = try vrmLoader.material(withMaterialIndex: 0)
        let gltfMaterial = try #require(vrmLoader.vrm.gltf.jsonData.materials?[0])

        #expect(material.name == gltfMaterial.name)
        #expect(material.lightingModel == .constant)
        #expect(material.isLitPerPixel == false)
        #expect(material.writesToDepthBuffer == true)
        #expect(material.shaderModifiers?[.surface]?.contains("mtoonLambert") == true)
        #expect(material.shaderModifiers?[.surface]?.contains("_surface.ambientOcclusion") == true)
        #expect(material.shaderModifiers?[.surface]?.contains("_surface.transparent") == false)

        let shadeColor = try #require(material.mtoonColor(forKey: MToonUniform.shadeColor))
        #expect(abs(shadeColor.x - 0.301212043) < 0.0001)
        #expect(abs(shadeColor.y - 0.301212043) < 0.0001)
        #expect(abs(shadeColor.z - 0.301212043) < 0.0001)

        let outlineColor = try #require(material.mtoonColor(forKey: MToonUniform.outlineColor))
        #expect(outlineColor == SIMD4<Float>(0, 0, 0, 1))

        let shadeParams = try #require(material.value(forKey: MToonUniform.shadeParams) as? SCNVector4)
        #expect(abs(Float(shadeParams.x) + 0.05) < 0.0001)
        #expect(abs(Float(shadeParams.y) - 0.95) < 0.0001)
    }

    @Test
    func testVRM1MToonOutlineNodeIsCreated() throws {
        let vrmLoader = try vrmLoader()
        let scene = try vrmLoader.loadScene()
        let outlineNodes = scene.rootNode.allNodes.filter { node in
            node.geometry?.materials.first?.name?.hasSuffix("_outline") == true
        }

        let outlineNode = try #require(outlineNodes.first)
        let outlineMaterial = try #require(outlineNode.geometry?.materials.first)
        #expect(outlineMaterial.cullMode == .front)
        #expect(outlineMaterial.shaderModifiers?[.geometry]?.contains("mtoonOutlineWidth") == true)
        #expect(outlineMaterial.shaderModifiers?[.geometry]?.contains("mtoonOutlineNormalLengthSquared") == true)
    }

    @Test
    func testVRM1MToonOutlineWidthMultiplyTextureUsesGreenChannel() throws {
        let vrmLoader = try vrmLoader()
        let material = try vrmLoader.material(withMaterialIndex: 0)
        let outlineMaterial = try #require(material.mtoonOutlineMaterial())
        let outlineTexture = outlineMaterial.value(forKey: MToonUniform.outlineWidthMultiplyTexture) as? SCNMaterialProperty
        let outlineGeometry = try #require(outlineMaterial.shaderModifiers?[.geometry])

        #expect(outlineTexture != nil)
        #expect(outlineGeometry.contains("mtoonOutlineWidthMultiplyTexture"))
        #expect(outlineGeometry.contains("mtoonOutlineWidthMultiplyTextureSampler"))
        #expect(outlineGeometry.contains(").g"))
    }

    @Test
    func testSceneKitMToonShaderModifiersUsePackedMaskChannels() throws {
        let source = try sceneKitMaterialSource()

        #expect(source.contains("mtoonUvAnimationMaskTexture.sample(mtoonUvAnimationMaskTextureSampler, mtoonUV).b"))
        #expect(source.contains("mtoonOutlineWidthMultiplyTexture.sample(mtoonOutlineWidthMultiplyTextureSampler, _geometry.texcoords[0]).g"))
    }

    @Test
    func testVRM1MToonOutlineColorBindUpdatesOutlineMaterial() throws {
        let vrmLoader = try vrmLoader()
        let scene = try vrmLoader.loadScene()
        let outlineMaterial = try #require(scene.rootNode.allNodes.compactMap {
            $0.geometry?.materials.first
        }.first { $0.name?.hasSuffix("_outline") == true })

        let color = SIMD4<Float>(0.2, 0.3, 0.4, 1.0)
        outlineMaterial.setMToonColor(color, forKey: MToonUniform.outlineColor)
        #expect(outlineMaterial.mtoonColor(forKey: MToonUniform.outlineColor)?.isApproximatelyEqual(to: color) == true)
    }

    @Test
    func testVRM1MToonSkinnedOutlineUsesIndependentSkinnerAndMorpher() throws {
        let vrmLoader = try constraintTwistSampleLoader()
        let scene = try vrmLoader.loadScene()
        let outlineNode = try #require(scene.rootNode.allNodes.first {
            $0.geometry?.materials.first?.name == "Face_00_SKIN_outline"
        })
        let baseNode = try #require(outlineNode.previousSibling)
        let baseMorpher = try #require(baseNode.morpher)
        let outlineMorpher = try #require(outlineNode.morpher)

        #expect(baseNode.skinner != nil)
        #expect(outlineNode.skinner != nil)
        #expect(baseMorpher !== outlineMorpher)
        #expect(baseMorpher.calculationMode == .normalized)
        #expect(outlineMorpher.calculationMode == .normalized)

        let baseVertex = try #require(baseNode.geometry?.sources(for: .vertex).first)
        let joyTarget = try #require(baseMorpher.targets[3].sources(for: .vertex).first)
        #expect(try joyTarget.maxVectorLength() > 0.1)
        #expect(try joyTarget.maxVectorDistance(from: baseVertex) < 0.1)
        #expect(abs(baseMorpher.weight(forTargetAt: 36)) < 0.001)
        #expect(abs(outlineMorpher.weight(forTargetAt: 36)) < 0.001)

        scene.vrmNode.setExpression(value: 0.5, for: .preset(.aa))
        #expect(abs(baseMorpher.weight(forTargetAt: 36) - 0.5) < 0.001)
        #expect(abs(outlineMorpher.weight(forTargetAt: 36) - 0.5) < 0.001)
    }

    private func sceneKitMaterialSource() throws -> String {
        let testFile = URL(fileURLWithPath: #filePath)
        let packageRoot = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = packageRoot
            .appendingPathComponent("Sources")
            .appendingPathComponent("VRMSceneKit")
            .appendingPathComponent("GLTF2SCN")
            .appendingPathComponent("SCNMaterial+GLTF.swift")
        return try String(contentsOf: sourceURL, encoding: .utf8)
    }

    @Test
    func testVRM1MToonDoesNotUseSceneKitMultiplyOrTransparentSlots() throws {
        let vrmLoader = try vrmLoader()
        let material = try vrmLoader.material(withMaterialIndex: 1)

        #expect(material.name == "huku_bake")
        #expect(!(material.multiply.contents is VRMImage))

        let outlineColor = try #require(material.mtoonColor(forKey: MToonUniform.outlineColor))
        let transparentColor = try #require((material.transparent.contents as? VRMColor)?.simd)
        #expect(!transparentColor.isApproximatelyEqual(to: outlineColor))

        let faceMaterial = try constraintTwistSampleLoader().material(withMaterialIndex: 7)
        #expect(faceMaterial.name == "Face_00_SKIN")
        #expect(!(faceMaterial.displacement.contents is VRMImage))
        #expect(faceMaterial.shaderModifiers?[.geometry] == nil)
    }

    @Test
    func testSceneKitFallbackShadeAndOutlineColorBindsDoNotOverwriteColor() throws {
        let material = SCNMaterial()
        let baseColor = VRMColor(red: 0.1, green: 0.2, blue: 0.3, alpha: 1)
        let boundColor = SIMD4<Float>(0.8, 0.7, 0.6, 1)
        material.diffuse.contents = baseColor

        material.setColor(boundColor, for: .shadeColor)
        #expect((material.diffuse.contents as? VRMColor)?.isApproximatelyEqual(to: baseColor) == true)
        #expect(material.currentColor(for: .shadeColor).isApproximatelyEqual(to: SIMD4<Float>(1, 1, 1, 1)))

        material.setColor(boundColor, for: .outlineColor)
        #expect((material.diffuse.contents as? VRMColor)?.isApproximatelyEqual(to: baseColor) == true)
        #expect(material.currentColor(for: .outlineColor).isApproximatelyEqual(to: SIMD4<Float>(1, 1, 1, 1)))

        material.setColor(boundColor, for: .color)
        #expect((material.diffuse.contents as? VRMColor)?.isApproximatelyEqual(to: boundColor) == true)
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

private extension SIMD4 where Scalar == Float {
    func isApproximatelyEqual(to other: SIMD4<Float>, tolerance: Float = 0.0001) -> Bool {
        abs(x - other.x) < tolerance &&
        abs(y - other.y) < tolerance &&
        abs(z - other.z) < tolerance &&
        abs(w - other.w) < tolerance
    }
}

private extension VRMColor {
    func isApproximatelyEqual(to other: VRMColor, tolerance: Float = 0.0001) -> Bool {
        testSIMD.isApproximatelyEqual(to: other.testSIMD, tolerance: tolerance)
    }

    func isApproximatelyEqual(to other: SIMD4<Float>, tolerance: Float = 0.0001) -> Bool {
        testSIMD.isApproximatelyEqual(to: other, tolerance: tolerance)
    }

    var testSIMD: SIMD4<Float> {
        #if os(macOS)
        let color = usingColorSpace(.deviceRGB) ?? self
        return SIMD4<Float>(Float(color.redComponent),
                            Float(color.greenComponent),
                            Float(color.blueComponent),
                            Float(color.alphaComponent))
        #else
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return SIMD4<Float>(Float(red), Float(green), Float(blue), Float(alpha))
        #endif
    }
}

private extension SCNNode {
    var allNodes: [SCNNode] {
        var nodes: [SCNNode] = []
        enumerateHierarchy { node, _ in
            nodes.append(node)
        }
        return nodes
    }

    var previousSibling: SCNNode? {
        guard let parent,
              let index = parent.childNodes.firstIndex(where: { $0 === self }),
              index > 0 else {
            return nil
        }
        return parent.childNodes[index - 1]
    }
}

private extension SCNGeometrySource {
    func maxVectorLength() throws -> Float {
        guard usesFloatComponents, bytesPerComponent == MemoryLayout<Float>.size else {
            throw VRMError.notSupported("\(semantic) source must use Float components")
        }
        var maxLength: Float = 0
        try data.withUnsafeBytes { raw in
            guard let baseAddress = raw.baseAddress else { return }
            for index in 0..<vectorCount {
                let byteOffset = dataOffset + index * dataStride
                var squaredLength: Float = 0
                for component in 0..<componentsPerVector {
                    let offset = byteOffset + component * bytesPerComponent
                    guard offset + bytesPerComponent <= data.count else {
                        throw VRMError.dataInconsistent("source data offset \(offset) is out of range")
                    }
                    let value = baseAddress.load(fromByteOffset: offset, as: Float.self)
                    squaredLength += value * value
                }
                maxLength = max(maxLength, sqrt(squaredLength))
            }
        }
        return maxLength
    }

    func maxVectorDistance(from other: SCNGeometrySource) throws -> Float {
        guard usesFloatComponents,
              other.usesFloatComponents,
              bytesPerComponent == MemoryLayout<Float>.size,
              other.bytesPerComponent == MemoryLayout<Float>.size,
              vectorCount == other.vectorCount,
              componentsPerVector == other.componentsPerVector else {
            throw VRMError.notSupported("\(semantic) sources must use matching Float components")
        }

        var maxDistance: Float = 0
        try data.withUnsafeBytes { raw in
            guard let baseAddress = raw.baseAddress else { return }
            try other.data.withUnsafeBytes { otherRaw in
                guard let otherAddress = otherRaw.baseAddress else { return }
                for index in 0..<vectorCount {
                    let byteOffset = dataOffset + index * dataStride
                    let otherByteOffset = other.dataOffset + index * other.dataStride
                    var squaredDistance: Float = 0
                    for component in 0..<componentsPerVector {
                        let offset = byteOffset + component * bytesPerComponent
                        let otherOffset = otherByteOffset + component * other.bytesPerComponent
                        guard offset + bytesPerComponent <= data.count,
                              otherOffset + other.bytesPerComponent <= other.data.count else {
                            throw VRMError.dataInconsistent("source data offset is out of range")
                        }
                        let value = baseAddress.load(fromByteOffset: offset, as: Float.self)
                        let otherValue = otherAddress.load(fromByteOffset: otherOffset, as: Float.self)
                        let difference = value - otherValue
                        squaredDistance += difference * difference
                    }
                    maxDistance = max(maxDistance, sqrt(squaredDistance))
                }
            }
        }
        return maxDistance
    }
}

private extension VRMColor {
    var simd: SIMD4<Float> {
        #if os(macOS)
        let color = usingColorSpace(.deviceRGB) ?? self
        return SIMD4<Float>(Float(color.redComponent),
                            Float(color.greenComponent),
                            Float(color.blueComponent),
                            Float(color.alphaComponent))
        #else
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return SIMD4<Float>(Float(red), Float(green), Float(blue), Float(alpha))
        #endif
    }
}
