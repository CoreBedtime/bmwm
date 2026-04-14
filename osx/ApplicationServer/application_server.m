#import "application_server.h"
#include <AppKit/AppKit.h>
#include <CoreFoundation/CFCGTypes.h>
#import <Cocoa/Cocoa.h>
#import <xcb/xcb.h>
#import <xcb/xcb_util.h>
#import <xcb/xcb_event.h>
#import <xcb/xtest.h>
#import <xcb/composite.h>

#include <sys/wait.h>
#include <unistd.h>
#include <stdlib.h>
#include <sys/stat.h>
#include <sys/select.h>
#include <errno.h>
#include <time.h>
#include <sys/socket.h>
#include <sys/un.h>

static const char *SOCKET_PATH = "/tmp/applicator_focus.sock";

static const char *xorg_paths[] = {
    "/opt/local/bin/Xorg",
    "/opt/X11/bin/Xorg",
    NULL
};

static uint8_t mac_keycode_to_x11_keycode(unsigned short keyCode) {
    switch (keyCode) {
        case 0: return 38;
        case 1: return 39;
        case 2: return 40;
        case 3: return 41;
        case 4: return 43;
        case 5: return 42;
        case 6: return 52;
        case 7: return 53;
        case 8: return 54;
        case 9: return 55;
        case 10: return 94;
        case 11: return 56;
        case 12: return 24;
        case 13: return 25;
        case 14: return 26;
        case 15: return 27;
        case 16: return 29;
        case 17: return 28;
        case 18: return 10;
        case 19: return 11;
        case 20: return 12;
        case 21: return 13;
        case 22: return 15;
        case 23: return 14;
        case 24: return 21;
        case 25: return 18;
        case 26: return 16;
        case 27: return 20;
        case 28: return 17;
        case 29: return 19;
        case 30: return 35;
        case 31: return 32;
        case 32: return 30;
        case 33: return 34;
        case 34: return 31;
        case 35: return 33;
        case 36: return 36;
        case 37: return 46;
        case 38: return 44;
        case 39: return 48;
        case 40: return 45;
        case 41: return 47;
        case 42: return 51;
        case 43: return 59;
        case 44: return 61;
        case 45: return 57;
        case 46: return 58;
        case 47: return 60;
        case 48: return 23;
        case 49: return 65;
        case 50: return 49;
        case 51: return 22;
        case 54: return 116;
        case 55: return 115;
        case 56: return 50;
        case 57: return 66;
        case 58: return 64;
        case 59: return 37;
        case 60: return 62;
        case 61: return 113;
        case 62: return 109;
        case 63: return 117;
        case 64: return 122;
        case 65: return 91;
        case 67: return 63;
        case 69: return 86;
        case 71: return 77;
        case 72: return 143;
        case 73: return 142;
        case 74: return 141;
        case 75: return 112;
        case 76: return 108;
        case 78: return 82;
        case 79: return 129;
        case 80: return 130;
        case 81: return 157;
        case 82: return 90;
        case 83: return 87;
        case 84: return 88;
        case 85: return 89;
        case 86: return 83;
        case 87: return 84;
        case 88: return 85;
        case 89: return 79;
        case 91: return 80;
        case 92: return 81;
        case 95: return 123;
        case 96: return 71;
        case 97: return 72;
        case 98: return 73;
        case 99: return 69;
        case 100: return 74;
        case 101: return 75;
        case 103: return 95;
        case 105: return 182;
        case 106: return 121;
        case 107: return 183;
        case 109: return 76;
        case 111: return 96;
        case 113: return 184;
        case 114: return 106;
        case 115: return 97;
        case 116: return 99;
        case 117: return 107;
        case 118: return 70;
        case 119: return 103;
        case 120: return 68;
        case 121: return 105;
        case 122: return 67;
        case 123: return 100;
        case 124: return 102;
        case 125: return 104;
        case 126: return 98;
        default: return 0;
    }
}

@interface XClientWindow : NSWindow
@end

@implementation XClientWindow
- (BOOL)canBecomeKeyWindow { return YES; }
- (BOOL)canBecomeMainWindow { return YES; }
@end

