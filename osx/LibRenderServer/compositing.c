#define _POSIX_C_SOURCE 200809L

#include "compositing.h"
#include "lua_config.h"

#include <CoreFoundation/CoreFoundation.h>
#include <CoreGraphics/CoreGraphics.h>
#include <ImageIO/ImageIO.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <xcb/composite.h>

typedef struct {
    int16_t  x;
    int16_t  y;
    uint16_t w;
    uint16_t h;
} RenderServerWindowRect;

typedef struct {
    uint32_t background_color;
    CGImageRef background_image;
} RenderServerBackdrop;

typedef struct {
    bool     enabled;
    int16_t  x_offset;
    int16_t  y_offset;
    uint16_t spread;
    uint8_t  opacity;
    uint32_t color;
} RenderServerShadow;

struct RenderServerCompositor {
    RenderServerBackdrop backdrop;
    RenderServerShadow shadow;
};

static void render_server_blend_pixel(uint8_t *pixel,
                                      uint8_t blue,
                                      uint8_t green,
                                      uint8_t red,
                                      uint8_t alpha)
{
    if (alpha == 0) {
        return;
    }

    uint32_t inverse = 255u - (uint32_t)alpha;
    pixel[0] = (uint8_t)(((uint32_t)blue  * alpha + (uint32_t)pixel[0] * inverse) / 255u);
    pixel[1] = (uint8_t)(((uint32_t)green * alpha + (uint32_t)pixel[1] * inverse) / 255u);
    pixel[2] = (uint8_t)(((uint32_t)red   * alpha + (uint32_t)pixel[2] * inverse) / 255u);
    pixel[3] = 0xFF;
}

static void render_server_apply_shadow_pass(uint8_t *destination,
                                            size_t destination_stride,
                                            uint32_t buffer_width,
                                            uint32_t buffer_height,
                                            int32_t rect_x,
                                            int32_t rect_y,
                                            uint16_t rect_w,
                                            uint16_t rect_h,
                                            uint16_t spread,
                                            uint8_t opacity,
                                            uint32_t shadow_color)
{
    if (destination == NULL || rect_w == 0 || rect_h == 0 || spread == 0 || opacity == 0) {
        return;
    }

    int32_t x0 = rect_x - (int32_t)spread;
    int32_t y0 = rect_y - (int32_t)spread;
    int32_t x1 = rect_x + (int32_t)rect_w + (int32_t)spread;
    int32_t y1 = rect_y + (int32_t)rect_h + (int32_t)spread;

    if (x0 < 0) x0 = 0;
    if (y0 < 0) y0 = 0;
    if (x1 > (int32_t)buffer_width) x1 = (int32_t)buffer_width;
    if (y1 > (int32_t)buffer_height) y1 = (int32_t)buffer_height;

    const int32_t inner_left = rect_x;
    const int32_t inner_top = rect_y;
    const int32_t inner_right = rect_x + (int32_t)rect_w;
    const int32_t inner_bottom = rect_y + (int32_t)rect_h;

    const uint8_t color_alpha = (uint8_t)((shadow_color >> 24) & 0xFFu);
    const uint8_t shadow_red = (uint8_t)((shadow_color >> 16) & 0xFFu);
    const uint8_t shadow_green = (uint8_t)((shadow_color >> 8) & 0xFFu);
    const uint8_t shadow_blue = (uint8_t)(shadow_color & 0xFFu);
    const uint32_t max_alpha = ((uint32_t)opacity * (uint32_t)color_alpha) / 255u;
    if (max_alpha == 0) {
        return;
    }

    for (int32_t y = y0; y < y1; ++y) {
        uint8_t *row = destination + ((size_t)y * destination_stride);

        for (int32_t x = x0; x < x1; ++x) {
            if (x >= inner_left && x < inner_right &&
                y >= inner_top && y < inner_bottom) {
                continue;
            }

            int32_t dx = 0;
            if (x < inner_left) {
                dx = inner_left - x;
            } else if (x >= inner_right) {
                dx = x - (inner_right - 1);
            }

            int32_t dy = 0;
            if (y < inner_top) {
                dy = inner_top - y;
            } else if (y >= inner_bottom) {
                dy = y - (inner_bottom - 1);
            }

            double distance = sqrt((double)(dx * dx + dy * dy));
            if (distance >= (double)spread) {
                continue;
            }

            double falloff = 1.0 - (distance / (double)spread);
            uint8_t alpha = (uint8_t)((double)max_alpha * falloff * falloff);
            if (alpha == 0) {
                continue;
            }

            render_server_blend_pixel(row + ((size_t)x * 4u),
                                      shadow_blue,
                                      shadow_green,
                                      shadow_red,
                                      alpha);
        }
    }
}

