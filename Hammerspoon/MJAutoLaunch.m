#import "MJAutoLaunch.h"
#import <ServiceManagement/ServiceManagement.h>

BOOL MJAutoLaunchGet(void) {
    SMAppService *service = [SMAppService mainAppService];
    return service.status == SMAppServiceStatusEnabled;
}

void MJAutoLaunchSet(BOOL opensAtLogin) {
    SMAppService *service = [SMAppService mainAppService];
    NSError *error = nil;
    if (opensAtLogin) {
        [service registerAndReturnError:&error];
    } else {
        [service unregisterAndReturnError:&error];
    }
    if (error) {
        NSLog(@"MJAutoLaunch: %@", error);
    }
}
