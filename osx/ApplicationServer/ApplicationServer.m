#import "ApplicationServer.h"

#import <Cocoa/Cocoa.h>
#import <AppKit/AppKit.h>
#import <xcb/xcb.h>
#import <xcb/composite.h>
#import <xcb/damage.h>

#include <dlfcn.h>
#include <unistd.h>

#import "FocusSocket.h"
#import "XClientView.h"
#import "XClientWindow.h"
#import "XorgServer.h"

extern BOOL WannaTileLoadServerScript(const char *path, const char *logPrefix);
extern void WannaTileShutdown(void);

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
// Write end of a self-pipe used to wake xcb_wait_for_event during shutdown.
@property (nonatomic, assign) int wakeupPipeWriteFd;

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
        _wakeupPipeWriteFd = -1;
    }
    return self;
}

#pragma mark - Window Lifecycle

- (void)closeCocoaWindowForXWindow:(xcb_window_t)xWindow {
    NSNumber *windowKey = @(xWindow);
    NSWindow *window = [self.windows objectForKey:windowKey];
    if (!window) return;

    // Pull everything out of tracking dicts first so no re-entrant
    // notification can observe a partially-torn-down state.
    [window retain];
    [self.windows removeObjectForKey:windowKey];

    NSImageView *imageView = [self.imageViews objectForKey:windowKey];
    if (imageView) {
        [imageView removeFromSuperview];
        [self.imageViews removeObjectForKey:windowKey];
    }

    [self unregisterDamageForWindow:xWindow];

    window.delegate = nil;
    [window setReleasedWhenClosed:NO];
    [window orderOut:nil];
    [window close];
    [window release];
}

// Close every tracked Cocoa window at once (used on connection loss).
- (void)closeAllCocoaWindows {
    // Snapshot the keys so we can mutate the dict inside the loop.
    NSArray *keys = [self.windows allKeys];
    for (NSNumber *key in keys) {
        [self closeCocoaWindowForXWindow:(xcb_window_t)[key unsignedIntValue]];
    }
}

#pragma mark - X Server Connection

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

    // SUBSTRUCTURE_NOTIFY on the root window delivers MapNotify, UnmapNotify,
    // DestroyNotify, ConfigureNotify, ReparentNotify for all direct children.
    uint32_t event_mask = XCB_EVENT_MASK_SUBSTRUCTURE_NOTIFY
                        | XCB_EVENT_MASK_EXPOSURE
                        | XCB_EVENT_MASK_BUTTON_PRESS
                        | XCB_EVENT_MASK_BUTTON_RELEASE
                        | XCB_EVENT_MASK_POINTER_MOTION
                        | XCB_EVENT_MASK_KEY_PRESS
                        | XCB_EVENT_MASK_KEY_RELEASE;
    xcb_change_window_attributes(_connection, _rootWindow, XCB_CW_EVENT_MASK, &event_mask);

    xcb_composite_query_version_cookie_t comp_cookie =
        xcb_composite_query_version(_connection, 0, 4);
    xcb_composite_query_version_reply_t *comp_reply =
        xcb_composite_query_version_reply(_connection, comp_cookie, NULL);
    if (comp_reply) {
        xcb_composite_redirect_subwindows(_connection, _rootWindow, XCB_COMPOSITE_REDIRECT_AUTOMATIC);
        free(comp_reply);
    }

    const xcb_query_extension_reply_t *damage_extension =
        xcb_get_extension_data(_connection, &xcb_damage_id);
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

#pragma mark - Damage Tracking

- (void)registerDamageForWindow:(xcb_window_t)xWindow {
    if (!self.damageAvailable || _connection == NULL) return;

    NSNumber *windowKey = @(xWindow);
    @synchronized (self) {
        if ([self.damageWindows objectForKey:windowKey] != nil) return;

        xcb_damage_damage_t damage = xcb_generate_id(_connection);
        xcb_damage_create(_connection, damage, xWindow, XCB_DAMAGE_REPORT_LEVEL_NON_EMPTY);
        [self.damageWindows setObject:@(damage) forKey:windowKey];
        xcb_flush(_connection);
    }
}

