#import "ModTitlebarPatch.h"
#import <objc/runtime.h>

@implementation NSWindow (ModTitlebarPatch)

- (void)modTitlebarPatch_makeKeyAndOrderFront:(id)sender {
    [self modTitlebarPatch_makeKeyAndOrderFront:sender];
    [self modTitlebarPatch];
}

- (void)modTitlebarPatch_orderFront:(id)sender {
    [self modTitlebarPatch_orderFront:sender];
    [self modTitlebarPatch];
}

- (void)modTitlebarPatch_setFrame:(NSRect)frame display:(BOOL)display {
    [self modTitlebarPatch_setFrame:frame display:display];
    [self modTitlebarPatch];
}

- (void)modTitlebarPatch_setFrame:(NSRect)frame display:(BOOL)display animate:(BOOL)animate {
    [self modTitlebarPatch_setFrame:frame display:display animate:animate];
    [self modTitlebarPatch];
}

- (id)modTitlebarPatch_initWithContentRect:(NSRect)contentRect styleMask:(NSWindowStyleMask)styleMask backing:(NSBackingStoreType)backing defer:(BOOL)flag {
    id result = [self modTitlebarPatch_initWithContentRect:contentRect styleMask:styleMask backing:backing defer:flag];
    [self modTitlebarPatch_hideTrafficLights];
    return result;
}

- (void)modTitlebarPatch_hideTrafficLights {
    [self standardWindowButton:NSWindowCloseButton].hidden = YES;
    [self standardWindowButton:NSWindowMiniaturizeButton].hidden = YES;
    [self standardWindowButton:NSWindowZoomButton].hidden = YES;
}

- (BOOL)isInFullscreenTransition {
    if (self.styleMask & NSWindowStyleMaskFullScreen) {
        return NO;
    }
    NSUInteger mask = self.styleMask;
    return (mask & 0x4000) != 0 || (mask & 0x8000) != 0;
}

- (NSString *)windowClassName {
    return NSStringFromClass([self class]);
}

- (void)cleanupModTitlebarPatchObservers {
    [[NSNotificationCenter defaultCenter] removeObserver:self name:NSWindowWillEnterFullScreenNotification object:self];
    [[NSNotificationCenter defaultCenter] removeObserver:self name:NSWindowDidExitFullScreenNotification object:self];
    [[NSNotificationCenter defaultCenter] removeObserver:self name:NSWindowWillCloseNotification object:self];
}

- (void)modTitlebarPatch_windowWillClose:(NSNotification *)notification {
    [self cleanupModTitlebarPatchObservers];
}

- (BOOL)isLikelyTitlebar:(NSView *)view {
    if (!view.window) return NO;

    NSRect frame = view.frame;
    CGFloat superviewHeight = view.superview.frame.size.height;
    BOOL isAtTop = frame.origin.y + frame.size.height >= superviewHeight - 50;
    BOOL spansWidth = frame.size.width >= (view.superview.frame.size.width * 0.7);
    BOOL hasTitlebarHeight = frame.size.height >= 20 && frame.size.height <= 50;

    return isAtTop && spansWidth && hasTitlebarHeight;
}

- (void)disableTitlebar {
    if ([self isInFullscreenTransition]) {
        // NSLog(@"[ModTitlebarPatch] Skipping - in fullscreen transition");
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self modTitlebarPatch];
        });
        return;
    }

    if (!self.contentView) {
       //  NSLog(@"[ModTitlebarPatch] Skipping - no content view");
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self modTitlebarPatch];
        });
        return;
    }

    NSString *className = [self windowClassName];
    if ([className containsString:@"SwiftUI"]) {
        [self handleSwiftUIWindow];
    } else {
        [self handleStandardWindow];
    }

    [self hideAllPotentialTitlebars];
    [self hideTitlebarSafely];
    [self setupFullscreenMonitoring];
}

