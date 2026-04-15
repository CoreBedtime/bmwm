#ifndef XCLIENTVIEW_H
#define XCLIENTVIEW_H

#import <Cocoa/Cocoa.h>
#import <xcb/xcb.h>

@interface XClientView : NSImageView
@property (nonatomic, assign) xcb_window_t xWindow;
@property (nonatomic, assign) xcb_connection_t *connection;
@property (nonatomic, assign) xcb_window_t rootWindow;
@property (nonatomic, assign) NSRect sourceFrame;
@property (nonatomic, assign) NSEventModifierFlags modifierFlagsState;

- (void)focusOwningWindow;
- (int)getCID;
@end

#endif
