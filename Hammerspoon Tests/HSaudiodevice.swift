import XCTest

@objcMembers
class HSaudiodevice: HSTestCase {
    override func setUp() {
        super.setUpWithRequire("test_audiodevice")
    }

    override func tearDown() {
        super.tearDown()
    }

    func testGetDefaultEffect() {
        XCTAssertTrue(luaTestFromSelector(#selector(testGetDefaultEffect)), "Test failed: testGetDefaultEffect")
    }

    func testGetDefaultOutput() {
        XCTAssertTrue(luaTestFromSelector(#selector(testGetDefaultOutput)), "Test failed: testGetDefaultOutput")
    }

    func testGetDefaultInput() {
        XCTAssertTrue(luaTestFromSelector(#selector(testGetDefaultInput)), "Test failed: testGetDefaultInput")
    }

    func testGetCurrentOutput() {
        XCTAssertTrue(luaTestFromSelector(#selector(testGetCurrentOutput)), "Test failed: testGetCurrentOutput")
    }

    func testGetCurrentInput() {
        XCTAssertTrue(luaTestFromSelector(#selector(testGetCurrentInput)), "Test failed: testGetCurrentInput")
    }

    func testGetAllDevices() throws {
        if isHeadless { throw XCTSkip("Test requires hardware (display, audio, keyboard, etc.)") }
        XCTAssertTrue(luaTestFromSelector(#selector(testGetAllDevices)), "Test failed: testGetAllDevices")
    }

    func testGetAllOutputDevices() throws {
        if isHeadless { throw XCTSkip("Test requires hardware (display, audio, keyboard, etc.)") }
        XCTAssertTrue(luaTestFromSelector(#selector(testGetAllOutputDevices)), "Test failed: testGetAllOutputDevices")
    }

    func testGetAllInputDevices() throws {
        if isHeadless { throw XCTSkip("Test requires hardware (display, audio, keyboard, etc.)") }
        XCTAssertTrue(luaTestFromSelector(#selector(testGetAllInputDevices)), "Test failed: testGetAllInputDevices")
    }

    func testFindDeviceByName() throws {
        if isHeadless { throw XCTSkip("Test requires hardware (display, audio, keyboard, etc.)") }
        XCTAssertTrue(luaTestFromSelector(#selector(testFindDeviceByName)), "Test failed: testFindDeviceByName")
    }

    func testFindDeviceByUID() throws {
        if isHeadless { throw XCTSkip("Test requires hardware (display, audio, keyboard, etc.)") }
        XCTAssertTrue(luaTestFromSelector(#selector(testFindDeviceByUID)), "Test failed: testFindDeviceByUID")
    }

    func testFindInputByName() throws {
        if isHeadless { throw XCTSkip("Test requires hardware (display, audio, keyboard, etc.)") }
        XCTAssertTrue(luaTestFromSelector(#selector(testFindInputByName)), "Test failed: testFindInputByName")
    }

    func testFindInputByUID() throws {
        if isHeadless { throw XCTSkip("Test requires hardware (display, audio, keyboard, etc.)") }
        XCTAssertTrue(luaTestFromSelector(#selector(testFindInputByUID)), "Test failed: testFindInputByUID")
    }

    func testFindOutputByName() throws {
        if isHeadless { throw XCTSkip("Test requires hardware (display, audio, keyboard, etc.)") }
        XCTAssertTrue(luaTestFromSelector(#selector(testFindOutputByName)), "Test failed: testFindOutputByName")
    }

    func testFindOutputByUID() throws {
        if isHeadless { throw XCTSkip("Test requires hardware (display, audio, keyboard, etc.)") }
        XCTAssertTrue(luaTestFromSelector(#selector(testFindOutputByUID)), "Test failed: testFindOutputByUID")
    }

    func testToString() {
        XCTAssertTrue(luaTestFromSelector(#selector(testToString)), "Test failed: testToString")
    }

    func testSetDefaultEffect() {
        XCTAssertTrue(luaTestFromSelector(#selector(testSetDefaultEffect)), "Test failed: testSetDefaultEffect")
    }

    func testSetDefaultOutput() {
        XCTAssertTrue(luaTestFromSelector(#selector(testSetDefaultOutput)), "Test failed: testSetDefaultOutput")
    }

    func testSetDefaultInput() {
        XCTAssertTrue(luaTestFromSelector(#selector(testSetDefaultInput)), "Test failed: testSetDefaultInput")
    }

    func testName() throws {
        if isHeadless { throw XCTSkip("Test requires hardware (display, audio, keyboard, etc.)") }
        XCTAssertTrue(luaTestFromSelector(#selector(testName)), "Test failed: testName")
    }

    func testUID() throws {
        if isHeadless { throw XCTSkip("Test requires hardware (display, audio, keyboard, etc.)") }
        XCTAssertTrue(luaTestFromSelector(#selector(testUID)), "Test failed: testUID")
    }

    func testIsInputDevice() {
        XCTAssertTrue(luaTestFromSelector(#selector(testIsInputDevice)), "Test failed: testIsInputDevice")
    }

    func testIsOutputDevice() {
        XCTAssertTrue(luaTestFromSelector(#selector(testIsOutputDevice)), "Test failed: testIsOutputDevice")
    }

    func testMute() {
        XCTAssertTrue(luaTestFromSelector(#selector(testMute)), "Test failed: testMute")
    }

    func testThru() {
        XCTAssertTrue(luaTestFromSelector(#selector(testThru)), "Test failed: testThru")
    }

    func testVolume() {
        XCTAssertTrue(luaTestFromSelector(#selector(testVolume)), "Test failed: testVolume")
    }

    func testInputVolume() {
        XCTAssertTrue(luaTestFromSelector(#selector(testInputVolume)), "Test failed: testInputVolume")
    }

    func testOutputVolume() {
        XCTAssertTrue(luaTestFromSelector(#selector(testOutputVolume)), "Test failed: testOutputVolume")
    }

    func testJackConnected() {
        XCTAssertTrue(luaTestFromSelector(#selector(testJackConnected)), "Test failed: testJackConnected")
    }

    func testTransportType() {
        XCTAssertTrue(luaTestFromSelector(#selector(testTransportType)), "Test failed: testTransportType")
    }

    func testWatcher() {
        XCTAssertTrue(luaTestFromSelector(#selector(testWatcher)), "Test failed: testWatcher")
    }

    func testWatcherCallback() throws {
        if isHeadless { throw XCTSkip("Test requires hardware (display, audio, keyboard, etc.)") }

        let timeoutDate = Date(timeIntervalSinceNow: 5.0)
        var result = false

        _ = runLua("testWatcherCallback()")

        while !result && timeoutDate.timeIntervalSinceNow > 0 {
            CFRunLoopRunInMode(.defaultMode, 0.5, false)
            result = luaTest("testWatcherCallbackResult()")
        }

        XCTAssertTrue(result, "hs.audiodevice watcher callback failed")
    }

    func testInputSupportsDataSources() throws {
        if isHeadless { throw XCTSkip("Test requires hardware (display, audio, keyboard, etc.)") }
        XCTAssertTrue(luaTestFromSelector(#selector(testInputSupportsDataSources)), "Test failed: testInputSupportsDataSources")
    }

    func testOutputSupportsDataSources() throws {
        if isHeadless { throw XCTSkip("Test requires hardware (display, audio, keyboard, etc.)") }
        XCTAssertTrue(luaTestFromSelector(#selector(testOutputSupportsDataSources)), "Test failed: testOutputSupportsDataSources")
    }

    func testCurrentInputDataSource() throws {
        if isHeadless { throw XCTSkip("Test requires hardware (display, audio, keyboard, etc.)") }
        XCTAssertTrue(luaTestFromSelector(#selector(testCurrentInputDataSource)), "Test failed: testCurrentInputDataSource")
    }

    func testCurrentOutputDataSource() throws {
        if isHeadless { throw XCTSkip("Test requires hardware (display, audio, keyboard, etc.)") }
        XCTAssertTrue(luaTestFromSelector(#selector(testCurrentOutputDataSource)), "Test failed: testCurrentOutputDataSource")
    }

    func testAllInputDataSources() throws {
        if isHeadless { throw XCTSkip("Test requires hardware (display, audio, keyboard, etc.)") }
        XCTAssertTrue(luaTestFromSelector(#selector(testAllInputDataSources)), "Test failed: testAllInputDataSources")
    }

    func testAllOutputDataSources() throws {
        if isHeadless { throw XCTSkip("Test requires hardware (display, audio, keyboard, etc.)") }
        XCTAssertTrue(luaTestFromSelector(#selector(testAllOutputDataSources)), "Test failed: testAllOutputDataSources")
    }

    func testDataSourceToString() throws {
        if isHeadless { throw XCTSkip("Test requires hardware (display, audio, keyboard, etc.)") }
        XCTAssertTrue(luaTestFromSelector(#selector(testDataSourceToString)), "Test failed: testDataSourceToString")
    }

    func testDataSourceName() throws {
        if isHeadless { throw XCTSkip("Test requires hardware (display, audio, keyboard, etc.)") }
        XCTAssertTrue(luaTestFromSelector(#selector(testDataSourceName)), "Test failed: testDataSourceName")
    }

    func testDataSourceSetDefault() throws {
        if isHeadless { throw XCTSkip("Test requires hardware (display, audio, keyboard, etc.)") }
        XCTAssertTrue(luaTestFromSelector(#selector(testDataSourceSetDefault)), "Test failed: testDataSourceSetDefault")
    }
}
