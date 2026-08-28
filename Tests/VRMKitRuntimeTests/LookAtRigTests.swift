import Foundation
import Testing
import simd
import VRMKit
@testable import VRMKitRuntime

/// Aiming a model's gaze: the angles a target comes out as, the curves they pass
/// through, and the eye rotations or expression weights VRM makes of them.
@Suite
struct LookAtRigTests {
    /// A model facing `forward` with its eyes a head apart, laid out so a target to the
    /// model's own left is a positive yaw whichever way the version faces.
    private struct Model {
        let root = TestRuntimeNode()
        let head: TestRuntimeNode
        let leftEye: TestRuntimeNode
        let rightEye: TestRuntimeNode

        init(forward: SIMD3<Float>) {
            head = TestRuntimeNode(translation: SIMD3(0, 1.5, 0))
            // The model's own left, which is +x facing +z and -x facing -z.
            let left = simd_cross(SIMD3<Float>(0, 1, 0), forward)
            leftEye = TestRuntimeNode(translation: left * 0.03)
            rightEye = TestRuntimeNode(translation: -left * 0.03)
            root.addChild(head)
            head.addChild(leftEye)
            head.addChild(rightEye)
        }

        /// The nodes under the indices a plan names them by.
        func node(at index: Int) -> TestRuntimeNode {
            [root, head, leftEye, rightEye][index]
        }
    }

    private static func plan(applier: VRMLookAtPlan.Applier,
                             forward: SIMD3<Float> = SIMD3(0, 0, 1),
                             horizontalInner: VRMLookAtPlan.RangeMap = .init(inputMaxValue: 90, outputScale: 4),
                             horizontalOuter: VRMLookAtPlan.RangeMap = .init(inputMaxValue: 90, outputScale: 8),
                             verticalUp: VRMLookAtPlan.RangeMap = .init(inputMaxValue: 90, outputScale: 6),
                             verticalDown: VRMLookAtPlan.RangeMap = .init(inputMaxValue: 90, outputScale: 2))
        -> VRMLookAtPlan {
        VRMLookAtPlan(applier: applier,
                      headNode: 1,
                      leftEyeNode: 2,
                      rightEyeNode: 3,
                      offsetFromHeadBone: SIMD3(0, 0.06, 0),
                      forwardDirection: forward,
                      horizontalInner: horizontalInner,
                      horizontalOuter: horizontalOuter,
                      verticalUp: verticalUp,
                      verticalDown: verticalDown)
    }

    private static func rig(_ model: Model, _ plan: VRMLookAtPlan) -> LookAtRig<TestRuntimeNode> {
        LookAtRig.make(plan: plan) { model.node(at: $0) }
    }

    /// Whether a solve turned an eye bone.
    private func isPosedBones(_ result: LookAtResult) -> Bool {
        if case .posedBones = result { return true }
        return false
    }

    /// The expression weights a solve produced, empty for one that turned bones or moved
    /// nothing.
    private static func weights(_ result: LookAtResult) -> [ExpressionKey: Double] {
        guard case .weights(let weights) = result else { return [:] }
        return weights
    }

    /// Whether two gazes state the same angles, to within the float error of turning a
    /// rotation into them.
    private static func isApproximatelyEqual(_ target: LookAtTarget,
                                             _ other: LookAtTarget,
                                             tolerance: Float = 1e-3) -> Bool {
        guard case .angles(let yaw, let pitch) = target,
              case .angles(let otherYaw, let otherPitch) = other else { return target == other }
        return abs(yaw - otherYaw) < tolerance && abs(pitch - otherPitch) < tolerance
    }

    /// The angle a rotation turns `forward` by, signed about `axis`: what an eye ended up
    /// looking along, in degrees.
    private static func angle(of node: TestRuntimeNode,
                              about axis: SIMD3<Float>,
                              from forward: SIMD3<Float>) -> Float {
        let turned = simd_act(node.localRotation, forward)
        let sine = simd_dot(simd_cross(forward, turned), axis)
        return atan2(sine, simd_dot(forward, turned)) * 180 / .pi
    }

    // MARK: - Range maps

