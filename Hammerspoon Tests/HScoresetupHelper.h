@import Foundation;

@interface HScoresetupHelper : NSObject
+ (void)registerShutdownLib;
+ (BOOL)shutdownFired;
+ (void)resetShutdownFlag;
@end
