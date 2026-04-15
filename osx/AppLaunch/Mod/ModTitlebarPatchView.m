#import "ModTitlebarPatch.h"

@implementation NSView (ModTitlebarPatch)

- (void)modTitlebarPatch_layout {
    [self modTitlebarPatch_layout];
    NSString *typeName = NSStringFromClass([self class]);
    NSLog(@"[ModTitlebarPatch] Layout called for view: %@ (window: %@)", typeName, self.window.description);

    if ([typeName containsString:@"NSTitlebar"] ||
        [typeName containsString:@"Titlebar"] ||
        [typeName containsString:@"WindowHeader"] ||
        [typeName containsString:@"TopBar"] ||
        [typeName containsString:@"HeaderView"] ||
        [typeName containsString:@"ThemeFrame"] ||
        [typeName containsString:@"NSThemeFrame"] ||
        [self.window isLikelyTitlebar:self]) {
        NSLog(@"[ModTitlebarPatch] Layout triggered modTitlebarPatch for: %@", typeName);
        [self.window modTitlebarPatch];
    }

    if (self.window) {
        NSLog(@"[ModTitlebarPatch] Force modTitlebarPatching window: %@", self.window);
        [self.window modTitlebarPatch];
    }
}

- (void)modTitlebarPatch_layoutSubtreeIfNeeded {
    [self modTitlebarPatch_layoutSubtreeIfNeeded];
    if ([NSStringFromClass([self class]) containsString:@"NSTitlebar"]) {
        [self.window modTitlebarPatch];
    }
}

@end
