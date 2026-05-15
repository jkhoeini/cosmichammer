/**
 * The HTTPMessage class is a simple Objective-C wrapper around Apple's CFHTTPMessage class.
**/

#import <Foundation/Foundation.h>

#if TARGET_OS_IPHONE
  // Note: You may need to add the CFNetwork Framework to your project
  #import <CFNetwork/CFNetwork.h>
#endif

#define HTTPVersion1_0  ((NSString *)kCFHTTPVersion1_0)
#define HTTPVersion1_1  ((NSString *)kCFHTTPVersion1_1)

// Swift-visible constants (macros are not imported into Swift)
static NSString * const HTTPVersion1_0_str NS_SWIFT_NAME(HTTPVersion1_0_str) = @"HTTP/1.0";
static NSString * const HTTPVersion1_1_str NS_SWIFT_NAME(HTTPVersion1_1_str) = @"HTTP/1.1";


@interface HTTPMessage : NSObject
{
	CFHTTPMessageRef message;
}

- (id)initEmptyRequest;

- (id)initRequestWithMethod:(NSString *)method URL:(NSURL *)url version:(NSString *)version;

- (id)initResponseWithStatusCode:(NSInteger)code description:(NSString *)description version:(NSString *)version;

- (BOOL)appendData:(NSData *)data;

- (BOOL)isHeaderComplete;

- (NSString *)version;

- (NSString *)method;
- (NSURL *)url;

- (NSInteger)statusCode;

- (NSDictionary *)allHeaderFields;
- (NSString *)headerField:(NSString *)headerField;

- (void)setHeaderField:(NSString *)headerField value:(NSString *)headerFieldValue;

- (NSData *)messageData;

- (NSData *)body;
- (void)setBody:(NSData *)body;

@end
