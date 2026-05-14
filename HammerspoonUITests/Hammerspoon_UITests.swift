import XCTest

@objcMembers
class HammerspoonUITestsSwift: XCTestCase {

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment = ["XCTESTING": "1"]
        app.launch()
    }

    override func tearDown() {
        super.tearDown()
    }

    func testPreferencesWindow() {
        let app = XCUIApplication()
        let hammerspoonConsoleWindow = app.windows["Hammerspoon Console"]
        let textField = hammerspoonConsoleWindow.children(matching: .textField).element

        hammerspoonConsoleWindow.click()
        textField.typeText("hs.openPreferences()\r")
        app.staticTexts["Hammerspoon Preferences"].click()
    }

    func testWindowMove() {
        let app = XCUIApplication()
        let hammerspoonConsoleWindow = app.windows["Hammerspoon Console"]
        let frame = hammerspoonConsoleWindow.frame
        NSLog("Initial Console window: %f,%f %fx%f", frame.origin.x, frame.origin.y, frame.size.width, frame.size.height)
        let textField = hammerspoonConsoleWindow.children(matching: .textField).element

        hammerspoonConsoleWindow.click()
        textField.typeText("hs.window.focusedWindow()")
        textField.typeKey(";", modifierFlags: .shift)
        textField.typeText("setFrame(hs.geometry.rect(0,50,400,300), 0)\r")

        let newFrame = hammerspoonConsoleWindow.frame

        XCTAssertTrue(newFrame.equalTo(CGRect(x: 0.0, y: 50.0, width: 400.0, height: 300.0)), "hs.window:move() failed")
    }
}
