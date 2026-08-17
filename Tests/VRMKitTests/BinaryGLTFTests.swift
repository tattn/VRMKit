import XCTest
import VRMKit

class BinaryGLTFTests: XCTestCase {
    
    override func setUp() {
        super.setUp()
    }
    
    func testLoadVRM() {
        let binaryGltf = try! BinaryGLTF(data: Resources.aliciaSolid.data)
        let json = binaryGltf.jsonData
        XCTAssertEqual(json.asset.generator, "UniGLTF")
        XCTAssertEqual(json.asset.version, "2.0")
    }

    func testStridedSubdataCopiesBytes() {
        let data = Data([0, 1, 2, 3, 4, 5, 6, 7, 8, 9])
        let strided = data.subdata(offset: 1, size: 2, stride: 4, count: 2)
        XCTAssertEqual(Array(strided), [1, 2, 5, 6])
    }
    
}
