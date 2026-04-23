#ifndef ModTitlebarPatch_h
#define ModTitlebarPatch_h

#import <Cocoa/Cocoa.h>
static NSString *const titlebarContainerViewKey = @"titlebarContainerViewKey";
static NSString *const originalParentKey = @"originalParentKey";

void ModTitlebarPatchSwizzle(Class cls, SEL orig, SEL swiz);
void ModTitlebarPatchInit(void);

@interface NSWindow (ModTitlebarPatch)
- (void)modTitlebarPatch_makeKeyAndOrderFront:(id)sender;
- (void)modTitlebarPatch_orderFront:(id)sender;
- (void)modTitlebarPatch_setFrame:(NSRect)frame display:(BOOL)display;
- (void)modTitlebarPatch_setFrame:(NSRect)frame display:(BOOL)display animate:(BOOL)animate;
- (id)modTitlebarPatch_initWithContentRect:(NSRect)contentRect styleMask:(NSWindowStyleMask)styleMask backing:(NSBackingStoreType)backing defer:(BOOL)flag;
- (void)modTitlebarPatch_hideTrafficLights;
- (void)modTitlebarPatch;
- (NSString *)windowClassName;
- (BOOL)isInFullscreenTransition;
- (BOOL)disableTitlebar;
- (void)handleSwiftUIWindow;
- (void)handleStandardWindow;
- (void)forceHideSwiftUITitlebars;
- (NSArray *)getAllWindowSubviews;
- (void)hideTitlebarSafely;
- (void)hideAllPotentialTitlebars;
- (void)searchAndHideTitlebarsIn:(NSView *)view;
- (void)hideViewsByClassNameIn:(NSView *)view;
- (void)hideVisualTitlebarElementsInContainer:(NSView *)container;
- (void)hideTitlebarViewsIn:(NSView *)view;
- (void)minimizeTitlebarSpace;
- (void)setupFullscreenMonitoring;
- (void)handleFullscreenWillEnter:(NSNotification *)notification;
- (void)handleFullscreenDidExit:(NSNotification *)notification;
- (void)handleFullscreenContainerRelocation;
- (void)moveContainerToSuperview:(NSView *)container;
- (void)restoreContainerFromSuperview;
- (void)cleanupModTitlebarPatchObservers;
- (void)modTitlebarPatch_windowWillClose:(NSNotification *)notification;
- (BOOL)isLikelyTitlebar:(NSView *)view;
@end

@interface NSView (ModTitlebarPatch)
- (void)modTitlebarPatch_layout;
- (void)modTitlebarPatch_layoutSubtreeIfNeeded;
@end

#endif