    /// A map with no curve is the straight line VRM 1.0 states, holding past its input.
    @Test
    func testARangeMapScalesTheInputAngleAndHoldsPastIt() {
        let map = VRMLookAtPlan.RangeMap(inputMaxValue: 30, outputScale: 10)

        #expect(map.map(0) == 0)
        #expect(map.map(15) == 5)
        #expect(map.map(30) == 10)
        #expect(map.map(90) == 10)
    }

    /// The 0.x curve every exporter writes is the straight line, so it maps as one.
    @Test
    func testTheLinearVRM0CurveMapsAsAStraightLine() throws {
        let curve = try #require(VRMLookAtPlan.RangeMap.Curve(flattened: [0, 0, 0, 1, 1, 1, 1, 0]))
        let map = VRMLookAtPlan.RangeMap(inputMaxValue: 30, outputScale: 10, curve: curve)

        #expect(abs(map.map(15) - 5) < 1e-5)
        #expect(abs(map.map(30) - 10) < 1e-5)
    }

    /// A hand-tuned 0.x curve is followed keyframe by keyframe, which is the whole point
    /// of the version stating one.
    @Test
    func testAVRM0CurveIsFollowedBetweenItsKeyframes() throws {
        // Flat tangents through (0, 0), (0.5, 0.8) and (1, 1): eyes that swing most of
        // the way over the first half of the gaze.
        let curve = try #require(VRMLookAtPlan.RangeMap.Curve(flattened: [0, 0, 0, 0,
                                                                         0.5, 0.8, 0, 0,
                                                                         1, 1, 0, 0]))
        let map = VRMLookAtPlan.RangeMap(inputMaxValue: 90, outputScale: 10, curve: curve)

        #expect(abs(map.map(0)) < 1e-5)
        #expect(abs(map.map(22.5) - 4) < 1e-5)
        #expect(abs(map.map(45) - 8) < 1e-5)
        #expect(abs(map.map(90) - 10) < 1e-5)
    }

    /// A curve short of two whole keyframes maps as the straight line rather than
    /// failing the load.
    @Test(arguments: [[Float](), [0, 0, 0, 1], [0, 0, 0, 1, 1, 1], [1, 1, 1, 0, 0, 0, 0, 1]])
    func testAMalformedVRM0CurveIsNoCurveAtAll(values: [Float]) {
        #expect(VRMLookAtPlan.RangeMap.Curve(flattened: values) == nil)
    }

    /// A map stating no input range has nothing to scale, so it moves nothing.
    @Test
    func testARangeMapWithNoInputRangeMapsToNothing() {
        #expect(VRMLookAtPlan.RangeMap(inputMaxValue: 0, outputScale: 10).map(45) == 0)
    }

    // MARK: - A gaze stated as a rotation

    /// A `.vrma` states its gaze as a rotation, which reads as the angles it turns the
    /// resting gaze by: VRM states such a rotation in its own space, looking along +z.
    @Test
    func testARotationReadsAsTheAnglesItTurnsTheGazeBy() {
        let up = SIMD3<Float>(0, 1, 0)
        let yaw = LookAtTarget.rotation(simd_quatf(angle: .pi / 6, axis: up))
        #expect(Self.isApproximatelyEqual(yaw, .angles(yaw: 30, pitch: 0)))

        // Turning +z up is a turn about the model's right, which is -x facing +z.
        let pitch = LookAtTarget.rotation(simd_quatf(angle: .pi / 9, axis: SIMD3(-1, 0, 0)))
        #expect(Self.isApproximatelyEqual(pitch, .angles(yaw: 0, pitch: 20)))

        let both = LookAtTarget.rotation(simd_quatf(angle: .pi / 6, axis: up)
            * simd_quatf(angle: .pi / 9, axis: SIMD3(-1, 0, 0)))
        #expect(Self.isApproximatelyEqual(both, .angles(yaw: 30, pitch: 20)))
    }

    /// A rotation carrying no orientation at all leaves the gaze ahead rather than
    /// putting a NaN through every angle below it.
    @Test
    func testARotationOfNothingLeavesTheGazeAhead() {
        #expect(LookAtTarget.rotation(simd_quatf(vector: .zero)) == .angles(yaw: 0, pitch: 0))
    }

    // MARK: - Bone look-at

    /// The eye toward the gaze turns through the outer map and the one away through the
    /// inner, which is what keeps a pair of eyes from crossing.
    @Test
    func testEachEyeTurnsThroughTheMapItsSideOfTheGazeCallsFor() {
        let model = Model(forward: SIMD3(0, 0, 1))
        let rig = Self.rig(model, Self.plan(applier: .bone))

        // 45 degrees to the model's own left, level with the gaze origin.
        rig.target = .position(SIMD3(1, 1.56, 1))
        let result = rig.apply()

        #expect(isPosedBones(result))
        let up = SIMD3<Float>(0, 1, 0)
        #expect(abs(Self.angle(of: model.leftEye, about: up, from: SIMD3(0, 0, 1)) - 4) < 1e-3)
        #expect(abs(Self.angle(of: model.rightEye, about: up, from: SIMD3(0, 0, 1)) - 2) < 1e-3)
    }

    /// The maps swap sides for a gaze the other way, the inner eye being whichever one
    /// turns toward the nose.
    @Test
    func testTheHorizontalMapsSwapForAGazeToTheOtherSide() {
        let model = Model(forward: SIMD3(0, 0, 1))
        let rig = Self.rig(model, Self.plan(applier: .bone))

        rig.target = .position(SIMD3(-1, 1.56, 1))
        _ = rig.apply()

        let up = SIMD3<Float>(0, 1, 0)
        #expect(abs(Self.angle(of: model.leftEye, about: up, from: SIMD3(0, 0, 1)) + 2) < 1e-3)
        #expect(abs(Self.angle(of: model.rightEye, about: up, from: SIMD3(0, 0, 1)) + 4) < 1e-3)
    }

    /// Up and down are the same for both eyes, and pass through maps of their own.
    @Test
    func testBothEyesTurnUpAndDownThroughTheVerticalMaps() {
        let model = Model(forward: SIMD3(0, 0, 1))
        let rig = Self.rig(model, Self.plan(applier: .bone))
        let right = SIMD3<Float>(-1, 0, 0)

        // 45 degrees up from the gaze origin, which sits 6cm above the head node.
        rig.target = .position(SIMD3(0, 2.56, 1))
        _ = rig.apply()
        for eye in [model.leftEye, model.rightEye] {
            #expect(abs(Self.angle(of: eye, about: right, from: SIMD3(0, 0, 1)) - 3) < 1e-3)
        }

        rig.target = .position(SIMD3(0, 0.56, 1))
        _ = rig.apply()
        for eye in [model.leftEye, model.rightEye] {
            #expect(abs(Self.angle(of: eye, about: right, from: SIMD3(0, 0, 1)) + 1) < 1e-3)
        }
    }

    /// A VRM 0.x model faces the other way, so the same gaze to its own left is the same
    /// turn of the same eye.
    @Test
    func testAModelFacingTheOtherWayTurnsItsEyesTheSameWay() {
        let forward = SIMD3<Float>(0, 0, -1)
        let model = Model(forward: forward)
        let rig = Self.rig(model, Self.plan(applier: .bone, forward: forward))

        // The model's own left is -x while it faces -z.
        rig.target = .position(SIMD3(-1, 1.56, -1))
        _ = rig.apply()

        let up = SIMD3<Float>(0, 1, 0)
        #expect(abs(Self.angle(of: model.leftEye, about: up, from: forward) - 4) < 1e-3)
        #expect(abs(Self.angle(of: model.rightEye, about: up, from: forward) - 2) < 1e-3)
    }

    /// The gaze is measured in the head's own frame, so a turned head leaves the eyes to
    /// make up the difference rather than following it twice.
    @Test
    func testATurnedHeadTakesItsShareOfTheGaze() {
        let model = Model(forward: SIMD3(0, 0, 1))
        let rig = Self.rig(model, Self.plan(applier: .bone))
        // The head turns the whole 45 degrees onto the target itself.
        model.head.rotation = simd_quatf(angle: .pi / 4, axis: SIMD3(0, 1, 0))

        rig.target = .position(SIMD3(1, 1.56, 1))
        _ = rig.apply()

        let up = SIMD3<Float>(0, 1, 0)
        #expect(abs(Self.angle(of: model.leftEye, about: up, from: SIMD3(0, 0, 1))) < 1e-3)
        #expect(abs(Self.angle(of: model.rightEye, about: up, from: SIMD3(0, 0, 1))) < 1e-3)
    }

    /// Angles stand in for a position, for a caller that already states them.
    @Test
    func testAGazeStatedAsAnglesSkipsTheSolve() {
        let model = Model(forward: SIMD3(0, 0, 1))
        let rig = Self.rig(model, Self.plan(applier: .bone))

        rig.target = .angles(yaw: 90, pitch: 0)
        _ = rig.apply()

        #expect(abs(Self.angle(of: model.leftEye, about: SIMD3(0, 1, 0), from: SIMD3(0, 0, 1)) - 8) < 1e-3)
    }

    /// A gaze that has not moved writes nothing, so holding a target writes nothing.
    @Test
    func testAGazeThatHasNotMovedIsNotAppliedAgain() {
        let model = Model(forward: SIMD3(0, 0, 1))
        let rig = Self.rig(model, Self.plan(applier: .bone))

        rig.target = .position(SIMD3(1, 1.56, 1))
        #expect(isPosedBones(rig.apply()))
        #expect(!isPosedBones(rig.apply()))
    }

    /// Following nothing puts the eyes back where the model rigged them.
    @Test
    func testClearingTheTargetPutsTheEyesBackAtRest() {
        let model = Model(forward: SIMD3(0, 0, 1))
        let rest = simd_quatf(angle: 0.1, axis: SIMD3(0, 1, 0))
        model.leftEye.rotation = rest
        model.rightEye.rotation = rest
        let rig = Self.rig(model, Self.plan(applier: .bone))

        rig.target = .position(SIMD3(1, 1.56, 1))
        _ = rig.apply()
        #expect(model.leftEye.rotation.vector != rest.vector)

        rig.target = nil
        _ = rig.apply()
        #expect(simd_length(model.leftEye.rotation.vector - rest.vector) < 1e-5)
        #expect(simd_length(model.rightEye.rotation.vector - rest.vector) < 1e-5)
    }

    /// A model that states no look-at moves nothing, whatever it is told to follow.
    @Test
    func testAModelStatingNoLookAtMovesNothing() {
        let model = Model(forward: SIMD3(0, 0, 1))
        let rig = LookAtRig<TestRuntimeNode>()

        rig.target = .position(SIMD3(1, 1.56, 1))
        let result = rig.apply()

        #expect(!isPosedBones(result))
        #expect(Self.weights(result).isEmpty)
        #expect(model.leftEye.rotation.vector == simd_quatf.identity.vector)
    }

    // MARK: - Expression look-at

    /// Both eyes move together, so the horizontal gaze passes through the outer map
    /// whichever way it goes, and the expressions it is not looking toward go to zero.
    @Test
    func testAnExpressionLookAtWeighsTheFourLookExpressions() {
        let model = Model(forward: SIMD3(0, 0, 1))
        let unit = VRMLookAtPlan.RangeMap(inputMaxValue: 90, outputScale: 1)
        let rig = Self.rig(model, Self.plan(applier: .expression,
                                            horizontalInner: unit,
                                            horizontalOuter: unit,
                                            verticalUp: unit,
                                            verticalDown: unit))

        rig.target = .angles(yaw: 45, pitch: -90)
        let result = rig.apply()

        #expect(!isPosedBones(result))
        #expect(model.leftEye.rotation.vector == simd_quatf.identity.vector)
        let weights = Self.weights(result)
        #expect(weights[.preset(.lookLeft)] == 0.5)
        #expect(weights[.preset(.lookRight)] == 0)
        #expect(weights[.preset(.lookUp)] == 0)
        #expect(weights[.preset(.lookDown)] == 1)
    }

    /// A weight is capped at 1 however far the gaze goes and however the model scales
    /// its map, an expression having nowhere further to go.
    @Test
    func testExpressionWeightsAreCappedAtOne() {
        let model = Model(forward: SIMD3(0, 0, 1))
        let rig = Self.rig(model, Self.plan(applier: .expression))

        rig.target = .angles(yaw: -90, pitch: 0)
        let weights = Self.weights(rig.apply())

        #expect(weights[.preset(.lookRight)] == 1)
        #expect(weights[.preset(.lookLeft)] == 0)
    }
}