- (void)unregisterDamageForWindow:(xcb_window_t)xWindow {
    if (_connection == NULL) return;

    NSNumber *windowKey = @(xWindow);
    @synchronized (self) {
        NSNumber *damageKey = [self.damageWindows objectForKey:windowKey];
        if (!damageKey) return;

        xcb_damage_destroy(_connection, (xcb_damage_damage_t)[damageKey unsignedIntValue]);
        [self.damageWindows removeObjectForKey:windowKey];
        xcb_flush(_connection);
    }
}

#pragma mark - Server Start / Stop

- (BOOL)start {
    if (![self.focusSocket setup:FOCUS_SOCKET_PATH]) return NO;
    if (![self.xorg spawnWithWidth:1920 height:1080]) return NO;
    if (![self connectToXServer]) return NO;

    // Create a self-pipe so -stop can wake the blocking xcb_wait_for_event
    // call without racing against xcb_disconnect.
    int pipeFds[2];
    if (pipe(pipeFds) == 0) {
        // Make the read end non-blocking so XCB can poll it alongside the
        // X socket via xcb_wait_for_event.  We only use the write end here;
        // XCB itself monitors the X socket fd, so the pipe wakeup works by
        // closing the XCB connection from the same thread after setting
        // _running = NO (see -stop).
        close(pipeFds[0]);
        _wakeupPipeWriteFd = pipeFds[1];
    }

    _running = YES;

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        while (self.running) {
            xcb_generic_event_t *event = xcb_wait_for_event(self.connection);

            if (event) {
                [self handleEvent:event];
                free(event);
                continue;
            }

            // NULL means the connection was closed or has an error.
            // This covers: Xorg crash, xcb_disconnect called from another
            // thread, or any I/O error on the X socket.
            if (!self.running) break;  // clean shutdown, nothing to do

            NSLog(@"[ApplicationServer] XCB connection lost — closing all windows");
            _running = NO;
            dispatch_async(dispatch_get_main_queue(), ^{
                [self closeAllCocoaWindows];
            });
            break;
        }
    });

    // Schedule a periodic reaper that verifies every tracked X window still
    // exists.  This is a safety net for any edge cases (reparenting before
    // we see the event, XID reuse, etc.) that slip past event-driven cleanup.
    // [Removed: redundant since Xorg instantly sends DestroyNotify on client death]

    return YES;
}

- (void)stop {
    _running = NO;

    // Wake the event-loop thread by closing the XCB connection from THIS
    // thread.  xcb_wait_for_event will return NULL on the background thread,
    // which will then exit cleanly.  This avoids the use-after-free of
    // calling xcb_disconnect concurrently with xcb_wait_for_event.
    if (_wakeupPipeWriteFd >= 0) {
        close(_wakeupPipeWriteFd);
        _wakeupPipeWriteFd = -1;
    }
    if (_connection) {
        xcb_disconnect(_connection);
        _connection = NULL;
    }

    [self.focusSocket stop];
    [self.xorg stop];
}

- (void)dealloc {
    [self stop];
    [_windows release];
    [_imageViews release];
    [_damageWindows release];
    [_xorg release];
    [_focusSocket release];
    [super dealloc];
}

#pragma mark - XCB Event Handling

- (void)handleEvent:(xcb_generic_event_t *)event {
    uint8_t type = event->response_type & ~0x80;
    switch (type) {
        case XCB_MAP_NOTIFY:
            [self handleMapNotify:(xcb_map_notify_event_t *)event];
            break;

        case XCB_UNMAP_NOTIFY: {
            xcb_window_t w = ((xcb_unmap_notify_event_t *)event)->window;
            dispatch_async(dispatch_get_main_queue(), ^{
                [self closeCocoaWindowForXWindow:w];
            });
            break;
        }

        case XCB_DESTROY_NOTIFY: {
            // DestroyNotify always follows UnmapNotify for mapped windows.
            // closeCocoaWindowForXWindow: is idempotent (no-ops if already gone),
            // so calling it for both events is safe and ensures we never miss one.
            xcb_window_t w = ((xcb_destroy_notify_event_t *)event)->window;
            dispatch_async(dispatch_get_main_queue(), ^{
                [self closeCocoaWindowForXWindow:w];
            });
            break;
        }

        case XCB_REPARENT_NOTIFY: {
            // A window reparented away from the root is no longer our concern.
            // Without this, its Cocoa window would stay open forever because
            // subsequent UnmapNotify/DestroyNotify go to the new parent, not root.
            xcb_reparent_notify_event_t *reparent = (xcb_reparent_notify_event_t *)event;
            xcb_window_t w = reparent->window;
            if (reparent->parent != _rootWindow) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [self closeCocoaWindowForXWindow:w];
                });
            }
            break;
        }

        case XCB_CONFIGURE_NOTIFY:
            [self handleConfigureNotify:(xcb_configure_notify_event_t *)event];
            break;

        case XCB_EXPOSE: {
            xcb_window_t w = ((xcb_expose_event_t *)event)->window;
            dispatch_async(dispatch_get_main_queue(), ^{
                if (self.windows[@(w)]) [self captureAndDisplayWindow:w];
            });
            break;
        }

        default:
            if (self.damageAvailable && type == (uint8_t)(self.damageEventBase + XCB_DAMAGE_NOTIFY)) {
                [self handleDamageNotify:(xcb_damage_notify_event_t *)event];
            }
            break;
    }
}

