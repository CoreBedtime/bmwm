#import "XClientView.h"
#import <xcb/xtest.h>
#import "KeycodeMapping.h"

@implementation XClientView

- (BOOL)acceptsFirstResponder { return YES; }

- (void)focusOwningWindow {
    NSWindow *window = self.window;
    if (window == nil) {
        return;
    }

    NSApplication *app = [NSApplication sharedApplication];
    [app activateIgnoringOtherApps:YES];
    [window makeKeyAndOrderFront:nil];
    [window makeMainWindow];
    [window makeFirstResponder:self];

    if (self.connection != NULL && self.xWindow != 0) {
        uint32_t stackMode = XCB_STACK_MODE_ABOVE;
        xcb_set_input_focus(self.connection, XCB_INPUT_FOCUS_POINTER_ROOT, self.xWindow, XCB_CURRENT_TIME);
        xcb_configure_window(self.connection, self.xWindow, XCB_CONFIG_WINDOW_STACK_MODE, &stackMode);
        xcb_flush(self.connection);
    }
}

- (int)getCID {
    if (self.connection == NULL || self.xWindow == 0) {
        return 0;
    }
    xcb_intern_atom_cookie_t cookie = xcb_intern_atom(self.connection, 0, 15, "_APP_LAUNCH_CID");
    xcb_intern_atom_reply_t *reply = xcb_intern_atom_reply(self.connection, cookie, NULL);
    if (reply == NULL) {
        NSLog(@"[getCID] atom reply NULL");
        return 0;
    }
    xcb_atom_t propAtom = reply->atom;
    free(reply);

    xcb_get_property_cookie_t propCookie = xcb_get_property(self.connection, 0, self.xWindow, propAtom, XCB_ATOM_ANY, 0, 1);
    xcb_get_property_reply_t *propReply = xcb_get_property_reply(self.connection, propCookie, NULL);
    if (propReply == NULL) {
        NSLog(@"[getCID] prop reply NULL");
        return 0;
    }
    int cid = 0;
    if (propReply->format == 32 && xcb_get_property_value_length(propReply) >= 4) {
        cid = *(int *)xcb_get_property_value(propReply);
    } else {
        NSLog(@"[getCID] format=%d, len=%d", propReply->format, xcb_get_property_value_length(propReply));
    }
    free(propReply);
    NSLog(@"[getCID] returning %d", cid);
    return cid;
}

- (BOOL)acceptsFirstMouse:(NSEvent *)event {
    (void)event;
    [self focusOwningWindow];
    return YES;
}

- (NSPoint)updateX11Pointer:(NSEvent *)event {
    NSPoint loc = [self convertPoint:[event locationInWindow] fromView:nil];
    CGFloat boundsWidth = self.bounds.size.width;
    CGFloat boundsHeight = self.bounds.size.height;

    if (boundsWidth <= 0 || boundsHeight <= 0 || self.sourceFrame.size.width <= 0 || self.sourceFrame.size.height <= 0) {
        return NSZeroPoint;
    }

    CGFloat normalizedX = loc.x / boundsWidth;
    CGFloat normalizedY = (boundsHeight - loc.y) / boundsHeight;
    if (normalizedX < 0.0) normalizedX = 0.0;
    if (normalizedX > 1.0) normalizedX = 1.0;
    if (normalizedY < 0.0) normalizedY = 0.0;
    if (normalizedY > 1.0) normalizedY = 1.0;

    int local_x = (int)(normalizedX * MAX(0.0, self.sourceFrame.size.width - 1) + 0.5);
    int local_y = (int)(normalizedY * MAX(0.0, self.sourceFrame.size.height - 1) + 0.5);

    int root_x = (int)self.sourceFrame.origin.x + local_x;
    int root_y = (int)self.sourceFrame.origin.y + local_y;

    xcb_screen_t *screen = xcb_setup_roots_iterator(xcb_get_setup(self.connection)).data;
    xcb_window_t rootWindow = self.rootWindow != 0 ? self.rootWindow : screen->root;
    xcb_test_fake_input(self.connection, XCB_MOTION_NOTIFY, 0, XCB_CURRENT_TIME, rootWindow, root_x, root_y, 0);
    xcb_flush(self.connection);
    return NSMakePoint(root_x, root_y);
}

- (void)sendX11KeyForMacKeyCode:(unsigned short)keyCode pressed:(BOOL)pressed {
    uint8_t x11_keycode = mac_keycode_to_x11_keycode(keyCode);
    if (x11_keycode == 0) {
        return;
    }

    xcb_test_fake_input(self.connection,
                        pressed ? XCB_KEY_PRESS : XCB_KEY_RELEASE,
                        x11_keycode,
                        XCB_CURRENT_TIME,
                        self.rootWindow,
                        0, 0, 0);
    xcb_flush(self.connection);
}

