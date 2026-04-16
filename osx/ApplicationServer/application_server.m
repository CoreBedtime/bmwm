#import "application_server.h"
#include <AppKit/AppKit.h>
#import <Cocoa/Cocoa.h>
#import <xcb/xcb.h>
#import <xcb/composite.h>
#import <xcb/damage.h>
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
@property (nonatomic, retain) NSMutableDictionary<NSNumber *, NSNumber *> *damageWindows;
@property (nonatomic, assign) BOOL damageAvailable;
@property (nonatomic, assign) uint8_t damageEventBase;
@end

@implementation ApplicationServer

- (instancetype)init {
    self = [super init];
    if (self) {
        _windows = [[NSMutableDictionary alloc] init];
        _imageViews = [[NSMutableDictionary alloc] init];
        _damageWindows = [[NSMutableDictionary alloc] init];
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

    [self unregisterDamageForWindow:xWindow];
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

    const xcb_query_extension_reply_t *damage_extension = xcb_get_extension_data(_connection, &xcb_damage_id);
    if (damage_extension && damage_extension->present) {
        xcb_damage_query_version_cookie_t damage_cookie =
            xcb_damage_query_version(_connection, XCB_DAMAGE_MAJOR_VERSION, XCB_DAMAGE_MINOR_VERSION);
        xcb_damage_query_version_reply_t *damage_reply =
            xcb_damage_query_version_reply(_connection, damage_cookie, NULL);
        if (damage_reply) {
            self.damageAvailable = YES;
            self.damageEventBase = damage_extension->first_event;
            free(damage_reply);
        }
    }

    xcb_flush(_connection);
    return YES;
}

- (void)registerDamageForWindow:(xcb_window_t)xWindow {
    if (!self.damageAvailable || _connection == NULL) {
        return;
    }

    NSNumber *windowKey = @(xWindow);
    @synchronized (self) {
        if ([self.damageWindows objectForKey:windowKey] != nil) {
            return;
        }

        xcb_damage_damage_t damage = xcb_generate_id(_connection);
        xcb_damage_create(_connection, damage, xWindow, XCB_DAMAGE_REPORT_LEVEL_NON_EMPTY);
        [self.damageWindows setObject:@(damage) forKey:windowKey];
        xcb_flush(_connection);
    }
}

- (void)unregisterDamageForWindow:(xcb_window_t)xWindow {
    if (_connection == NULL) {
        return;
    }

    NSNumber *windowKey = @(xWindow);
    @synchronized (self) {
        NSNumber *damageKey = [self.damageWindows objectForKey:windowKey];
        if (!damageKey) {
            return;
        }

        xcb_damage_destroy(_connection, (xcb_damage_damage_t)[damageKey unsignedIntValue]);
        [self.damageWindows removeObjectForKey:windowKey];
        xcb_flush(_connection);
    }
}

- (BOOL)start {
    if (![self.focusSocket setup:FOCUS_SOCKET_PATH]) return NO;
    if (![self.xorg spawnWithWidth:1920 height:1080]) return NO;
    if (![self connectToXServer]) return NO;

    _running = YES;

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
        default:
            if (self.damageAvailable && type == (uint8_t)(self.damageEventBase + XCB_DAMAGE_NOTIFY)) {
                [self handleDamageNotify:(xcb_damage_notify_event_t *)event];
            }
            break;
    }
}

- (void)handleDamageNotify:(xcb_damage_notify_event_t *)event {
    if (event == NULL) {
        return;
    }

    [self captureAndDisplayWindow:(xcb_window_t)event->drawable];
}

- (void)captureAndDisplayWindow:(xcb_window_t)xWindow {
    [self retain];
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        xcb_damage_damage_t damageId = 0;
        if (self.damageAvailable) {
            @synchronized (self) {
                NSNumber *damageKey = [self.damageWindows objectForKey:@(xWindow)];
                if (damageKey) {
                    damageId = (xcb_damage_damage_t)[damageKey unsignedIntValue];
                }
            }
            if (damageId != 0) {
                xcb_damage_subtract(self.connection, damageId, XCB_XFIXES_REGION_NONE, XCB_XFIXES_REGION_NONE);
                xcb_flush(self.connection);
            }
        }

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
        [self registerDamageForWindow:window];
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
    _running = NO;
    [self.damageWindows removeAllObjects];
    if (_connection) { xcb_disconnect(_connection); _connection = NULL; }
    [self.focusSocket stop]; [self.xorg stop];
}

- (void)dealloc {
    [self stop]; [_windows release]; [_imageViews release]; [_damageWindows release]; [_xorg release]; [_focusSocket release]; [super dealloc];
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
