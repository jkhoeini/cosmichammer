import XCTest

@objcMembers
class HThttp: HSTestCase {
    override func setUp() {
        super.setUpWithRequire("test_http")
    }

    override func tearDown() {
        super.tearDown()
    }

    func testHttpDoAsyncRequestWithCachePolicyParam() {
        twoPartTestName(#selector(testHttpDoAsyncRequestWithCachePolicyParam), timeout: 5)
    }

    func testHttpDoAsyncRequestWithoutEnableRedirectAndCachePolicyParam() {
        twoPartTestName(#selector(testHttpDoAsyncRequestWithoutEnableRedirectAndCachePolicyParam), timeout: 5)
    }

    func testHttpDoAsyncRequestWithRedirection() {
        twoPartTestName(#selector(testHttpDoAsyncRequestWithRedirection), timeout: 5)
    }

    func testHttpDoAsyncRequestWithoutRedirection() {
        twoPartTestName(#selector(testHttpDoAsyncRequestWithoutRedirection), timeout: 5)
    }
}