- (void)handleSwiftUIWindow {
    NSLog(@"[ModTitlebarPatch] Handling SwiftUI window");
    self.titleVisibility = NSWindowTitleHidden;
    self.titlebarAppearsTransparent = YES;
    self.styleMask |= NSWindowStyleMaskFullSizeContentView;
    self.movableByWindowBackground = YES;

    [self standardWindowButton:NSWindowCloseButton].hidden = YES;
    [self standardWindowButton:NSWindowMiniaturizeButton].hidden = YES;
    [self standardWindowButton:NSWindowZoomButton].hidden = YES;

    NSLog(@"[ModTitlebarPatch] SwiftUI window properties set successfully");
    [self forceHideSwiftUITitlebars];
}

- (void)handleStandardWindow {
    self.titleVisibility = NSWindowTitleHidden;
    self.titlebarAppearsTransparent = YES;
    self.styleMask |= NSWindowStyleMaskFullSizeContentView;
    self.movableByWindowBackground = YES;

    [self standardWindowButton:NSWindowCloseButton].hidden = YES;
    [self standardWindowButton:NSWindowMiniaturizeButton].hidden = YES;
    [self standardWindowButton:NSWindowZoomButton].hidden = YES;
}

- (void)forceHideSwiftUITitlebars {
    NSLog(@"[ModTitlebarPatch] Force hiding SwiftUI titlebars with refined detection");
    NSArray *allViews = [self getAllWindowSubviews];

    for (NSView *view in allViews) {
        NSString *className = NSStringFromClass([view class]);
        NSRect frame = view.frame;
        CGFloat windowHeight = view.window.frame.size.height;

        if (frame.size.height > 0 && frame.size.height < 50 && frame.size.width > 300) {
            BOOL isAtVeryTop = frame.origin.y + frame.size.height >= windowHeight - 50;

            BOOL isTitlebarClass = [className.lowercaseString containsString:@"title"] ||
                                    [className.lowercaseString containsString:@"header"] ||
                                    ([className.lowercaseString containsString:@"bar"] &&
                                     ![className.lowercaseString containsString:@"toolbar"] &&
                                     ![className.lowercaseString containsString:@"statusbar"] &&
                                     ![className.lowercaseString containsString:@"tabbar"]);

            if (isAtVeryTop && isTitlebarClass) {
                NSLog(@"[ModTitlebarPatch] Refined hiding SwiftUI titlebar: %@ (frame: %@)", className, NSStringFromRect(frame));
                view.hidden = YES;
                view.alphaValue = 0.0;
                NSRect newFrame = frame;
                newFrame.size.height = 0;
                view.frame = newFrame;
            }
        }
    }
}

- (NSArray *)getAllWindowSubviews {
    NSMutableArray *allViews = [NSMutableArray array];

    void (^collectViews)(NSView *) = ^(NSView *v) {
        [allViews addObject:v];
        for (NSView *subview in v.subviews) {
            collectViews(subview);
        }
    };

    if (self.contentView) {
        collectViews(self.contentView);
    }

    for (NSView *subview in self.contentView.superview.subviews) {
        collectViews(subview);
    }

    return allViews;
}

- (void)hideTitlebarSafely {
    if (!self.contentView) return;
    [self hideTitlebarViewsIn:self.contentView];
    [self minimizeTitlebarSpace];
}

- (void)hideAllPotentialTitlebars {
    if (!self.contentView) return;
    [self searchAndHideTitlebarsIn:self.contentView];

    for (NSView *subview in self.contentView.superview.subviews) {
        [self searchAndHideTitlebarsIn:subview];
    }

    [self hideViewsByClassNameIn:self.contentView];
}

- (void)searchAndHideTitlebarsIn:(NSView *)view {
    NSString *typeName = NSStringFromClass([view class]);
    NSRect frame = view.frame;
    CGFloat windowHeight = view.window.frame.size.height;

    if (frame.size.height > 0 && frame.size.height < 50 && frame.size.width > 300) {
        BOOL isAtVeryTop = frame.origin.y + frame.size.height >= windowHeight - 50;

        BOOL isTitlebarClass = [typeName.lowercaseString containsString:@"title"] ||
                                [typeName.lowercaseString containsString:@"header"] ||
                                ([typeName.lowercaseString containsString:@"bar"] &&
                                 ![typeName.lowercaseString containsString:@"toolbar"] &&
                                 ![typeName.lowercaseString containsString:@"statusbar"] &&
                                 ![typeName.lowercaseString containsString:@"tabbar"]);

        if (isAtVeryTop && isTitlebarClass) {
            NSLog(@"[ModTitlebarPatch] Refined hiding titlebar: %@ (frame: %@)", typeName, NSStringFromRect(frame));
            view.hidden = YES;
            NSRect newFrame = frame;
            newFrame.size.height = 0;
            view.frame = newFrame;
        }
    }

    for (NSView *subview in view.subviews) {
        [self searchAndHideTitlebarsIn:subview];
    }
}

