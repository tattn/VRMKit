import SceneKit
import SpriteKit
import VRMKit

extension SCNMaterial {
    static var `default`: SCNMaterial {
        let material = SCNMaterial()
        material.diffuse.contents = SKColor(red: 1, green: 1, blue: 1, alpha: 1)
        material.metalness.contents = SKColor(white: 1, alpha: 1)
        material.roughness.contents = SKColor(white: 1, alpha: 1)
        material.isDoubleSided = false
        material.lightingModel = .physicallyBased
        return material
    }
}

extension SCNMatrix4 {
    init(_ v: [Float]) throws {
        guard v.count == 16 else {
            throw VRMError._dataInconsistent("SCNMatrix4 needs 16 values, got \(v.count)")
        }
        #if os(macOS)
        self.init(m11: CGFloat(v[0]), m12: CGFloat(v[1]), m13: CGFloat(v[2]), m14: CGFloat(v[3]),
                  m21: CGFloat(v[4]), m22: CGFloat(v[5]), m23: CGFloat(v[6]), m24: CGFloat(v[7]),
                  m31: CGFloat(v[8]), m32: CGFloat(v[9]), m33: CGFloat(v[10]), m34: CGFloat(v[11]),
                  m41: CGFloat(v[12]), m42: CGFloat(v[13]), m43: CGFloat(v[14]), m44: CGFloat(v[15]))
        #else
        self.init(m11: v[0], m12: v[1], m13: v[2], m14: v[3],
                  m21: v[4], m22: v[5], m23: v[6], m24: v[7],
                  m31: v[8], m32: v[9], m33: v[10], m34: v[11],
                  m41: v[12], m42: v[13], m43: v[14], m44: v[15])
        #endif
    }

    static func * (_ left: SCNMatrix4, right: SCNMatrix4) -> SCNMatrix4 {
        SCNMatrix4Mult(left, right)
    }
}
