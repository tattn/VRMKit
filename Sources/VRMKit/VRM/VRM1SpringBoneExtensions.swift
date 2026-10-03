import Foundation
import simd

// The extensions `VRMC_springBone` colliders and joints carry. Both live in the
// `extensions` the base types keep as written, so they are read on demand.

extension VRM1.SpringBone.Collider {
    /// The shape `VRMC_springBone_extended_collider` gives the collider. When there is
    /// one it replaces ``shape``, which is then only the fallback for readers without
    /// the extension. Nil when the collider carries none, or one in a version this type
    /// does not model.
    public func extendedShape() throws -> ExtendedShape? {
        guard let value = extensions?.dictionaryValue[GLTFExtension.springBoneExtendedCollider.rawValue] else {
            return nil
        }
        let extended = try value.decode(ExtendedCollider.self)
        guard extended.specVersion == "1.0" else { return nil }
        return extended.shape
    }

    private struct ExtendedCollider: Decodable {
        let specVersion: String
        let shape: ExtendedShape?
    }

    /// A shape of `VRMC_springBone_extended_collider`: the sphere and capsule of
    /// `VRMC_springBone`, either of which may keep joints inside it instead, and a plane.
    public enum ExtendedShape: Decodable, Sendable, Equatable {
        case sphere(offset: SIMD3<Float>, radius: Float, inside: Bool)
        case capsule(offset: SIMD3<Float>, tail: SIMD3<Float>, radius: Float, inside: Bool)
        /// An infinite plane joints are kept on the side `normal` points to.
        case plane(offset: SIMD3<Float>, normal: SIMD3<Float>)

        private enum CodingKeys: String, CodingKey {
            case sphere, capsule, plane
        }

        private enum ShapeKeys: String, CodingKey {
            case offset, radius, tail, inside, normal
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            var shapes: [Self] = []
            if container.contains(.sphere) {
                shapes.append(try .sphere(container.nestedContainer(keyedBy: ShapeKeys.self, forKey: .sphere)))
            }
            if container.contains(.capsule) {
                shapes.append(try .capsule(container.nestedContainer(keyedBy: ShapeKeys.self, forKey: .capsule)))
            }
            if container.contains(.plane) {
                shapes.append(try .plane(container.nestedContainer(keyedBy: ShapeKeys.self, forKey: .plane)))
            }
            guard shapes.count == 1, let shape = shapes.first else {
                throw VRMError._dataInconsistent(
                    "a VRMC_springBone_extended_collider shape is one of a sphere, a capsule or a plane, "
                    + "and this one states \(shapes.isEmpty ? "none" : "more than one")"
                )
            }
            self = shape
        }

        private static func sphere(_ container: KeyedDecodingContainer<ShapeKeys>) throws -> Self {
            .sphere(offset: try container.simd3(forKey: .offset, default: .zero),
                    radius: Float(try container.decodeIfPresent(Double.self, forKey: .radius) ?? 0),
                    inside: try container.decodeIfPresent(Bool.self, forKey: .inside) ?? false)
        }

        private static func capsule(_ container: KeyedDecodingContainer<ShapeKeys>) throws -> Self {
            .capsule(offset: try container.simd3(forKey: .offset, default: .zero),
                     tail: try container.simd3(forKey: .tail, default: .zero),
                     radius: Float(try container.decodeIfPresent(Double.self, forKey: .radius) ?? 0),
                     inside: try container.decodeIfPresent(Bool.self, forKey: .inside) ?? false)
        }

        private static func plane(_ container: KeyedDecodingContainer<ShapeKeys>) throws -> Self {
            .plane(offset: try container.simd3(forKey: .offset, default: .zero),
                   normal: try container.simd3(forKey: .normal, default: SIMD3(0, 0, 1)))
        }
    }
}

extension VRM1.SpringBone.Spring.Joint {
    /// The range `VRMC_springBone_limit` keeps the joint's swing in, or nil when the
    /// joint carries none, or one in a version this type does not model. The spec has
    /// a spring's last joint ignore it, since that joint is only a tail.
    public func limit() throws -> Limit? {
        guard let value = extensions?.dictionaryValue[GLTFExtension.springBoneLimit.rawValue] else {
            return nil
        }
        let extended = try value.decode(LimitExtension.self)
        // UniVRM (0.131) writes the limit without the specVersion the spec requires.
        guard extended.specVersion == nil || extended.specVersion == "1.0" else { return nil }
        return extended.limit
    }

    private struct LimitExtension: Decodable {
        let specVersion: String?
        let limit: Limit
    }

    /// A limit of `VRMC_springBone_limit`. Angles are in radians, and `rotation` turns
    /// the limit from the orientation the joint's rest direction gives it.
    public enum Limit: Decodable, Sendable, Equatable {
        /// Keeps the tail within `angle` of the cone's axis.
        case cone(angle: Float, rotation: simd_quatf)
        /// Keeps the tail on the hinge's plane, within `angle` of its axis.
        case hinge(angle: Float, rotation: simd_quatf)
        /// Keeps the tail within `pitch` about the x-axis and `yaw` about the z-axis.
        case spherical(pitch: Float, yaw: Float, rotation: simd_quatf)

        private enum CodingKeys: String, CodingKey {
            case cone, hinge, spherical
        }

        private enum LimitKeys: String, CodingKey {
            case angle, pitch, yaw, rotation
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            var limits: [Limit] = []
            if container.contains(.cone) {
                let cone = try container.nestedContainer(keyedBy: LimitKeys.self, forKey: .cone)
                limits.append(.cone(angle: Float(try cone.decode(Double.self, forKey: .angle)),
                                    rotation: try Self.rotation(cone)))
            }
            if container.contains(.hinge) {
                let hinge = try container.nestedContainer(keyedBy: LimitKeys.self, forKey: .hinge)
                limits.append(.hinge(angle: Float(try hinge.decode(Double.self, forKey: .angle)),
                                     rotation: try Self.rotation(hinge)))
            }
            if container.contains(.spherical) {
                let spherical = try container.nestedContainer(keyedBy: LimitKeys.self, forKey: .spherical)
                limits.append(.spherical(pitch: Float(try spherical.decode(Double.self, forKey: .pitch)),
                                         yaw: Float(try spherical.decode(Double.self, forKey: .yaw)),
                                         rotation: try Self.rotation(spherical)))
            }
            guard limits.count == 1, let limit = limits.first else {
                throw VRMError._dataInconsistent(
                    "a VRMC_springBone_limit limit is exactly one of a cone, a hinge or a spherical limit, "
                    + "and this one states \(limits.isEmpty ? "none" : "more than one")"
                )
            }
            self = limit
        }

        private static func rotation(_ container: KeyedDecodingContainer<LimitKeys>) throws -> simd_quatf {
            guard container.contains(.rotation) else { return simd_quatf(ix: 0, iy: 0, iz: 0, r: 1) }
            let value = try container.simd4(forKey: .rotation, default: SIMD4(0, 0, 0, 1))
            return simd_quatf(ix: value.x, iy: value.y, iz: value.z, r: value.w)
        }
    }
}
