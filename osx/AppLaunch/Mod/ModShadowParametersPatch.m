#import "ModShadowParametersPatch.h"
#import <objc/message.h>
#import <objc/runtime.h>

#define NSLog(...)

static void *shadowStyleKey = &shadowStyleKey;
static IMP originalShadowParametersIMP;

@implementation NSWindow (ModShadowParametersPatch)

- (NSInteger)shadowStyle {
    NSNumber *value = objc_getAssociatedObject(self, shadowStyleKey);
    return value ? [value integerValue] : 0;
}

- (void)setShadowStyle:(NSInteger)shadowStyle {
    objc_setAssociatedObject(self, shadowStyleKey, @(shadowStyle), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

@end

static NSDictionary *hook_shadowParameters(id self, SEL _cmd) {
    NSDictionary *parent = ((NSDictionary *(*)(id, SEL))originalShadowParametersIMP)(self, _cmd);
    NSMutableDictionary *copy = [parent mutableCopy];
    NSArray *keys = @[@"com.apple.WindowShadowRimDensityActive",
                      @"com.apple.WindowShadowRimDensityInactive"];
    for (NSString *key in keys) {
        if ([parent objectForKey:key] != nil) {
            [copy setValue:@(0) forKey:key];
        }
    }
    return copy;
}

void ModShadowParametersPatchInit(void) {
    Class windowClass = [NSWindow class];
    SEL shadowParamsSel = @selector(shadowParameters);
    Method shadowParamsMethod = class_getInstanceMethod(windowClass, shadowParamsSel);

    if (shadowParamsMethod) {
        originalShadowParametersIMP = method_getImplementation(shadowParamsMethod);
        method_setImplementation(shadowParamsMethod, (IMP)hook_shadowParameters);
        NSLog(@"[ModShadowParametersPatch] Successfully hooked NSWindow shadowParameters");
    } else {
        NSLog(@"[ModShadowParametersPatch] ERROR: shadowParameters method not found on NSWindow");
    }
}
