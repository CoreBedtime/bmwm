#import <Cocoa/Cocoa.h>
#import <objc/runtime.h>

void swizzle(Class c, SEL orig, SEL new) {
    Method origMethod = class_getInstanceMethod(c, orig);
    Method newMethod = class_getInstanceMethod(c, new);
    if (class_addMethod(c, orig, method_getImplementation(newMethod), method_getTypeEncoding(newMethod))) {
        class_replaceMethod(c, new, method_getImplementation(origMethod), method_getTypeEncoding(origMethod));
    } else {
        method_exchangeImplementations(origMethod, newMethod);
    }
}

@interface NSWindow (Headless)
@end

@implementation NSWindow (Headless)

- (void)headless__reallyDoOrderWindow:(id)a0 {
    // skip ordering to screen
}

- (void)headless__doOrderWindow:(id)a0 {
    // skip ordering to screen
}

- (void)headless_orderWindow:(NSInteger)place relativeTo:(NSInteger)otherWin {
    // skip ordering to screen
}

- (void)headless_makeKeyAndOrderFront:(id)sender {
    [self makeKeyWindow]; // Just make key, don't order front
}

- (void)headless_orderFront:(id)sender {
    // skip
}

- (BOOL)headless__isActiveAndOnScreen:(id)a0 {
    return YES;
}

@end

__attribute__((constructor))
static void initializer(void) {
    Class c = NSClassFromString(@"NSWindow");
    swizzle(c, NSSelectorFromString(@"_reallyDoOrderWindow:"), @selector(headless__reallyDoOrderWindow:));
    swizzle(c, NSSelectorFromString(@"_doOrderWindow:"), @selector(headless__doOrderWindow:));
    swizzle(c, @selector(orderWindow:relativeTo:), @selector(headless_orderWindow:relativeTo:));
    swizzle(c, @selector(makeKeyAndOrderFront:), @selector(headless_makeKeyAndOrderFront:));
    swizzle(c, @selector(orderFront:), @selector(headless_orderFront:));
    swizzle(c, NSSelectorFromString(@"_isActiveAndOnScreen:"), @selector(headless__isActiveAndOnScreen:));
}
