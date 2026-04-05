#define _POSIX_C_SOURCE 200809L

#include "bwm.h"

#include <CoreFoundation/CoreFoundation.h>
#include <CoreGraphics/CoreGraphics.h>
#include <ImageIO/ImageIO.h>
#include <lua.h>
#include <lauxlib.h>
#include <lualib.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static uint32_t channel_to_mask(uint8_t value, uint32_t mask)
{
    if (mask == 0) return 0;

    unsigned shift = 0;
    while (shift < 32u && ((mask >> shift) & 1u) == 0u) {
        ++shift;
    }

    unsigned bits = 0;
    while (shift + bits < 32u && ((mask >> (shift + bits)) & 1u) != 0u) {
        ++bits;
    }

    if (bits == 0) return 0;

    uint32_t max = (bits >= 31u) ? 0xFFFFFFFFu : ((1u << bits) - 1u);
    uint32_t scaled = (uint32_t)((value * max + 127u) / 255u);
    return (scaled << shift) & mask;
}

static const xcb_visualtype_t *find_root_visual(BwmWM *wm)
{
    xcb_depth_iterator_t depth_it = xcb_screen_allowed_depths_iterator(wm->screen);
    for (; depth_it.rem; xcb_depth_next(&depth_it)) {
        xcb_visualtype_iterator_t visual_it = xcb_depth_visuals_iterator(depth_it.data);
        for (; visual_it.rem; xcb_visualtype_next(&visual_it)) {
            if (visual_it.data->visual_id == wm->screen->root_visual) {
                return visual_it.data;
            }
        }
    }
    return NULL;
}

static uint32_t pack_rgb(const xcb_visualtype_t *visual, uint8_t r, uint8_t g, uint8_t b)
{
    if (visual == NULL) {
        return ((uint32_t)r << 16) | ((uint32_t)g << 8) | (uint32_t)b;
    }

    return channel_to_mask(r, visual->red_mask) |
           channel_to_mask(g, visual->green_mask) |
           channel_to_mask(b, visual->blue_mask);
}

static void unpack_argb(uint32_t argb, uint8_t *a, uint8_t *r, uint8_t *g, uint8_t *b)
{
    if (a != NULL) *a = (uint8_t)((argb >> 24) & 0xFFu);
    if (r != NULL) *r = (uint8_t)((argb >> 16) & 0xFFu);
    if (g != NULL) *g = (uint8_t)((argb >> 8) & 0xFFu);
    if (b != NULL) *b = (uint8_t)(argb & 0xFFu);
}

static void load_number_field(lua_State *L, int table_index, const char *name, uint32_t *dst)
{
    lua_getfield(L, table_index, name);
    if (lua_isnumber(L, -1)) {
        *dst = (uint32_t)lua_tointeger(L, -1);
    }
    lua_pop(L, 1);
}

static void load_string_field(lua_State *L, int table_index, const char *name,
                              char *dst, size_t dst_len)
{
    lua_getfield(L, table_index, name);
    if (lua_isstring(L, -1)) {
        const char *src = lua_tostring(L, -1);
        if (src != NULL && dst_len > 0) {
            snprintf(dst, dst_len, "%s", src);
        }
    }
    lua_pop(L, 1);
}

static void load_config_table(lua_State *L, BwmWM *wm)
{
    load_number_field(L, -1, "root_color", &wm->config.root_color);
    load_string_field(L, -1, "root_image", wm->config.root_image, sizeof(wm->config.root_image));
    load_number_field(L, -1, "titlebar_color", &wm->config.titlebar_color);
    load_number_field(L, -1, "titlebar_focus_color", &wm->config.titlebar_focus_color);
}

