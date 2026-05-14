import XCTest

@objcMembers
class HStaskSwift: HSTestCase {

    override func setUp() {
        super.setUpWithRequire("test_task")
    }

    override func tearDown() {
        super.tearDown()
    }

    func testNewTask() {
        XCTAssertTrue(luaTestFromSelector(#selector(testNewTask)), "Test failed: testNewTask")
    }

    func testSimpleTask() {
        luaTestWithCheckAndTimeOut(5, setupCode: "testSimpleTask()", checkCode: "testSimpleTaskValueCheck()")
    }

    func testSimpleTaskFail() {
        luaTestWithCheckAndTimeOut(5, setupCode: "testSimpleTaskFail()", checkCode: "testSimpleTaskFailValueCheck()")
    }

    func testStreamingTask() {
        luaTestWithCheckAndTimeOut(10, setupCode: "testStreamingTask()", checkCode: "testStreamingTaskValueCheck()")
    }

    func testTaskLifecycle() {
        XCTAssertTrue(luaTestFromSelector(#selector(testTaskLifecycle)), "Test failed: testTaskLifecycle")
    }

    func testTaskEnvironment() {
        XCTAssertTrue(luaTestFromSelector(#selector(testTaskEnvironment)), "Test failed: testTaskEnvironment")
    }

    func testTaskBlock() {
        XCTAssertTrue(luaTestFromSelector(#selector(testTaskBlock)), "Test failed: testTaskBlock")
    }

    func testTaskWorkingDirectory() {
        XCTAssertTrue(luaTestFromSelector(#selector(testTaskWorkingDirectory)), "Test failed: testTaskWorkingDirectory")
    }
}