static void render_server_apply_window_shadow(uint8_t *destination,
                                             size_t destination_stride,
                                             uint32_t buffer_width,
                                             uint32_t buffer_height,
                                             const RenderServerShadow *shadow,
                                             int32_t x,
                                             int32_t y,
                                             uint16_t w,
                                             uint16_t h)
{
    if (shadow == NULL || !shadow->enabled) {
        return;
    }

    render_server_apply_shadow_pass(destination,
                                    destination_stride,
                                    buffer_width,
                                    buffer_height,
                                    x + shadow->x_offset,
                                    y + shadow->y_offset,
                                    w,
                                    h,
                                    shadow->spread,
                                    shadow->opacity,
                                    shadow->color);
}

static void render_server_unpack_argb(uint32_t argb,
                                      CGFloat *alpha,
                                      CGFloat *red,
                                      CGFloat *green,
                                      CGFloat *blue)
{
    if (alpha != NULL) {
        *alpha = (CGFloat)((argb >> 24) & 0xFFu) / 255.0;
    }
    if (red != NULL) {
        *red = (CGFloat)((argb >> 16) & 0xFFu) / 255.0;
    }
    if (green != NULL) {
        *green = (CGFloat)((argb >> 8) & 0xFFu) / 255.0;
    }
    if (blue != NULL) {
        *blue = (CGFloat)(argb & 0xFFu) / 255.0;
    }
}

static CGImageRef render_server_load_image_from_path(const char *path)
{
    if (path == NULL || *path == '\0') {
        return NULL;
    }

    CFStringRef path_string = CFStringCreateWithCString(kCFAllocatorDefault, path, kCFStringEncodingUTF8);
    if (path_string == NULL) {
        return NULL;
    }

    CFURLRef url = CFURLCreateWithFileSystemPath(kCFAllocatorDefault,
                                                 path_string,
                                                 kCFURLPOSIXPathStyle,
                                                 false);
    CFRelease(path_string);
    if (url == NULL) {
        return NULL;
    }

    CGImageSourceRef source = CGImageSourceCreateWithURL(url, NULL);
    CFRelease(url);
    if (source == NULL) {
        return NULL;
    }

    CGImageRef image = CGImageSourceCreateImageAtIndex(source, 0, NULL);
    CFRelease(source);
    return image;
}

static void render_server_set_default_shadow(RenderServerShadow *shadow)
{
    if (shadow == NULL) {
        return;
    }

    shadow->enabled = true;
    shadow->x_offset = 0;
    shadow->y_offset = 0;
    shadow->spread = 28;
    shadow->opacity = 52;
    shadow->color = 0xFF0E0F11u;
}

static bool render_server_load_compositor_config(const char *config_path,
                                                 RenderServerCompositor *compositor)
{
    if (compositor == NULL) {
        return false;
    }

    compositor->backdrop.background_color = 0xFFFFFFFFu;
    compositor->backdrop.background_image = NULL;
    render_server_set_default_shadow(&compositor->shadow);

    ApplicatorLuaConfig config;
    applicator_lua_config_init(&config);
    if (!applicator_lua_config_load_file(config_path, &config, "[RenderServer]")) {
        return true;
    }

    if (config.has_background_color) {
        compositor->backdrop.background_color = config.background_color;
    }
    if (config.has_shadow_enabled) {
        compositor->shadow.enabled = config.shadow_enabled;
    }
    if (config.has_shadow_x_offset) {
        compositor->shadow.x_offset = config.shadow_x_offset;
    }
    if (config.has_shadow_y_offset) {
        compositor->shadow.y_offset = config.shadow_y_offset;
    }
    if (config.has_shadow_spread) {
        compositor->shadow.spread = config.shadow_spread;
    }
    if (config.has_shadow_opacity) {
        compositor->shadow.opacity = config.shadow_opacity;
    }
    if (config.has_shadow_color) {
        compositor->shadow.color = config.shadow_color;
    }

    if (config.has_background_image && config.background_image[0] != '\0') {
        compositor->backdrop.background_image = render_server_load_image_from_path(config.background_image);
        if (compositor->backdrop.background_image == NULL) {
            fprintf(stderr, "[RenderServer] warning: could not load background image %s\n",
                    config.background_image);
        }
    }

    return true;
}

