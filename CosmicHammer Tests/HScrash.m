//
//  HScrash.m
//  Cosmic Hammer
//
//  Created by Chris Jones on 03/07/2017.
//  Copyright © 2017 Cosmic Hammer. All rights reserved.
//

#import "HSTestCase.h"

@interface HScrash : HSTestCase

@end

@implementation HScrash

- (void)setUp {
    [super setUpWithRequire:@"test_crash"];
    // Put setup code here. This method is called before the invocation of each test method in the class.
}

- (void)tearDown {
    // Put teardown code here. This method is called after the invocation of each test method in the class.
    [super tearDown];
}

- (void)testResidentSize {
    RUN_LUA_TEST();
}

- (void)testThrowTheWorld {
    NSString *result = [self runLua:@"testThrowTheWorld()"];
    XCTAssertTrue([result containsString:@"objc_exception_throw"], @"hs.crash.throwException() didn't throw an exception");
}

@end
