import simd
import VRMKit

/// Where a model looks, read off whichever VRM version states it: the gaze origin, the
/// curves the gaze angles pass through, and whether the gaze turns bones or weighs
/// expressions.
///
/// VRM 0.x states this on `firstPerson` and VRM 1.0 on `lookAt`. They differ only in that
/// a 0.x map carries a Unity animation curve where a 1.0 map is a straight line.
package struct VRMLookAtPlan: Sendable {
    /// What a gaze moves, the maps stating degrees of eye rotation or expression weights.
    package enum Applier: Sendable {
        case bone
        /// The `lookUp` / `lookDown` / `lookLeft` / `lookRight` expressions.
        case expression
    }

    package let applier: Applier
    /// The node the gaze hangs off: the head, or whichever bone VRM 0.x hangs its
    /// first-person camera off.
    package let headNode: Int
    /// The eye bones, either of them nil for a model that does not rig it.
    package let leftEyeNode: Int?
    package let rightEyeNode: Int?
    /// The gaze origin, in the head node's space: the point between the eyes.
    package let offsetFromHeadBone: SIMD3<Float>
    /// The way the model faces in its own node space: what yaw and pitch are measured from.
    package let forwardDirection: SIMD3<Float>
    package let horizontalInner: RangeMap
    package let horizontalOuter: RangeMap
    package let verticalUp: RangeMap
    package let verticalDown: RangeMap

    package init(applier: Applier,
                 headNode: Int,
                 leftEyeNode: Int?,
                 rightEyeNode: Int?,
                 offsetFromHeadBone: SIMD3<Float>,
                 forwardDirection: SIMD3<Float>,
                 horizontalInner: RangeMap,
                 horizontalOuter: RangeMap,
                 verticalUp: RangeMap,
                 verticalDown: RangeMap) {
        self.applier = applier
        self.headNode = headNode
        self.leftEyeNode = leftEyeNode
        self.rightEyeNode = rightEyeNode
        self.offsetFromHeadBone = offsetFromHeadBone
        self.forwardDirection = forwardDirection
        self.horizontalInner = horizontalInner
        self.horizontalOuter = horizontalOuter
        self.verticalUp = verticalUp
        self.verticalDown = verticalDown
    }

    /// What the model states about its gaze, or nil for one that states none: a VRM 0.x
    /// `None` look-at, a VRM 1.0 model without the extension, a model with no head, or a
    /// bone look-at on a model that rigs neither eye.
    package init?(vrm: VRM) {
        let gltf = vrm.document.gltf
        guard let applier = vrm.lookAtApplier, let head = vrm.headNode(in: gltf) else { return nil }
        let defaults = RangeMap.defaults(for: applier)
        let leftEye = vrm.eyeNode(of: .leftEye, in: gltf)
        let rightEye = vrm.eyeNode(of: .rightEye, in: gltf)
        // A bone look-at needs an eye to turn; an expression one has its weights whatever
        // the model rigs.
        guard applier == .expression || leftEye != nil || rightEye != nil else { return nil }

        let offset: SIMD3<Float>
        let maps: [RangeMap]
        switch vrm {
        case .v0(let vrm0):
            // VRM 0.x states the offset against the first-person bone, which is the bone
            // the gaze hangs off.
            offset = vrm0.firstPerson?.firstPersonBoneOffset ?? .zero
            maps = [vrm0.firstPerson?.lookAtHorizontalInner, vrm0.firstPerson?.lookAtHorizontalOuter,
                    vrm0.firstPerson?.lookAtVerticalUp, vrm0.firstPerson?.lookAtVerticalDown]
                .map { RangeMap($0, defaults: defaults) }
        case .v1(let vrm1):
            offset = vrm1.lookAt?.offsetFromHeadBone ?? .zero
            maps = [vrm1.lookAt?.rangeMapHorizontalInner, vrm1.lookAt?.rangeMapHorizontalOuter,
                    vrm1.lookAt?.rangeMapVerticalUp, vrm1.lookAt?.rangeMapVerticalDown]
                .map { RangeMap($0, defaults: defaults) }
        }

        self.init(applier: applier,
                  headNode: head,
                  leftEyeNode: leftEye,
                  rightEyeNode: rightEye,
                  offsetFromHeadBone: offset,
                  forwardDirection: vrm.forwardDirection,
                  horizontalInner: maps[0],
                  horizontalOuter: maps[1],
                  verticalUp: maps[2],
                  verticalDown: maps[3])
    }
}

