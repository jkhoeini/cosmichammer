import Testing
import Foundation

extension CosmicHammerTests {
    @Suite(.serialized) @MainActor final class Distributednotifications {
        init() throws { try loadLuaModule("test_distributednotifications") }

        @Test func testdistributednotifications() {
            luaTestWithCheckAndTimeout(5, setup: "testDistributedNotifications()", check: "testDistNotValueCheck()")
        }
    }
}
