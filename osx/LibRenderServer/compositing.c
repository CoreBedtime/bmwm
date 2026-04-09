#define _POSIX_C_SOURCE 200809L

#include "compositing.h"
#include "lua_config.h"

#include <CoreFoundation/CoreFoundation.h>
#include <CoreGraphics/CoreGraphics.h>
#include <ImageIO/ImageIO.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <xcb/composite.h>

typedef struct {
    int32_t  x;
    int32_t  y;
    uint16_t w;
    uint16_t h;
} RenderServerWindowRect;

typedef struct {
    uint32_t background_color;
    CGImageRef background_image;
    uint8_t *cached_pixels;
    size_t cached_size;
    uint32_t cached_width;
    uint32_t cached_height;
} RenderServerBackdrop;

typedef struct {
    bool     enabled;
    int16_t  x_offset;
    int16_t  y_offset;
    uint16_t spread;
    uint8_t  opacity;
    uint32_t color;
    CGColorRef cg_color;
} RenderServerShadow;

typedef struct {
    int32_t  x;
    int32_t  y;
    uint16_t w;
    uint16_t h;
    xcb_window_t window;
    RenderServerWindowRect rect;
    bool viewable;
    bool override_redirect;
    bool image_requested;
    xcb_get_window_attributes_cookie_t attributes_cookie;
    xcb_get_geometry_cookie_t geometry_cookie;
    xcb_pixmap_t pixmap;
    xcb_get_image_cookie_t image_cookie;
} RenderServerWindowSnapshot;

struct RenderServerCompositor {
    RenderServerBackdrop backdrop;
    RenderServerShadow shadow;
};

static void render_server_release_shadow(RenderServerShadow *shadow)
{
    if (shadow == NULL) {
        return;
    }

    if (shadow->cg_color != NULL) {
        CGColorRelease(shadow->cg_color);
        shadow->cg_color = NULL;
    }
}

static bool render_server_prepare_shadow_color(RenderServerShadow *shadow)
{
    if (shadow == NULL) {
        return false;
    }

    render_server_release_shadow(shadow);
    CGFloat components[4] = {
        (CGFloat)((shadow->color >> 16) & 0xFFu) / 255.0,
        (CGFloat)((shadow->color >> 8) & 0xFFu) / 255.0,
        (CGFloat)(shadow->color & 0xFFu) / 255.0,
        (CGFloat)((shadow->color >> 24) & 0xFFu) / 255.0,
    };

    CGColorSpaceRef color_space = CGColorSpaceCreateDeviceRGB();
    if (color_space == NULL) {
        return false;
    }

    shadow->cg_color = CGColorCreate(color_space, components);
    CGColorSpaceRelease(color_space);
    return shadow->cg_color != NULL;
}

static bool render_server_rect_intersects_bounds(const RenderServerWindowRect *rect,
                                                 uint32_t buffer_width,
                                                 uint32_t buffer_height)
{
    if (rect == NULL || rect->w == 0 || rect->h == 0) {
        return false;
    }

    int32_t left = rect->x;
    int32_t top = rect->y;
    int32_t right = rect->x + (int32_t)rect->w;
    int32_t bottom = rect->y + (int32_t)rect->h;

    if (left < 0) {
        left = 0;
    }
    if (top < 0) {
        top = 0;
    }
    if (right > (int32_t)buffer_width) {
        right = (int32_t)buffer_width;
    }
    if (bottom > (int32_t)buffer_height) {
        bottom = (int32_t)buffer_height;
    }

    return right > left && bottom > top;
}

static void render_server_apply_window_shadow(CGContextRef ctx,
                                              const RenderServerShadow *shadow,
                                              int32_t x,
                                              int32_t y,
                                              uint16_t w,
                                              uint16_t h)
{
    if (ctx == NULL || shadow == NULL || !shadow->enabled || shadow->cg_color == NULL ||
        w == 0 || h == 0) {
        return;
    }

    CGContextSaveGState(ctx);
    CGContextSetShadowWithColor(ctx,
                                CGSizeMake((CGFloat)shadow->x_offset, (CGFloat)shadow->y_offset),
                                (CGFloat)shadow->spread,
                                shadow->cg_color);
    CGContextSetFillColorWithColor(ctx, shadow->cg_color);
    CGContextFillRect(ctx, CGRectMake((CGFloat)x, (CGFloat)y, (CGFloat)w, (CGFloat)h));
    CGContextRestoreGState(ctx);
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
    if (applicator_lua_config_load_file(config_path, &config, "[RenderServer]")) {
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
    }

    if (!render_server_prepare_shadow_color(&compositor->shadow)) {
        fprintf(stderr, "[RenderServer] warning: could not prepare the shadow color\n");
    }

    return true;
}

