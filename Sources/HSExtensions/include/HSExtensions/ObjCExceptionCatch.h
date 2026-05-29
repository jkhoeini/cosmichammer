#ifndef ObjCExceptionCatch_h
#define ObjCExceptionCatch_h

#import <Foundation/Foundation.h>

/// Run a block inside @try/@catch. Returns YES on success, NO if an
/// NSException was thrown. On failure, *outError is set to the
/// exception description.
BOOL objc_tryCatch(void (NS_NOESCAPE ^_Nonnull block)(void),
                   NSString *_Nullable *_Nullable outError);

#endif
