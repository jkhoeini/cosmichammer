import XCTest

@objcMembers
class HSrequire_allSwift: HSTestCase {

    override func setUp() {
        super.setUp()
    }

    override func tearDown() {
        super.tearDown()
    }

    func testRequireAll() {
        let res = runLua("return testrequires()")
        let errors = res?.components(separatedBy: CharacterSet(charactersIn: "\u{1F4A9}")) ?? []
        let filteredErrors = errors.filter { !$0.contains("failed to create new local port") && !$0.isEmpty }
        XCTAssertEqual(0, filteredErrors.count, "Some modules failed to load: \(filteredErrors)")
    }
}
