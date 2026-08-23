import Foundation

/// Hand-written `.vrma` (`VRMC_vrm_animation`) fixtures, built as JSON glTF
/// with a data-URI buffer, for the cases a real file cannot express: malformed
/// input, and channels whose retargeted result is predictable to the digit.
public enum VRMASampleFixture {
    /// Accumulates the buffer, accessors, samplers and channels a fixture's
    /// glTF needs, so each one below only spells out its own keyframes.
    private struct Builder {
        private var buffer = Data()
        private var bufferViews: [String] = []
        private var accessors: [String] = []
        private var samplers: [String] = []
        private var channels: [String] = []

        /// - Parameter timeBounds: writes the spec's `min` / `max`, which a
        ///   sampler input carries and the animation's duration reads.
        mutating func accessor(_ floats: [Float], type: String, count: Int, timeBounds: Bool = false) -> Int {
            let offset = buffer.count
            buffer.append(Data(littleEndianFloats: floats))
            bufferViews.append("{\"buffer\": 0, \"byteOffset\": \(offset), \"byteLength\": \(floats.count * 4)}")
            var json = "{\"bufferView\": \(bufferViews.count - 1), \"componentType\": 5126, \"count\": \(count), \"type\": \"\(type)\""
            if timeBounds, let first = floats.first, let last = floats.last {
                json += ", \"min\": [\(first)], \"max\": [\(last)]"
            }
            json += "}"
            accessors.append(json)
            return accessors.count - 1
        }

        mutating func channel(node: Int, path: String, input: Int, output: Int, interpolation: String) {
            samplers.append("{\"input\": \(input), \"interpolation\": \"\(interpolation)\", \"output\": \(output)}")
            channels.append("{\"sampler\": \(samplers.count - 1), \"target\": {\"node\": \(node), \"path\": \"\(path)\"}}")
        }

        /// The `animations` and buffer members every fixture closes with.
        func resourcesJSON(animationName: String) -> String {
            """
            "animations": [{
                "name": "\(animationName)",
                "channels": [\(channels.joined(separator: ", "))],
                "samplers": [\(samplers.joined(separator: ", "))]
            }],
            "buffers": [{"uri": "data:application/octet-stream;base64,\(buffer.base64EncodedString())", "byteLength": \(buffer.count)}],
            "bufferViews": [\(bufferViews.joined(separator: ", "))],
            "accessors": [\(accessors.joined(separator: ", "))]
            """
        }
    }