static void render_server_release_backdrop(RenderServerBackdrop *backdrop)
{
    if (backdrop == NULL) {
        return;
    }

    if (backdrop->background_image != NULL) {
        CGImageRelease(backdrop->background_image);
        backdrop->background_image = NULL;
    }
}

RenderServerCompositor *render_server_compositor_create(const char *config_path)
{
    RenderServerCompositor *compositor = calloc(1, sizeof(*compositor));
    if (compositor == NULL) {
        return NULL;
    }

    if (!render_server_load_compositor_config(config_path, compositor)) {
        render_server_release_backdrop(&compositor->backdrop);
        free(compositor);
        return NULL;
    }

    return compositor;
}

void render_server_compositor_destroy(RenderServerCompositor *compositor)
{
    if (compositor == NULL) {
        return;
    }

    render_server_release_backdrop(&compositor->backdrop);
    free(compositor);
}

static CGContextRef render_server_create_bitmap_context(uint8_t *destination,
                                                        size_t destination_stride,
                                                        uint32_t width,
                                                        uint32_t height)
{
    if (destination == NULL || width == 0 || height == 0 || destination_stride < ((size_t)width * 4u)) {
        return NULL;
    }

    CGColorSpaceRef color_space = CGColorSpaceCreateDeviceRGB();
    if (color_space == NULL) {
        return NULL;
    }

    CGContextRef ctx = CGBitmapContextCreate(destination,
                                             width,
                                             height,
                                             8,
                                             destination_stride,
                                             color_space,
                                             kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
    CGColorSpaceRelease(color_space);
    if (ctx == NULL) {
        return NULL;
    }

    CGContextTranslateCTM(ctx, 0.0, (CGFloat)height);
    CGContextScaleCTM(ctx, 1.0, -1.0);
    return ctx;
}

static void render_server_draw_backdrop(CGContextRef ctx,
                                        const RenderServerBackdrop *backdrop,
                                        uint32_t width,
                                        uint32_t height)
{
    if (ctx == NULL || width == 0 || height == 0) {
        return;
    }

    CGFloat alpha = 1.0;
    CGFloat red = 1.0;
    CGFloat green = 1.0;
    CGFloat blue = 1.0;
    uint32_t background_color = 0xFFFFFFFFu;
    if (backdrop != NULL) {
        background_color = backdrop->background_color;
    }
    render_server_unpack_argb(background_color, &alpha, &red, &green, &blue);

    CGContextSetRGBFillColor(ctx, red, green, blue, alpha);
    CGContextFillRect(ctx, CGRectMake(0.0, 0.0, (CGFloat)width, (CGFloat)height));

    if (backdrop != NULL && backdrop->background_image != NULL) {
        CGContextSetInterpolationQuality(ctx, kCGInterpolationHigh);
        /* Draw the backdrop image with the same layer flip used for window pixmaps. */
        CGContextSaveGState(ctx);
        CGContextTranslateCTM(ctx, 0.0, (CGFloat)height);
        CGContextScaleCTM(ctx, 1.0, -1.0);
        CGContextDrawImage(ctx,
                           CGRectMake(0.0, 0.0, (CGFloat)width, (CGFloat)height),
                           backdrop->background_image);
        CGContextRestoreGState(ctx);
    }
}

static bool render_server_draw_surface_background(uint8_t *destination,
                                                  size_t destination_stride,
                                                  uint32_t width,
                                                  uint32_t height,
                                                  const RenderServerBackdrop *backdrop)
{
    CGContextRef ctx = render_server_create_bitmap_context(destination,
                                                           destination_stride,
                                                           width,
                                                           height);
    if (ctx == NULL) {
        return false;
    }

    render_server_draw_backdrop(ctx, backdrop, width, height);
    CGContextRelease(ctx);
    return true;
}

static CGImageRef render_server_create_window_image(const uint8_t *source,
                                                    size_t source_length,
                                                    uint16_t width,
                                                    uint16_t height)
{
    if (source == NULL || width == 0 || height == 0) {
        return NULL;
    }

    size_t source_stride = (size_t)width * 4u;
    size_t required_bytes = source_stride * (size_t)height;
    if (source_length < required_bytes) {
        return NULL;
    }

    CGColorSpaceRef color_space = CGColorSpaceCreateDeviceRGB();
    if (color_space == NULL) {
        return NULL;
    }

    CGDataProviderRef provider = CGDataProviderCreateWithData(NULL, source, required_bytes, NULL);
    if (provider == NULL) {
        CGColorSpaceRelease(color_space);
        return NULL;
    }

    CGImageRef image = CGImageCreate(width,
                                     height,
                                     8,
                                     32,
                                     source_stride,
                                     color_space,
                                     kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder32Little,
                                     provider,
                                     NULL,
                                     false,
                                     kCGRenderingIntentDefault);
    CGDataProviderRelease(provider);
    CGColorSpaceRelease(color_space);
    return image;
}

int render_server_prepare_initial_frame(RenderState *state,
                                        const RenderServerCompositor *compositor)
{
    ScreenprocBuffers buffers;
    memset(&buffers, 0, sizeof(buffers));
    screenproc_get_buffers(state, &buffers);

    if (buffers.buffer0 == NULL || buffers.buffer1 == NULL || buffers.width == 0 || buffers.height == 0) {
        fprintf(stderr, "[RenderServer] framebuffer buffers are unavailable\n");
        return 1;
    }

    if ((size_t)buffers.stride < ((size_t)buffers.width * 4)) {
        fprintf(stderr, "[RenderServer] framebuffer stride is too small\n");
        return 1;
    }

    if (!render_server_draw_surface_background((uint8_t *)buffers.buffer0,
                                               buffers.stride,
                                               buffers.width,
                                               buffers.height,
                                               compositor != NULL ? &compositor->backdrop : NULL)) {
        fprintf(stderr, "[RenderServer] failed to draw the initial background\n");
        return 1;
    }

    if (!render_server_draw_surface_background((uint8_t *)buffers.buffer1,
                                               buffers.stride,
                                               buffers.width,
                                               buffers.height,
                                               compositor != NULL ? &compositor->backdrop : NULL)) {
        fprintf(stderr, "[RenderServer] failed to draw the initial background\n");
        return 1;
    }
    screenproc_render_frame(state);
    return 0;
}

int render_server_enable_composite(xcb_connection_t *connection,
                                   xcb_screen_t *screen,
                                   const char *display_name,
                                   bool *composite_enabled_out)
{
    if (composite_enabled_out != NULL) {
        *composite_enabled_out = false;
    }

    xcb_composite_query_version_cookie_t version_cookie =
        xcb_composite_query_version(connection, XCB_COMPOSITE_MAJOR_VERSION, XCB_COMPOSITE_MINOR_VERSION);
    xcb_composite_query_version_reply_t *version_reply =
        xcb_composite_query_version_reply(connection, version_cookie, NULL);
    if (version_reply == NULL) {
        fprintf(stderr, "[RenderServer] XComposite is unavailable on %s\n",
                display_name != NULL ? display_name : "(unknown)");
        return 1;
    }

    free(version_reply);

    xcb_void_cookie_t redirect_cookie =
        xcb_composite_redirect_subwindows_checked(connection,
                                                  screen->root,
                                                  XCB_COMPOSITE_REDIRECT_MANUAL);
    xcb_generic_error_t *error = xcb_request_check(connection, redirect_cookie);
    if (error != NULL) {
        fprintf(stderr,
                "[RenderServer] failed to redirect root subwindows with XComposite on %s (error %u)\n",
                display_name != NULL ? display_name : "(unknown)",
                error->error_code);
        free(error);
        return 1;
    }

    if (composite_enabled_out != NULL) {
        *composite_enabled_out = true;
    }

    xcb_flush(connection);
    return 0;
}

static bool render_server_compose_window(xcb_connection_t *connection,
                                         xcb_window_t window,
                                         const RenderServerCompositor *compositor,
                                         CGContextRef ctx,
                                         uint8_t *destination,
                                         size_t destination_stride,
                                         uint32_t buffer_width,
                                         uint32_t buffer_height)
{
    xcb_get_window_attributes_cookie_t attributes_cookie =
        xcb_get_window_attributes(connection, window);
    xcb_get_window_attributes_reply_t *attributes =
        xcb_get_window_attributes_reply(connection, attributes_cookie, NULL);
    if (attributes == NULL) {
        return false;
    }

    bool viewable = attributes->map_state == XCB_MAP_STATE_VIEWABLE;
    bool override_redirect = attributes->override_redirect;
    free(attributes);
    if (!viewable) {
        return true;
    }

    xcb_get_geometry_cookie_t geometry_cookie = xcb_get_geometry(connection, window);
    xcb_get_geometry_reply_t *geometry = xcb_get_geometry_reply(connection, geometry_cookie, NULL);
    if (geometry == NULL) {
        return false;
    }

    RenderServerWindowRect rect = {
        .x = geometry->x,
        .y = geometry->y,
        .w = geometry->width,
        .h = geometry->height,
    };
    free(geometry);

    if (!override_redirect && rect.w >= 32 && rect.h >= 24) {
        render_server_apply_window_shadow(destination,
                                          destination_stride,
                                          buffer_width,
                                          buffer_height,
                                          compositor != NULL ? &compositor->shadow : NULL,
                                          rect.x,
                                          rect.y,
                                          rect.w,
                                          rect.h);
    }

    xcb_pixmap_t pixmap = xcb_generate_id(connection);
    xcb_composite_name_window_pixmap(connection, window, pixmap);

    xcb_get_image_cookie_t image_cookie = xcb_get_image(connection,
                                                        XCB_IMAGE_FORMAT_Z_PIXMAP,
                                                        pixmap,
                                                        0,
                                                        0,
                                                        rect.w,
                                                        rect.h,
                                                        UINT32_MAX);
    xcb_get_image_reply_t *image_reply = xcb_get_image_reply(connection, image_cookie, NULL);
    xcb_free_pixmap(connection, pixmap);
    if (image_reply == NULL) {
        return false;
    }

    const uint8_t *source = xcb_get_image_data(image_reply);
    int source_length = xcb_get_image_data_length(image_reply);
    bool ok = true;
    if (source == NULL || source_length < 0) {
        ok = false;
    } else {
        CGImageRef image = render_server_create_window_image(source,
                                                             (size_t)source_length,
                                                             rect.w,
                                                             rect.h);
        if (image == NULL) {
            ok = false;
        } else {
            /* X11 window pixmaps arrive in the opposite vertical orientation from
             * the IOSurface-backed bitmap context, so flip the image layer only. */
            CGContextSaveGState(ctx);
            CGContextTranslateCTM(ctx, (CGFloat)rect.x, (CGFloat)rect.y + (CGFloat)rect.h);
            CGContextScaleCTM(ctx, 1.0, -1.0);
            CGContextDrawImage(ctx,
                               CGRectMake(0.0, 0.0, (CGFloat)rect.w, (CGFloat)rect.h),
                               image);
            CGContextRestoreGState(ctx);
            CGImageRelease(image);
        }
    }

    free(image_reply);
    return ok;
}

int render_server_compose_frame(RenderState *state,
                                xcb_connection_t *connection,
                                xcb_screen_t *screen,
                                const RenderServerCompositor *compositor,
                                bool composite_enabled,
                                uint16_t width,
                                uint16_t height)
{
    if (state == NULL || connection == NULL || screen == NULL) {
        return 1;
    }

    IOSurfaceRef back_surface = state->surfaces[state->backIdx];
    if (back_surface == NULL) {
        fprintf(stderr, "[RenderServer] back IOSurface is unavailable\n");
        return 1;
    }

    IOSurfaceLock(back_surface, 0, NULL);
    uint8_t *destination = (uint8_t *)IOSurfaceGetBaseAddress(back_surface);
    size_t destination_stride = IOSurfaceGetBytesPerRow(back_surface);

    if (destination == NULL || destination_stride < ((size_t)width * 4u)) {
        IOSurfaceUnlock(back_surface, 0, NULL);
        fprintf(stderr, "[RenderServer] back IOSurface layout is invalid\n");
        return 1;
    }

    CGContextRef ctx = render_server_create_bitmap_context(destination,
                                                           destination_stride,
                                                           width,
                                                           height);
    if (ctx == NULL) {
        IOSurfaceUnlock(back_surface, 0, NULL);
        fprintf(stderr, "[RenderServer] failed to create a CoreGraphics bitmap context\n");
        return 1;
    }

    render_server_draw_backdrop(ctx,
                                compositor != NULL ? &compositor->backdrop : NULL,
                                width,
                                height);

    if (composite_enabled) {
        xcb_query_tree_cookie_t tree_cookie = xcb_query_tree(connection, screen->root);
        xcb_query_tree_reply_t *tree_reply = xcb_query_tree_reply(connection, tree_cookie, NULL);
        if (tree_reply != NULL) {
            xcb_window_t *children = xcb_query_tree_children(tree_reply);
            int child_count = xcb_query_tree_children_length(tree_reply);

            for (int i = 0; i < child_count; ++i) {
                (void)render_server_compose_window(connection,
                                                   children[i],
                                                   compositor,
                                                   ctx,
                                                   destination,
                                                   destination_stride,
                                                   width,
                                                   height);
            }

            free(tree_reply);
        }
    }

    CGContextRelease(ctx);
    IOSurfaceUnlock(back_surface, 0, NULL);

    screenproc_render_frame(state);
    return 0;
}
