#import "Mod/ModTitlebarPatch.h"
#import "Mod/ModCornerMaskPatch.h"
#import <objc/runtime.h>

__attribute__((constructor))
static void initializer(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        Class windowClass = [NSWindow class];
        Class viewClass = [NSView class];

        ModTitlebarPatchSwizzle(windowClass, @selector(makeKeyAndOrderFront:), @selector(modTitlebarPatch_makeKeyAndOrderFront:));
        ModTitlebarPatchSwizzle(windowClass, @selector(orderFront:), @selector(modTitlebarPatch_orderFront:));
        ModTitlebarPatchSwizzle(windowClass, @selector(setFrame:display:), @selector(modTitlebarPatch_setFrame:display:));
        ModTitlebarPatchSwizzle(windowClass, @selector(setFrame:display:animate:), @selector(modTitlebarPatch_setFrame:display:animate:));
        ModTitlebarPatchSwizzle(windowClass, @selector(initWithContentRect:styleMask:backing:defer:), @selector(modTitlebarPatch_initWithContentRect:styleMask:backing:defer:));

        ModTitlebarPatchSwizzle(viewClass, @selector(layout), @selector(modTitlebarPatch_layout));
        ModTitlebarPatchSwizzle(viewClass, @selector(layoutSubtreeIfNeeded), @selector(modTitlebarPatch_layoutSubtreeIfNeeded));

        NSLog(@"[ModTitlebarPatch] Swizzling initialized");

        ModCornerMaskPatchInit();
    });
}