- (void)hideViewsByClassNameIn:(NSView *)view {
    for (NSView *subview in view.subviews) {
        NSString *typeName = NSStringFromClass([subview class]);
        NSRect frame = subview.frame;
        CGFloat windowHeight = subview.window.frame.size.height;
        BOOL isAtVeryTop = frame.origin.y + frame.size.height >= windowHeight - 50;
        BOOL hasTitlebarSize = frame.size.height > 0 && frame.size.height < 50 && frame.size.width > 300;

        if (isAtVeryTop && hasTitlebarSize && (
            [typeName.lowercaseString containsString:@"title"] ||
            [typeName.lowercaseString containsString:@"header"] ||
            ([typeName.lowercaseString containsString:@"bar"] &&
             ![typeName.lowercaseString containsString:@"toolbar"] &&
             ![typeName.lowercaseString containsString:@"statusbar"] &&
             ![typeName.lowercaseString containsString:@"tabbar"]))) {
            NSLog(@"[ModTitlebarPatch] Refined hiding view by class name: %@", typeName);
            subview.hidden = YES;
        }

        [self hideViewsByClassNameIn:subview];
    }
}

- (void)hideVisualTitlebarElementsInContainer:(NSView *)container {
    NSLog(@"[ModTitlebarPatch] Selectively hiding visual elements in titlebar container");

    for (NSView *subview in container.subviews) {
        NSString *typeName = NSStringFromClass([subview class]);

        BOOL isVisualElement = [typeName containsString:@"Background"] ||
                                [typeName containsString:@"Decoration"] ||
                                [typeName containsString:@"Shadow"] ||
                                [typeName containsString:@"Border"] ||
                                ([typeName containsString:@"NSView"] && subview.subviews.count == 0) ||
                                [typeName containsString:@"_NSTitlebarDecorationView"];

        if (isVisualElement) {
            NSLog(@"[ModTitlebarPatch] Hiding visual titlebar element: %@", typeName);
            subview.hidden = YES;
            subview.alphaValue = 0.0;
        } else {
            [self hideVisualTitlebarElementsInContainer:subview];
        }
    }
}

- (void)hideTitlebarViewsIn:(NSView *)view {
    for (NSView *subview in view.subviews) {
        NSString *typeName = NSStringFromClass([subview class]);

        if ([typeName.lowercaseString containsString:@"title"] ||
            [typeName.lowercaseString containsString:@"header"] ||
            [typeName.lowercaseString containsString:@"bar"]) {
            NSLog(@"[ModTitlebarPatch] Found potential titlebar view: %@", typeName);
        }

        BOOL isTitlebarView = [typeName containsString:@"NSTitlebarView"] ||
                               [typeName containsString:@"TitlebarView"] ||
                               [typeName containsString:@"WindowHeaderView"] ||
                               [typeName containsString:@"TopBarView"] ||
                               [typeName containsString:@"HeaderBarView"] ||
                               [typeName containsString:@"_NSTitlebarView"] ||
                               [typeName containsString:@"NSThemeFrame"] ||
                               [typeName containsString:@"ThemeFrame"] ||
                               ([typeName containsString:@"NSView"] && [self isLikelyTitlebar:subview]);

        BOOL isTitlebarContainer = [typeName containsString:@"NSTitlebarContainerView"] ||
                                    [typeName containsString:@"TitlebarContainerView"] ||
                                    [typeName containsString:@"WindowHeaderContainerView"] ||
                                    [typeName containsString:@"TopBarContainerView"] ||
                                    [typeName containsString:@"HeaderContainerView"] ||
                                    [typeName containsString:@"_NSTitlebarContainerView"];

        if (isTitlebarView) {
            NSLog(@"[ModTitlebarPatch] Hiding titlebar view: %@", typeName);
            subview.hidden = YES;
            NSRect frame = subview.frame;
            frame.size.height = 0;
            subview.frame = frame;
        } else if (isTitlebarContainer) {
            NSLog(@"[ModTitlebarPatch] Preserving titlebar container functionality: %@", typeName);
            objc_setAssociatedObject(self, titlebarContainerViewKey, subview, OBJC_ASSOCIATION_RETAIN);
            [self hideVisualTitlebarElementsInContainer:subview];
        }

        [self hideTitlebarViewsIn:subview];
    }
}