@interface ApplicationServer () <NSWindowDelegate, NSApplicationDelegate>
@property (nonatomic, assign) xcb_connection_t *connection;
@property (nonatomic, assign) xcb_screen_t *screen;
@property (nonatomic, assign) xcb_window_t rootWindow;
@property (nonatomic, assign) pid_t xorg_pid;
@property (nonatomic, assign) int display_number;
@property (nonatomic, assign) BOOL running;
@property (nonatomic, assign) NSMutableDictionary<NSNumber *, NSWindow *> *windows;
@property (nonatomic, assign) NSMutableDictionary<NSNumber *, NSImageView *> *imageViews;
@property (nonatomic, assign) NSString *xorgConfigPath;
@property (nonatomic, assign) NSString *xorgLogPath;
@property (nonatomic, assign) NSTimer *refreshTimer;
@property (nonatomic, assign) int server_fd;
@end

@interface XClientView : NSImageView
@property (nonatomic, assign) xcb_window_t xWindow;
@property (nonatomic, assign) xcb_connection_t *connection;
@property (nonatomic, assign) xcb_window_t rootWindow;
@property (nonatomic, assign) NSRect sourceFrame;
@property (nonatomic, assign) NSEventModifierFlags modifierFlagsState;
- (BOOL)isAppKitBacked;
@end

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

- (BOOL)isAppKitBacked {
    if (self.connection == NULL || self.xWindow == 0) {
        return NO;
    }
    xcb_intern_atom_cookie_t cookie = xcb_intern_atom(self.connection, 1, 18, "_APP_LAUNCH_APPKIT");
    xcb_intern_atom_reply_t *reply = xcb_intern_atom_reply(self.connection, cookie, NULL);
    if (reply == NULL) {
        return NO;
    }
    xcb_atom_t propAtom = reply->atom;
    free(reply);

    xcb_get_property_cookie_t propCookie = xcb_get_property(self.connection, 0, self.xWindow, propAtom, XCB_ATOM_ANY, 0, 1);
    xcb_get_property_reply_t *propReply = xcb_get_property_reply(self.connection, propCookie, NULL);
    if (propReply == NULL) {
        return NO;
    }
    BOOL exists = (propReply->format == 32 && xcb_get_property_value_length(propReply) >= 4);
    free(propReply);
    return exists;
}

