#import "HSExtensions/ObjCExceptionCatch.h"

BOOL objc_tryCatch(void (NS_NOESCAPE ^block)(void), NSString *__autoreleasing *outError) {
    @try {
        block();
        return YES;
    }
    @catch (NSException *exception) {
        if (outError) {
            *outError = [NSString stringWithFormat:@"%@: %@", exception.name, exception.reason ?: @"(no reason)"];
        }
        return NO;
    }
}
