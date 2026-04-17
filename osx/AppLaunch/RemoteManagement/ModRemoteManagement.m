#import "ModRemoteManagement.h"
#import <objc/runtime.h>

@interface ModRemoteManagementService : NSObject
- (void)setFrame:(uint32_t)windowId rect:(CGRect)rectangle;
@end

@implementation ModRemoteManagementService
- (void)setFrame:(uint32_t)windowId rect:(CGRect)rectangle {
    dispatch_async(dispatch_get_main_queue(), ^{
        for (NSWindow *window in [NSApp windows]) {
            if ([window windowNumber] == (NSInteger)windowId) {
                [window setFrame:NSRectFromCGRect(rectangle) display:YES];
                return;
            }
        }
    });
}
@end

void ModRemoteManagementInit(void) {
    pid_t pid = getpid();
    NSString *name = [NSString stringWithFormat:@"bedtime.wm.%d", pid];

    ModRemoteManagementService *service = [[ModRemoteManagementService alloc] init];
    NSConnection *listener =  [NSConnection serviceConnectionWithName:name rootObject:service];

    [listener setRootObject:service];
    [listener retain];
}
