import Foundation
import simd

/// One animated property of one node, as a keyframe track: the times and, for each,
/// the value the node takes. What glTF writes as a sampler and the channel naming it.
public struct GLTFAnimationTrack: Sendable {
    /// Which property the keyframes drive, and their values, one per time.
    public enum Values: Sendable {
        case translation([SIMD3<Float>])
        case rotation([simd_quatf])
        case scale([SIMD3<Float>])

        var count: Int {
            switch self {
            case .translation(let values), .scale(let values): values.count
            case .rotation(let values): values.count
            }
        }
    }

    public var node: GLTFNodeIndex
    /// Seconds, strictly increasing from zero or later.
    public var times: [Float]
    public var values: Values
    /// `CUBICSPLINE` is not written: its output carries tangents this track has no
    /// place for.
    public var interpolation: GLTF.Animation.Sampler.Interpolation

    public init(node: GLTFNodeIndex,
                times: [Float],
                values: Values,
                interpolation: GLTF.Animation.Sampler.Interpolation = .LINEAR) {
        self.node = node
        self.times = times
        self.values = values
        self.interpolation = interpolation
    }
}

extension GLTFEditableDocument {
    /// Adds an animation made of `tracks`, and returns its index.
    ///
    /// Each track becomes one sampler over two accessors of its own, the times and the
    /// values, and the channel binding it to its node. A track glTF cannot describe is
    /// refused and the document left as it was.
    @discardableResult
    public mutating func addAnimation(name: String? = nil,
                                      tracks: [GLTFAnimationTrack]) throws -> GLTFAnimationIndex {
        guard !tracks.isEmpty else {
            throw VRMError._invalidArgument("an animation needs at least one track")
        }
        for track in tracks {
            try validate(track)
        }

        var samplers: [JSONObject] = []
        var channels: [JSONObject] = []
        for track in tracks {
            let accessors = appendAccessors([Self.timesPayload(track.times), Self.valuesPayload(track.values)])
            var sampler: JSONObject = ["input": .int(accessors[0]), "output": .int(accessors[1])]
            // LINEAR is what a sampler naming none interpolates with.
            if track.interpolation != .LINEAR {
                sampler["interpolation"] = .string(track.interpolation.rawValue)
            }
            samplers.append(sampler)
            channels.append(["sampler": .int(samplers.count - 1),
                             "target": ["node": .int(track.node.rawValue), "path": .string(track.values.path)]])
        }

        var animation: JSONObject = ["channels": .objects(channels), "samplers": .objects(samplers)]
        animation.set("name", name)
        return GLTFAnimationIndex(json.appendObject(animation, to: .animations))
    }

    private func validate(_ track: GLTFAnimationTrack) throws {
        try requireNode(at: track.node.rawValue)
        guard track.interpolation != .CUBICSPLINE else {
            throw VRMError._notSupported("writing a CUBICSPLINE animation track")
        }
        guard !track.times.isEmpty else {
            throw VRMError._invalidArgument("an animation track needs at least one keyframe")
        }
        guard track.times.count == track.values.count else {
            throw VRMError._invalidArgument(
                "an animation track has \(track.times.count) times but \(track.values.count) values"
            )
        }
        guard track.times.allSatisfy(\.isFinite), track.times[0] >= 0,
              zip(track.times, track.times.dropFirst()).allSatisfy({ $0 < $1 }) else {
            throw VRMError._invalidArgument("animation keyframe times must increase strictly from 0 or later")
        }
        let isFinite: Bool
        switch track.values {
        case .translation(let vectors), .scale(let vectors):
            isFinite = vectors.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }
        case .rotation(let rotations):
            isFinite = rotations.allSatisfy { rotation in
                let v = rotation.vector
                return v.x.isFinite && v.y.isFinite && v.z.isFinite && v.w.isFinite
            }
        }
        guard isFinite else {
            throw VRMError._invalidArgument("animation keyframe values cannot contain infinity or NaN")
        }
    }

    /// glTF requires the bounds of a sampler input, which is how a reader learns the
    /// animation's duration without decoding the buffer.
    private static func timesPayload(_ times: [Float]) -> AccessorPayload {
        AccessorPayload(data: packed(times),
                        type: .SCALAR,
                        componentType: .float,
                        count: times.count,
                        target: nil,
                        bounds: (min: [times[0]], max: [times[times.count - 1]]))
    }

    private static func valuesPayload(_ values: GLTFAnimationTrack.Values) -> AccessorPayload {
        switch values {
        case .translation(let vectors), .scale(let vectors):
            return AccessorPayload(data: packed(vectors),
                                   type: .VEC3,
                                   componentType: .float,
                                   count: vectors.count,
                                   target: nil)
        case .rotation(let rotations):
            // A zero-length rotation is written as the identity, as a node transform is.
            let vectors = rotations.map(\.safelyNormalized.vector)
            return AccessorPayload(data: packed(vectors),
                                   type: .VEC4,
                                   componentType: .float,
                                   count: vectors.count,
                                   target: nil)
        }
    }
}

private extension GLTFAnimationTrack.Values {
    var path: String {
        switch self {
        case .translation: GLTF.Animation.Channel.Target.TargetPath.translation.rawValue
        case .rotation: GLTF.Animation.Channel.Target.TargetPath.rotation.rawValue
        case .scale: GLTF.Animation.Channel.Target.TargetPath.scale.rawValue
        }
    }
}
