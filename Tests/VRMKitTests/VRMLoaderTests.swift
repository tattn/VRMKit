import XCTest
import VRMKit

class VRMLoaderTests: XCTestCase {

    func testLoadMetaFromVRM0Data() throws {
        let meta = try VRMLoader().loadMeta(withData: Resources.aliciaSolid.data)

        XCTAssertEqual(meta.title, "Alicia Solid")
        XCTAssertEqual(meta.author, "DWANGO Co., Ltd.")
        XCTAssertEqual(meta.texture, 6)
        XCTAssertEqual(meta.licenseName, "Other")
    }

    func testLoadMetaFromVRM1Data() throws {
        let meta = try VRMLoader().loadMeta(withData: Resources.seedSan.data)

        XCTAssertEqual(meta.title, "Seed-san")
        XCTAssertEqual(meta.author, "VirtualCast, Inc.")
        XCTAssertEqual(meta.texture, 14)
        XCTAssertEqual(meta.licenseName, "https://vrm.dev/licenses/1.0/")
    }

    func testLoadMetaFromURL() throws {
        let meta = try VRMLoader().loadMeta(withURL: Resources.aliciaSolid.url)

        XCTAssertEqual(meta.title, "Alicia Solid")
        XCTAssertEqual(meta.author, "DWANGO Co., Ltd.")
    }
}
