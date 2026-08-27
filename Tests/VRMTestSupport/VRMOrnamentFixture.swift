import Foundation
import VRMKit
import simd

public extension GLTFEditableDocument {
    /// A line of three fresh nodes hanging off `parent`, parent first, as a
    /// hair ornament merged onto a model arrives. Shared so that the tests for
    /// writing a spring bone chain and for swinging one use the same content.
    mutating func addOrnamentChain(under parent: GLTFNodeIndex) throws -> [GLTFNodeIndex] {
        var joints: [GLTFNodeIndex] = []
        for step in 0..<3 {
            joints.append(try addNode(name: "charm\(step)",
                                      parent: joints.last ?? parent,
                                      transform: GLTFNodeTransform(translation: SIMD3(0, 0.05, 0))))
        }
        return joints
    }
}
