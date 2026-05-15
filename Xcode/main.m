#import <Cocoa/Cocoa.h>

int main(int argc, const char * argv[]) {
    Class delegateClass = NSClassFromString(@"MJAppDelegate");
    [NSApplication sharedApplication].delegate = [[delegateClass alloc] init];
    return NSApplicationMain(argc, argv);
}