    /// The general-purpose fixture. Its skeleton rests in the spec's normalized
    /// T-pose with the hips 1 m up, so a retargeting test can predict every
    /// value:
    ///
    /// - hips (node 1): rotation LINEAR identity → 90° around +X over 1 s, and
    ///   translation LINEAR `[0, 1, 0]` → `[0, 1, 0.5]`
    /// - spine (node 2): rotation STEP holding 45° around +Z
    /// - leftThumbMetacarpal (node 9): rotation STEP holding 30° around +Z, which a
    ///   VRM 0.x target must remap to its `leftThumbProximal` naming
    /// - "tail" (node 7): a bone name outside the VRM humanoid, to be skipped
    /// - expressions `happy` (node 4) STEP weight 0.7, `aa` (node 8) LINEAR
    ///   0 → 1.5 (clamps to 1), custom `wink` (node 5) STEP weight 0.4
    /// - lookAt (node 6): a rotation channel the runtime does not retarget yet
    /// - head (node 3): a scale channel, which the spec forbids on humanoid bones
    /// - leftEye / rightEye (nodes 10, 11): rotation channels a `.vrma` humanoid
    ///   may not carry
    ///
    /// - Parameter specVersion: nil omits the property, as some exporters do.
    public static func standard(specVersion: String? = "1.0") -> Data {
        var builder = Builder()

        let halfX: Float = sin(.pi / 4)  // 90° around +X, as (x, y, z, w)
        let z45: (s: Float, c: Float) = (sin(.pi / 8), cos(.pi / 8))
        let z30: (s: Float, c: Float) = (sin(.pi / 12), cos(.pi / 12))

        let times = builder.accessor([0, 1], type: "SCALAR", count: 2, timeBounds: true)
        let hipsRotation = builder.accessor([0, 0, 0, 1, halfX, 0, 0, halfX], type: "VEC4", count: 2)
        let hipsTranslation = builder.accessor([0, 1, 0, 0, 1, 0.5], type: "VEC3", count: 2)
        let spineRotation = builder.accessor([0, 0, z45.s, z45.c, 0, 0, z45.s, z45.c], type: "VEC4", count: 2)
        let thumbRotation = builder.accessor([0, 0, z30.s, z30.c, 0, 0, z30.s, z30.c], type: "VEC4", count: 2)
        let tailRotation = builder.accessor([0, 0, 0, 1, 0, 0, 0, 1], type: "VEC4", count: 2)
        let happyWeight = builder.accessor([0.7, 0, 0, 0.7, 0, 0], type: "VEC3", count: 2)
        let aaWeight = builder.accessor([0, 0, 0, 1.5, 0, 0], type: "VEC3", count: 2)
        let winkWeight = builder.accessor([0.4, 0, 0, 0.4, 0, 0], type: "VEC3", count: 2)
        let lookAtRotation = builder.accessor([0, 0, 0, 1, 0, 0, 0, 1], type: "VEC4", count: 2)
        let headScale = builder.accessor([1, 1, 1, 1, 1, 1], type: "VEC3", count: 2)
        let eyeRotation = builder.accessor([z30.s, 0, 0, z30.c, z30.s, 0, 0, z30.c], type: "VEC4", count: 2)

        builder.channel(node: 1, path: "rotation", input: times, output: hipsRotation, interpolation: "LINEAR")
        builder.channel(node: 1, path: "translation", input: times, output: hipsTranslation, interpolation: "LINEAR")
        builder.channel(node: 2, path: "rotation", input: times, output: spineRotation, interpolation: "STEP")
        builder.channel(node: 9, path: "rotation", input: times, output: thumbRotation, interpolation: "STEP")
        builder.channel(node: 7, path: "rotation", input: times, output: tailRotation, interpolation: "STEP")
        builder.channel(node: 4, path: "translation", input: times, output: happyWeight, interpolation: "STEP")
        builder.channel(node: 8, path: "translation", input: times, output: aaWeight, interpolation: "LINEAR")
        builder.channel(node: 5, path: "translation", input: times, output: winkWeight, interpolation: "STEP")
        builder.channel(node: 6, path: "rotation", input: times, output: lookAtRotation, interpolation: "LINEAR")
        builder.channel(node: 3, path: "scale", input: times, output: headScale, interpolation: "STEP")
        builder.channel(node: 10, path: "rotation", input: times, output: eyeRotation, interpolation: "STEP")
        builder.channel(node: 11, path: "rotation", input: times, output: eyeRotation, interpolation: "STEP")

        return Data("""
        {
            "asset": {"version": "2.0"},
            "extensionsUsed": ["VRMC_vrm_animation"],
            "extensions": {
                "VRMC_vrm_animation": {
                    \(specVersion.map { "\"specVersion\": \"\($0)\"," } ?? "")
                    "humanoid": {
                        "humanBones": {
                            "hips": {"node": 1},
                            "spine": {"node": 2},
                            "head": {"node": 3},
                            "leftThumbMetacarpal": {"node": 9},
                            "leftEye": {"node": 10},
                            "rightEye": {"node": 11},
                            "tail": {"node": 7}
                        }
                    },
                    "expressions": {
                        "preset": {
                            "happy": {"node": 4},
                            "aa": {"node": 8}
                        },
                        "custom": {
                            "wink": {"node": 5}
                        }
                    },
                    "lookAt": {"node": 6, "offsetFromHeadBone": [0, 0.06, 0]}
                }
            },
            "scene": 0,
            "scenes": [{"nodes": [0]}],
            "nodes": [
                {"name": "Root", "children": [1, 4, 5, 6, 7, 8]},
                {"name": "Hips", "translation": [0, 1, 0], "children": [2]},
                {"name": "Spine", "translation": [0, 0.1, 0], "children": [3, 9]},
                {"name": "Head", "translation": [0, 0.4, 0], "children": [10, 11]},
                {"name": "HappyExpression"},
                {"name": "WinkExpression"},
                {"name": "LookAt"},
                {"name": "Tail"},
                {"name": "AaExpression"},
                {"name": "LeftThumbMetacarpal", "translation": [0.3, 0, 0]},
                {"name": "LeftEye", "translation": [0.03, 0.05, 0.03]},
                {"name": "RightEye", "translation": [-0.03, 0.05, 0.03]}
            ],
            \(builder.resourcesJSON(animationName: "fixture"))
        }
        """.utf8)
    }

