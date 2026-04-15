#import "application_server.h"
#include <AppKit/AppKit.h>
#import <Cocoa/Cocoa.h>
#import <xcb/xcb.h>
#import <xcb/composite.h>
#include <dlfcn.h>

#import "XClientWindow.h"
#import "XClientView.h"
#import "XorgServer.h"
#import "FocusSocket.h"

static const char *FOCUS_SOCKET_PATH = "/tmp/applicator_focus.sock";

@interface ApplicationServer () <NSWindowDelegate, NSApplicationDelegate>
@property (nonatomic, assign) xcb_connection_t *connection;
@property (nonatomic, assign) xcb_screen_t *screen;
@property (nonatomic, assign) xcb_window_t rootWindow;
@property (nonatomic, retain) XorgServer *xorg;
@property (nonatomic, retain) FocusSocket *focusSocket;
@property (nonatomic, assign) BOOL running;
@property (nonatomic, retain) NSMutableDictionary<NSNumber *, NSWindow *> *windows;
@property (nonatomic, retain) NSMutableDictionary<NSNumber *, NSImageView *> *imageViews;
@property (nonatomic, retain) NSTimer *refreshTimer;
@end

@implementation ApplicationServer

- (instancetype)init {
    self = [super init];
    if (self) {
        _windows = [[NSMutableDictionary alloc] init];
        _imageViews = [[NSMutableDictionary alloc] init];
        _running = NO;
        _xorg = [[XorgServer alloc] init];
        _focusSocket = [[FocusSocket alloc] init];
    }
    return self;
}

- (void)closeCocoaWindowForXWindow:(xcb_window_t)xWindow {
    NSNumber *windowKey = @(xWindow);
    NSWindow *window = [self.windows objectForKey:windowKey];
    if (!window) return;

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

- (BOOL)connectToXServer {
    char display[64];
    snprintf(display, sizeof(display), ":%d", self.xorg.displayNumber);

    for (int attempt = 0; attempt < 50; attempt++) {
        _connection = xcb_connect(display, NULL);
        if (_connection && !xcb_connection_has_error(_connection)) break;
        usleep(100000);
    }

    if (xcb_connection_has_error(_connection)) return NO;

    const xcb_setup_t *setup = xcb_get_setup(_connection);
    xcb_screen_iterator_t iter = xcb_setup_roots_iterator(setup);
    _screen = iter.data;
    _rootWindow = _screen->root;

    uint32_t event_mask = XCB_EVENT_MASK_SUBSTRUCTURE_NOTIFY | XCB_EVENT_MASK_EXPOSURE | XCB_EVENT_MASK_BUTTON_PRESS | XCB_EVENT_MASK_BUTTON_RELEASE | XCB_EVENT_MASK_POINTER_MOTION | XCB_EVENT_MASK_KEY_PRESS | XCB_EVENT_MASK_KEY_RELEASE;
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
    if (![self.focusSocket setup:FOCUS_SOCKET_PATH]) return NO;
    if (![self.xorg spawnWithWidth:1920 height:1080]) return NO;
    if (![self connectToXServer]) return NO;

    _running = YES;
    __block ApplicationServer *blockSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        self.refreshTimer = [NSTimer scheduledTimerWithTimeInterval:1.0/60.0 repeats:YES block:^(NSTimer * _Nonnull timer) {
            [blockSelf retain];
            [blockSelf.focusSocket handleIncomingData];
            NSMutableArray *toRemove = [NSMutableArray array];
            for (NSNumber *windowId in [blockSelf windows]) {
                xcb_window_t xWin = (xcb_window_t)[windowId unsignedIntValue];
                xcb_get_window_attributes_cookie_t attr_cookie = xcb_get_window_attributes((xcb_connection_t *)[blockSelf connection], xWin);
                xcb_get_window_attributes_reply_t *attr = xcb_get_window_attributes_reply((xcb_connection_t *)[blockSelf connection], attr_cookie, NULL);
                if (!attr || attr->map_state == XCB_MAP_STATE_UNMAPPED) {
                    [toRemove addObject:windowId];
                    if (attr) free(attr);
                    continue;
                }
                free(attr);

                xcb_intern_atom_cookie_t pid_atom_cookie = xcb_intern_atom((xcb_connection_t *)[blockSelf connection], 0, 11, "_NET_WM_PID");
                xcb_intern_atom_reply_t *pid_atom_reply = xcb_intern_atom_reply((xcb_connection_t *)[blockSelf connection], pid_atom_cookie, NULL);
                if (pid_atom_reply) {
                    xcb_get_property_cookie_t prop_cookie = xcb_get_property((xcb_connection_t *)[blockSelf connection], 0, xWin, pid_atom_reply->atom, XCB_ATOM_CARDINAL, 0, 1);
                    xcb_get_property_reply_t *prop_reply = xcb_get_property_reply((xcb_connection_t *)[blockSelf connection], prop_cookie, NULL);
                    if (prop_reply && prop_reply->format == 32 && xcb_get_property_value_length(prop_reply) >= 4) {
                        pid_t owner_pid = *(pid_t *)xcb_get_property_value(prop_reply);
                        if (kill(owner_pid, 0) == -1 && errno == ESRCH) [toRemove addObject:windowId];
                    }
                    if (prop_reply) free(prop_reply);
                    free(pid_atom_reply);
                }

                if (![toRemove containsObject:windowId]) [blockSelf captureAndDisplayWindow:xWin];
            }
            for (NSNumber *windowId in toRemove) [blockSelf closeCocoaWindowForXWindow:(xcb_window_t)[windowId unsignedIntValue]];
            [blockSelf release];
        }];
        [[NSRunLoop mainRunLoop] addTimer:self.refreshTimer forMode:NSRunLoopCommonModes];
    });

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        while (self.running) {
            xcb_generic_event_t *event = xcb_wait_for_event(self.connection);
            if (event) {
                [self handleEvent:event];
                free(event);
            }
        }
    });

    return YES;
}