- (uint32_t)getNativeWindowID {
    if (self.connection == NULL || self.xWindow == 0) {
        return 0;
    }
    xcb_intern_atom_cookie_t cookie = xcb_intern_atom(self.connection, 1, 21, "_APP_LAUNCH_NATIVE_ID");
    xcb_intern_atom_reply_t *reply = xcb_intern_atom_reply(self.connection, cookie, NULL);
    if (reply == NULL) {
        return 0;
    }
    xcb_atom_t propAtom = reply->atom;
    free(reply);

    xcb_get_property_cookie_t propCookie = xcb_get_property(self.connection, 0, self.xWindow, propAtom, XCB_ATOM_ANY, 0, 1);
    xcb_get_property_reply_t *propReply = xcb_get_property_reply(self.connection, propCookie, NULL);
    if (propReply == NULL) {
        return 0;
    }
    uint32_t nativeId = 0;
    if (propReply->format == 32 && xcb_get_property_value_length(propReply) >= 4) {
        nativeId = *(uint32_t *)xcb_get_property_value(propReply);
    }
    free(propReply);
    return nativeId;
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

    // NSLog(@"[AppSrv] updateX11Pointer: loc=(%.1f,%.1f) bounds=%.0fx%.0f srcFrame=(%.0f,%.0f %.0fx%.0f) norm=(%.3f,%.3f) local=(%d,%d) root=(%d,%d)",
    //       loc.x, loc.y, boundsWidth, boundsHeight,
    //       self.sourceFrame.origin.x, self.sourceFrame.origin.y,
    //       self.sourceFrame.size.width, self.sourceFrame.size.height,
    //       normalizedX, normalizedY, local_x, local_y, root_x, root_y);

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

@implementation ApplicationServer

- (instancetype)init {
    self = [super init];
    if (self) {
        _windows = [[NSMutableDictionary alloc] init];
        _imageViews = [[NSMutableDictionary alloc] init];
        _running = NO;
        _xorg_pid = -1;
        _server_fd = -1;
    }
    return self;
}

- (void)broadcastFocusChange:(xcb_window_t)xWindow isAppKitBacked:(BOOL)isAppKitBacked {
    if (self.server_fd < 0) return;

    NSString *message = [NSString stringWithFormat:@"%u %d\n", xWindow, isAppKitBacked];
    const char *msg = [message UTF8String];
    size_t len = strlen(msg);

    // We just try to send to anyone connected, but since we don't have a list of clients
    // and this is a simple local socket, we could accept and send immediately or just
    // have a single persistent connection if we were more complex.
    // Given the prompt "listen over socket", I'll implement a simple broadcast to all connected clients.
}

- (void)setupFocusSocket {
    unlink(SOCKET_PATH);
    self.server_fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (self.server_fd < 0) return;

    struct sockaddr_un addr;
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    strncpy(addr.sun_path, SOCKET_PATH, sizeof(addr.sun_path) - 1);

    if (bind(self.server_fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        close(self.server_fd);
        self.server_fd = -1;
        return;
    }

    if (listen(self.server_fd, 5) < 0) {
        close(self.server_fd);
        self.server_fd = -1;
        return;
    }

    int flags = fcntl(self.server_fd, F_GETFL, 0);
    fcntl(self.server_fd, F_SETFL, flags | O_NONBLOCK);
}

- (void)updateFocusClientsWithWindow:(xcb_window_t)xWindow nativeWindowId:(uint32_t)nativeWindowId isAppKitBacked:(BOOL)isAppKitBacked {
    if (self.server_fd < 0) return;

    NSString *message = [NSString stringWithFormat:@"%u %u %d\n", nativeWindowId, xWindow, isAppKitBacked ? 1 : 0];
    NSLog(@"[AppSrv] Broadcasting focus change: %@", message);
    [self broadcastToClients:message];

    // Also notify redirect.m so it can push to Frida (done synchronously to ensure it sends)
    int sock = socket(AF_UNIX, SOCK_STREAM, 0);
    if (sock >= 0) {
        struct sockaddr_un addr;
        memset(&addr, 0, sizeof(addr));
        addr.sun_family = AF_UNIX;
        strncpy(addr.sun_path, "/tmp/applicator_loader.sock", sizeof(addr.sun_path) - 1);

        if (connect(sock, (struct sockaddr *)&addr, sizeof(addr)) == 0) {
            NSLog(@"[AppSrv] Successfully connected and sent to loader socket");
            send(sock, [message UTF8String], [message length], 0);
        } else {
            NSLog(@"[AppSrv] Failed to connect to loader socket: %s", strerror(errno));
        }
        close(sock);
    } else {
        NSLog(@"[AppSrv] Failed to create socket for loader: %s", strerror(errno));
    }
}

- (void)broadcastToClients:(NSString *)message {
    int client_fd;
    while ((client_fd = accept(self.server_fd, NULL, NULL)) >= 0) {
        send(client_fd, [message UTF8String], [message length], 0);
        close(client_fd);
    }
}

- (void)handleIncomingSocketData {
    int client_fd;
    while ((client_fd = accept(self.server_fd, NULL, NULL)) >= 0) {
        // Just drain for now, as focus is pushed from this server to loader
        char buffer[1024];
        recv(client_fd, buffer, sizeof(buffer), 0);
        close(client_fd);
    }
}

- (void)closeCocoaWindowForXWindow:(xcb_window_t)xWindow {
    NSNumber *windowKey = @(xWindow);
    NSWindow *window = [self.windows objectForKey:windowKey];
    if (window == nil) {
        return;
    }

    [window retain];
    [self.windows removeObjectForKey:windowKey];

    NSImageView *imageView = [self.imageViews objectForKey:windowKey];
    if (imageView) {
        [imageView removeFromSuperview];
        [self.imageViews removeObjectForKey:windowKey];
    }

    window.delegate = nil;
    [window setReleasedWhenClosed:NO];
    [window orderOut:nil];
    [window close];
    [window release];
}

- (const char *)findXorg {
    for (int i = 0; xorg_paths[i] != NULL; i++) {
        if (access(xorg_paths[i], X_OK) == 0) {
            return xorg_paths[i];
        }
    }
    return NULL;
}

- (int)writeXorgConfigWithWidth:(int)width height:(int)height {
    char config_template[] = "/tmp/applicator-xorg-XXXXXX";
    int config_fd = mkstemp(config_template);
    if (config_fd < 0) {
        return -1;
    }

    _xorgConfigPath = [NSString stringWithUTF8String:config_template];

    char log_path[256];
    snprintf(log_path, sizeof(log_path), "/tmp/applicator-xorg-%ld.log", (long)getpid());
    _xorgLogPath = [NSString stringWithUTF8String:log_path];

    char mode_name[] = "Mode0";
    char modeline[] = "173.00 1920 2048 2248 2576 1080 1083 1088 1120 -hsync +vsync";

    FILE *config = fdopen(config_fd, "w");
    if (!config) {
        close(config_fd);
        return -1;
    }

    fprintf(config,
        "Section \"ServerLayout\"\n"
        "    Identifier \"Layout0\"\n"
        "    Screen \"Screen0\"\n"
        "    InputDevice \"Mouse0\" \"CorePointer\"\n"
        "    InputDevice \"Keyboard0\" \"CoreKeyboard\"\n"
        "EndSection\n"
        "\n"
        "Section \"InputDevice\"\n"
        "    Identifier \"Mouse0\"\n"
        "    Driver \"void\"\n"
        "EndSection\n"
        "\n"
        "Section \"InputDevice\"\n"
        "    Identifier \"Keyboard0\"\n"
        "    Driver \"void\"\n"
        "EndSection\n"
        "\n"
        "Section \"Monitor\"\n"
        "    Identifier \"Monitor0\"\n"
        "    HorizSync 1.0-300.0\n"
        "    VertRefresh 1.0-300.0\n"
        "    Modeline \"%s\" %s\n"
        "EndSection\n"
        "\n"
        "Section \"Device\"\n"
        "    Identifier \"DummyDevice\"\n"
        "    Driver \"dummy\"\n"
        "    VideoRam 512000\n"
        "    Option \"Shadow\" \"no\"\n"
        "EndSection\n"
        "\n"
        "Section \"Screen\"\n"
        "    Identifier \"Screen0\"\n"
        "    Device \"DummyDevice\"\n"
        "    Monitor \"Monitor0\"\n"
        "    DefaultDepth 24\n"
        "    SubSection \"Display\"\n"
        "        Depth 24\n"
        "        Modes \"%s\"\n"
        "        Virtual %d %d\n"
        "        ViewPort 0 0\n"
        "    EndSubSection\n"
        "EndSection\n",
        mode_name, modeline, mode_name, width, height);

    fclose(config);
    return 0;
}

- (int)waitForDisplayFd:(int)fd displayNumber:(int *)displayNumber {
    char buffer[64] = {0};
    ssize_t total_read = 0;
    struct timeval timeout = { .tv_sec = 10, .tv_usec = 0 };

    fd_set read_fds;
    FD_ZERO(&read_fds);
    FD_SET(fd, &read_fds);

    int select_result = select(fd + 1, &read_fds, NULL, NULL, &timeout);
    if (select_result <= 0) {
        return -1;
    }

    ssize_t n = read(fd, buffer, sizeof(buffer) - 1);
    if (n <= 0) {
        return -1;
    }
    total_read += n;

    char *endptr = NULL;
    long display = strtol(buffer, &endptr, 10);
    if (endptr == buffer || display < 0 || display > 1024) {
        return -1;
    }

    *displayNumber = (int)display;
    return 0;
}

- (int)spawnXorg {
    const char *xorg = [self findXorg];
    if (!xorg) {
        NSLog(@"Failed to find Xorg");
        return -1;
    }

    mkdir("/tmp/.X11-unix", 0777);
    // Ownership check for Xorg will be handled by the loader
    chmod("/tmp/.X11-unix", 01777);

    if ([self writeXorgConfigWithWidth:1920 height:1080] != 0) {
        NSLog(@"Failed to write Xorg config");
        return -1;
    }

    int display_pipe[2];
    if (pipe(display_pipe) != 0) {
        NSLog(@"Failed to create display pipe: %s", strerror(errno));
        return -1;
    }

    pid_t pid = fork();
    if (pid < 0) {
        close(display_pipe[0]);
        close(display_pipe[1]);
        NSLog(@"Failed to fork: %s", strerror(errno));
        return -1;
    }

    if (pid == 0) {
        close(display_pipe[0]);
        if (dup2(display_pipe[1], 99) < 0) {
            _exit(127);
        }
        close(display_pipe[1]);

        int devnull = open("/dev/null", O_RDWR);
        if (devnull >= 0) {
            dup2(devnull, STDIN_FILENO);
            dup2(devnull, STDOUT_FILENO);
            dup2(devnull, STDERR_FILENO);
            if (devnull > STDERR_FILENO) {
                close(devnull);
            }
        }

        char *argv[16];
        size_t argc = 0;

        argv[argc++] = (char *)xorg;
        argv[argc++] = "-quiet";
        argv[argc++] = "-config";
        argv[argc++] = (char *)[_xorgConfigPath UTF8String];
        argv[argc++] = "-noreset";
        argv[argc++] = "-logfile";
        argv[argc++] = (char *)[_xorgLogPath UTF8String];
        argv[argc++] = "-displayfd";
        argv[argc++] = "99";
        argv[argc++] = "-listen";
        argv[argc++] = "local";
        argv[argc] = NULL;

        execv(xorg, argv);
        _exit(127);
    }

    close(display_pipe[1]);

    int display_num = -1;
    if ([self waitForDisplayFd:display_pipe[0] displayNumber:&display_num] != 0) {
        close(display_pipe[0]);
        NSLog(@"Failed to get display number from Xorg");
        return -1;
    }
    close(display_pipe[0]);

    _display_number = display_num;
    _xorg_pid = pid;

    NSLog(@"Xorg started on display :%d", _display_number);
    return 0;
}

- (BOOL)connectToXServer {
    char display[64];
    snprintf(display, sizeof(display), ":%d", _display_number);

    for (int attempt = 0; attempt < 50; attempt++) {
        _connection = xcb_connect(display, NULL);
        if (_connection && !xcb_connection_has_error(_connection)) {
            break;
        }
        usleep(100000);
    }

    if (xcb_connection_has_error(_connection)) {
        NSLog(@"Failed to connect to X server");
        return NO;
    }

    const xcb_setup_t *setup = xcb_get_setup(_connection);
    xcb_screen_iterator_t iter = xcb_setup_roots_iterator(setup);
    _screen = iter.data;
    _rootWindow = _screen->root;

    uint32_t event_mask = XCB_EVENT_MASK_SUBSTRUCTURE_NOTIFY |
                          XCB_EVENT_MASK_EXPOSURE |
                          XCB_EVENT_MASK_BUTTON_PRESS |
                          XCB_EVENT_MASK_BUTTON_RELEASE |
                          XCB_EVENT_MASK_POINTER_MOTION |
                          XCB_EVENT_MASK_KEY_PRESS |
                          XCB_EVENT_MASK_KEY_RELEASE;
    xcb_change_window_attributes(_connection, _rootWindow, XCB_CW_EVENT_MASK, &event_mask);

    xcb_composite_query_version_cookie_t comp_cookie = xcb_composite_query_version(_connection, 0, 4);
    xcb_composite_query_version_reply_t *comp_reply = xcb_composite_query_version_reply(_connection, comp_cookie, NULL);
    if (comp_reply) {
        xcb_composite_redirect_subwindows(_connection, _rootWindow, XCB_COMPOSITE_REDIRECT_AUTOMATIC);
        free(comp_reply);
    }

    xcb_flush(_connection);

    return YES;
}

- (BOOL)start {
    [self setupFocusSocket];
    if ([self spawnXorg] != 0) {
        return NO;
    }

    if (![self connectToXServer]) {
        return NO;
    }

    _running = YES;

    __block id blockSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        self.refreshTimer = [NSTimer scheduledTimerWithTimeInterval:1.0/60.0 repeats:YES block:^(NSTimer * _Nonnull timer) {
            [blockSelf retain];
            [blockSelf handleIncomingSocketData];
            for (NSNumber *windowId in [blockSelf windows]) {
                [blockSelf captureAndDisplayWindow:(xcb_window_t)[windowId unsignedIntValue]];
            }
            [blockSelf release];
        }];
        [[NSRunLoop mainRunLoop] addTimer:self.refreshTimer forMode:NSRunLoopCommonModes];
    });

    [self runEventLoop];

    return YES;
}