    /// A one-second STEP fixture holding a single pose: the hips turned by
    /// `hipsRotation` (x, y, z, w) and the `aa` expression at `expressionWeight`.
    ///
    /// It shares ``standard()``'s rest skeleton and drives targets ``standard()``
    /// also drives, so the two can compete for them in a playback-order test.
    public static func holdingPose(hipsRotation: [Float] = [0, 0, 0, 1],
                                   expressionWeight: Float) -> Data {
        var builder = Builder()
        let times = builder.accessor([0, 1], type: "SCALAR", count: 2, timeBounds: true)
        let rotation = builder.accessor(hipsRotation + hipsRotation, type: "VEC4", count: 2)
        let weight = builder.accessor([expressionWeight, 0, 0, expressionWeight, 0, 0], type: "VEC3", count: 2)
        builder.channel(node: 1, path: "rotation", input: times, output: rotation, interpolation: "STEP")
        builder.channel(node: 2, path: "translation", input: times, output: weight, interpolation: "STEP")

        return Data("""
        {
            "asset": {"version": "2.0"},
            "extensionsUsed": ["VRMC_vrm_animation"],
            "extensions": {
                "VRMC_vrm_animation": {
                    "specVersion": "1.0",
                    "humanoid": {"humanBones": {"hips": {"node": 1}}},
                    "expressions": {"preset": {"aa": {"node": 2}}}
                }
            },
            "scene": 0,
            "scenes": [{"nodes": [0]}],
            "nodes": [
                {"name": "Root", "children": [1, 2]},
                {"name": "Hips", "translation": [0, 1, 0]},
                {"name": "AaExpression"}
            ],
            \(builder.resourcesJSON(animationName: "holding pose"))
        }
        """.utf8)
    }

    /// A one-second STEP fixture holding its hips at `[0, 1, 0.5]` under a
    /// parent that does not rest untransformed, as glTF allows above the hips.
    /// With `parentTranslation` `[0, 0.4, 0]` and `parentScale` 1.5 the hips
    /// rest 1.9 m up and hold `[0, 1.9, 0.75]` in model space.
    public static func hipsUnderTransformedParent(parentTranslation: [Float],
                                                  parentScale: Float) -> Data {
        var builder = Builder()
        let times = builder.accessor([0, 1], type: "SCALAR", count: 2, timeBounds: true)
        let translation = builder.accessor([0, 1, 0.5, 0, 1, 0.5], type: "VEC3", count: 2)
        builder.channel(node: 1, path: "translation", input: times, output: translation, interpolation: "STEP")

        return Data("""
        {
            "asset": {"version": "2.0"},
            "extensionsUsed": ["VRMC_vrm_animation"],
            "extensions": {
                "VRMC_vrm_animation": {
                    "specVersion": "1.0",
                    "humanoid": {"humanBones": {"hips": {"node": 1}}}
                }
            },
            "scene": 0,
            "scenes": [{"nodes": [0]}],
            "nodes": [
                {
                    "name": "Armature",
                    "translation": [\(parentTranslation.map { "\($0)" }.joined(separator: ", "))],
                    "scale": [\(parentScale), \(parentScale), \(parentScale)],
                    "children": [1]
                },
                {"name": "Hips", "translation": [0, 1, 0]}
            ],
            \(builder.resourcesJSON(animationName: "transformed parent"))
        }
        """.utf8)
    }

