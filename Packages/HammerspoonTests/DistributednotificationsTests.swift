import Testing
import Foundation

extension HammerspoonTests {
    @Suite(.serialized) @MainActor final class Distributednotifications {
        init() throws { try loadLuaModule("test_distributednotifications") }

        @Test func testdistributednotifications() {
            luaTestWithCheckAndTimeout(5, setup: "testDistributedNotifications()", check: "testDistNotValueCheck()")
        }
    }
}
