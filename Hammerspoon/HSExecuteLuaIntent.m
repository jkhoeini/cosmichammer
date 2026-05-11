//
// HSExecuteLuaIntent.m
//
// This file was automatically generated and should not be edited.
//

#import "HSExecuteLuaIntent.h"

#if __has_include(<Intents/Intents.h>) && !TARGET_OS_TV

@implementation HSExecuteLuaIntent

@dynamic source;

@end

@interface HSExecuteLuaIntentResponse ()

@property (readwrite, NS_NONATOMIC_IOSONLY) HSExecuteLuaIntentResponseCode code;

@end

@implementation HSExecuteLuaIntentResponse

@synthesize code = _code;

@dynamic result, error;

- (instancetype)initWithCode:(HSExecuteLuaIntentResponseCode)code userActivity:(nullable NSUserActivity *)userActivity {
    self = [super init];
    if (self) {
        _code = code;
        self.userActivity = userActivity;
    }
    return self;
}

+ (instancetype)successIntentResponseWithResult:(NSString *)result {
    HSExecuteLuaIntentResponse *intentResponse = [[HSExecuteLuaIntentResponse alloc] initWithCode:HSExecuteLuaIntentResponseCodeSuccess userActivity:nil];
    intentResponse.result = result;
    return intentResponse;
}

+ (instancetype)failureIntentResponseWithError:(NSString *)error {
    HSExecuteLuaIntentResponse *intentResponse = [[HSExecuteLuaIntentResponse alloc] initWithCode:HSExecuteLuaIntentResponseCodeFailure userActivity:nil];
    intentResponse.error = error;
    return intentResponse;
}

@end

@implementation HSExecuteLuaSourceResolutionResult

+ (instancetype)unsupportedForReason:(HSExecuteLuaSourceUnsupportedReason)reason {
    return [super unsupportedWithReason:reason];
}

@end

#endif