- (void)minimizeTitlebarSpace {
    if ([self respondsToSelector:NSSelectorFromString(@"setTitlebarHeight:")]) {
        #pragma clang diagnostic push
        #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        [self performSelector:NSSelectorFromString(@"setTitlebarHeight:") withObject:@0];
        #pragma clang diagnostic pop
    }

    if (self.toolbar) {
        self.toolbar.visible = NO;
    }

    if (self.contentView) {
        self.contentView.wantsLayer = YES;
        [self.contentView setNeedsLayout:YES];
    }
}

- (void)setupFullscreenMonitoring {
    [self cleanupModTitlebarPatchObservers];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handleFullscreenWillEnter:)
                                                 name:NSWindowWillEnterFullScreenNotification
                                               object:self];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handleFullscreenDidExit:)
                                                 name:NSWindowDidExitFullScreenNotification
                                               object:self];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(modTitlebarPatch_windowWillClose:)
                                                 name:NSWindowWillCloseNotification
                                               object:self];
}

- (void)handleFullscreenWillEnter:(NSNotification *)notification {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (self.styleMask & NSWindowStyleMaskFullScreen) {
            [self handleFullscreenContainerRelocation];
        }
    });
}

- (void)handleFullscreenDidExit:(NSNotification *)notification {
    [self restoreContainerFromSuperview];

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self modTitlebarPatch];
    });
}

- (void)handleFullscreenContainerRelocation {
    NSView *container = objc_getAssociatedObject(self, titlebarContainerViewKey);
    if (container) {
        [self moveContainerToSuperview:container];
    }
}

- (void)moveContainerToSuperview:(NSView *)container {
    if (!self.contentView || !self.contentView.superview) return;
    NSView *superview = self.contentView.superview;
    if (container.superview == superview) return;

    NSView *originalParent = container.superview;
    [container removeFromSuperview];
    [superview addSubview:container];

    container.translatesAutoresizingMaskIntoConstraints = NO;
    [NSLayoutConstraint activateConstraints:@[
        [container.topAnchor constraintEqualToAnchor:superview.topAnchor],
        [container.leadingAnchor constraintEqualToAnchor:superview.leadingAnchor],
        [container.trailingAnchor constraintEqualToAnchor:superview.trailingAnchor],
        [container.heightAnchor constraintEqualToConstant:28]
    ]];

    container.hidden = NO;
    objc_setAssociatedObject(container, originalParentKey, originalParent, OBJC_ASSOCIATION_RETAIN);
}

- (void)restoreContainerFromSuperview {
    NSView *container = objc_getAssociatedObject(self, titlebarContainerViewKey);
    NSView *originalParent = objc_getAssociatedObject(container, originalParentKey);
    if (!container || !originalParent) return;

    [container removeFromSuperview];
    [originalParent addSubview:container];

    container.translatesAutoresizingMaskIntoConstraints = YES;
    NSRect frame = container.frame;
    frame.size.height = 0;
    container.frame = frame;
    container.hidden = YES;

    objc_setAssociatedObject(container, originalParentKey, nil, OBJC_ASSOCIATION_RETAIN);
}

- (void)modTitlebarPatch {
    NSString *className = [self windowClassName];
    if ([className containsString:@"MenuBar"] ||
        [className containsString:@"StatusBar"] ||
        [className containsString:@"Dock"] ||
        [className containsString:@"PopupMenu"] ||
        [className containsString:@"ContextMenu"]) {
        return;
    }

    [self disableTitlebar];
}

@end