- (void)handleEvent:(xcb_generic_event_t *)event {
    uint8_t type = event->response_type & ~0x80;
    switch (type) {
        case XCB_MAP_NOTIFY: [self handleMapNotify:(xcb_map_notify_event_t *)event]; break;
        case XCB_UNMAP_NOTIFY: dispatch_async(dispatch_get_main_queue(), ^{ [self closeCocoaWindowForXWindow:((xcb_unmap_notify_event_t *)event)->window]; }); break;
        case XCB_DESTROY_NOTIFY: dispatch_async(dispatch_get_main_queue(), ^{ [self closeCocoaWindowForXWindow:((xcb_destroy_notify_event_t *)event)->window]; }); break;
        case XCB_CONFIGURE_NOTIFY: [self handleConfigureNotify:(xcb_configure_notify_event_t *)event]; break;
        case XCB_EXPOSE: dispatch_async(dispatch_get_main_queue(), ^{ if (self.windows[@(((xcb_expose_event_t *)event)->window)]) [self captureAndDisplayWindow:((xcb_expose_event_t *)event)->window]; }); break;
    }
}

- (void)captureAndDisplayWindow:(xcb_window_t)xWindow {
    [self retain];
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        xcb_get_geometry_reply_t *geom = xcb_get_geometry_reply(self.connection, xcb_get_geometry(self.connection, xWindow), NULL);
        if (!geom) { [self release]; return; }
        xcb_get_image_reply_t *reply = xcb_get_image_reply(self.connection, xcb_get_image(self.connection, XCB_IMAGE_FORMAT_Z_PIXMAP, xWindow, 0, 0, geom->width, geom->height, UINT32_MAX), NULL);
        if (!reply) { free(geom); [self release]; return; }

        int root_x = geom->x, root_y = geom->y, width = geom->width, height = geom->height;
        free(geom);
        const uint8_t *data = xcb_get_image_data(reply);
        int data_len = xcb_get_image_data_length(reply);
        if (width <= 0 || height <= 0 || data_len < width * height * 4) { free(reply); [self release]; return; }

        NSBitmapImageRep *bitmap = [[[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:width pixelsHigh:height bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSCalibratedRGBColorSpace bytesPerRow:width * 4 bitsPerPixel:32] autorelease];
        uint8_t *bitmap_data = [bitmap bitmapData];
        memcpy(bitmap_data, data, width * height * 4);
        for (int i = 0; i < width * height; i++) {
            uint8_t b = bitmap_data[i*4 + 0], g = bitmap_data[i*4 + 1], r = bitmap_data[i*4 + 2];
            bitmap_data[i*4 + 0] = r; bitmap_data[i*4 + 1] = g; bitmap_data[i*4 + 2] = b; bitmap_data[i*4 + 3] = 255;
        }

        NSImage *image = [[[NSImage alloc] initWithSize:NSMakeSize(width, height)] autorelease];
        [image addRepresentation:bitmap];
        CGFloat scale = [NSScreen mainScreen].backingScaleFactor;
        if (scale > 1.0) image.size = NSMakeSize(width / scale, height / scale);

        dispatch_async(dispatch_get_main_queue(), ^{
            NSWindow *cocoaWindow = self.windows[@(xWindow)];
            if (!cocoaWindow) { [self release]; return; }
            XClientView *imageView = (XClientView *)self.imageViews[@(xWindow)];
            NSRect sourceFrame = NSMakeRect(root_x, root_y, width, height);
            if (imageView) { imageView.sourceFrame = sourceFrame; imageView.image = image; }
            else {
                XClientView *newView = [[[XClientView alloc] initWithFrame:cocoaWindow.contentView.bounds] autorelease];
                newView.xWindow = xWindow; newView.connection = self.connection; newView.rootWindow = self.rootWindow; newView.sourceFrame = sourceFrame;
                newView.imageScaling = NSImageScaleAxesIndependently; newView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable; newView.image = image;
                [newView addTrackingArea:[[[NSTrackingArea alloc] initWithRect:newView.bounds options:NSTrackingMouseMoved | NSTrackingActiveInKeyWindow | NSTrackingInVisibleRect owner:newView userInfo:nil] autorelease]];
                [cocoaWindow.contentView addSubview:newView]; [cocoaWindow makeFirstResponder:newView]; self.imageViews[@(xWindow)] = newView;
            }
            [self release];
        });
        free(reply);
    });
}

