import XCTest

@objcMembers
class HSdistributednotifications: HSTestCase {
    override func setUp() {
        super.setUpWithRequire("test_distributednotifications")
    }

    override func tearDown() {
        super.tearDown()
    }

    func testdistributednotifications() {
        luaTestWithCheckAndTimeOut(5, setupCode: "testDistributedNotifications()", checkCode: "testDistNotValueCheck()")
    }
}
