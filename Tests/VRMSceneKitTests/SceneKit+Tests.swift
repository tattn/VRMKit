import Testing
import SceneKit
@testable import VRMSceneKit

@Suite
struct SceneKit_Tests {

    @Test
    func testSCNMatrix4_initWithArray() throws {
        do {
            let v: [Float] = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16]
            let matrix = try SCNMatrix4(v)
            #expect(v.map { SCNFloat($0) } == matrix.array)
        }

        do {
            let v: [Float] = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15]
            #expect(throws: (any Error).self) { try SCNMatrix4(v) }
            let v2: [Float] = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17]
            #expect(throws: (any Error).self) { try SCNMatrix4(v2) }
        }
    }

    @Test
    func testSCNMatrix4_mulByMatrix4() throws {
        let matrix = try SCNMatrix4([1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16] as [Float])
        let expected = SCNMatrix4(m11: 90.0, m12: 100.0, m13: 110.0, m14: 120.0, m21: 202.0, m22: 228.0, m23: 254.0, m24: 280.0, m31: 314.0, m32: 356.0, m33: 398.0, m34: 440.0, m41: 426.0, m42: 484.0, m43: 542.0, m44: 600.0)
        #expect(matrix * matrix == expected)
    }
}