- (void)handleMapNotify:(xcb_map_notify_event_t *)event {
    xcb_window_t window = event->window;
    if (window == _rootWindow) return;
    xcb_get_window_attributes_reply_t *reply = xcb_get_window_attributes_reply(_connection, xcb_get_window_attributes(_connection, window), NULL);
    if (!reply) return;

    [self retain];
    dispatch_async(dispatch_get_main_queue(), ^{
        [self closeCocoaWindowForXWindow:window];
        int cid = 0;
        xcb_intern_atom_reply_t *cid_atom_reply = xcb_intern_atom_reply(_connection, xcb_intern_atom(_connection, 0, 15, "_APP_LAUNCH_CID"), NULL);
        if (cid_atom_reply) {
            xcb_get_property_reply_t *cid_prop_reply = xcb_get_property_reply(_connection, xcb_get_property(_connection, 0, window, cid_atom_reply->atom, XCB_ATOM_ANY, 0, 1), NULL);
            if (cid_prop_reply && cid_prop_reply->format == 32 && xcb_get_property_value_length(cid_prop_reply) >= 4) cid = *(int *)xcb_get_property_value(cid_prop_reply);
            if (cid_prop_reply) free(cid_prop_reply); free(cid_atom_reply);
        }

        NSWindow *cocoaWindow = [[[XClientWindow alloc] initWithContentRect:NSMakeRect(100, 100, 800, 600) styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable | NSWindowStyleMaskFullSizeContentView backing:NSBackingStoreBuffered defer:NO] autorelease];
        cocoaWindow.titlebarAppearsTransparent = YES; cocoaWindow.titleVisibility = NSWindowTitleHidden; cocoaWindow.title = [NSString stringWithFormat:@"X Client 0x%x", window]; cocoaWindow.delegate = self;

        xcb_get_geometry_reply_t *geom = xcb_get_geometry_reply(self.connection, xcb_get_geometry(self.connection, window), NULL);
        if (geom) { [cocoaWindow setFrame:NSMakeRect(100, 100, geom->width, geom->height) display:YES]; free(geom); }

        self.windows[@(window)] = cocoaWindow; [cocoaWindow makeKeyAndOrderFront:nil];
        [self captureAndDisplayWindow:window]; [self.focusSocket updateFocusWithWindow:window nativeWindowId:0 cid:cid];
        xcb_configure_window(_connection, window, XCB_CONFIG_WINDOW_BORDER_WIDTH, (uint32_t[]){0}); xcb_map_window(_connection, window);
        [self release];
    });
    free(reply);
}