static void render_server_release_backdrop(RenderServerBackdrop *backdrop)
{
    if (backdrop == NULL) {
        return;
    }

    if (backdrop->cached_pixels != NULL) {
        free(backdrop->cached_pixels);
        backdrop->cached_pixels = NULL;
    }
    backdrop->cached_size = 0;
    backdrop->cached_width = 0;
    backdrop->cached_height = 0;

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
    render_server_release_shadow(&compositor->shadow);
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
                                        uint32_t height);

static bool render_server_prepare_backdrop_cache(RenderServerBackdrop *backdrop,
                                                 uint32_t width,
                                                 uint32_t height)
{
    if (backdrop == NULL || width == 0 || height == 0) {
        return false;
    }

    size_t row_bytes = (size_t)width * 4u;
    if (row_bytes / 4u != (size_t)width) {
        return false;
    }

    size_t cache_size = row_bytes * (size_t)height;
    if (height != 0 && cache_size / (size_t)height != row_bytes) {
        return false;
    }

    if (backdrop->cached_pixels != NULL &&
        backdrop->cached_width == width &&
        backdrop->cached_height == height &&
        backdrop->cached_size == cache_size) {
        return true;
    }

    free(backdrop->cached_pixels);
    backdrop->cached_pixels = NULL;
    backdrop->cached_size = 0;
    backdrop->cached_width = 0;
    backdrop->cached_height = 0;

    uint8_t *pixels = malloc(cache_size);
    if (pixels == NULL) {
        return false;
    }

    CGContextRef ctx = render_server_create_bitmap_context(pixels,
                                                           row_bytes,
                                                           width,
                                                           height);
    if (ctx == NULL) {
        free(pixels);
        return false;
    }

    render_server_draw_backdrop(ctx, backdrop, width, height);
    CGContextRelease(ctx);

    backdrop->cached_pixels = pixels;
    backdrop->cached_size = cache_size;
    backdrop->cached_width = width;
    backdrop->cached_height = height;
    return true;
}