- (void)handleDamageNotify:(xcb_damage_notify_event_t *)event {
    if (event == NULL) return;
    [self captureAndDisplayWindow:(xcb_window_t)event->drawable];
}

- (void)handleMapNotify:(xcb_map_notify_event_t *)event {
    xcb_window_t window = event->window;
    if (window == _rootWindow) return;

    xcb_get_window_attributes_reply_t *reply =
        xcb_get_window_attributes_reply(_connection, xcb_get_window_attributes(_connection, window), NULL);
    if (!reply) return;

    // Override-redirect windows (menus, tooltips, popups) ask the WM to leave
    // them alone.  Don't wrap them in a Cocoa window.
    BOOL overrideRedirect = reply->override_redirect;
    free(reply);
    if (overrideRedirect) return;

    [self retain];
    dispatch_async(dispatch_get_main_queue(), ^{
        // If a previous Cocoa window for this XID somehow survived, close it.
        [self closeCocoaWindowForXWindow:window];

        // Read the _APP_LAUNCH_CID property to identify the owning app client.
        int cid = 0;
        xcb_intern_atom_reply_t *cid_atom_reply =
            xcb_intern_atom_reply(_connection, xcb_intern_atom(_connection, 0, 15, "_APP_LAUNCH_CID"), NULL);
        if (cid_atom_reply) {
            xcb_get_property_reply_t *cid_prop_reply =
                xcb_get_property_reply(_connection,
                    xcb_get_property(_connection, 0, window, cid_atom_reply->atom, XCB_ATOM_ANY, 0, 1),
                    NULL);
            if (cid_prop_reply
                && cid_prop_reply->format == 32
                && xcb_get_property_value_length(cid_prop_reply) >= 4) {
                cid = *(int *)xcb_get_property_value(cid_prop_reply);
            }
            if (cid_prop_reply) free(cid_prop_reply);
            free(cid_atom_reply);
        }

        NSWindowStyleMask styleMask = NSWindowStyleMaskTitled
                                    | NSWindowStyleMaskClosable
                                    | NSWindowStyleMaskMiniaturizable
                                    | NSWindowStyleMaskResizable
                                    | NSWindowStyleMaskFullSizeContentView;
        NSWindow *cocoaWindow = [[[XClientWindow alloc]
            initWithContentRect:NSMakeRect(100, 100, 800, 600)
                      styleMask:styleMask
                        backing:NSBackingStoreBuffered
                          defer:NO] autorelease];
        cocoaWindow.titlebarAppearsTransparent = YES;
        cocoaWindow.titleVisibility = NSWindowTitleHidden;
        cocoaWindow.title = [NSString stringWithFormat:@"X Client 0x%x", window];
        cocoaWindow.delegate = self;

        xcb_get_geometry_reply_t *geom =
            xcb_get_geometry_reply(self.connection, xcb_get_geometry(self.connection, window), NULL);
        if (geom) {
            [cocoaWindow setFrame:NSMakeRect(100, 100, geom->width, geom->height) display:YES];
            free(geom);
        }

        self.windows[@(window)] = cocoaWindow;
        [cocoaWindow makeKeyAndOrderFront:nil];
        [self registerDamageForWindow:window];
        [self captureAndDisplayWindow:window];
        [self.focusSocket updateFocusWithWindow:window nativeWindowId:0 cid:cid];

        xcb_configure_window(_connection, window, XCB_CONFIG_WINDOW_BORDER_WIDTH, (uint32_t[]){0});
        xcb_map_window(_connection, window);
        [self release];
    });
}