- (void)handleConfigureNotify:(xcb_configure_notify_event_t *)event {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSWindow *window = self.windows[@(event->window)];
        if (window) { [window setFrame:NSMakeRect(event->x, event->y, event->width, event->height) display:YES]; [self captureAndDisplayWindow:event->window]; }
    });
}

- (void)windowDidResize:(NSNotification *)notification {
    NSWindow *cocoaWindow = notification.object;
    for (NSNumber *key in self.windows) {
        if (self.windows[key] == cocoaWindow) {
            xcb_window_t xWindow = (xcb_window_t)[key unsignedIntValue];
            NSRect contentRect = [cocoaWindow contentRectForFrameRect:cocoaWindow.frame];
            uint32_t values[] = { (uint32_t)contentRect.size.width, (uint32_t)contentRect.size.height };
            xcb_configure_window(_connection, xWindow, XCB_CONFIG_WINDOW_WIDTH | XCB_CONFIG_WINDOW_HEIGHT, values);
            xcb_flush(_connection); [self captureAndDisplayWindow:xWindow]; break;
        }
    }
}

- (void)windowDidBecomeKey:(NSNotification *)notification {
    NSWindow *cocoaWindow = notification.object;
    for (NSNumber *key in self.windows) {
        if (self.windows[key] == cocoaWindow) {
            xcb_window_t xWindow = (xcb_window_t)[key unsignedIntValue];
            XClientView *view = (XClientView *)self.imageViews[key];
            [self.focusSocket updateFocusWithWindow:xWindow nativeWindowId:0 cid:view ? [view getCID] : 0];
            if (view) [cocoaWindow makeFirstResponder:view];
            xcb_set_input_focus(_connection, XCB_INPUT_FOCUS_POINTER_ROOT, xWindow, XCB_CURRENT_TIME);
            xcb_configure_window(_connection, xWindow, XCB_CONFIG_WINDOW_STACK_MODE, (uint32_t[]){XCB_STACK_MODE_ABOVE});
            xcb_flush(_connection); break;
        }
    }
}

- (BOOL)windowShouldClose:(NSWindow *)sender {
    for (NSNumber *key in self.windows) {
        if (self.windows[key] == sender) { xcb_kill_client(_connection, (xcb_window_t)[key unsignedIntValue]); xcb_flush(_connection); break; }
    }
    return YES;
}

- (void)stop {
    _running = NO; [self.refreshTimer invalidate]; self.refreshTimer = nil;
    if (_connection) { xcb_disconnect(_connection); _connection = NULL; }
    [self.focusSocket stop]; [self.xorg stop];
}

- (void)dealloc {
    [self stop]; [_windows release]; [_imageViews release]; [_xorg release]; [_focusSocket release]; [super dealloc];
}

@end

int main(int argc, char *argv[]) {
    signal(SIGPIPE, SIG_IGN);
    @autoreleasepool {
        Dl_info info;
        if (dladdr((void *)main, &info) == 0) {
            NSLog(@"Failed to get current binary info");
            return 1;
        }

        NSString *dylibPath = [[NSString stringWithUTF8String:info.dli_fname] stringByDeletingLastPathComponent];
        dylibPath = [dylibPath stringByAppendingPathComponent:@"libAppLaunchRunner.dylib"];

        void *handle = dlopen([dylibPath UTF8String], RTLD_NOW);
        if (!handle) {
            NSLog(@"Failed to load %@: %s", dylibPath, dlerror());
        } else {
            NSLog(@"Loaded AppLaunchRunner dylib from %@", dylibPath);
        }

        NSApplication *app = [NSApplication sharedApplication];
        [app setActivationPolicy:NSApplicationActivationPolicyRegular];
        [app activateIgnoringOtherApps:YES];
        ApplicationServer *server = [[ApplicationServer alloc] init];
        app.delegate = server;
        if (![server start]) { [server release]; return 1; }
        [app run]; [server release];
    }
    return 0;
}
