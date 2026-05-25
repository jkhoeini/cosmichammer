/**
 * Logging macros for CocoaHTTPServer.
 *
 * There are 4 log levels:
 * - Error
 * - Warning
 * - Info
 * - Verbose
 *
 * In addition to this, there is a Trace flag that can be enabled.
 * When tracing is enabled, it spits out the methods that are being called.
 *
 * Please note that tracing is separate from the log levels.
 * For example, one could set the log level to warning, and enable tracing.
 *
 * To use logging within your own custom files, follow the steps below.
 *
 * Step 1:
 * Import this header in your implementation file:
 *
 * #import "HTTPLogging.h"
 *
 * Step 2:
 * Define your logging level in your implementation file:
 *
 * // Log levels: off, error, warn, info, verbose
 * static const int httpLogLevel = HTTP_LOG_LEVEL_VERBOSE;
 *
 * If you wish to enable tracing, you could do something like this:
 *
 * // Debug levels: off, error, warn, info, verbose
 * static const int httpLogLevel = HTTP_LOG_LEVEL_INFO | HTTP_LOG_FLAG_TRACE;
 *
 * Step 3:
 * Replace your NSLog statements with HTTPLog statements according to the severity of the message.
 *
 * NSLog(@"Fatal error, no dohickey found!"); -> HTTPLogError(@"Fatal error, no dohickey found!");
 *
 * HTTPLog works exactly the same as NSLog.
 * This means you can pass it multiple variables just like NSLog.
**/

#import <os/log.h>
#import <Foundation/Foundation.h>

// Compatibility macros formerly provided by CocoaLumberjack.

#ifndef THIS_FILE
#define THIS_FILE [[@(__FILE__) lastPathComponent] stringByDeletingPathExtension]
#endif

#ifndef THIS_METHOD
#define THIS_METHOD NSStringFromSelector(_cmd)
#endif

// Configure log levels.

#define HTTP_LOG_FLAG_ERROR   (1 << 0) // 0...00001
#define HTTP_LOG_FLAG_WARN    (1 << 1) // 0...00010
#define HTTP_LOG_FLAG_INFO    (1 << 2) // 0...00100
#define HTTP_LOG_FLAG_VERBOSE (1 << 3) // 0...01000

#define HTTP_LOG_LEVEL_OFF     0                                              // 0...00000
#define HTTP_LOG_LEVEL_ERROR   (HTTP_LOG_LEVEL_OFF   | HTTP_LOG_FLAG_ERROR)   // 0...00001
#define HTTP_LOG_LEVEL_WARN    (HTTP_LOG_LEVEL_ERROR | HTTP_LOG_FLAG_WARN)    // 0...00011
#define HTTP_LOG_LEVEL_INFO    (HTTP_LOG_LEVEL_WARN  | HTTP_LOG_FLAG_INFO)    // 0...00111
#define HTTP_LOG_LEVEL_VERBOSE (HTTP_LOG_LEVEL_INFO  | HTTP_LOG_FLAG_VERBOSE) // 0...01111

// Tracing flag (separate from log levels).

#define HTTP_LOG_FLAG_TRACE   (1 << 4) // 0...10000

// Setup the usual boolean macros.

#define HTTP_LOG_ERROR   (httpLogLevel & HTTP_LOG_FLAG_ERROR)
#define HTTP_LOG_WARN    (httpLogLevel & HTTP_LOG_FLAG_WARN)
#define HTTP_LOG_INFO    (httpLogLevel & HTTP_LOG_FLAG_INFO)
#define HTTP_LOG_VERBOSE (httpLogLevel & HTTP_LOG_FLAG_VERBOSE)
#define HTTP_LOG_TRACE   (httpLogLevel & HTTP_LOG_FLAG_TRACE)

// Helper: format an NSString and emit via os_log.
// os_log requires a compile-time string literal for its format parameter,
// so we pre-format with NSString and pass a single "%{public}@" literal.

#define _HTTPLogEmit(type, frmt, ...) \
    do { \
        NSString *_httplog_msg = [[NSString alloc] initWithFormat:frmt, ##__VA_ARGS__]; \
        os_log_with_type(OS_LOG_DEFAULT, type, "%{public}@", _httplog_msg); \
    } while(0)

// Define logging primitives using os_log.
// The httpLogLevel variable (defined per-file) gates whether the macro emits anything.

#define HTTPLogError(frmt, ...)    do { if (HTTP_LOG_ERROR)   _HTTPLogEmit(OS_LOG_TYPE_ERROR, frmt, ##__VA_ARGS__); } while(0)
#define HTTPLogWarn(frmt, ...)     do { if (HTTP_LOG_WARN)    _HTTPLogEmit(OS_LOG_TYPE_INFO,  frmt, ##__VA_ARGS__); } while(0)
#define HTTPLogInfo(frmt, ...)     do { if (HTTP_LOG_INFO)    _HTTPLogEmit(OS_LOG_TYPE_DEBUG, frmt, ##__VA_ARGS__); } while(0)
#define HTTPLogVerbose(frmt, ...)  do { if (HTTP_LOG_VERBOSE) _HTTPLogEmit(OS_LOG_TYPE_DEBUG, frmt, ##__VA_ARGS__); } while(0)

#define HTTPLogTrace()             do { if (HTTP_LOG_TRACE)   os_log_debug(OS_LOG_DEFAULT, "%{public}s", __PRETTY_FUNCTION__); } while(0)
#define HTTPLogTrace2(frmt, ...)   do { if (HTTP_LOG_TRACE)   _HTTPLogEmit(OS_LOG_TYPE_DEBUG, frmt, ##__VA_ARGS__); } while(0)

// C-function variants (identical behavior, kept for source compatibility).

#define HTTPLogCError(frmt, ...)   do { if (HTTP_LOG_ERROR)   _HTTPLogEmit(OS_LOG_TYPE_ERROR, frmt, ##__VA_ARGS__); } while(0)
#define HTTPLogCWarn(frmt, ...)    do { if (HTTP_LOG_WARN)    _HTTPLogEmit(OS_LOG_TYPE_INFO,  frmt, ##__VA_ARGS__); } while(0)
#define HTTPLogCInfo(frmt, ...)    do { if (HTTP_LOG_INFO)    _HTTPLogEmit(OS_LOG_TYPE_DEBUG, frmt, ##__VA_ARGS__); } while(0)
#define HTTPLogCVerbose(frmt, ...) do { if (HTTP_LOG_VERBOSE) _HTTPLogEmit(OS_LOG_TYPE_DEBUG, frmt, ##__VA_ARGS__); } while(0)

#define HTTPLogCTrace()            do { if (HTTP_LOG_TRACE)   os_log_debug(OS_LOG_DEFAULT, "%{public}s", __FUNCTION__); } while(0)
#define HTTPLogCTrace2(frmt, ...)  do { if (HTTP_LOG_TRACE)   _HTTPLogEmit(OS_LOG_TYPE_DEBUG, frmt, ##__VA_ARGS__); } while(0)
