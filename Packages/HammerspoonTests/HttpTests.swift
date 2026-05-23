import Testing
import Foundation

extension HammerspoonTests {
    @Suite @MainActor final class Http {
        init() throws { try loadLuaModule("test_http") }

        @Test func testHttpDoAsyncRequestWithCachePolicyParam() {
            runTwoPartLuaTest(timeout: 5)
        }

        @Test func testHttpDoAsyncRequestWithoutEnableRedirectAndCachePolicyParam() {
            runTwoPartLuaTest(timeout: 5)
        }

        @Test func testHttpDoAsyncRequestWithRedirection() {
            runTwoPartLuaTest(timeout: 5)
        }

        @Test func testHttpDoAsyncRequestWithoutRedirection() {
            runTwoPartLuaTest(timeout: 5)
        }
    }
}