- (NSEventModifierFlags)modifierMaskForKeyCode:(unsigned short)keyCode {
    switch (keyCode) {
        case 54:
        case 55:
            return NSEventModifierFlagCommand;
        case 56:
        case 60:
            return NSEventModifierFlagShift;
        case 57:
            return NSEventModifierFlagCapsLock;
        case 58:
        case 61:
            return NSEventModifierFlagOption;
        case 59:
        case 62:
            return NSEventModifierFlagControl;
        default:
            return 0;
    }
}

- (void)mouseDown:(NSEvent *)event {
    [self focusOwningWindow];
    NSPoint rootPoint = [self updateX11Pointer:event];
    xcb_test_fake_input(self.connection, XCB_BUTTON_PRESS, 1, XCB_CURRENT_TIME, self.rootWindow, (int16_t)rootPoint.x, (int16_t)rootPoint.y, 0);
    xcb_flush(self.connection);
}

- (void)mouseUp:(NSEvent *)event {
    NSPoint rootPoint = [self updateX11Pointer:event];
    xcb_test_fake_input(self.connection, XCB_BUTTON_RELEASE, 1, XCB_CURRENT_TIME, self.rootWindow, (int16_t)rootPoint.x, (int16_t)rootPoint.y, 0);
    xcb_flush(self.connection);
}

- (void)rightMouseDown:(NSEvent *)event {
    [self focusOwningWindow];
    NSPoint rootPoint = [self updateX11Pointer:event];
    xcb_test_fake_input(self.connection, XCB_BUTTON_PRESS, 3, XCB_CURRENT_TIME, self.rootWindow, (int16_t)rootPoint.x, (int16_t)rootPoint.y, 0);
    xcb_flush(self.connection);
}

- (void)rightMouseUp:(NSEvent *)event {
    [self focusOwningWindow];
    NSPoint rootPoint = [self updateX11Pointer:event];
    xcb_test_fake_input(self.connection, XCB_BUTTON_RELEASE, 3, XCB_CURRENT_TIME, self.rootWindow, (int16_t)rootPoint.x, (int16_t)rootPoint.y, 0);
    xcb_flush(self.connection);
}

- (void)mouseMoved:(NSEvent *)event {
    [self updateX11Pointer:event];
}

- (void)mouseDragged:(NSEvent *)event {
    [self updateX11Pointer:event];
}

- (void)scrollWheel:(NSEvent *)event {
    [self focusOwningWindow];
    NSPoint rootPoint = [self updateX11Pointer:event];
    int button = event.scrollingDeltaY > 0 ? 4 : (event.scrollingDeltaY < 0 ? 5 : 0);
    if (button != 0) {
        xcb_test_fake_input(self.connection, XCB_BUTTON_PRESS, button, XCB_CURRENT_TIME, self.rootWindow, (int16_t)rootPoint.x, (int16_t)rootPoint.y, 0);
        xcb_test_fake_input(self.connection, XCB_BUTTON_RELEASE, button, XCB_CURRENT_TIME, self.rootWindow, (int16_t)rootPoint.x, (int16_t)rootPoint.y, 0);
        xcb_flush(self.connection);
    }
}

- (void)keyDown:(NSEvent *)event {
    [self sendX11KeyForMacKeyCode:event.keyCode pressed:YES];
}

- (void)keyUp:(NSEvent *)event {
    [self sendX11KeyForMacKeyCode:event.keyCode pressed:NO];
}

- (void)flagsChanged:(NSEvent *)event {
    NSEventModifierFlags trackedFlags = event.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask;
    NSEventModifierFlags modifierMask = [self modifierMaskForKeyCode:event.keyCode];
    if (modifierMask == 0) {
        self.modifierFlagsState = trackedFlags;
        return;
    }

    if (modifierMask == NSEventModifierFlagCapsLock) {
        BOOL oldCaps = (self.modifierFlagsState & NSEventModifierFlagCapsLock) != 0;
        BOOL newCaps = (trackedFlags & NSEventModifierFlagCapsLock) != 0;
        if (oldCaps != newCaps) {
            [self sendX11KeyForMacKeyCode:event.keyCode pressed:YES];
            [self sendX11KeyForMacKeyCode:event.keyCode pressed:NO];
        }
    } else {
        BOOL pressed = (trackedFlags & modifierMask) != 0;
        [self sendX11KeyForMacKeyCode:event.keyCode pressed:pressed];
    }

    self.modifierFlagsState = trackedFlags;
}

@end
