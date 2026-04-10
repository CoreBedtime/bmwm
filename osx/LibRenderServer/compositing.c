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
#include <xcb/damage.h>

/* -------------------------------------------------------------------------
 * Geometry / rect helpers
 * ---------------------------------------------------------------------- */

typedef struct {
    int32_t  x;
    int32_t  y;
    uint16_t w;
    uint16_t h;
} RenderServerWindowRect;

/* -------------------------------------------------------------------------
 * Backdrop
 * ---------------------------------------------------------------------- */

typedef struct {
    uint32_t   background_color;
    CGImageRef background_image;
    uint8_t   *cached_pixels;
    size_t     cached_size;
    uint32_t   cached_width;
    uint32_t   cached_height;
} RenderServerBackdrop;

/* -------------------------------------------------------------------------
 * Shadow
 * ---------------------------------------------------------------------- */

typedef struct {
    bool       enabled;
    int16_t    x_offset;
    int16_t    y_offset;
    uint16_t   spread;
    uint8_t    opacity;
    uint32_t   color;
    CGColorRef cg_color;
} RenderServerShadow;

/* -------------------------------------------------------------------------
 * Per-window cache entry
 *
 * One entry per top-level X11 window.  We keep the last-fetched pixel buffer
 * and a CGImage wrapping it so we only call xcb_get_image when XDamage tells
 * us the window content has changed.
 * ---------------------------------------------------------------------- */

typedef struct RenderServerWindowEntry RenderServerWindowEntry;
struct RenderServerWindowEntry {
    xcb_window_t              window;

    /* XDamage handle for this window (-1 when damage is unavailable) */
    xcb_damage_damage_t       damage;

    /* True when XDamage reported new damage since we last fetched pixels. */
    bool                      dirty;

    /* Cached geometry (populated once and updated on ConfigureNotify). */
    RenderServerWindowRect    rect;
    bool                      viewable;
    bool                      override_redirect;

    /* Pixel buffer fetched via xcb_get_image. */
    uint8_t                  *pixels;
    size_t                    pixel_size;

    /* CGImage built from pixels (NULL when pixels == NULL). */
    CGImageRef                image;

    /* Intrusive linked-list pointer (entries live in compositor->entries). */
    RenderServerWindowEntry  *next;
};

/* -------------------------------------------------------------------------
 * Compositor
 * ---------------------------------------------------------------------- */

struct RenderServerCompositor {
    RenderServerBackdrop   backdrop;
    RenderServerShadow     shadow;

    /* Damage extension availability and first-event code. */
    bool                   damage_available;
    int                    damage_first_event;
    xcb_damage_damage_t    damage_next_id;   /* monotonic counter for IDs */

    /* Linked list of per-window cache entries (order = stacking order). */
    RenderServerWindowEntry *entries;
    size_t                   entry_count;

    /* When true the compositor will re-query the window tree on the next
     * compose call (set by render_server_compositor_invalidate_tree or when
     * a window is found to have disappeared). */
    bool                     tree_dirty;
};

/* -------------------------------------------------------------------------
 * Shadow helpers
 * ---------------------------------------------------------------------- */

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
        (CGFloat)((shadow->color >>  8) & 0xFFu) / 255.0,
        (CGFloat)( shadow->color        & 0xFFu) / 255.0,
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

/* -------------------------------------------------------------------------
 * Rect helpers
 * ---------------------------------------------------------------------- */

static bool render_server_rect_intersects_bounds(const RenderServerWindowRect *rect,
                                                 uint32_t buffer_width,
                                                 uint32_t buffer_height)
{
    if (rect == NULL || rect->w == 0 || rect->h == 0) {
        return false;
    }

    int32_t left   = rect->x;
    int32_t top    = rect->y;
    int32_t right  = rect->x + (int32_t)rect->w;
    int32_t bottom = rect->y + (int32_t)rect->h;

    if (left   < 0)                  left   = 0;
    if (top    < 0)                  top    = 0;
    if (right  > (int32_t)buffer_width)  right  = (int32_t)buffer_width;
    if (bottom > (int32_t)buffer_height) bottom = (int32_t)buffer_height;

    return right > left && bottom > top;
}

/* -------------------------------------------------------------------------
 * Color helpers
 * ---------------------------------------------------------------------- */

