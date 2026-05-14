import XCTest

private var testFlag = false

private func verifyShutdown(_ L: OpaquePointer!) -> Int32 {
    testFlag = true
    return 0
}

@objcMembers
class HScoresetup: HSTestCase {
    override func setUp() {
        super.setUpWithRequire("test_coresetup")
        testFlag = false
    }

    override func tearDown() {
        super.tearDown()
    }

    func testOSExit() {
        XCTAssertTrue(luaTestFromSelector(#selector(testOSExit)), "Test failed: testOSExit")
    }

    func testConfigDir() {
        XCTAssertTrue(luaTestFromSelector(#selector(testConfigDir)), "Test failed: testConfigDir")
    }

    func testDocstringsJSONFile() {
        XCTAssertTrue(luaTestFromSelector(#selector(testDocstringsJSONFile)), "Test failed: testDocstringsJSONFile")
    }

    func testProcessInfo() {
        XCTAssertTrue(luaTestFromSelector(#selector(testProcessInfo)), "Test failed: testProcessInfo")
    }

    func testShutdownCallback() {
        var shutdownLib = [
            luaL_Reg(name: "verifyShutdown", func: verifyShutdown),
            luaL_Reg(name: nil, func: nil)
        ]

        let skin = LuaSkin.shared(withState: nil)
        skin.registerLibrary("shutdownLib", functions: &shutdownLib, metaFunctions: nil)
        lua_setglobal(skin.L, "shutdownLib")

        XCTAssertTrue(luaTestFromSelector(#selector(testShutdownCallback)), "Test failed: testShutdownCallback")

        let timeoutDate = Date(timeIntervalSinceNow: 5)
        var result = false

        while !result && timeoutDate.timeIntervalSinceNow > 0 {
            CFRunLoopRunInMode(.defaultMode, 0.5, false)
            result = testFlag
        }
        XCTAssertTrue(testFlag, "hs.shutdownCallback was not called successfully")
    }

    func testAccessibilityState() {
        XCTAssertTrue(luaTestFromSelector(#selector(testAccessibilityState)), "Test failed: testAccessibilityState")
    }

    func testAutoLaunch() {
        XCTAssertTrue(luaTestFromSelector(#selector(testAutoLaunch)), "Test failed: testAutoLaunch")
    }

    func testAutomaticallyCheckForUpdates() {
        XCTAssertTrue(luaTestFromSelector(#selector(testAutomaticallyCheckForUpdates)), "Test failed: testAutomaticallyCheckForUpdates")
    }

    func testCheckForUpdates() {
        XCTAssertTrue(luaTestFromSelector(#selector(testCheckForUpdates)), "Test failed: testCheckForUpdates")
    }

    func testCleanUTF8forConsole() {
        XCTAssertTrue(luaTestFromSelector(#selector(testCleanUTF8forConsole)), "Test failed: testCleanUTF8forConsole")
    }

    func testConsoleOnTop() {
        XCTAssertTrue(luaTestFromSelector(#selector(testConsoleOnTop)), "Test failed: testConsoleOnTop")
    }

    func testDockIcon() {
        XCTAssertTrue(luaTestFromSelector(#selector(testDockIcon)), "Test failed: testDockIcon")
    }

    func testGetObjectMetatable() {
        XCTAssertTrue(luaTestFromSelector(#selector(testGetObjectMetatable)), "Test failed: testGetObjectMetatable")
    }

    func testMenuIcon() {
        XCTAssertTrue(luaTestFromSelector(#selector(testMenuIcon)), "Test failed: testMenuIcon")
    }
}
