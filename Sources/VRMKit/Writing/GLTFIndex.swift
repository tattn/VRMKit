import Foundation

/// Which of a glTF document's arrays an index points into.
public protocol GLTFIndexKind: Sendable {
    static var arrayName: String { get }
}

/// An index into one of a glTF document's arrays: a top-level one, or one an
/// extension carries.
///
/// Every index in the format is a plain integer, and the type is what stops a material
/// index reaching an API that wanted a node. An index is only meaningful against the
/// document it came from; ``GLTFPruneResult`` is how one survives a prune's renumbering.
public struct GLTFIndex<Kind: GLTFIndexKind>: Hashable, Sendable, Comparable {
    public let rawValue: Int

    public init(_ rawValue: Int) {
        self.rawValue = rawValue
    }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

extension GLTFIndex: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int) {
        self.init(value)
    }
}

extension GLTFIndex: CustomStringConvertible {
    public var description: String { "\(Kind.arrayName)[\(rawValue)]" }
}

public enum GLTFNodeKind: GLTFIndexKind {
    public static var arrayName: String { "nodes" }
}

public enum GLTFMeshKind: GLTFIndexKind {
    public static var arrayName: String { "meshes" }
}

public enum GLTFMaterialKind: GLTFIndexKind {
    public static var arrayName: String { "materials" }
}

public enum GLTFSceneKind: GLTFIndexKind {
    public static var arrayName: String { "scenes" }
}

public enum GLTFTextureKind: GLTFIndexKind {
    public static var arrayName: String { "textures" }
}

public enum GLTFImageKind: GLTFIndexKind {
    public static var arrayName: String { "images" }
}

/// A VRM 0.x bone group, in the `VRM` extension's `secondaryAnimation.boneGroups`.
public enum VRM0BoneGroupKind: GLTFIndexKind {
    public static var arrayName: String { "secondaryAnimation.boneGroups" }
}

/// A VRM 1.0 spring, in the `VRMC_springBone` extension's `springs`.
public enum VRM1SpringKind: GLTFIndexKind {
    public static var arrayName: String { "VRMC_springBone.springs" }
}

public typealias GLTFNodeIndex = GLTFIndex<GLTFNodeKind>
public typealias GLTFMeshIndex = GLTFIndex<GLTFMeshKind>
public typealias GLTFMaterialIndex = GLTFIndex<GLTFMaterialKind>
public typealias GLTFSceneIndex = GLTFIndex<GLTFSceneKind>
public typealias GLTFTextureIndex = GLTFIndex<GLTFTextureKind>
public typealias GLTFImageIndex = GLTFIndex<GLTFImageKind>
public typealias VRM0BoneGroupIndex = GLTFIndex<VRM0BoneGroupKind>
public typealias VRM1SpringIndex = GLTFIndex<VRM1SpringKind>
