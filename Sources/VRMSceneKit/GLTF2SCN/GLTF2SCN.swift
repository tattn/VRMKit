import VRMKit
import Foundation
import SceneKit
import SpriteKit

func semantic(of key: GLTF.Mesh.Primitive.AttributeKey) -> SCNGeometrySource.Semantic {
    switch key {
    case .POSITION: return .vertex
    case .NORMAL: return .normal
    case .TANGENT: return .tangent
    case .TEXCOORD_0: return .texcoord
    case .TEXCOORD_1: return .texcoord
    case .COLOR_0: return .color
    case .JOINTS_0: return .boneIndices
    case .WEIGHTS_0: return .boneWeights
    }
}

extension SCNGeometryPrimitiveType {
    func primitiveCount(ofCount count: Int) -> Int {
        switch self {
        case .line: return count / 2
        case .point: return count
        case .polygon: return count - 2
        case .triangles: return count / 3
        case .triangleStrip: return count - 2
        @unknown default: fatalError()
        }
    }
}

func primitiveTypeOf(_ mode: GLTF.Mesh.Primitive.Mode) -> SCNGeometryPrimitiveType? {
    switch mode {
    case .POINTS: return .point
    case .LINES: return .line
    case .TRIANGLES: return .triangles
    case .TRIANGLE_STRIP: return .triangleStrip
    case .LINE_LOOP, .LINE_STRIP, .TRIANGLE_FAN: return nil // TODO
    }
}

extension SIMD3 where Scalar == Float {
    func createSCNVector3() -> SCNVector3 {
        SCNVector3(x: SCNFloat(x), y: SCNFloat(y), z: SCNFloat(z))
    }
}

extension SIMD4 where Scalar == Float {
    func createSCNVector4() -> SCNVector4 {
        SCNVector4(x: SCNFloat(x), y: SCNFloat(y), z: SCNFloat(z), w: SCNFloat(w))
    }

    func createSKColor() -> SKColor {
        SKColor(red: CGFloat(x), green: CGFloat(y), blue: CGFloat(z), alpha: CGFloat(w))
    }
}

extension SKColor {
    convenience init(color3 values: [Double], alpha: CGFloat) {
        self.init(red: CGFloat(values[safe: 0] ?? 0),
                  green: CGFloat(values[safe: 1] ?? 0),
                  blue: CGFloat(values[safe: 2] ?? 0),
                  alpha: alpha)
    }
}
