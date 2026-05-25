//
//  HSTestCase.h
//  Cosmic Hammer
//
//  Created by Chris Jones on 01/02/2016.
//  Copyright © 2016 Cosmic Hammer. All rights reserved.
//

#import <XCTest/XCTest.h>
#import "LuaSkin/LuaSkin.h"
#import "MJLua.h"

#define RUN_LUA_TEST() XCTAssertTrue([self luaTestFromSelector:_cmd], @"Test failed: %@", NSStringFromSelector(_cmd));
#define RUN_TWO_PART_LUA_TEST_WITH_TIMEOUT(timeout) [self twoPartTestName:_cmd withTimeout:timeout];

#define SKIP_IN_HEADLESS() if(self.isHeadless) { NSLog(@"Skipping %@ due to headless environment", NSStringFromSelector(_cmd)) ; XCTSkip("Test requires hardware (display, audio, keyboard, etc.)"); }

@interface HSTestCase : XCTestCase
@property (nonatomic) BOOL isHeadless;

/**
 Sets up the testing environment and loads a Lua file with require()

 @param requireName The name of a Lua file to load (without the .lua suffix). This file should contain the Lua functions required to execute your tests
 */
- (void)setUpWithRequire:(NSString *)requireName;

/**
 Executes Lua code and returns its result

 @param luaCode An NSString containing some Lua code

 @return An NSString containing the result of the code
 */
- (NSString *)runLua:(NSString *)luaCode;

/**
 Executes Lua code and checks whether it returns the string "Success"

 @important This method does not assert anything, you should assert that it returns true

 @param luaCode An NSString containing some Lua code

 @return A boolean, true if the Lua code returned "Success" otherwise false
 */
- (BOOL)luaTest:(NSString *)luaCode;

/**
Executes a two-part Lua test with a timeout.

 This is similar to luaTestWithCheckAndTimeOut, but automatically finds the second function by appending `Values` to the first function.
 The second function will be called repeatedly until it either returns successfully, or timeout is reached.
 */
- (void)twoPartTestName:(SEL)selector withTimeout:(NSTimeInterval)timeout;

/**
 Executes a two-part Lua test with a timeout.

 The provided setup code is executed immediately, and then the supplied check code will be tested every 0.5 seconds until it either passes, or `timeout` is reached

 @param timeOut        The amount of time to allow the test to run unsuccessfully, before failing it
 @param setupCode      An NSString containing some Lua code to instantiate the test
 @param checkCode      An NSString containing some Lua code to check if the test has passed
 */
- (void)luaTestWithCheckAndTimeOut:(NSTimeInterval)timeOut setupCode:(NSString *)setupCode checkCode:(NSString *)checkCode;

/**
 Executes a Lua function with the same name as an Objective C selector. This reduces the amount of typing required in the Objective C portions of your tests - if you name your Lua test functions correctly, all you need to do is call [self luaTestFromSelector:_cmd] in each method. This is also neatly abstracted to a #define called RUN_LUA_TEST()

 @important This method does not assert anything, you should assert that it returns true

 @param selector A selector, which will be transformed into a string. A Lua function of the same name will be called

 @return A boolean, true if the test passed, otherwise false
 */
- (BOOL)luaTestFromSelector:(SEL)selector;

/**
 Determines if the test run is happening in a headless environment (no display, audio, etc.)
 Set HEADLESS=1 in the environment to skip hardware-dependent tests.

 @return A boolean, true if the HEADLESS environment variable is set, false otherwise
 */
- (BOOL)runningHeadless;

@end
