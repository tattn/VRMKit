#if canImport(RealityKit)
import CoreGraphics
import RealityKit
import VRMKit

/// One glTF image read through a scalar factor baked into its pixels.
@available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
struct GLTFBakedImageKey: Hashable {
    let imageIndex: Int
    let factor: Float
    let semantic: TextureResource.Semantic
}

/// One primitive decoded and conditioned for the build: its geometry, and what the build
/// would otherwise derive from it on the actor one vertex at a time.
@available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
struct GLTFPreparedPrimitive: @unchecked Sendable {
    let geometry: GLTFPrimitiveGeometry
    /// Whether ``firstPersonMask`` was cut for a node with head joints. A template drawn
    /// with the other cut derives its own mask.
    let cutsHead: Bool
    let firstPersonMask: FirstPersonPrimitiveMask
    /// Four per vertex in the skin's joint order, or nil for an unskinned primitive.
    let jointInfluences: [MeshJointInfluence]?
}

/// What the prepare passes decoded off the actor the entity graph is built on, for the
/// build to turn into mesh and texture resources.
///
/// Each of these is a CPU-side copy of part of the model, so it lives for the one load
/// that decoded it: the resources built from them carry the data on, and holding it any
/// longer would be a second copy of the model.
@available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
struct GLTFPreparedResources {
    /// Nil for a primitive this renderer draws nothing of.
    var primitives: [PrimitiveGeometryKey: GLTFPreparedPrimitive?] = [:]
    var images: [Int: CGImage] = [:]
    var bakedImages: [GLTFBakedImageKey: CGImage] = [:]
    /// Metal and roughness split out of one image's channels.
    var metallicRoughnessImages: [Int: (metal: CGImage, rough: CGImage)] = [:]
}
#endif
