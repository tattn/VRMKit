import Foundation
import SIMDCompat
import VRMKit

/// What one scene of a glTF document draws, read without any renderer: the node
/// hierarchy, the skins, the vertex data of every mesh the scene draws, the materials as
/// read and the images as stored.
///
/// A renderer builds its own resources from this. Every model built from one asset
/// shares its vertex data, so nothing here changes once it is loaded.
public final class GLTFAsset: Sendable {
    public let document: GLTFDocument
    public let sceneIndex: Int
    /// The nodes the scene hangs off.
    public let rootNodes: [Int]
    /// Every node of the document, by glTF node index.
    public let nodes: [Node]
    /// Every skin of the document, by glTF skin index.
    public let skins: [Skin]
    /// The meshes the scene draws, one per way a node draws a glTF mesh.
    public let meshes: [Mesh]
    /// Which of ``meshes`` each node of the scene that draws a mesh draws.
    public let meshIndicesByNode: [Int: Int]
    /// Every material of the document, by glTF material index.
    public let materials: [GLTFMaterialData]
    /// Every image of the document, by glTF image index.
    public let images: [GLTFImageSource]
    /// What the read ran into that a renderer may want to report, once each.
    package let warnings: [GLTFGeometryWarning]

    /// One glTF node at rest.
    public struct Node: Sendable {
        public let name: String
        public let parent: Int?
        public let children: [Int]
        public let restTransform: GLTFNodeTransform
        /// The glTF mesh the node draws.
        public let mesh: Int?
        public let skin: Int?
        /// The morph weights the node starts at: its own, else its mesh's. Nil for none.
        public let initialMorphWeights: [Float]?
    }

    /// One glTF skin, its joints ordered so that every joint follows its parent.
    public struct Skin: Sendable {
        /// The node of each joint.
        public let joints: [Int]
        /// The joint each joint hangs off, as an index into ``joints``.
        public let parents: [Int?]
        public let inverseBindMatrices: [simd_float4x4]
        /// glTF joint index → its index in ``joints``.
        package let jointIndexRemap: [Int]
    }

    /// One glTF mesh as one node draws it: through a skin or not, and cut for a
    /// first-person camera or not.
    public struct Mesh: Sendable {
        public let name: String
        /// The glTF mesh.
        public let meshIndex: Int
        /// The skin the vertices are bound to. Nil for a mesh drawn without one.
        public let skinIndex: Int?
        /// Whether the slots carry the triangles a first-person camera draws.
        public let cutsHead: Bool
        public let geometry: GLTFMeshGeometry
        /// The glTF material of each slot of ``geometry``. Nil for a primitive that names
        /// none, which glTF draws with its default material.
        public let materialIndices: [Int?]
    }

    package init(document: GLTFDocument,
                 sceneIndex: Int,
                 rootNodes: [Int],
                 nodes: [Node],
                 skins: [Skin],
                 meshes: [Mesh],
                 meshIndicesByNode: [Int: Int],
                 materials: [GLTFMaterialData],
                 images: [GLTFImageSource],
                 warnings: [GLTFGeometryWarning]) {
        self.document = document
        self.sceneIndex = sceneIndex
        self.rootNodes = rootNodes
        self.nodes = nodes
        self.skins = skins
        self.meshes = meshes
        self.meshIndicesByNode = meshIndicesByNode
        self.materials = materials
        self.images = images
        self.warnings = warnings
    }

    /// The mesh the node at `index` draws.
    public func mesh(drawnByNode index: Int) -> Mesh? {
        meshIndicesByNode[index].map { meshes[$0] }
    }

    /// The image the texture at `index` reads.
    ///
    /// - Throws: when the texture takes its image from an extension this package does not read.
    public func imageIndex(ofTexture index: Int) throws -> Int {
        try document.gltf.imageIndex(ofTextureAt: index)
    }

    /// How the texture at `index` is sampled. Nil for glTF's defaults.
    public func sampler(ofTexture index: Int) throws -> GLTF.Sampler? {
        guard let samplerIndex = try document.gltf.load(\.textures, at: index).sampler else { return nil }
        return try document.gltf.load(\.samplers, at: samplerIndex)
    }

    /// Reads a plain glTF's scene, its default one unless told otherwise. The vertex data of
    /// its meshes decodes concurrently.
    ///
    /// - Throws: when the glTF holds several scenes, names no default one and none is given.
    public static func load(document: GLTFDocument, sceneIndex: Int? = nil) async throws -> GLTFAsset {
        let reader = try GLTFAssetReader(document: document, profile: GLTFDefaultAssetProfile())
        return try await reader.asset(sceneIndex: sceneIndex ?? document.gltf.defaultSceneIndex())
    }

    /// Reads a VRM's scene, with the first-person cut and VRM's morph target sharing.
    public static func load(vrm: VRM) async throws -> GLTFAsset {
        let reader = try GLTFAssetReader(document: vrm.document, profile: VRMAssetProfile(vrm: vrm))
        return try await reader.asset(sceneIndex: vrm.document.gltf.defaultSceneIndex())
    }
}
