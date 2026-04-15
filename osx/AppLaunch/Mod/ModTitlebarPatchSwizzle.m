#import "ModTitlebarPatch.h"
#import <objc/runtime.h>

void ModTitlebarPatchSwizzle(Class cls, SEL orig, SEL swiz) {
    Method origMethod = class_getInstanceMethod(cls, orig);
    Method swizMethod = class_getInstanceMethod(cls, swiz);
    if (!origMethod || !swizMethod) return;

    if (class_addMethod(cls, orig, method_getImplementation(swizMethod), method_getTypeEncoding(swizMethod))) {
        class_replaceMethod(cls, swiz, method_getImplementation(origMethod), method_getTypeEncoding(origMethod));
    } else {
        method_exchangeImplementations(origMethod, swizMethod);
    }
}