- (void)runEventLoop {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        while (self.running) {
            xcb_generic_event_t *event = xcb_wait_for_event(self.connection);
            if (event) {
                [self handleEvent:event];
                free(event);
            }
        }
    });
}

- (void)handleEvent:(xcb_generic_event_t *)event {
    uint8_t type = event->response_type & ~0x80;

    switch (type) {
        case XCB_MAP_NOTIFY:
            [self handleMapNotify:(xcb_map_notify_event_t *)event];
            break;
        case XCB_UNMAP_NOTIFY:
            [self handleUnmapNotify:(xcb_unmap_notify_event_t *)event];
            break;
        case XCB_DESTROY_NOTIFY:
            [self handleDestroyNotify:(xcb_destroy_notify_event_t *)event];
            break;
        case XCB_CONFIGURE_NOTIFY:
            [self handleConfigureNotify:(xcb_configure_notify_event_t *)event];
            break;
        case XCB_EXPOSE:
            [self handleExpose:(xcb_expose_event_t *)event];
            break;
    }
}

- (void)captureAndDisplayWindow:(xcb_window_t)xWindow {
    [self retain];

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        xcb_get_geometry_reply_t *geom = xcb_get_geometry_reply(self.connection,
            xcb_get_geometry(self.connection, xWindow), NULL);

        if (!geom) {
            [self release];
            return;
        }

        xcb_get_image_cookie_t cookie = xcb_get_image(self.connection,
            XCB_IMAGE_FORMAT_Z_PIXMAP, xWindow, 0, 0, geom->width, geom->height, UINT32_MAX);

        xcb_get_image_reply_t *reply = xcb_get_image_reply(self.connection, cookie, NULL);

        if (!reply) {
            free(geom);
            [self release];
            return;
        }

        int root_x = geom->x;
        int root_y = geom->y;
        int width = geom->width;
        int height = geom->height;
        free(geom);

        const uint8_t *data = xcb_get_image_data(reply);
        int data_len = xcb_get_image_data_length(reply);

        if (width <= 0 || height <= 0 || data_len <= 0) {
            free(reply);
            return;
        }

        NSBitmapImageRep *bitmap = [[[NSBitmapImageRep alloc]
            initWithBitmapDataPlanes:NULL
                        pixelsWide:width
                        pixelsHigh:height
                     bitsPerSample:8
                   samplesPerPixel:4
                          hasAlpha:YES
                          isPlanar:NO
                    colorSpaceName:NSCalibratedRGBColorSpace
                       bytesPerRow:width * 4
                      bitsPerPixel:32] autorelease];

        uint8_t *bitmap_data = [bitmap bitmapData];
        if (!bitmap_data) {
            free(reply);
            return;
        }

        // If data_len is exactly width * height * 4, we have a 32bpp ZPixmap
        int pixel_count = width * height;
        if (data_len >= pixel_count * 4) {
            memcpy(bitmap_data, data, pixel_count * 4);
            for (int i = 0; i < pixel_count; i++) {
                uint8_t b = bitmap_data[i*4 + 0];
                uint8_t g = bitmap_data[i*4 + 1];
                uint8_t r = bitmap_data[i*4 + 2];
                bitmap_data[i*4 + 0] = r;
                bitmap_data[i*4 + 1] = g;
                bitmap_data[i*4 + 2] = b;
                bitmap_data[i*4 + 3] = 255;
            }
        } else if (data_len >= pixel_count * 3) {
            // 24bpp packed ZPixmap? Less common, but just in case
            for (int i = 0; i < pixel_count; i++) {
                bitmap_data[i*4 + 0] = data[i*3 + 2];
                bitmap_data[i*4 + 1] = data[i*3 + 1];
                bitmap_data[i*4 + 2] = data[i*3 + 0];
                bitmap_data[i*4 + 3] = 255;
            }
        }

        NSImage *image = [[[NSImage alloc] initWithSize:NSMakeSize(width, height)] autorelease];
        [image addRepresentation:bitmap];

        CGFloat scale = 1.0;
        if ([NSThread isMainThread]) {
            scale = [NSScreen mainScreen].backingScaleFactor;
        } else {
            // This is a bit of a hack but we need a scale on the bg thread
            // and mainScreen is only for main thread usually.
            // However, in AppKit it's often readable.
            scale = [NSScreen mainScreen].backingScaleFactor;
        }

        if (scale > 1.0) {
            image.size = NSMakeSize(width / scale, height / scale);
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            NSWindow *cocoaWindow = [self.windows objectForKey:@(xWindow)];
            if (!cocoaWindow) {
                [self release];
                return;
            }

            XClientView *imageView = (XClientView *)self.imageViews[@(xWindow)];
            NSRect sourceFrame = NSMakeRect(root_x, root_y, width, height );

            if (imageView) {
                imageView.sourceFrame = sourceFrame;
                imageView.image = image;
            } else {
                XClientView *newView = [[[XClientView alloc] initWithFrame:cocoaWindow.contentView.bounds] autorelease];
                newView.xWindow = xWindow;
                newView.connection = self.connection;
                newView.rootWindow = self.rootWindow;
                newView.sourceFrame = sourceFrame;
                newView.imageScaling = NSImageScaleAxesIndependently;
                newView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
                newView.image = image;

                // Add tracking area for mouse movement
                NSTrackingArea *trackingArea = [[[NSTrackingArea alloc] initWithRect:newView.bounds
                                                                            options:NSTrackingMouseMoved | NSTrackingActiveInKeyWindow | NSTrackingInVisibleRect
                                                                              owner:newView
                                                                         userInfo:nil] autorelease];
                [newView addTrackingArea:trackingArea];

                [cocoaWindow.contentView addSubview:newView];
                [cocoaWindow makeFirstResponder:newView];
                self.imageViews[@(xWindow)] = newView;
            }
            [self release];
        });

        free(reply);
    });
}

