#import <Cocoa/Cocoa.h>
#include <CoreGraphics/CGAffineTransform.h>
#include <CoreFoundation/CFBase.h>
#include <stdio.h>
#include <stdint.h>
#import <CoreGraphics/CoreGraphics.h>
#import <objc/runtime.h>
#import <xcb/xcb.h>
#import <dispatch/dispatch.h>
#import <AVFoundation/AVFoundation.h>
#import <IOSurface/IOSurface.h>
#import <CoreImage/CoreImage.h>
#import <dlfcn.h>

static xcb_connection_t *x_conn = NULL;
static xcb_screen_t *x_screen = NULL;

int g_space = 0;
int g_connection = 0;

extern int SLSMainConnectionID(void);
extern int SLSSpaceCreate(int cid, int one, int zero);
extern CGError SLSSpaceSetAbsoluteLevel(int cid, int sid, int level);
extern CGError SLSShowSpaces(int cid, CFArrayRef space_list);
extern CGError SLSHideSpaces(int cid, CFArrayRef space_list);
extern CGError SLSSpaceAddWindowsAndRemoveFromSpaces(int cid, int sid, CFArrayRef array, int seven);
extern CGError SLSSpaceSetTransform(int cid, int sid, CGAffineTransform transform);


static CFArrayRef CFNumberArray(void *values, size_t size, int count, CFNumberType type) {
    CFNumberRef temp[count];

    for (int i = 0; i < count; ++i) {
        temp[i] = CFNumberCreate(NULL, type, ((char *)values) + (size * i));
    }

    CFArrayRef result = CFArrayCreate(NULL, (const void **)temp, count, &kCFTypeArrayCallBacks);

    for (int i = 0; i < count; ++i) {
        CFRelease(temp[i]);
    }

    return result;
}


static xcb_connection_t* get_x_connection() {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        for (int i = 0; i < 50; i++) {
            char display[64];
            snprintf(display, sizeof(display), ":%d", i);
            xcb_connection_t *conn = xcb_connect(display, NULL);
            if (conn && !xcb_connection_has_error(conn)) {
                x_conn = conn;
                x_screen = xcb_setup_roots_iterator(xcb_get_setup(x_conn)).data;
                break;
            }
            if (conn) xcb_disconnect(conn);
        }

        g_connection = SLSMainConnectionID();
        if (!g_space) {
            g_space = SLSSpaceCreate(g_connection, 1, 0);
            SLSSpaceSetAbsoluteLevel(g_connection, g_space, 0);

            CFArrayRef space_list = CFNumberArray(&g_space,
                                                  sizeof(uint32_t),
                                                  1,
                                                  kCFNumberSInt32Type);
            SLSShowSpaces(g_connection, space_list);
            SLSSpaceSetTransform(g_connection, g_space, CGAffineTransformMakeTranslation(999999.0, 999999.0)); // get an offscreen render space (what a fucking hack lol)
            CFRelease(space_list);

            NSLog(@"gspace %d", g_space);
        }
    });
    return x_conn;
}

void swizzle(Class c, SEL orig, SEL new) {
    Method origMethod = class_getInstanceMethod(c, orig);
    Method newMethod = class_getInstanceMethod(c, new);
    if (class_addMethod(c, orig, method_getImplementation(newMethod), method_getTypeEncoding(newMethod))) {
        class_replaceMethod(c, new, method_getImplementation(origMethod), method_getTypeEncoding(origMethod));
    } else {
        method_exchangeImplementations(origMethod, newMethod);
    }
}

@interface NSCGSWindow : NSObject
+ (id)windowWithWindowID:(unsigned)windowID;
- (CGImageRef)backingStoreImageInRect:(CGRect)rect;
@end

@interface NSWindow (Headless)
@property (nonatomic, assign) xcb_window_t x11_window;
@property (nonatomic, assign) CGDisplayStreamRef captureStream;
@end

@implementation NSWindow (Headless)

- (xcb_window_t)x11_window {
    NSNumber *val = objc_getAssociatedObject(self, @selector(x11_window));
    return [val unsignedIntValue];
}

