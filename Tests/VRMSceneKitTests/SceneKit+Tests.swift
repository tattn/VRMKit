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
}