- (void)handleMapNotify:(xcb_map_notify_event_t *)event {
    xcb_window_t window = event->window;

    if (window == _rootWindow) return;

    xcb_get_window_attributes_reply_t *reply = xcb_get_window_attributes_reply(
        _connection, xcb_get_window_attributes(_connection, window), NULL);

    if (!reply) return;

    [self retain];
    dispatch_async(dispatch_get_main_queue(), ^{
        NSNumber *windowKey = @(window);

        NSWindow *existingWindow = [self.windows objectForKey:windowKey];
        if (existingWindow) {
            [existingWindow retain];
            [self.windows removeObjectForKey:windowKey];
            NSImageView *existingImageView = [self.imageViews objectForKey:windowKey];
            if (existingImageView) {
                [existingImageView removeFromSuperview];
                [self.imageViews removeObjectForKey:windowKey];
            }
            [existingWindow setReleasedWhenClosed:NO];
            [existingWindow orderOut:nil];
            [existingWindow close];
            [existingWindow release];
        }

        BOOL isAppKitBacked = NO;
        uint32_t nativeWindowId = 0;
        int wait_count = 0;
        // Wait up to 500ms (100 * 5ms) for properties
        // This handles AppKit apps becoming ready while allowing X-only apps to show
        while (wait_count < 100) {
            xcb_intern_atom_cookie_t native_atom_cookie = xcb_intern_atom(_connection, 1, 21, "_APP_LAUNCH_NATIVE_ID");
            xcb_intern_atom_reply_t *native_atom_reply = xcb_intern_atom_reply(_connection, native_atom_cookie, NULL);
            if (native_atom_reply) {
                xcb_get_property_cookie_t native_prop_cookie = xcb_get_property(_connection, 0, window, native_atom_reply->atom, XCB_ATOM_ANY, 0, 1);
                xcb_get_property_reply_t *native_prop_reply = xcb_get_property_reply(_connection, native_prop_cookie, NULL);
                if (native_prop_reply && native_prop_reply->format == 32 && xcb_get_property_value_length(native_prop_reply) >= 4) {
                    nativeWindowId = *(uint32_t *)xcb_get_property_value(native_prop_reply);
                }
                if (native_prop_reply) free(native_prop_reply);
                free(native_atom_reply);
            }

            xcb_intern_atom_cookie_t atom_cookie = xcb_intern_atom(_connection, 1, 18, "_APP_LAUNCH_APPKIT");
            xcb_intern_atom_reply_t *atom_reply = xcb_intern_atom_reply(_connection, atom_cookie, NULL);
            if (atom_reply) {
                xcb_get_property_cookie_t prop_cookie = xcb_get_property(_connection, 0, window, atom_reply->atom, XCB_ATOM_ANY, 0, 1);
                xcb_get_property_reply_t *prop_reply = xcb_get_property_reply(_connection, prop_cookie, NULL);
                if (prop_reply && prop_reply->format == 32 && xcb_get_property_value_length(prop_reply) > 0) {
                    isAppKitBacked = YES;
                }
                if (prop_reply) free(prop_reply);
                free(atom_reply);
            }

            if (nativeWindowId != 0 || isAppKitBacked) {
                break;
            }
            
            usleep(5000); // 5ms
            wait_count++;
        }

        NSWindowStyleMask styleMask = NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                                      NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable;

        styleMask |= NSWindowStyleMaskFullSizeContentView;

        NSRect frame = NSMakeRect(100, 100, 800, 600);
        NSWindow *cocoaWindow = [[[XClientWindow alloc] initWithContentRect:frame
                                                         styleMask:styleMask
                                                            backing:NSBackingStoreBuffered
                                                              defer:NO] autorelease];
        [cocoaWindow setReleasedWhenClosed:NO];
        [[cocoaWindow standardWindowButton:NSWindowCloseButton] setHidden:YES];
        [[cocoaWindow standardWindowButton:NSWindowMiniaturizeButton] setHidden:YES];
        [[cocoaWindow standardWindowButton:NSWindowZoomButton] setHidden:YES];

        cocoaWindow.titlebarAppearsTransparent = YES;
        cocoaWindow.titleVisibility = NSWindowTitleHidden;

        cocoaWindow.title = [NSString stringWithFormat:@"X Client 0x%x", window];

        cocoaWindow.delegate = self;

        xcb_get_geometry_reply_t *geom = xcb_get_geometry_reply(self.connection,
            xcb_get_geometry(self.connection, window), NULL);
        if (geom) {
            [cocoaWindow setFrame:NSMakeRect(100, 100, geom->width, geom->height - 28) display:YES];
            free(geom);
        }

        self.windows[@(window)] = cocoaWindow;
        [cocoaWindow makeKeyAndOrderFront:nil];

        [self captureAndDisplayWindow:window];
        [self updateFocusClientsWithWindow:window nativeWindowId:nativeWindowId isAppKitBacked:isAppKitBacked];

        xcb_configure_window(_connection, window, XCB_CONFIG_WINDOW_BORDER_WIDTH, (uint32_t[]){0});
        xcb_map_window(_connection, window);

        [self release];
    });

    free(reply);
}