package extension VRMLookAtPlan {
    /// One of the four curves a gaze angle passes through: how far the eyes turn, or how
    /// hard an expression is weighed, for the model to look somewhere.
    struct RangeMap: Sendable {
        /// The input angle, in degrees, that reaches the far end of the curve. Past it
        /// the output holds.
        package let inputMaxValue: Float
        /// What the curve's 0...1 output scales to.
        package let outputScale: Float
        /// The curve between them, nil for the straight line VRM 1.0 always maps through.
        package let curve: Curve?

        package init(inputMaxValue: Float, outputScale: Float, curve: Curve? = nil) {
            self.inputMaxValue = inputMaxValue
            self.outputScale = outputScale
            self.curve = curve
        }

        /// What UniVRM leaves a map at, which is what a file stating none is read as.
        package static func defaults(for applier: Applier) -> RangeMap {
            switch applier {
            case .bone: RangeMap(inputMaxValue: 90, outputScale: 10)
            case .expression: RangeMap(inputMaxValue: 90, outputScale: 1)
            }
        }

        package init(_ rangeMap: VRM1.LookAt.LookAtRangeMap?, defaults: RangeMap) {
            self.init(inputMaxValue: rangeMap.map { Float($0.inputMaxValue) } ?? defaults.inputMaxValue,
                      outputScale: rangeMap.map { Float($0.outputScale) } ?? defaults.outputScale)
        }

        package init(_ degreeMap: VRM0.FirstPerson.DegreeMap?, defaults: RangeMap) {
            self.init(inputMaxValue: degreeMap?.xRange.map(Float.init) ?? defaults.inputMaxValue,
                      outputScale: degreeMap?.yRange.map(Float.init) ?? defaults.outputScale,
                      curve: Curve(flattened: degreeMap?.curve))
        }

        /// What the model does for a gaze `degrees` off its forward. Both sides are
        /// unsigned: which way the gaze goes is what picked this map, so the caller
        /// carries the direction.
        package func map(_ degrees: Float) -> Float {
            guard inputMaxValue > 0 else { return 0 }
            let input = (degrees / inputMaxValue).clamped(to: 0...1)
            return (curve?.evaluate(input) ?? input) * outputScale
        }
    }
}

package extension VRMLookAtPlan.RangeMap {
    /// The Unity animation curve VRM 0.x states a map's shape as: cubic Hermite between
    /// its keyframes, holding at either end.
    struct Curve: Sendable {
        private struct Key: Sendable {
            let time: Float
            let value: Float
            let inTangent: Float
            let outTangent: Float
        }

        private let keys: [Key]

        /// Nil for anything short of two whole keyframes, so a malformed curve maps as
        /// the straight line rather than failing the load.
        package init?(flattened values: [Float]?) {
            guard let values, values.count >= 8, values.count.isMultiple(of: 4) else { return nil }
            keys = stride(from: 0, to: values.count, by: 4).map {
                Key(time: values[$0], value: values[$0 + 1], inTangent: values[$0 + 2], outTangent: values[$0 + 3])
            }
            guard zip(keys, keys.dropFirst()).allSatisfy({ $0.time <= $1.time }) else { return nil }
        }

        /// The curve's value at `time`, which the maps always ask for within 0...1.
        package func evaluate(_ time: Float) -> Float {
            // At least two keyframes, which is what init takes.
            guard time > keys[0].time else { return keys[0].value }
            guard time < keys[keys.count - 1].time,
                  let index = keys.firstIndex(where: { $0.time > time }) else { return keys[keys.count - 1].value }

            let start = keys[index - 1]
            let end = keys[index]
            let span = end.time - start.time
            guard span > 0 else { return end.value }
            // Unity spells a step as an infinite tangent, which holds the value it steps from.
            guard start.outTangent.isFinite, end.inTangent.isFinite else { return start.value }

            let t = (time - start.time) / span
            let t2 = t * t
            let t3 = t2 * t
            return (2 * t3 - 3 * t2 + 1) * start.value
                + (t3 - 2 * t2 + t) * span * start.outTangent
                + (-2 * t3 + 3 * t2) * end.value
                + (t3 - t2) * span * end.inTangent
        }
    }
}

private extension VRM {
    /// What the model's gaze moves, nil for a model whose look-at moves nothing: a
    /// VRM 0.x `None` look-at, or a VRM 1.0 model without the extension.
    var lookAtApplier: VRMLookAtPlan.Applier? {
        switch self {
        case .v0(let vrm0):
            switch vrm0.firstPerson?.lookAtTypeName {
            case .bone: .bone
            case .blendShape: .expression
            case nil, .some(.none): nil
            }
        case .v1(let vrm1):
            // The spec requires the type, so a file leaving it out is read as the bones
            // it would have to rig anyway.
            vrm1.lookAt.map { $0.type == .expression ? .expression : .bone }
        }
    }

    /// The node an eye bone is rigged to, nil for one the model does not rig or rigs
    /// outside its own nodes.
    func eyeNode(of bone: HumanoidBone, in gltf: GLTF) -> Int? {
        nodeIndex(of: bone).flatMap { gltf.nodes.indices.contains($0) ? $0 : nil }
    }
}