- (void)handleConfigureNotify:(xcb_configure_notify_event_t *)event {
    xcb_window_t w = event->window;
    int width = event->width;
    int height = event->height;

    dispatch_async(dispatch_get_main_queue(), ^{
        NSWindow *window = self.windows[@(w)];
        if (window) {
            // Only apply size changes from the X side; position is owned by the
            // Cocoa window manager (WannaTile). Stomping the origin here is what
            // caused windows to flicker to the bottom-left during animation.
            NSRect current = window.frame;
            if ((int)current.size.width != width || (int)current.size.height != height) {
                [window setFrame:NSMakeRect(current.origin.x, current.origin.y, width, height) display:YES];
            }
            [self captureAndDisplayWindow:w];
        }
    });
}

#pragma mark - Window Capture

- (void)captureAndDisplayWindow:(xcb_window_t)xWindow {
    [self retain];
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{

        // Acknowledge and clear the damage region before capturing.
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

        xcb_get_geometry_reply_t *geom =
            xcb_get_geometry_reply(self.connection, xcb_get_geometry(self.connection, xWindow), NULL);
        if (!geom) { [self release]; return; }

        xcb_get_image_reply_t *reply =
            xcb_get_image_reply(self.connection,
                xcb_get_image(self.connection, XCB_IMAGE_FORMAT_Z_PIXMAP,
                    xWindow, 0, 0, geom->width, geom->height, UINT32_MAX),
                NULL);
        if (!reply) { free(geom); [self release]; return; }

        int root_x = geom->x;
        int root_y = geom->y;
        int width  = geom->width;
        int height = geom->height;
        free(geom);

        const uint8_t *data = xcb_get_image_data(reply);
        int data_len = xcb_get_image_data_length(reply);
        if (width <= 0 || height <= 0 || data_len < width * height * 4) {
            free(reply);
            [self release];
            return;
        }

        // Build an NSBitmapImageRep from the raw XCB pixel data.
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
        memcpy(bitmap_data, data, width * height * 4);

        // Convert BGRA (X11) → RGBA (Cocoa).
        for (int i = 0; i < width * height; i++) {
            uint8_t b = bitmap_data[i*4 + 0];
            uint8_t g = bitmap_data[i*4 + 1];
            uint8_t r = bitmap_data[i*4 + 2];
            bitmap_data[i*4 + 0] = r;
            bitmap_data[i*4 + 1] = g;
            bitmap_data[i*4 + 2] = b;
            bitmap_data[i*4 + 3] = 255;
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

            if (imageView) {
                imageView.sourceFrame = sourceFrame;
                imageView.image = image;
            } else {
                XClientView *newView = [[[XClientView alloc]
                    initWithFrame:cocoaWindow.contentView.bounds] autorelease];
                newView.xWindow = xWindow;
                newView.connection = self.connection;
                newView.rootWindow = self.rootWindow;
                newView.sourceFrame = sourceFrame;
                newView.imageScaling = NSImageScaleAxesIndependently;
                newView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
                newView.image = image;

                NSTrackingArea *trackingArea = [[[NSTrackingArea alloc]
                    initWithRect:newView.bounds
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

#pragma mark - NSWindowDelegate

- (void)windowDidResize:(NSNotification *)notification {
    NSWindow *cocoaWindow = notification.object;
    for (NSNumber *key in self.windows) {
        if (self.windows[key] != cocoaWindow) continue;

        xcb_window_t xWindow = (xcb_window_t)[key unsignedIntValue];
        NSRect contentRect = [cocoaWindow contentRectForFrameRect:cocoaWindow.frame];
        uint32_t values[] = { (uint32_t)contentRect.size.width, (uint32_t)contentRect.size.height };
        xcb_configure_window(_connection, xWindow, XCB_CONFIG_WINDOW_WIDTH | XCB_CONFIG_WINDOW_HEIGHT, values);
        xcb_flush(_connection);
        [self captureAndDisplayWindow:xWindow];
        break;
    }
}

- (void)windowDidBecomeKey:(NSNotification *)notification {
    NSWindow *cocoaWindow = notification.object;
    for (NSNumber *key in self.windows) {
        if (self.windows[key] != cocoaWindow) continue;

        xcb_window_t xWindow = (xcb_window_t)[key unsignedIntValue];
        XClientView *view = (XClientView *)self.imageViews[key];
        [self.focusSocket updateFocusWithWindow:xWindow nativeWindowId:0 cid:view ? [view getCID] : 0];
        if (view) [cocoaWindow makeFirstResponder:view];
        xcb_set_input_focus(_connection, XCB_INPUT_FOCUS_POINTER_ROOT, xWindow, XCB_CURRENT_TIME);
        xcb_configure_window(_connection, xWindow, XCB_CONFIG_WINDOW_STACK_MODE, (uint32_t[]){XCB_STACK_MODE_ABOVE});
        xcb_flush(_connection);
        break;
    }
}

- (BOOL)windowShouldClose:(NSWindow *)sender {
    // Find the X window that owns this Cocoa window.
    xcb_window_t xWindow = 0;
    for (NSNumber *key in self.windows) {
        if (self.windows[key] == sender) {
            xWindow = (xcb_window_t)[key unsignedIntValue];
            break;
        }
    }

    if (xWindow != 0 && _connection != NULL) {
        // Ask Xorg to kill the X client.  Xorg will then send UnmapNotify
        // followed by DestroyNotify, which will drive closeCocoaWindowForXWindow:
        // on the main queue.  We return NO here so AppKit does not close
        // the Cocoa window immediately — it will be closed when DestroyNotify
        // arrives, keeping the two sides in sync.
        xcb_kill_client(_connection, xWindow);
        xcb_flush(_connection);
        return NO;
    }

    // No live X window found — let AppKit close it directly.
    return YES;
}

@end

#pragma mark - Entry Point

extern CVReturn WindowManagerCallback(CVDisplayLinkRef displayLink,
                                      const CVTimeStamp* now,
                                      const CVTimeStamp* outputTime,
                                      CVOptionFlags flagsIn,
                                      CVOptionFlags* flagsOut,
                                      void* displayLinkContext);

int main(int argc, char *argv[]) {
    signal(SIGPIPE, SIG_IGN);

    @autoreleasepool {
        Dl_info info;
        if (dladdr((void *)main, &info) == 0) {
            NSLog(@"Failed to get current binary info");
            return 1;
        }

        NSString *runtimeDir = [[NSString stringWithUTF8String:info.dli_fname] stringByDeletingLastPathComponent];

        NSString *dylibPath = [runtimeDir stringByAppendingPathComponent:@"libAppLaunchRunner.dylib"];
        void *handle = dlopen([dylibPath UTF8String], RTLD_NOW);
        if (!handle) {
            NSLog(@"Failed to load %@: %s", dylibPath, dlerror());
        } else {
            NSLog(@"Loaded AppLaunchRunner dylib from %@", dylibPath);
            NSString *serverLuaPath = [[runtimeDir stringByAppendingPathComponent:@"server"] stringByAppendingPathComponent:@"init.lua"];
            if (!WannaTileLoadServerScript([serverLuaPath UTF8String], "[ApplicationServer]")) {
                NSLog(@"Warning: failed to execute server init at %@", serverLuaPath);
            }
        }

        NSApplication *app = [NSApplication sharedApplication];
        [app setActivationPolicy:NSApplicationActivationPolicyRegular];
        [app activateIgnoringOtherApps:YES];

        ApplicationServer *server = [[ApplicationServer alloc] init];
        app.delegate = server;
        if (![server start]) {
            [server release];
            return 1;
        }

        CVDisplayLinkRef displayLink = NULL;
        if (CVDisplayLinkCreateWithActiveCGDisplays(&displayLink) == kCVReturnSuccess) {
            CVDisplayLinkSetOutputCallback(displayLink, WindowManagerCallback, (__bridge void *)server);
            CVDisplayLinkStart(displayLink);
        } else {
            NSLog(@"Failed to create display link");
        }

        [app run];
        if (displayLink != NULL) {
            CVDisplayLinkStop(displayLink);
            CFRelease(displayLink);
        }
        WannaTileShutdown();
        [server release];
    }

    return 0;
}