- (void)handleUnmapNotify:(xcb_unmap_notify_event_t *)event {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self closeCocoaWindowForXWindow:event->window];
    });
}

- (void)handleDestroyNotify:(xcb_destroy_notify_event_t *)event {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self closeCocoaWindowForXWindow:event->window];
    });
}

- (void)handleConfigureNotify:(xcb_configure_notify_event_t *)event {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSWindow *window = self.windows[@(event->window)];
        if (window) {
            NSRect frame = NSMakeRect(event->x, event->y, event->width, event->height);
            [window setFrame:frame display:YES];
            [self captureAndDisplayWindow:event->window];
        }
    });
}

- (void)windowDidResignKey:(NSNotification *)notification {
    NSLog(@"[AppSrv] Window resigned key: %@", notification.object);
}

- (void)handleExpose:(xcb_expose_event_t *)event {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSWindow *window = self.windows[@(event->window)];
        if (window) {
            [self captureAndDisplayWindow:event->window];
        }
    });
}

- (void)windowDidBecomeKey:(NSNotification *)notification {
    NSWindow *cocoaWindow = notification.object;
    NSNumber *foundKey = nil;
    for (NSNumber *key in self.windows) {
        if (self.windows[key] == cocoaWindow) {
            foundKey = key;
            break;
        }
    }
    if (foundKey) {
        xcb_window_t xWindow = (xcb_window_t)[foundKey unsignedIntValue];
        XClientView *view = (XClientView *)self.imageViews[foundKey];
        BOOL isAppKitBacked = view ? [view isAppKitBacked] : NO;
        uint32_t nativeWindowId = view ? [view getNativeWindowID] : 0;
        [self updateFocusClientsWithWindow:xWindow nativeWindowId:nativeWindowId isAppKitBacked:isAppKitBacked];

        NSView *firstResponder = self.imageViews[foundKey];
        if (firstResponder != nil) {
            [cocoaWindow makeFirstResponder:firstResponder];
        }
        xcb_set_input_focus(_connection, XCB_INPUT_FOCUS_POINTER_ROOT, xWindow, XCB_CURRENT_TIME);

        uint32_t values[] = { XCB_STACK_MODE_ABOVE };
        xcb_configure_window(_connection, xWindow, XCB_CONFIG_WINDOW_STACK_MODE, values);
        xcb_flush(_connection);
    }
}

