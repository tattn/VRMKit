import Foundation

/// The CC0-1.0 fixtures from KhronosGroup/glTF-Sample-Assets that ship with the
/// test bundle. See `Tests/Assets/GLTF/README.md` for provenance.
public enum GLTFSampleAsset: String, CaseIterable, Sendable {
    case triangle = "Triangle/Triangle.gltf"
    case triangleWithoutIndices = "TriangleWithoutIndices/TriangleWithoutIndices.gltf"
    case simpleMeshes = "SimpleMeshes/SimpleMeshes.gltf"
    case simpleTexture = "SimpleTexture/SimpleTexture.gltf"
    case simpleSkin = "SimpleSkin/SimpleSkin.gltf"
    case simpleMorph = "SimpleMorph/SimpleMorph.gltf"
    case cameras = "Cameras/Cameras.gltf"
    case animatedTriangle = "AnimatedTriangle/AnimatedTriangle.gltf"
    case boxVertexColors = "BoxVertexColors/BoxVertexColors.glb"
    case animatedMorphCube = "AnimatedMorphCube/AnimatedMorphCube.glb"
    case interpolationTest = "InterpolationTest/InterpolationTest.glb"
    case textureTransformTest = "TextureTransformTest/TextureTransformTest.gltf"

    /// The fixture's location in the bundle. `GLTFDocument` derives the root
    /// directory from it, so sibling `.bin` and `.png` files resolve.
    public var url: URL {
        TestAssetBundle.url(forFixture: "GLTF/\(rawValue)")
    }

    public var data: Data {
        TestAssetBundle.data(forFixture: "GLTF/\(rawValue)")
    }

    /// The directory holding the fixture, i.e. the base its external `.bin` and
    /// `.png` resources resolve against.
    public var rootDirectory: URL {
        url.deletingLastPathComponent()
    }

    /// The fixture with its glTF JSON rewritten, so tests can feed the loaders
    /// malformed or unusual files without shipping extra assets. The result has
    /// no directory of its own, so load it with ``rootDirectory``.
    public func rewritingJSON(_ modify: (inout [String: Any]) throws -> Void) throws -> Data {
        let data = data
        guard !GLBRewriter.isGLB(data) else {
            return try GLBRewriter.rewritingJSON(of: data, modify)
        }
        guard var json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GLBRewriter.Error.invalidJSON
        }
        try modify(&json)
        return try JSONSerialization.data(withJSONObject: json)
    }
}