    /// A one-second STEP fixture for the rules a `.vrma` expression follows:
    ///
    /// - `aa` and `ih` (both node 1): two expressions naming one node, whose
    ///   weight 0.6 belongs to both
    /// - `lookRight` (node 2): a preset a `.vrma` may not carry, held at 1
    public static func contestedExpressions() -> Data {
        var builder = Builder()
        let times = builder.accessor([0, 1], type: "SCALAR", count: 2, timeBounds: true)
        let shared = builder.accessor([0.6, 0, 0, 0.6, 0, 0], type: "VEC3", count: 2)
        let look = builder.accessor([1, 0, 0, 1, 0, 0], type: "VEC3", count: 2)
        builder.channel(node: 1, path: "translation", input: times, output: shared, interpolation: "STEP")
        builder.channel(node: 2, path: "translation", input: times, output: look, interpolation: "STEP")

        return Data("""
        {
            "asset": {"version": "2.0"},
            "extensionsUsed": ["VRMC_vrm_animation"],
            "extensions": {
                "VRMC_vrm_animation": {
                    "specVersion": "1.0",
                    "expressions": {
                        "preset": {
                            "aa": {"node": 1},
                            "ih": {"node": 1},
                            "lookRight": {"node": 2}
                        }
                    }
                }
            },
            "scene": 0,
            "scenes": [{"nodes": [0]}],
            "nodes": [
                {"name": "Root", "children": [1, 2]},
                {"name": "SharedExpression"},
                {"name": "LookRightExpression"}
            ],
            \(builder.resourcesJSON(animationName: "contested expressions"))
        }
        """.utf8)
    }

    /// A fixture whose nodes describe no hierarchy: two roots claim the hips as
    /// their child, which the loader rejects in a model and retargeting has to
    /// reject in an animation.
    public static func hipsWithTwoParents() -> Data {
        var builder = Builder()
        let times = builder.accessor([0, 1], type: "SCALAR", count: 2, timeBounds: true)
        let translation = builder.accessor([0, 1, 0, 0, 1, 0.5], type: "VEC3", count: 2)
        builder.channel(node: 2, path: "translation", input: times, output: translation, interpolation: "LINEAR")

        return Data("""
        {
            "asset": {"version": "2.0"},
            "extensionsUsed": ["VRMC_vrm_animation"],
            "extensions": {
                "VRMC_vrm_animation": {
                    "specVersion": "1.0",
                    "humanoid": {"humanBones": {"hips": {"node": 2}}}
                }
            },
            "scene": 0,
            "scenes": [{"nodes": [0, 1]}],
            "nodes": [
                {"name": "RootA", "children": [2]},
                {"name": "RootB", "children": [2]},
                {"name": "Hips", "translation": [0, 1, 0]}
            ],
            \(builder.resourcesJSON(animationName: "two parents"))
        }
        """.utf8)
    }

    /// A fixture whose only channel turns `upperChest` 90° around +X, held over
    /// one second.
    ///
    /// `upperChest` is optional in the VRM humanoid, and the source chain here
    /// (hips → spine → chest → upperChest → neck / shoulders) is the one a model
    /// without it flattens onto `chest`. Every bone rests unrotated, so the
    /// rotation the neck and shoulders must end up carrying is exactly the 90°.
    public static func rotatingUpperChest() -> Data {
        var builder = Builder()
        let halfX: Float = sin(.pi / 4)
        let times = builder.accessor([0, 1], type: "SCALAR", count: 2, timeBounds: true)
        let rotation = builder.accessor([halfX, 0, 0, halfX, halfX, 0, 0, halfX], type: "VEC4", count: 2)
        builder.channel(node: 4, path: "rotation", input: times, output: rotation, interpolation: "STEP")

        return Data("""
        {
            "asset": {"version": "2.0"},
            "extensionsUsed": ["VRMC_vrm_animation"],
            "extensions": {
                "VRMC_vrm_animation": {
                    "specVersion": "1.0",
                    "humanoid": {
                        "humanBones": {
                            "hips": {"node": 1},
                            "spine": {"node": 2},
                            "chest": {"node": 3},
                            "upperChest": {"node": 4},
                            "neck": {"node": 5},
                            "leftShoulder": {"node": 6},
                            "rightShoulder": {"node": 7}
                        }
                    }
                }
            },
            "scene": 0,
            "scenes": [{"nodes": [0]}],
            "nodes": [
                {"name": "Root", "children": [1]},
                {"name": "Hips", "translation": [0, 1, 0], "children": [2]},
                {"name": "Spine", "translation": [0, 0.1, 0], "children": [3]},
                {"name": "Chest", "translation": [0, 0.1, 0], "children": [4]},
                {"name": "UpperChest", "translation": [0, 0.1, 0], "children": [5, 6, 7]},
                {"name": "Neck", "translation": [0, 0.1, 0]},
                {"name": "LeftShoulder", "translation": [0.05, 0.05, 0]},
                {"name": "RightShoulder", "translation": [-0.05, 0.05, 0]}
            ],
            \(builder.resourcesJSON(animationName: "upper chest"))
        }
        """.utf8)
    }
}
