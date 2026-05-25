//
//  Cosmic HammerUITests.m
//  Cosmic HammerUITests
//
//  Created by Chris Jones on 14/12/2015.
//  Copyright © 2015 Cosmic Hammer. All rights reserved.
//

#import <XCTest/XCTest.h>

@interface Cosmic HammerUITests : XCTestCase

@end

@implementation Cosmic HammerUITests

- (void)setUp {
    [super setUp];
    
    // Put setup code here. This method is called before the invocation of each test method in the class.
    
    // In UI tests it is usually best to stop immediately when a failure occurs.
    self.continueAfterFailure = NO;
    // UI tests must launch the application that they test. Doing this in setup will make sure it happens for each test method.
    XCUIApplication *app = [[XCUIApplication alloc] init];
    app.launchEnvironment = @{@"XCTESTING": @"1"};
    [app launch];
    
    // In UI tests it’s important to set the initial state - such as interface orientation - required for your tests before they run. The setUp method is a good place to do this.
}

- (void)tearDown {
    // Put teardown code here. This method is called after the invocation of each test method in the class.
    [super tearDown];
}

- (void)testPreferencesWindow {
    // TODO: Do some XCTAssert()ing based on what the defaults should be. Each checkbox can be inspected with .value (0 or 1).
    XCUIApplication *app = [[XCUIApplication alloc] init];
    XCUIElement *cosmicHammerConsoleWindow = app.windows[@"Cosmic Hammer Console"];
    XCUIElement *textField = [cosmicHammerConsoleWindow childrenMatchingType:XCUIElementTypeTextField].element;

    [cosmicHammerConsoleWindow click];
    [textField typeText:@"hs.openPreferences()\r"];
    [app.staticTexts[@"Cosmic Hammer Preferences"] click];

//    XCUIElement *launchCosmicHammerAtLoginCheckBox = app.checkBoxes[@"Launch Cosmic Hammer at login"];
//    [launchCosmicHammerAtLoginCheckBox click];
//    [launchCosmicHammerAtLoginCheckBox click];
//    
//    XCUIElement *showDockIconCheckBox = app.checkBoxes[@"Show dock icon"];
//    [showDockIconCheckBox click];
//    [showDockIconCheckBox click];
//    
//    XCUIElement *showMenuIconCheckBox = app.checkBoxes[@"Show menu icon"];
//    [showMenuIconCheckBox click];
//    [app.sheets[@"alert"].buttons[@"OK"] click];
//    [showMenuIconCheckBox click];
//    
//    XCUIElement *keepConsoleWindowOnTopCheckBox = app.checkBoxes[@"Keep Console window on top"];
//    [keepConsoleWindowOnTopCheckBox click];
//    [keepConsoleWindowOnTopCheckBox click];
//    
//    XCUIElement *sendCrashDataRequiresRestartCheckBox = app.checkBoxes[@"Send crash data (requires restart)"];
//    [sendCrashDataRequiresRestartCheckBox click];
//    [sendCrashDataRequiresRestartCheckBox click];
}

- (void)testWindowMove {
    XCUIApplication *app = [[XCUIApplication alloc] init];
    XCUIElement *cosmicHammerConsoleWindow = app.windows[@"Cosmic Hammer Console"];
    CGRect frame = cosmicHammerConsoleWindow.frame;
    NSLog(@"Initial Console window: %f,%f %fx%f", frame.origin.x, frame.origin.y, frame.size.width, frame.size.height);
    XCUIElement *textField = [cosmicHammerConsoleWindow childrenMatchingType:XCUIElementTypeTextField].element;

    [cosmicHammerConsoleWindow click];
    [textField typeText:@"hs.window.focusedWindow()"];
    [textField typeKey:@";" modifierFlags:XCUIKeyModifierShift];
    [textField typeText:@"setFrame(hs.geometry.rect(0,50,400,300), 0)\r"];

    CGRect newFrame = cosmicHammerConsoleWindow.frame;

    XCTAssertTrue(CGRectEqualToRect(newFrame, CGRectMake(0.0, 50.0, 400.0, 300.0)), @"hs.window:move() failed");
}
@end
