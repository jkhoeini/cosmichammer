import XCTest

@objcMembers
class HSfs: HSTestCase {
    override func setUp() {
        super.setUpWithRequire("test_fs")
        _ = luaTestFromSelector(#selector(setUp))
    }

    override func tearDown() {
        _ = luaTestFromSelector(#selector(tearDown))
        super.tearDown()
    }

    func testMkdir() {
        XCTAssertTrue(luaTestFromSelector(#selector(testMkdir)), "Test failed: testMkdir")
    }

    func testChdir() {
        XCTAssertTrue(luaTestFromSelector(#selector(testChdir)), "Test failed: testChdir")
    }

    func testRmdir() {
        XCTAssertTrue(luaTestFromSelector(#selector(testRmdir)), "Test failed: testRmdir")
    }

    func testAttributes() {
        XCTAssertTrue(luaTestFromSelector(#selector(testAttributes)), "Test failed: testAttributes")
    }

    func testTags() {
        XCTAssertTrue(luaTestFromSelector(#selector(testTags)), "Test failed: testTags")
    }

    func testLinks() {
        XCTAssertTrue(luaTestFromSelector(#selector(testLinks)), "Test failed: testLinks")
    }

    func testTouch() {
        XCTAssertTrue(luaTestFromSelector(#selector(testTouch)), "Test failed: testTouch")
    }

    func testFileUTI() {
        XCTAssertTrue(luaTestFromSelector(#selector(testFileUTI)), "Test failed: testFileUTI")
    }

    func testDirWalker() {
        XCTAssertTrue(luaTestFromSelector(#selector(testDirWalker)), "Test failed: testDirWalker")
    }

    func testLockDir() {
        XCTAssertTrue(luaTestFromSelector(#selector(testLockDir)), "Test failed: testLockDir")
    }

    func testLock() {
        XCTAssertTrue(luaTestFromSelector(#selector(testLock)), "Test failed: testLock")
    }

    func testVolumes() throws {
        if isHeadless { throw XCTSkip("Test requires hardware (display, audio, keyboard, etc.)") }
        luaTestWithCheckAndTimeOut(10, setupCode: "testVolumes()", checkCode: "testVolumesValues()")
    }
}
