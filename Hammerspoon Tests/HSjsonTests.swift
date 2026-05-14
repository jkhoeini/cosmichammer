import XCTest

@objcMembers
class HSjsonTestsSwift: HSTestCase {

    override func setUp() {
        super.setUpWithRequire("test_json")
    }

    override func tearDown() {
        super.tearDown()
    }

    func testEncodeDecode() {
        XCTAssertTrue(luaTestFromSelector(#selector(testEncodeDecode)), "Test failed: testEncodeDecode")
    }

    func testEncodeDecodeFailures() {
        XCTAssertFalse(luaTestFromSelector(#selector(testEncodeDecodeFailures)), "Test failed: testEncodeDecodeFailures")
    }

    func testReadWrite() {
        XCTAssertTrue(luaTestFromSelector(#selector(testReadWrite)), "Test failed: testReadWrite")
    }
}