- (BOOL)windowShouldClose:(NSWindow *)sender {
    NSNumber *foundKey = nil;
    for (NSNumber *key in self.windows) {
        if (self.windows[key] == sender) {
            foundKey = key;
            break;
        }
    }
    if (foundKey) {
        xcb_window_t xWindow = (xcb_window_t)[foundKey unsignedIntValue];
        xcb_kill_client(_connection, xWindow);
        xcb_flush(_connection);
    }
    return YES;
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender {
    (void)sender;
    return NO;
}

- (void)stop {
    _running = NO;
    [self.refreshTimer invalidate];
    self.refreshTimer = nil;

    if (_connection) {
        xcb_disconnect(_connection);
        _connection = NULL;
    }

    if (_server_fd >= 0) {
        close(_server_fd);
        _server_fd = -1;
        unlink(SOCKET_PATH);
    }

    if (_xorg_pid > 0) {
        kill(_xorg_pid, SIGTERM);
        waitpid(_xorg_pid, NULL, 0);
        _xorg_pid = -1;
    }

    if (_xorgConfigPath) {
        unlink([_xorgConfigPath UTF8String]);
    }
}

- (void)dealloc {
    [self stop];
    [_windows release];
    [_imageViews release];
    [_xorgConfigPath release];
    [_xorgLogPath release];
    [super dealloc];
}

@end

int main(int argc, char *argv[]) {
    signal(SIGPIPE, SIG_IGN);
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        [app setActivationPolicy:NSApplicationActivationPolicyRegular];
        [app activateIgnoringOtherApps:YES];

        ApplicationServer *server = [[ApplicationServer alloc] init];
        app.delegate = server;

        if (![server start]) {
            [server release];
            return 1;
        }

        [app run];
        [server release];
    }
    return 0;
}
