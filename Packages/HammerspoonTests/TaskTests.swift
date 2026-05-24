import Testing
import Foundation

extension HammerspoonTests {
    @Suite(.serialized) @MainActor final class Task {
        init() throws { try loadLuaModule("test_task") }

        @Test func testNewTask() { runLuaTest() }
        @Test func testTaskLifecycle() { runLuaTest() }
        @Test func testTaskEnvironment() { runLuaTest() }
        @Test func testTaskBlock() { runLuaTest() }
        @Test func testTaskWorkingDirectory() { runLuaTest() }

        @Test func testSimpleTask() {
            luaTestWithCheckAndTimeout(5, setup: "testSimpleTask()", check: "testSimpleTaskValueCheck()")
        }

        @Test func testSimpleTaskFail() {
            luaTestWithCheckAndTimeout(5, setup: "testSimpleTaskFail()", check: "testSimpleTaskFailValueCheck()")
        }

        @Test func testStreamingTask() {
            luaTestWithCheckAndTimeout(10, setup: "testStreamingTask()", check: "testStreamingTaskValueCheck()")
        }
    }
}
