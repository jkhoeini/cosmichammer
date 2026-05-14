//
//  HSTestCase.swift
//  Hammerspoon
//
//  Created by Chris Jones on 01/02/2016.
//  Copyright © 2016 Hammerspoon. All rights reserved.
//

import XCTest

// MARK: - Convenience macros (use these in subclasses)

/// Equivalent of RUN_LUA_TEST() — call from any @objc test method.
func runLuaTest(_ testCase: HSTestCase, selector: Selector, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertTrue(testCase.luaTestFromSelector(selector), "Test failed: \(NSStringFromSelector(selector))", file: file, line: line)
}

/// Equivalent of RUN_TWO_PART_LUA_TEST_WITH_TIMEOUT(timeout).
func runTwoPartLuaTest(_ testCase: HSTestCase, selector: Selector, timeout: TimeInterval) {
    testCase.twoPartTestName(selector, timeout: timeout)
}

/// Equivalent of SKIP_IN_HEADLESS().
func skipInHeadless(_ testCase: HSTestCase, selector: Selector) throws {
    if testCase.isHeadless {
        NSLog("Skipping %@ due to headless environment", NSStringFromSelector(selector))
        throw XCTSkip("Test requires hardware (display, audio, keyboard, etc.)")
    }
}

// MARK: - HSTestCase

@objcMembers
class HSTestCase: XCTestCase {

    var isHeadless: Bool = false

    // MARK: Setup / Teardown

    /// Sets up the testing environment and loads a Lua file with require().
    ///
    /// - Parameter requireName: The name of a Lua file to load (without the .lua suffix).
    ///   This file should contain the Lua functions required to execute your tests.
    func setUpWithRequire(_ requireName: String) {
        super.setUp()
        isHeadless = runningHeadless()

        let result = runLua("require('\(requireName)')")
        XCTAssertEqual("true", result, "Unable to load \(requireName).lua")
    }

    override func tearDown() {
        MJLuaReplace()
        super.tearDown()
    }

    // MARK: Lua execution helpers

    /// Executes Lua code and returns its result.
    ///
    /// - Parameter luaCode: A string containing some Lua code.
    /// - Returns: A string containing the result of the code.
    func runLua(_ luaCode: String) -> String? {
        return MJLuaRunString(luaCode)
    }

    /// Executes Lua code and checks whether it returns the string "Success".
    ///
    /// - Important: This method does not assert anything; you should assert that it returns `true`.
    /// - Parameter luaCode: A string containing some Lua code.
    /// - Returns: `true` if the Lua code returned "Success", otherwise `false`.
    func luaTest(_ luaCode: String) -> Bool {
        let result = runLua(luaCode)
        NSLog("Test returned: %@ for: %@", result ?? "(nil)", luaCode)
        return result == "Success"
    }

    /// Executes a two-part Lua test with a timeout.
    ///
    /// The provided setup code is executed immediately, and then the supplied check code
    /// will be tested every 0.5 seconds until it either passes or `timeOut` is reached.
    ///
    /// - Parameters:
    ///   - timeOut: The amount of time to allow the test to run unsuccessfully before failing it.
    ///   - setupCode: Lua code to instantiate the test.
    ///   - checkCode: Lua code to check if the test has passed.
    func luaTestWithCheckAndTimeOut(_ timeOut: TimeInterval, setupCode: String, checkCode: String) {
        let expectation = self.expectation(description: setupCode)

        NSLog("Calling setup code: %@", setupCode)
        let result = runLua(setupCode)
        NSLog("Test returned %@ for: %@", result ?? "(nil)", setupCode)

        if result != "Success" {
            // Invert the expectation and then fulfill it, to force a failure
            expectation.isInverted = true
            expectation.fulfill()
            return
        }

        let timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] timer in
            guard let self else { return }
            NSLog("Calling check code: %@", checkCode)
            let passed = self.luaTest(checkCode)
            if passed {
                expectation.fulfill()
                timer.invalidate()
            }
        }

        waitForExpectations(timeout: timeOut) { error in
            if let error {
                NSLog("%@ failed: %@", setupCode, error.localizedDescription)
            } else {
                NSLog("%@ succeeded", setupCode)
            }
            timer.invalidate()
        }
    }

    /// Executes a two-part Lua test with a timeout.
    ///
    /// This is similar to `luaTestWithCheckAndTimeOut`, but automatically finds the second
    /// function by appending `Values` to the first function.
    ///
    /// - Parameters:
    ///   - selector: The test selector whose name becomes the Lua function name.
    ///   - timeout: The amount of time to allow the test to run before failing it.
    func twoPartTestName(_ selector: Selector, timeout: TimeInterval) {
        let funcName = NSStringFromSelector(selector)
        luaTestWithCheckAndTimeOut(timeout,
                                   setupCode: "\(funcName)()",
                                   checkCode: "\(funcName)Values()")
    }

    /// Executes a Lua function with the same name as an Objective-C selector.
    ///
    /// This reduces the amount of typing required in test code -- if you name your Lua test
    /// functions correctly, all you need to do is call `luaTestFromSelector(_cmd)`.
    ///
    /// - Important: This method does not assert anything; you should assert that it returns `true`.
    /// - Parameter selector: A selector which will be transformed into a string.
    ///   A Lua function of the same name will be called.
    /// - Returns: `true` if the test passed, otherwise `false`.
    func luaTestFromSelector(_ selector: Selector) -> Bool {
        let funcName = NSStringFromSelector(selector)
        NSLog("Calling Lua function from selector: %@()", funcName)
        return luaTest("\(funcName)()")
    }

    /// Determines if the test run is happening in a headless environment.
    ///
    /// Set `HEADLESS=1` in the environment to skip hardware-dependent tests.
    /// - Returns: `true` if the `HEADLESS` environment variable is set.
    func runningHeadless() -> Bool {
        return getenv("HEADLESS") != nil
    }

    // MARK: - Self-tests

    func testrunLua() {
        let result = runLua("return 'hello world!'")
        XCTAssertEqual("hello world!", result, "Lua code evaluation is not working")
    }

    func testTestLuaSuccess() {
        _ = luaTest("return 'Success'")
    }
}