static void render_server_unpack_argb(uint32_t argb,
                                      CGFloat *alpha,
                                      CGFloat *red,
                                      CGFloat *green,
                                      CGFloat *blue)
{
    if (alpha != NULL) *alpha = (CGFloat)((argb >> 24) & 0xFFu) / 255.0;
    if (red   != NULL) *red   = (CGFloat)((argb >> 16) & 0xFFu) / 255.0;
    if (green != NULL) *green = (CGFloat)((argb >>  8) & 0xFFu) / 255.0;
    if (blue  != NULL) *blue  = (CGFloat)( argb        & 0xFFu) / 255.0;
}

/* -------------------------------------------------------------------------
 * Image loading
 * ---------------------------------------------------------------------- */

static CGImageRef render_server_load_image_from_path(const char *path)
{
    if (path == NULL || *path == '\0') {
        return NULL;
    }

    CFStringRef path_string = CFStringCreateWithCString(kCFAllocatorDefault,
                                                        path,
                                                        kCFStringEncodingUTF8);
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

/* -------------------------------------------------------------------------
 * Backdrop helpers
 * ---------------------------------------------------------------------- */

static void render_server_set_default_shadow(RenderServerShadow *shadow)
{
    if (shadow == NULL) {
        return;
    }

    shadow->enabled  = true;
    shadow->x_offset = 0;
    shadow->y_offset = 0;
    shadow->spread   = 28;
    shadow->opacity  = 52;
    shadow->color    = 0xFF0E0F11u;
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
        if (config.has_background_color)  compositor->backdrop.background_color  = config.background_color;
        if (config.has_shadow_enabled)    compositor->shadow.enabled             = config.shadow_enabled;
        if (config.has_shadow_x_offset)   compositor->shadow.x_offset            = config.shadow_x_offset;
        if (config.has_shadow_y_offset)   compositor->shadow.y_offset            = config.shadow_y_offset;
        if (config.has_shadow_spread)     compositor->shadow.spread              = config.shadow_spread;
        if (config.has_shadow_opacity)    compositor->shadow.opacity             = config.shadow_opacity;
        if (config.has_shadow_color)      compositor->shadow.color               = config.shadow_color;

        if (config.has_background_image && config.background_image[0] != '\0') {
            compositor->backdrop.background_image =
                render_server_load_image_from_path(config.background_image);
            if (compositor->backdrop.background_image == NULL) {
                fprintf(stderr,
                        "[RenderServer] warning: could not load background image %s\n",
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
    backdrop->cached_size   = 0;
    backdrop->cached_width  = 0;
    backdrop->cached_height = 0;

    if (backdrop->background_image != NULL) {
        CGImageRelease(backdrop->background_image);
        backdrop->background_image = NULL;
    }
}

/* -------------------------------------------------------------------------
 * Per-window entry helpers
 * ---------------------------------------------------------------------- */

static void render_server_window_entry_free_image(RenderServerWindowEntry *e)
{
    if (e->image != NULL) {
        CGImageRelease(e->image);
        e->image = NULL;
    }
    if (e->pixels != NULL) {
        free(e->pixels);
        e->pixels     = NULL;
        e->pixel_size = 0;
    }
}

static void render_server_window_entry_destroy(RenderServerWindowEntry *e,
                                               xcb_connection_t        *connection)
{
    if (e == NULL) {
        return;
    }

    render_server_window_entry_free_image(e);

    if (connection != NULL && e->damage != 0) {
        xcb_damage_destroy(connection, e->damage);
        e->damage = 0;
    }

    free(e);
}

/* Find an entry by window ID (O(n), but the list is typically very short). */
static RenderServerWindowEntry *render_server_find_entry(RenderServerCompositor *compositor,
                                                         xcb_window_t            window)
{
    for (RenderServerWindowEntry *e = compositor->entries; e != NULL; e = e->next) {
        if (e->window == window) {
            return e;
        }
    }
    return NULL;
}

/* -------------------------------------------------------------------------
 * Public API — create / destroy / damage setup
 * ---------------------------------------------------------------------- */

RenderServerCompositor *render_server_compositor_create(const char *config_path)
{
    RenderServerCompositor *compositor = calloc(1, sizeof(*compositor));
    if (compositor == NULL) {
        return NULL;
    }

    compositor->tree_dirty = true;

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

    RenderServerWindowEntry *e = compositor->entries;
    while (e != NULL) {
        RenderServerWindowEntry *next = e->next;
        render_server_window_entry_destroy(e, NULL);   /* connection already closed */
        e = next;
    }
    compositor->entries     = NULL;
    compositor->entry_count = 0;

    render_server_release_backdrop(&compositor->backdrop);
    render_server_release_shadow(&compositor->shadow);
    free(compositor);
}

bool render_server_compositor_setup_damage(RenderServerCompositor *compositor,
                                           xcb_connection_t       *connection)
{
    if (compositor == NULL || connection == NULL) {
        return false;
    }

    xcb_damage_query_version_cookie_t ck =
        xcb_damage_query_version(connection,
                                 XCB_DAMAGE_MAJOR_VERSION,
                                 XCB_DAMAGE_MINOR_VERSION);
    xcb_damage_query_version_reply_t *reply =
        xcb_damage_query_version_reply(connection, ck, NULL);
    if (reply == NULL) {
        fprintf(stderr, "[RenderServer] XDamage unavailable; falling back to full-frame redraws\n");
        compositor->damage_available = false;
        return false;
    }
    free(reply);

    /* Query the first event code for XDamage so we can identify DamageNotify. */
    const xcb_query_extension_reply_t *ext =
        xcb_get_extension_data(connection, &xcb_damage_id);
    if (ext == NULL || !ext->present) {
        fprintf(stderr, "[RenderServer] XDamage extension not present\n");
        compositor->damage_available = false;
        return false;
    }

    compositor->damage_available   = true;
    compositor->damage_first_event = ext->first_event;
    return true;
}

void render_server_compositor_invalidate_tree(RenderServerCompositor *compositor)
{
    if (compositor != NULL) {
        compositor->tree_dirty = true;
    }
}

void render_server_compositor_update_geometry(RenderServerCompositor *compositor,
                                              xcb_window_t            window,
                                              int16_t                 x,
                                              int16_t                 y,
                                              uint16_t                w,
                                              uint16_t                h)
{
    if (compositor == NULL) {
        return;
    }

    RenderServerWindowEntry *e = render_server_find_entry(compositor, window);
    if (e == NULL) {
        /* Window not yet in the cache — trigger a full sync so it gets added. */
        compositor->tree_dirty = true;
        return;
    }

    render_server_window_entry_free_image(e);
    e->dirty = true;

    e->rect.x = x;
    e->rect.y = y;
    e->rect.w = w;
    e->rect.h = h;
}

/* -------------------------------------------------------------------------
 * Event handler — returns true if the event was a damage notification
 * ---------------------------------------------------------------------- */

bool render_server_compositor_handle_event(RenderServerCompositor *compositor,
                                           xcb_connection_t       *connection,
                                           xcb_generic_event_t    *event)
{
    if (compositor == NULL || event == NULL) {
        return false;
    }

    uint8_t type = event->response_type & 0x7Fu;

    /* DamageNotify: mark the affected window dirty. */
    if (compositor->damage_available &&
        type == (uint8_t)compositor->damage_first_event) {
        xcb_damage_notify_event_t *dn = (xcb_damage_notify_event_t *)event;

        RenderServerWindowEntry *e = render_server_find_entry(compositor, dn->drawable);
        if (e != NULL) {
            e->dirty = true;
        }

        /* Subtract (acknowledge) the damage so Xorg stops accumulating it. */
        xcb_damage_subtract(connection, dn->damage, XCB_NONE, XCB_NONE);
        return true;
    }

    return false;
}

/* -------------------------------------------------------------------------
 * Bitmap context helpers
 * ---------------------------------------------------------------------- */

static CGContextRef render_server_create_bitmap_context(uint8_t      *destination,
                                                         size_t        destination_stride,
                                                         uint32_t      width,
                                                         uint32_t      height)
{
    if (destination == NULL || width == 0 || height == 0 ||
        destination_stride < ((size_t)width * 4u)) {
        return NULL;
    }

    CGColorSpaceRef color_space = CGColorSpaceCreateDeviceRGB();
    if (color_space == NULL) {
        return NULL;
    }

    CGContextRef ctx =
        CGBitmapContextCreate(destination,
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

    /* Flip so Y=0 is at the top (matching the IOSurface layout). */
    CGContextTranslateCTM(ctx, 0.0, (CGFloat)height);
    CGContextScaleCTM(ctx, 1.0, -1.0);
    return ctx;
}

/* -------------------------------------------------------------------------
 * Backdrop drawing / caching
 * ---------------------------------------------------------------------- */

static void render_server_draw_backdrop(CGContextRef               ctx,
                                        const RenderServerBackdrop *backdrop,
                                        uint32_t                   width,
                                        uint32_t                   height);

static bool render_server_prepare_backdrop_cache(RenderServerBackdrop *backdrop,
                                                 uint32_t              width,
                                                 uint32_t              height)
{
    if (backdrop == NULL || width == 0 || height == 0) {
        return false;
    }

    size_t row_bytes  = (size_t)width * 4u;
    if (row_bytes / 4u != (size_t)width) {
        return false;
    }

    size_t cache_size = row_bytes * (size_t)height;
    if (height != 0 && cache_size / (size_t)height != row_bytes) {
        return false;
    }

    if (backdrop->cached_pixels != NULL &&
        backdrop->cached_width  == width &&
        backdrop->cached_height == height &&
        backdrop->cached_size   == cache_size) {
        return true;   /* already valid */
    }

    free(backdrop->cached_pixels);
    backdrop->cached_pixels = NULL;
    backdrop->cached_size   = 0;
    backdrop->cached_width  = 0;
    backdrop->cached_height = 0;

    uint8_t *pixels = malloc(cache_size);
    if (pixels == NULL) {
        return false;
    }

    CGContextRef ctx = render_server_create_bitmap_context(pixels, row_bytes, width, height);
    if (ctx == NULL) {
        free(pixels);
        return false;
    }

    render_server_draw_backdrop(ctx, backdrop, width, height);
    CGContextRelease(ctx);

    backdrop->cached_pixels = pixels;
    backdrop->cached_size   = cache_size;
    backdrop->cached_width  = width;
    backdrop->cached_height = height;
    return true;
}

static bool render_server_copy_backdrop_cache(const RenderServerBackdrop *backdrop,
                                              uint8_t                    *destination,
                                              size_t                      destination_stride,
                                              uint32_t                    width,
                                              uint32_t                    height)
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

static void render_server_draw_backdrop(CGContextRef               ctx,
                                        const RenderServerBackdrop *backdrop,
                                        uint32_t                   width,
                                        uint32_t                   height)
{
    if (ctx == NULL || width == 0 || height == 0) {
        return;
    }

    CGFloat alpha = 1.0, red = 1.0, green = 1.0, blue = 1.0;
    uint32_t background_color = 0xFFFFFFFFu;
    if (backdrop != NULL) {
        background_color = backdrop->background_color;
    }
    render_server_unpack_argb(background_color, &alpha, &red, &green, &blue);

    CGContextSetRGBFillColor(ctx, red, green, blue, alpha);
    CGContextFillRect(ctx, CGRectMake(0.0, 0.0, (CGFloat)width, (CGFloat)height));

    if (backdrop != NULL && backdrop->background_image != NULL) {
        CGContextSetInterpolationQuality(ctx, kCGInterpolationHigh);
        CGContextSaveGState(ctx);
        CGContextTranslateCTM(ctx, 0.0, (CGFloat)height);
        CGContextScaleCTM(ctx, 1.0, -1.0);
        CGContextDrawImage(ctx,
                           CGRectMake(0.0, 0.0, (CGFloat)width, (CGFloat)height),
                           backdrop->background_image);
        CGContextRestoreGState(ctx);
    }
}

static bool render_server_draw_surface_background(uint8_t                    *destination,
                                                  size_t                      destination_stride,
                                                  uint32_t                    width,
                                                  uint32_t                    height,
                                                  const RenderServerBackdrop *backdrop)
{
    if (render_server_copy_backdrop_cache(backdrop, destination,
                                          destination_stride, width, height)) {
        return true;
    }

    CGContextRef ctx = render_server_create_bitmap_context(destination,
                                                           destination_stride,
                                                           width, height);
    if (ctx == NULL) {
        return false;
    }

    render_server_draw_backdrop(ctx, backdrop, width, height);
    CGContextRelease(ctx);
    return true;
}

/* -------------------------------------------------------------------------
 * Window image helpers (cached)
 * ---------------------------------------------------------------------- */

static CGImageRef render_server_create_window_image(const uint8_t *source,
                                                    size_t         source_length,
                                                    uint16_t       width,
                                                    uint16_t       height)
{
    if (source == NULL || width == 0 || height == 0) {
        return NULL;
    }

    size_t source_stride   = (size_t)width * 4u;
    size_t required_bytes  = source_stride * (size_t)height;
    if (source_length < required_bytes) {
        return NULL;
    }

    CGColorSpaceRef color_space = CGColorSpaceCreateDeviceRGB();
    if (color_space == NULL) {
        return NULL;
    }

    CGDataProviderRef provider =
        CGDataProviderCreateWithData(NULL, source, required_bytes, NULL);
    if (provider == NULL) {
        CGColorSpaceRelease(color_space);
        return NULL;
    }

    CGImageRef image =
        CGImageCreate(width,
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

/*
 * Re-fetch pixel data for a window entry via xcb_get_image and rebuild its
 * cached CGImage.  Returns true on success.  The entry's dirty flag is
 * cleared on success.
 */
static bool render_server_refresh_window_pixels(RenderServerWindowEntry *e,
                                                xcb_connection_t        *connection)
{
    if (e == NULL || connection == NULL ||
        e->rect.w == 0 || e->rect.h == 0) {
        return false;
    }

    /* Create a named composite pixmap for this window and fetch its pixels. */
    xcb_pixmap_t pixmap = xcb_generate_id(connection);
    xcb_composite_name_window_pixmap(connection, e->window, pixmap);

    xcb_get_image_cookie_t image_cookie =
        xcb_get_image_unchecked(connection,
                                XCB_IMAGE_FORMAT_Z_PIXMAP,
                                pixmap,
                                0, 0,
                                e->rect.w,
                                e->rect.h,
                                UINT32_MAX);
    xcb_free_pixmap(connection, pixmap);

    xcb_get_image_reply_t *image_reply =
        xcb_get_image_reply(connection, image_cookie, NULL);
    if (image_reply == NULL) {
        return false;
    }

    const uint8_t *src    = xcb_get_image_data(image_reply);
    int            src_len = xcb_get_image_data_length(image_reply);
    bool           ok     = false;

    if (src != NULL && src_len > 0) {
        size_t needed = (size_t)e->rect.w * (size_t)e->rect.h * 4u;
        if ((size_t)src_len >= needed) {
            /* Grow pixel buffer if necessary. */
            if (e->pixel_size < needed) {
                uint8_t *buf = realloc(e->pixels, needed);
                if (buf == NULL) {
                    free(image_reply);
                    return false;
                }
                e->pixels     = buf;
                e->pixel_size = needed;
            }

            memcpy(e->pixels, src, needed);

            /* Rebuild the CGImage from the new pixel buffer. */
            if (e->image != NULL) {
                CGImageRelease(e->image);
                e->image = NULL;
            }
            e->image = render_server_create_window_image(e->pixels,
                                                         e->pixel_size,
                                                         e->rect.w,
                                                         e->rect.h);
            ok = e->image != NULL;
        }
    }

    free(image_reply);

    if (ok) {
        e->dirty = false;
    }
    return ok;
}

/* -------------------------------------------------------------------------
 * Shadow drawing
 * ---------------------------------------------------------------------- */

static void render_server_apply_window_shadow(CGContextRef              ctx,
                                              const RenderServerShadow *shadow,
                                              int32_t                   x,
                                              int32_t                   y,
                                              uint16_t                  w,
                                              uint16_t                  h)
{
    if (ctx == NULL || shadow == NULL || !shadow->enabled ||
        shadow->cg_color == NULL || w == 0 || h == 0) {
        return;
    }

    CGContextSaveGState(ctx);
    CGContextSetShadowWithColor(ctx,
                                CGSizeMake((CGFloat)shadow->x_offset,
                                           (CGFloat)shadow->y_offset),
                                (CGFloat)shadow->spread,
                                shadow->cg_color);
    CGContextSetFillColorWithColor(ctx, shadow->cg_color);
    CGContextFillRect(ctx, CGRectMake((CGFloat)x, (CGFloat)y,
                                      (CGFloat)w, (CGFloat)h));
    CGContextRestoreGState(ctx);
}

/* -------------------------------------------------------------------------
 * Window image drawing (from cached CGImage)
 * ---------------------------------------------------------------------- */

static bool render_server_draw_window_image(CGContextRef                  ctx,
                                            const RenderServerWindowRect *rect,
                                            CGImageRef                    image)
{
    if (ctx == NULL || rect == NULL || image == NULL ||
        rect->w == 0 || rect->h == 0) {
        return false;
    }

    /* X11 pixmaps arrive in the opposite vertical orientation from the
     * IOSurface-backed bitmap context, so flip the image layer only. */
    CGContextSaveGState(ctx);
    CGContextTranslateCTM(ctx, (CGFloat)rect->x,
                          (CGFloat)rect->y + (CGFloat)rect->h);
    CGContextScaleCTM(ctx, 1.0, -1.0);
    CGContextDrawImage(ctx,
                       CGRectMake(0.0, 0.0, (CGFloat)rect->w, (CGFloat)rect->h),
                       image);
    CGContextRestoreGState(ctx);
    return true;
}

/* -------------------------------------------------------------------------
 * Window tree reconciliation
 *
 * Called when tree_dirty is set.  We query the root's children and
 * synchronise the compositor's entry list:
 *   - entries for windows no longer in the tree are removed
 *   - new windows get a fresh entry and an XDamage subscription
 *   - geometry / viewability of existing entries is refreshed
 * The tree order (bottom-to-top stacking) is preserved.
 * ---------------------------------------------------------------------- */

static void render_server_sync_window_tree(RenderServerCompositor *compositor,
                                           xcb_connection_t       *connection,
                                           xcb_screen_t           *screen)
{
    if (compositor == NULL || connection == NULL || screen == NULL) {
        return;
    }

    xcb_query_tree_cookie_t tree_cookie =
        xcb_query_tree(connection, screen->root);
    xcb_query_tree_reply_t *tree_reply =
        xcb_query_tree_reply(connection, tree_cookie, NULL);
    if (tree_reply == NULL) {
        fprintf(stderr, "[RenderServer] query_tree failed\n");
        return;
    }

    xcb_window_t *children   = xcb_query_tree_children(tree_reply);
    int           child_count = xcb_query_tree_children_length(tree_reply);
    fprintf(stderr, "[RenderServer] child_count=%d\n", child_count);

    /* --- Phase 1: batch-fetch attributes + geometry for all children --- */

    typedef struct {
        xcb_window_t                       window;
        xcb_get_window_attributes_cookie_t attr_cookie;
        xcb_get_geometry_cookie_t          geom_cookie;
    } PendingQuery;

    PendingQuery *pending = NULL;
    if (child_count > 0) {
        pending = calloc((size_t)child_count, sizeof(*pending));
    }

    if (pending != NULL) {
        for (int i = 0; i < child_count; ++i) {
            pending[i].window      = children[i];
            pending[i].attr_cookie =
                xcb_get_window_attributes_unchecked(connection, children[i]);
            pending[i].geom_cookie =
                xcb_get_geometry_unchecked(connection, children[i]);
        }
        xcb_flush(connection);
    }

    /* --- Phase 2: build new entry list in stacking order --- */

    RenderServerWindowEntry *new_head = NULL;
    RenderServerWindowEntry *new_tail = NULL;
    size_t                   new_count = 0;

    for (int i = 0; (pending != NULL) && i < child_count; ++i) {
        xcb_get_window_attributes_reply_t *attr =
            xcb_get_window_attributes_reply(connection,
                                            pending[i].attr_cookie, NULL);
        xcb_get_geometry_reply_t *geom =
            xcb_get_geometry_reply(connection,
                                   pending[i].geom_cookie, NULL);

        bool viewable         = false;
        bool override_redirect = false;
        RenderServerWindowRect rect = {0, 0, 0, 0};

        if (attr != NULL) {
            viewable          = (attr->map_state == XCB_MAP_STATE_VIEWABLE);
            override_redirect = (bool)attr->override_redirect;
            free(attr);
        }
        if (geom != NULL) {
            rect.x = geom->x;
            rect.y = geom->y;
            rect.w = geom->width;
            rect.h = geom->height;
            free(geom);
        }

        /* Try to reuse an existing entry for this window. */
        RenderServerWindowEntry *e =
            render_server_find_entry(compositor, pending[i].window);
        if (e != NULL) {
            /* Unlink from the old list so we can re-insert in new order. */
            RenderServerWindowEntry **pp = &compositor->entries;
            while (*pp != NULL && *pp != e) {
                pp = &(*pp)->next;
            }
            if (*pp == e) {
                *pp = e->next;
                e->next = NULL;
                compositor->entry_count--;
            }

            /* Invalidate the pixel cache to force a fresh fetch. */
            render_server_window_entry_free_image(e);
            e->dirty = true;
        } else {
            /* New window — allocate and subscribe to damage. */
            e = calloc(1, sizeof(*e));
            if (e == NULL) {
                continue;
            }
            e->window = pending[i].window;
            e->dirty  = true;   /* must fetch pixels on first paint */

            if (compositor->damage_available) {
                e->damage = xcb_generate_id(connection);
                xcb_damage_create(connection,
                                  e->damage,
                                  e->window,
                                  XCB_DAMAGE_REPORT_LEVEL_NON_EMPTY);
            }
        }

        e->viewable          = viewable;
        e->override_redirect = override_redirect;
        e->rect              = rect;
        e->next              = NULL;

        /* Append to new list (maintains bottom-to-top stacking order). */
        if (new_tail != NULL) {
            new_tail->next = e;
        } else {
            new_head = e;
        }
        new_tail = e;
        new_count++;
    }

    free(pending);
    free(tree_reply);

    /* --- Phase 3: destroy entries for windows that are gone --- */
    RenderServerWindowEntry *gone = compositor->entries;
    while (gone != NULL) {
        RenderServerWindowEntry *next = gone->next;
        render_server_window_entry_destroy(gone, connection);
        gone = next;
    }

    compositor->entries     = new_head;
    compositor->entry_count = new_count;
    compositor->tree_dirty  = false;
    fprintf(stderr, "[RenderServer] synced %zu windows\n", new_count);
}

/* -------------------------------------------------------------------------
 * Public: prepare_initial_frame / enable_composite
 * ---------------------------------------------------------------------- */

int render_server_prepare_initial_frame(RenderState            *state,
                                        RenderServerCompositor *compositor)
{
    ScreenprocBuffers buffers;
    memset(&buffers, 0, sizeof(buffers));
    screenproc_get_buffers(state, &buffers);

    if (buffers.buffer0 == NULL || buffers.buffer1 == NULL ||
        buffers.width == 0 || buffers.height == 0) {
        fprintf(stderr, "[RenderServer] framebuffer buffers are unavailable\n");
        return 1;
    }

    if ((size_t)buffers.stride < ((size_t)buffers.width * 4)) {
        fprintf(stderr, "[RenderServer] framebuffer stride is too small\n");
        return 1;
    }

    if (compositor != NULL &&
        !render_server_prepare_backdrop_cache(&compositor->backdrop,
                                              buffers.width, buffers.height)) {
        fprintf(stderr,
                "[RenderServer] warning: failed to cache the backdrop, "
                "falling back to direct drawing\n");
    }

    if (!render_server_draw_surface_background(
            (uint8_t *)buffers.buffer0, buffers.stride,
            buffers.width, buffers.height,
            compositor != NULL ? &compositor->backdrop : NULL)) {
        fprintf(stderr, "[RenderServer] failed to draw the initial background\n");
        return 1;
    }

    if (!render_server_draw_surface_background(
            (uint8_t *)buffers.buffer1, buffers.stride,
            buffers.width, buffers.height,
            compositor != NULL ? &compositor->backdrop : NULL)) {
        fprintf(stderr, "[RenderServer] failed to draw the initial background\n");
        return 1;
    }

    screenproc_render_frame(state);
    return 0;
}

int render_server_enable_composite(xcb_connection_t *connection,
                                   xcb_screen_t     *screen,
                                   const char       *display_name,
                                   bool             *composite_enabled_out)
{
    if (composite_enabled_out != NULL) {
        *composite_enabled_out = false;
    }

    xcb_composite_query_version_cookie_t version_cookie =
        xcb_composite_query_version(connection,
                                    XCB_COMPOSITE_MAJOR_VERSION,
                                    XCB_COMPOSITE_MINOR_VERSION);
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
                "[RenderServer] failed to redirect root subwindows with "
                "XComposite on %s (error %u)\n",
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

/* -------------------------------------------------------------------------
 * Public: compose_frame
 * ---------------------------------------------------------------------- */

int render_server_compose_frame(RenderState            *state,
                                xcb_connection_t       *connection,
                                xcb_screen_t           *screen,
                                RenderServerCompositor *compositor,
                                bool                    composite_enabled,
                                uint16_t                width,
                                uint16_t                height,
                                int16_t                 cursor_x,
                                int16_t                 cursor_y)
{
    static int64_t frame_count = 0;
    static struct timespec last_frame_ts = {0, 0};
    static struct timespec last_sync_ts = {0, 0};
    struct timespec frame_start;
    clock_gettime(CLOCK_MONOTONIC, &frame_start);
    frame_count++;

    if (state == NULL || connection == NULL || screen == NULL) {
        return 1;
    }

    IOSurfaceRef back_surface = state->surfaces[state->backIdx];
    if (back_surface == NULL) {
        fprintf(stderr, "[RenderServer] back IOSurface is unavailable\n");
        return 1;
    }

    IOSurfaceLock(back_surface, 0, NULL);
    uint8_t *destination        = (uint8_t *)IOSurfaceGetBaseAddress(back_surface);
    size_t   destination_stride = IOSurfaceGetBytesPerRow(back_surface);

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

    /* --- Draw backdrop (memcpy from cache when available) --- */
    if (!render_server_copy_backdrop_cache(
            compositor != NULL ? &compositor->backdrop : NULL,
            destination, destination_stride, width, height)) {
        render_server_draw_backdrop(ctx,
                                    compositor != NULL ? &compositor->backdrop : NULL,
                                    width, height);
    }

    if (compositor == NULL) {
        IOSurfaceUnlock(back_surface, 0, NULL);
        screenproc_render_frame(state);
        return 0;
    }

    /* --- Reconcile window tree if stale or every 5 seconds --- */
    if (compositor->tree_dirty ||
        (frame_start.tv_sec - last_sync_ts.tv_sec >= 5)) {
        if (!compositor->tree_dirty) {
            fprintf(stderr, "[RenderServer] periodic re-sync\n");
        }
        compositor->tree_dirty = true;
        last_sync_ts = frame_start;
        render_server_sync_window_tree(compositor, connection, screen);
    }

    /* --- For each dirty window: fetch pixels (batched xcb_get_image) --- */

    /* First pass: issue requests for all dirty windows. */
    for (RenderServerWindowEntry *e = compositor->entries; e != NULL; e = e->next) {
        if (!e->viewable || e->rect.w == 0 || e->rect.h == 0) {
            continue;
        }
        if (!render_server_rect_intersects_bounds(&e->rect, width, height)) {
            continue;
        }

        /* refresh_window_pixels is synchronous (issue + receive) because the
         * replies must arrive before we draw.  The key saving is that we only
         * do this when the window is actually dirty — for a static screen the
         * cost drops to zero. */
        render_server_refresh_window_pixels(e, connection);
    }

    /* --- Second pass: draw all visible windows bottom-to-top --- */
    for (RenderServerWindowEntry *e = compositor->entries; e != NULL; e = e->next) {
        if (!e->viewable) {
            fprintf(stderr, "[RenderServer] skip draw: not viewable win=%u\n", e->window);
            continue;
        }
        if (e->image == NULL) {
            fprintf(stderr, "[RenderServer] skip draw: no image win=%u\n", e->window);
            continue;
        }
        if (!render_server_rect_intersects_bounds(&e->rect, width, height)) {
            fprintf(stderr, "[RenderServer] skip draw: OOB win=%u\n", e->window);
            continue;
        }
        fprintf(stderr, "[RenderServer] DRAW win=%u viewable=%d image=%p\n", e->window, e->viewable, (void*)e->image);

        /* Shadow (non-override-redirect windows only, minimum 32×24). */
        if (!e->override_redirect &&
            e->rect.w >= 32 && e->rect.h >= 24) {
            render_server_apply_window_shadow(ctx,
                                             &compositor->shadow,
                                             e->rect.x, e->rect.y,
                                             e->rect.w, e->rect.h);
        }

        render_server_draw_window_image(ctx, &e->rect, e->image);
    }

    /* --- Draw software cursor dot --- */
    if (cursor_x >= 0 && cursor_y >= 0 &&
        cursor_x < (int16_t)width && cursor_y < (int16_t)height) {
#define CURSOR_RADIUS 4
        int32_t cx = cursor_x;
        int32_t cy = cursor_y;
        int32_t x0 = cx - CURSOR_RADIUS;
        int32_t y0 = cy - CURSOR_RADIUS;
        int32_t x1 = cx + CURSOR_RADIUS;
        int32_t y1 = cy + CURSOR_RADIUS;
        if (x0 < 0) x0 = 0;
        if (y0 < 0) y0 = 0;
        if (x1 >= (int32_t)width)  x1 = (int32_t)width  - 1;
        if (y1 >= (int32_t)height) y1 = (int32_t)height - 1;
        /* Paint a solid red square directly into the IOSurface pixel buffer.
         * BGRA layout (kCGBitmapByteOrder32Little | AlphaPremultipliedFirst):
         *   byte 0 = blue, 1 = green, 2 = red, 3 = alpha */
        for (int32_t py = y0; py <= y1; ++py) {
            uint8_t *row = destination + (size_t)py * destination_stride + (size_t)x0 * 4u;
            for (int32_t px = x0; px <= x1; ++px) {
                row[0] = 0x00;   /* B */
                row[1] = 0x00;   /* G */
                row[2] = 0xFF;   /* R */
                row[3] = 0xFF;   /* A */
                row += 4;
            }
        }
#undef CURSOR_RADIUS
    }

    IOSurfaceUnlock(back_surface, 0, NULL);
    screenproc_render_frame(state);

    /* FPS logging every 60 frames */
    if (frame_count % 60 == 0) {
        struct timespec now;
        clock_gettime(CLOCK_MONOTONIC, &now);
        if (last_frame_ts.tv_sec != 0) {
            int64_t elapsed_ns = (now.tv_sec - last_frame_ts.tv_sec) * 1000000000LL +
                                 (now.tv_nsec - last_frame_ts.tv_nsec);
            double fps = 60.0 * 1000000000.0 / (double)elapsed_ns;
            fprintf(stderr, "[RenderServer] frame %lld, avg FPS: %.1f\n",
                    (long long)frame_count, fps);
        }
        last_frame_ts = now;
    }

    return 0;
}