- (void)setX11_window:(xcb_window_t)win {
    objc_setAssociatedObject(self, @selector(x11_window), @(win), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

- (CGDisplayStreamRef)captureStream {
    NSValue *val = objc_getAssociatedObject(self, @selector(captureStream));
    return [val pointerValue];
}

- (void)setCaptureStream:(CGDisplayStreamRef)stream {
    objc_setAssociatedObject(self, @selector(captureStream), [NSValue valueWithPointer:stream], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

- (void)create_x11_window_if_needed {
    xcb_connection_t *conn = get_x_connection();
    if (!conn) return;

    if (self.x11_window == 0) {
        xcb_window_t win = xcb_generate_id(conn);
        self.x11_window = win;

        uint32_t wid = (uint32_t)[self windowNumber];
        CFArrayRef window_list = CFNumberArray(&wid,
                                               sizeof(uint32_t),
                                               1,
                                               kCFNumberSInt32Type);

        SLSSpaceAddWindowsAndRemoveFromSpaces(g_connection,
                                              g_space,
                                              window_list,
                                              0x7);

        CFRelease(window_list);

        NSRect frame = [self frame];
        uint32_t mask = XCB_CW_BACK_PIXEL | XCB_CW_EVENT_MASK;
        uint32_t values[2] = { x_screen->white_pixel, XCB_EVENT_MASK_EXPOSURE | XCB_EVENT_MASK_KEY_PRESS | XCB_EVENT_MASK_STRUCTURE_NOTIFY };

        xcb_create_window(conn,
                          XCB_COPY_FROM_PARENT,
                          win,
                          x_screen->root,
                          (int16_t)frame.origin.x, (int16_t)frame.origin.y,
                          (uint16_t)(frame.size.width > 0 ? frame.size.width : 1),
                          (uint16_t)(frame.size.height > 0 ? frame.size.height : 1),
                          0,
                          XCB_WINDOW_CLASS_INPUT_OUTPUT,
                          x_screen->root_visual,
                          mask, values);

        xcb_intern_atom_cookie_t cookie = xcb_intern_atom(conn, 0, 18, "_APP_LAUNCH_APPKIT");
        xcb_intern_atom_reply_t *reply = xcb_intern_atom_reply(conn, cookie, NULL);
        if (reply) {
            uint32_t prop_val = 1;
            xcb_change_property(conn, XCB_PROP_MODE_REPLACE, win, reply->atom, XCB_ATOM_INTEGER, 32, 1, &prop_val);
            free(reply);
        }

        if (wid > 0) {
            NSDictionary *dsprops = @{
                @"AllowNonIntersectingWindows" : @(YES),
                @"ExcludeCursorWindow" : @(YES)
            };

            __weak typeof(self) weakSelf = self;
            CGDisplayStreamRef (*streamCreate)(uint32_t, uint32_t, CFDictionaryRef, dispatch_queue_t, CGDisplayStreamFrameAvailableHandler) = dlsym(RTLD_DEFAULT, "SLSHWCaptureStreamCreateWithWindow");

            if (streamCreate) {
                CGDisplayStreamRef stream = streamCreate(wid, 0x8000 | 0x40000, (__bridge CFDictionaryRef)dsprops, dispatch_get_main_queue(),
                    ^(CGDisplayStreamFrameStatus status, uint64_t displayTime, IOSurfaceRef _Nullable frameSurface, CGDisplayStreamUpdateRef _Nullable updateRef) {
                    if (status == 0 && frameSurface) {
                        [weakSelf push_iosurface_to_x11:frameSurface];
                    }
                });

                if (stream) {
                    self.captureStream = stream;
                    void (*streamStart)(CGDisplayStreamRef) = dlsym(RTLD_DEFAULT, "CGDisplayStreamStart");
                    if (streamStart) streamStart(stream);
                }
            }
        }
    }
}

- (void)push_iosurface_to_x11:(IOSurfaceRef)surface {
    if (!self.x11_window) return;
    xcb_connection_t *conn = get_x_connection();
    if (!conn) return;

    static CIContext *ciContext = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        ciContext = [CIContext contextWithOptions:nil];
    });

    CIImage *ciImage = [[CIImage alloc] initWithIOSurface:surface];
    if (!ciImage) return;

    CGImageRef cgImage = [ciContext createCGImage:ciImage fromRect:[ciImage extent]];
    if (!cgImage) return;

    size_t width = CGImageGetWidth(cgImage);
    size_t height = CGImageGetHeight(cgImage);

    if (width == 0 || height == 0) {
        CGImageRelease(cgImage);
        return;
    }

    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    size_t bytesPerPixel = 4;
    size_t bytesPerRow = bytesPerPixel * width;
    uint8_t *rawData = (uint8_t *)malloc(height * bytesPerRow);

    CGContextRef context = CGBitmapContextCreate(rawData, width, height, 8, bytesPerRow, colorSpace, kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Host);
    CGColorSpaceRelease(colorSpace);

    if (context) {
        CGContextSetBlendMode(context, kCGBlendModeCopy);
        CGContextDrawImage(context, CGRectMake(0, 0, width, height), cgImage);
        CGContextRelease(context);

        xcb_gcontext_t gc = xcb_generate_id(conn);
        xcb_create_gc(conn, gc, self.x11_window, 0, NULL);

        int rows_per_chunk = 64;
        for (int y = 0; y < (int)height; y += rows_per_chunk) {
            int lines = MIN(rows_per_chunk, (int)height - y);
            xcb_put_image(conn, XCB_IMAGE_FORMAT_Z_PIXMAP, self.x11_window, gc, (uint16_t)width, (uint16_t)lines, 0, (int16_t)y, 0, 24, (uint32_t)(lines * bytesPerRow), rawData + (y * bytesPerRow));
        }

        xcb_free_gc(conn, gc);
        xcb_flush(conn);
    }
    free(rawData);
    CGImageRelease(cgImage);
}

- (void)headless__reallyDoOrderWindow:(id)a0 {
    [self headless__reallyDoOrderWindow:a0];
}

- (void)headless__doOrderWindow:(id)a0 {
    [self headless__doOrderWindow:a0];
}

- (void)headless_orderWindow:(NSInteger)place relativeTo:(NSInteger)otherWin {
    [self headless_orderWindow:place relativeTo:otherWin];
    [self create_x11_window_if_needed];
    if (self.x11_window) {
        if (place == 0) xcb_unmap_window(get_x_connection(), self.x11_window);
        else xcb_map_window(get_x_connection(), self.x11_window);
        xcb_flush(get_x_connection());
    }
}

- (void)headless_makeKeyAndOrderFront:(id)sender {
    [self headless_makeKeyAndOrderFront:sender];
    [self create_x11_window_if_needed];
    if (self.x11_window) {
        xcb_map_window(get_x_connection(), self.x11_window);
        xcb_flush(get_x_connection());
    }
}

- (void)headless_orderFront:(id)sender {
    [self headless_orderFront:sender];
    [self create_x11_window_if_needed];
    if (self.x11_window) {
        xcb_map_window(get_x_connection(), self.x11_window);
        xcb_flush(get_x_connection());
    }
}

- (BOOL)headless__isActiveAndOnScreen:(id)a0 { return YES; }

- (void)headless_setFrame:(NSRect)frameRect display:(BOOL)flag {
    [self headless_setFrame:frameRect display:flag];
    if (self.x11_window) {
        uint32_t values[] = { (uint32_t)frameRect.origin.x, (uint32_t)frameRect.origin.y, (uint32_t)MAX(1, frameRect.size.width), (uint32_t)MAX(1, frameRect.size.height) };
        xcb_configure_window(get_x_connection(), self.x11_window, XCB_CONFIG_WINDOW_X | XCB_CONFIG_WINDOW_Y | XCB_CONFIG_WINDOW_WIDTH | XCB_CONFIG_WINDOW_HEIGHT, values);
        xcb_flush(get_x_connection());
    }
}

- (void)headless_close {
    if (self.x11_window) {
        xcb_destroy_window(get_x_connection(), self.x11_window);
        xcb_flush(get_x_connection());
        self.x11_window = 0;
    }
    if (self.captureStream) {
        void (*streamStop)(CGDisplayStreamRef) = dlsym(RTLD_DEFAULT, "CGDisplayStreamStop");
        if (streamStop) streamStop(self.captureStream);
        CFRelease(self.captureStream);
        self.captureStream = NULL;
    }
    [self headless_close];
}

- (void)headless_displayIfNeeded { [self headless_displayIfNeeded]; }
- (void)headless_setNeedsDisplay:(BOOL)flag { [self headless_setNeedsDisplay:flag]; }
- (void)headless_display { [self headless_display]; }
- (void)headless_flushWindow { [self headless_flushWindow]; }

@end

__attribute__((constructor))
static void initializer(void) {
    Class c = NSClassFromString(@"NSWindow");
    swizzle(c, NSSelectorFromString(@"_reallyDoOrderWindow:"), @selector(headless__reallyDoOrderWindow:));
    swizzle(c, NSSelectorFromString(@"_doOrderWindow:"), @selector(headless__doOrderWindow:));
    swizzle(c, @selector(orderWindow:relativeTo:), @selector(headless_orderWindow:relativeTo:));
    swizzle(c, @selector(makeKeyAndOrderFront:), @selector(headless_makeKeyAndOrderFront:));
    swizzle(c, @selector(orderFront:), @selector(headless_orderFront:));
    swizzle(c, NSSelectorFromString(@"_isActiveAndOnScreen:"), @selector(headless__isActiveAndOnScreen:));
    swizzle(c, @selector(setFrame:display:), @selector(headless_setFrame:display:));
    swizzle(c, @selector(close), @selector(headless_close));
    swizzle(c, @selector(flushWindow), @selector(headless_flushWindow));
    swizzle(c, @selector(displayIfNeeded), @selector(headless_displayIfNeeded));
    swizzle(c, @selector(display), @selector(headless_display));
    swizzle(c, @selector(setViewsNeedDisplay:), @selector(headless_setNeedsDisplay:));
}
