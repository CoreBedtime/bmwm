#import "XClientWindow.h"

@implementation XClientWindow
- (BOOL)canBecomeKeyWindow { return YES; }
- (BOOL)canBecomeMainWindow { return YES; }
- (void)setFrame:(NSRect)frame display:(BOOL)display {
    [super setFrame:frame display:display];
    [[self standardWindowButton:NSWindowCloseButton] setHidden:YES];
    [[self standardWindowButton:NSWindowMiniaturizeButton] setHidden:YES];
    [[self standardWindowButton:NSWindowZoomButton] setHidden:YES];
}
@end