static bool upload_root_image(BwmWM *wm, const char *path)
{
    if (path == NULL || *path == '\0' || wm->conn == NULL) {
        return false;
    }

    CFStringRef path_string = CFStringCreateWithCString(kCFAllocatorDefault, path, kCFStringEncodingUTF8);
    if (path_string == NULL) {
        return false;
    }

    CFURLRef url = CFURLCreateWithFileSystemPath(kCFAllocatorDefault, path_string,
                                                 kCFURLPOSIXPathStyle, false);
    CFRelease(path_string);
    if (url == NULL) {
        return false;
    }

    CGImageSourceRef source = CGImageSourceCreateWithURL(url, NULL);
    CFRelease(url);
    if (source == NULL) {
        return false;
    }

    CGImageRef image = CGImageSourceCreateImageAtIndex(source, 0, NULL);
    CFRelease(source);
    if (image == NULL) {
        return false;
    }

    size_t width = (size_t)wm->root_w;
    size_t height = (size_t)wm->root_h;
    if (width == 0 || height == 0) {
        CGImageRelease(image);
        return false;
    }

    size_t bytes_per_row = width * 4u;
    size_t data_len = bytes_per_row * height;
    uint8_t *rgba = (uint8_t *)calloc(1, data_len);
    if (rgba == NULL) {
        CGImageRelease(image);
        return false;
    }

    CGColorSpaceRef color_space = CGColorSpaceCreateDeviceRGB();
    if (color_space == NULL) {
        free(rgba);
        CGImageRelease(image);
        return false;
    }

    CGContextRef ctx = CGBitmapContextCreate(rgba, width, height, 8, bytes_per_row,
                                             color_space,
                                             kCGImageAlphaPremultipliedLast |
                                             kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(color_space);
    if (ctx == NULL) {
        free(rgba);
        CGImageRelease(image);
        return false;
    }

    CGContextTranslateCTM(ctx, 0.0, (CGFloat)height);
    CGContextScaleCTM(ctx, 1.0, -1.0);
    CGContextDrawImage(ctx, CGRectMake(0.0, 0.0, (CGFloat)width, (CGFloat)height), image);
    CGContextRelease(ctx);
    CGImageRelease(image);

    const xcb_visualtype_t *visual = find_root_visual(wm);
    uint8_t bg_a, bg_r, bg_g, bg_b;
    unpack_argb(wm->config.root_color, &bg_a, &bg_r, &bg_g, &bg_b);
    (void)bg_a;

    uint32_t *pixels = (uint32_t *)calloc(width * height, sizeof(uint32_t));
    if (pixels == NULL) {
        free(rgba);
        return false;
    }

    for (size_t i = 0; i < width * height; ++i) {
        uint8_t a = rgba[i * 4u + 3u];
        uint8_t r = rgba[i * 4u + 0u];
        uint8_t g = rgba[i * 4u + 1u];
        uint8_t b = rgba[i * 4u + 2u];

        if (a < 255u) {
            r = (uint8_t)((r * a + bg_r * (255u - a)) / 255u);
            g = (uint8_t)((g * a + bg_g * (255u - a)) / 255u);
            b = (uint8_t)((b * a + bg_b * (255u - a)) / 255u);
        }

        pixels[i] = pack_rgb(visual, r, g, b);
    }

    if (wm->root_background != XCB_NONE) {
        xcb_free_pixmap(wm->conn, wm->root_background);
        wm->root_background = XCB_NONE;
    }

    wm->root_background = xcb_generate_id(wm->conn);
    xcb_create_pixmap(wm->conn, wm->screen->root_depth, wm->root_background, wm->root,
                      (uint16_t)width, (uint16_t)height);

    xcb_gcontext_t gc = xcb_generate_id(wm->conn);
    xcb_create_gc(wm->conn, gc, wm->root_background, 0, NULL);
    xcb_put_image(wm->conn, XCB_IMAGE_FORMAT_Z_PIXMAP, wm->root_background, gc,
                  (uint16_t)width, (uint16_t)height, 0, 0, 0,
                  wm->screen->root_depth, (uint32_t)data_len, (const uint8_t *)pixels);
    xcb_free_gc(wm->conn, gc);

    uint32_t back = wm->root_background;
    xcb_change_window_attributes(wm->conn, wm->root, XCB_CW_BACK_PIXMAP, &back);
    xcb_clear_area(wm->conn, 0, wm->root, 0, 0, 0, 0);
    xcb_flush(wm->conn);

    free(pixels);
    free(rgba);
    return true;
}

void bwm_load_config(BwmWM *wm, const char *path)
{
    if (path == NULL || *path == '\0') {
        return;
    }

    lua_State *L = luaL_newstate();
    if (L == NULL) {
        fprintf(stderr, "[bwm] warning: could not allocate Lua state for %s\n", path);
        return;
    }

    luaL_openlibs(L);

    if (luaL_loadfile(L, path) != LUA_OK) {
        fprintf(stderr, "[bwm] warning: could not load config %s: %s\n",
                path, lua_tostring(L, -1));
        lua_close(L);
        return;
    }

    if (lua_pcall(L, 0, 1, 0) != LUA_OK) {
        fprintf(stderr, "[bwm] warning: config %s failed: %s\n",
                path, lua_tostring(L, -1));
        lua_close(L);
        return;
    }

    if (!lua_istable(L, -1)) {
        fprintf(stderr, "[bwm] warning: config %s did not return a table\n", path);
        lua_close(L);
        return;
    }

    load_config_table(L, wm);

    lua_close(L);
}

void bwm_apply_root_background(BwmWM *wm)
{
    if (wm->conn == NULL) {
        return;
    }

    if (wm->root_background != XCB_NONE) {
        xcb_free_pixmap(wm->conn, wm->root_background);
        wm->root_background = XCB_NONE;
    }

    if (wm->config.root_image[0] != '\0' && upload_root_image(wm, wm->config.root_image)) {
        return;
    }

    if (wm->config.root_image[0] != '\0') {
        fprintf(stderr, "[bwm] warning: could not load root image %s, using solid color\n",
                wm->config.root_image);
    }

    uint32_t pixel = wm->config.root_color;
    xcb_change_window_attributes(wm->conn, wm->root, XCB_CW_BACK_PIXEL, &pixel);
    xcb_clear_area(wm->conn, 0, wm->root, 0, 0, 0, 0);
    xcb_flush(wm->conn);
}
