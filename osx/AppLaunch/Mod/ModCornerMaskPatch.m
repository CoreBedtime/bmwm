#import "ModCornerMaskPatch.h"
#include <CoreFoundation/CFCGTypes.h>
#import <objc/runtime.h>
#define NSLog(...)

@interface NSCGSWindowCornerRadiusMask : NSObject
- (double)cornerRadius;
@end

static double hook_cornerRadius(id self, SEL _cmd) {
    return CGFLOAT_EPSILON;
}

void ModCornerMaskPatchInit(void) {
    Class maskClass = NSClassFromString(@"NSCGSWindowCornerRadiusMask");
    if (!maskClass) {
        NSLog(@"[ModCornerMaskPatch] ERROR: NSCGSWindowCornerRadiusMask not found");
        return;
    }

    SEL cornerRadiusSel = @selector(cornerRadius);
    Method cornerRadiusMethod = class_getInstanceMethod(maskClass, cornerRadiusSel);

    if (cornerRadiusMethod) {
        method_setImplementation(cornerRadiusMethod, (IMP)hook_cornerRadius);
        NSLog(@"[ModCornerMaskPatch] Successfully hooked NSCGSWindowCornerRadiusMask cornerRadius to return 0");
    } else {
        NSLog(@"[ModCornerMaskPatch] ERROR: cornerRadius method not found on NSCGSWindowCornerRadiusMask");
    }
}