static bool render_server_copy_backdrop_cache(const RenderServerBackdrop *backdrop,
                                             uint8_t *destination,
                                             size_t destination_stride,
                                             uint32_t width,
                                             uint32_t height)
{
    if (backdrop == NULL || backdrop->cached_pixels == NULL || destination == NULL) {
        return false;
    }

    if (backdrop->cached_width != width || backdrop->cached_height != height) {
        return false;
    }

    size_t row_bytes = (size_t)width * 4u;
    if (destination_stride < row_bytes) {
        return false;
    }

    if (destination_stride == row_bytes) {
        memcpy(destination, backdrop->cached_pixels, backdrop->cached_size);
        return true;
    }

    for (uint32_t y = 0; y < height; ++y) {
        memcpy(destination + ((size_t)y * destination_stride),
               backdrop->cached_pixels + ((size_t)y * row_bytes),
               row_bytes);
    }

    return true;
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
    if (render_server_copy_backdrop_cache(backdrop, destination, destination_stride, width, height)) {
        return true;
    }

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
                                        RenderServerCompositor *compositor)
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

    if (compositor != NULL &&
        !render_server_prepare_backdrop_cache(&compositor->backdrop, buffers.width, buffers.height)) {
        fprintf(stderr, "[RenderServer] warning: failed to cache the backdrop, falling back to direct drawing\n");
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

static bool render_server_draw_window_image(CGContextRef ctx,
                                            const RenderServerWindowRect *rect,
                                            const uint8_t *source,
                                            int source_length)
{
    if (ctx == NULL || rect == NULL || source == NULL || source_length < 0 ||
        rect->w == 0 || rect->h == 0) {
        return false;
    }

    CGImageRef image = render_server_create_window_image(source,
                                                         (size_t)source_length,
                                                         rect->w,
                                                         rect->h);
    if (image == NULL) {
        return false;
    }

    /* X11 pixmaps arrive in the opposite vertical orientation from the
     * IOSurface-backed bitmap context, so flip the image layer only. */
    CGContextSaveGState(ctx);
    CGContextTranslateCTM(ctx, (CGFloat)rect->x, (CGFloat)rect->y + (CGFloat)rect->h);
    CGContextScaleCTM(ctx, 1.0, -1.0);
    CGContextDrawImage(ctx,
                       CGRectMake(0.0, 0.0, (CGFloat)rect->w, (CGFloat)rect->h),
                       image);
    CGContextRestoreGState(ctx);
    CGImageRelease(image);
    return true;
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

    CGContextRef ctx = state->surfaceContexts[state->backIdx];
    if (ctx == NULL) {
        IOSurfaceUnlock(back_surface, 0, NULL);
        fprintf(stderr, "[RenderServer] back surface bitmap context is unavailable\n");
        return 1;
    }

    if (!render_server_copy_backdrop_cache(compositor != NULL ? &compositor->backdrop : NULL,
                                           destination,
                                           destination_stride,
                                           width,
                                           height)) {
        render_server_draw_backdrop(ctx,
                                    compositor != NULL ? &compositor->backdrop : NULL,
                                    width,
                                    height);
    }

    if (composite_enabled) {
        xcb_query_tree_cookie_t tree_cookie = xcb_query_tree(connection, screen->root);
        xcb_query_tree_reply_t *tree_reply = xcb_query_tree_reply(connection, tree_cookie, NULL);
        if (tree_reply != NULL) {
            xcb_window_t *children = xcb_query_tree_children(tree_reply);
            int child_count = xcb_query_tree_children_length(tree_reply);

            if (child_count > 0) {
                RenderServerWindowSnapshot *windows =
                    calloc((size_t)child_count, sizeof(*windows));
                if (windows != NULL) {
                    /* Batch the X11 metadata requests so the server can work
                     * ahead of the client instead of stalling on each window. */
                    for (int i = 0; i < child_count; ++i) {
                        windows[i].window = children[i];
                        windows[i].viewable = false;
                        windows[i].override_redirect = false;
                        windows[i].image_requested = false;
                        windows[i].attributes_cookie =
                            xcb_get_window_attributes_unchecked(connection, children[i]);
                        windows[i].geometry_cookie =
                            xcb_get_geometry_unchecked(connection, children[i]);
                        windows[i].pixmap = XCB_NONE;
                        windows[i].image_cookie.sequence = 0;
                        windows[i].rect.x = 0;
                        windows[i].rect.y = 0;
                        windows[i].rect.w = 0;
                        windows[i].rect.h = 0;
                    }

                    xcb_flush(connection);

                    for (int i = 0; i < child_count; ++i) {
                        xcb_get_window_attributes_reply_t *attributes =
                            xcb_get_window_attributes_reply(connection,
                                                            windows[i].attributes_cookie,
                                                            NULL);
                        if (attributes == NULL) {
                            continue;
                        }

                        windows[i].viewable = attributes->map_state == XCB_MAP_STATE_VIEWABLE;
                        windows[i].override_redirect = attributes->override_redirect;
                        free(attributes);
                        if (!windows[i].viewable) {
                            continue;
                        }

                        xcb_get_geometry_reply_t *geometry =
                            xcb_get_geometry_reply(connection, windows[i].geometry_cookie, NULL);
                        if (geometry == NULL) {
                            windows[i].viewable = false;
                            continue;
                        }

                        windows[i].rect.x = geometry->x;
                        windows[i].rect.y = geometry->y;
                        windows[i].rect.w = geometry->width;
                        windows[i].rect.h = geometry->height;
                        free(geometry);
                    }

                    for (int i = 0; i < child_count; ++i) {
                        if (!windows[i].viewable) {
                            continue;
                        }

                        if (!render_server_rect_intersects_bounds(&windows[i].rect,
                                                                  width,
                                                                  height)) {
                            continue;
                        }

                        if (!windows[i].override_redirect &&
                            windows[i].rect.w >= 32 &&
                            windows[i].rect.h >= 24) {
                            render_server_apply_window_shadow(ctx,
                                                              compositor != NULL ? &compositor->shadow : NULL,
                                                              windows[i].rect.x,
                                                              windows[i].rect.y,
                                                              windows[i].rect.w,
                                                              windows[i].rect.h);
                        }

                        windows[i].pixmap = xcb_generate_id(connection);
                        xcb_composite_name_window_pixmap(connection,
                                                         windows[i].window,
                                                         windows[i].pixmap);
                        windows[i].image_cookie =
                            xcb_get_image_unchecked(connection,
                                                   XCB_IMAGE_FORMAT_Z_PIXMAP,
                                                   windows[i].pixmap,
                                                   0,
                                                   0,
                                                   windows[i].rect.w,
                                                   windows[i].rect.h,
                                                   UINT32_MAX);
                        windows[i].image_requested = true;
                        xcb_free_pixmap(connection, windows[i].pixmap);
                    }

                    xcb_flush(connection);

                    for (int i = 0; i < child_count; ++i) {
                        if (!windows[i].image_requested) {
                            continue;
                        }

                        xcb_get_image_reply_t *image_reply =
                            xcb_get_image_reply(connection, windows[i].image_cookie, NULL);
                        if (image_reply == NULL) {
                            continue;
                        }

                        const uint8_t *source = xcb_get_image_data(image_reply);
                        int source_length = xcb_get_image_data_length(image_reply);
                        if (source != NULL) {
                            (void)render_server_draw_window_image(ctx,
                                                                  &windows[i].rect,
                                                                  source,
                                                                  source_length);
                        }
                        free(image_reply);
                    }

                    free(windows);
                }
            }

            free(tree_reply);
        }
    }

    IOSurfaceUnlock(back_surface, 0, NULL);

    screenproc_render_frame(state);
    return 0;
}
