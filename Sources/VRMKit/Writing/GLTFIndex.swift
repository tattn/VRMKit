import Foundation

/// Which of a glTF document's top-level arrays an index points into.
public protocol GLTFIndexKind: Sendable {
    static var arrayName: String { get }
}

/// An index into one of a glTF document's top-level arrays.
///
/// Every index in the format is a plain integer, and the type is what stops a
/// material index reaching an API that wanted a node. An index is only
/// meaningful against the document it came from, and ``GLTFPruneResult`` is how
/// one survives the renumbering a prune does.
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

public typealias GLTFNodeIndex = GLTFIndex<GLTFNodeKind>
public typealias GLTFMeshIndex = GLTFIndex<GLTFMeshKind>
public typealias GLTFMaterialIndex = GLTFIndex<GLTFMaterialKind>
public typealias GLTFSceneIndex = GLTFIndex<GLTFSceneKind>
