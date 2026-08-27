import simd
import VRMKit
@testable import VRMKitRuntime

/// A scene graph node of nothing but transforms.
///
/// The runtimes reach a renderer's nodes through ``VRMRuntimeNode``, so this
/// stands in for either renderer's and makes what they do testable without one.
final class TestRuntimeNode: VRMRuntimeNode {
    typealias RuntimeNode = TestRuntimeNode

    private(set) weak var parentNode: TestRuntimeNode?
    private(set) var childNodes: [TestRuntimeNode] = []
    var translation: SIMD3<Float>
    var rotation: simd_quatf
    var scale: SIMD3<Float>
    /// Every world transform a runtime asked this node for, so a test can say
    /// how much of the scene graph a solve had to walk.
    private(set) var worldReads = 0

    init(translation: SIMD3<Float> = .zero,
         rotation: simd_quatf = .identity,
         scale: SIMD3<Float> = SIMD3(repeating: 1)) {
        self.translation = translation
        self.rotation = rotation
        self.scale = scale
    }

    @discardableResult
    func addChild(_ child: TestRuntimeNode) -> TestRuntimeNode {
        child.parentNode = self
        childNodes.append(child)
        return child
    }

    var runtimeParent: TestRuntimeNode? { parentNode }
    var runtimeChildren: [TestRuntimeNode] { childNodes }

    var localMatrix: simd_float4x4 {
        var matrix = simd_float4x4(rotation)
        matrix.columns.0 *= scale.x
        matrix.columns.1 *= scale.y
        matrix.columns.2 *= scale.z
        matrix.columns.3 = SIMD4(translation, 1)
        return matrix
    }

    var localRotation: simd_quatf { rotation }

    func setLocalRotation(_ rotation: simd_quatf) {
        self.rotation = rotation
    }

    var worldMatrix: simd_float4x4 {
        worldReads += 1
        return uncountedWorldMatrix
    }

    var worldRotation: simd_quatf {
        worldReads += 1
        return uncountedWorldRotation
    }

    /// The same transforms, without counting as a read, for a test to check
    /// where a node ended up.
    var uncountedWorldMatrix: simd_float4x4 {
        guard let parentNode else { return localMatrix }
        return parentNode.uncountedWorldMatrix * localMatrix
    }

    var uncountedWorldRotation: simd_quatf {
        guard let parentNode else { return rotation }
        return parentNode.uncountedWorldRotation * rotation
    }

    var worldPosition: SIMD3<Float> { uncountedWorldMatrix.translation }

    func resetWorldReads() {
        worldReads = 0
        childNodes.forEach { $0.resetWorldReads() }
    }
}

extension simd_quatf {
    static let identity = simd_quatf(vector: SIMD4(0, 0, 0, 1))
}
