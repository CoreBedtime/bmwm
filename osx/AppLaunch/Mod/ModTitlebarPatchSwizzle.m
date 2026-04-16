#import "ModTitlebarPatch.h"
#import <objc/runtime.h>

#define NSLog(...)

void ModTitlebarPatchInit(void) {
    Class windowClass = [NSWindow class];
    Class viewClass = [NSView class];

    ModTitlebarPatchSwizzle(windowClass, @selector(makeKeyAndOrderFront:), @selector(modTitlebarPatch_makeKeyAndOrderFront:));
    ModTitlebarPatchSwizzle(windowClass, @selector(orderFront:), @selector(modTitlebarPatch_orderFront:));
    ModTitlebarPatchSwizzle(windowClass, @selector(setFrame:display:), @selector(modTitlebarPatch_setFrame:display:));
    ModTitlebarPatchSwizzle(windowClass, @selector(setFrame:display:animate:), @selector(modTitlebarPatch_setFrame:display:animate:));
    ModTitlebarPatchSwizzle(windowClass, @selector(initWithContentRect:styleMask:backing:defer:), @selector(modTitlebarPatch_initWithContentRect:styleMask:backing:defer:));

    ModTitlebarPatchSwizzle(viewClass, @selector(layout), @selector(modTitlebarPatch_layout));
    ModTitlebarPatchSwizzle(viewClass, @selector(layoutSubtreeIfNeeded), @selector(modTitlebarPatch_layoutSubtreeIfNeeded));
}
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
