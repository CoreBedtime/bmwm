#define _POSIX_C_SOURCE 200809L

#include "bwm.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <xcb/xcb.h>

/* -------------------------------------------------------------------------
 * Atom helper
 * ---------------------------------------------------------------------- */

static xcb_atom_t bwm_intern_atom(xcb_connection_t *conn, const char *name)
{
    xcb_intern_atom_cookie_t ck = xcb_intern_atom(conn, 0, (uint16_t)strlen(name), name);
    xcb_intern_atom_reply_t *rp = xcb_intern_atom_reply(conn, ck, NULL);
    if (rp == NULL) return XCB_ATOM_NONE;
    xcb_atom_t atom = rp->atom;
    free(rp);
    return atom;
}

static void bwm_set_default_config(BwmWM *wm)
{
    wm->config.root_color = 0xFFFFFFFF;
    wm->config.titlebar_color = BWM_COLOR_TITLE_BG;
    wm->config.titlebar_focus_color = BWM_COLOR_TITLE_FOCUS;
}

static bool env_flag(const char *name)
{
    const char *value = getenv(name);
    return value != NULL && *value != '\0' && strcmp(value, "0") != 0;
}

static xcb_gcontext_t make_gc(BwmWM *wm, xcb_drawable_t drawable, uint32_t foreground, uint32_t line_width)
{
    xcb_gcontext_t gc = xcb_generate_id(wm->conn);
    uint32_t mask = XCB_GC_FOREGROUND | XCB_GC_GRAPHICS_EXPOSURES | XCB_GC_LINE_WIDTH;
    uint32_t vals[] = { foreground, 0, line_width };
    xcb_create_gc(wm->conn, gc, drawable, mask, vals);
    return gc;
}

static void draw_exit_button(BwmWM *wm)
{
    if (wm->exit_button == XCB_NONE) {
        return;
    }

    uint16_t width = BWM_EXIT_BUTTON_W;
    uint16_t height = BWM_EXIT_BUTTON_H;

    xcb_gcontext_t bg_gc = make_gc(wm, wm->exit_button, BWM_COLOR_EXIT_BG, 0);
    xcb_rectangle_t rect = { 0, 0, width, height };
    xcb_poly_fill_rectangle(wm->conn, wm->exit_button, bg_gc, 1, &rect);
    xcb_free_gc(wm->conn, bg_gc);

    xcb_gcontext_t gc = make_gc(wm, wm->exit_button, BWM_COLOR_EXIT_FG, 2);
    xcb_segment_t segments[2] = {
        { 6, 6, (int16_t)(width - 7), (int16_t)(height - 7) },
        { 6, (int16_t)(height - 7), (int16_t)(width - 7), 6 }
    };
    xcb_poly_segment(wm->conn, wm->exit_button, gc, 2, segments);
    xcb_free_gc(wm->conn, gc);
}

void bwm_redraw_exit_button(BwmWM *wm)
{
    draw_exit_button(wm);
}

static void create_exit_button(BwmWM *wm)
{
    if (!wm->exit_button_enabled || wm->exit_button != XCB_NONE) {
        return;
    }

    wm->exit_button = xcb_generate_id(wm->conn);

    uint16_t width = BWM_EXIT_BUTTON_W;
    uint16_t height = BWM_EXIT_BUTTON_H;
    int16_t x = 8;
    int16_t y = 8;
    if (wm->root_w > (uint16_t)(width + 16)) {
        x = (int16_t)(wm->root_w - width - 8);
    }
    if (wm->root_h <= (uint16_t)(height + 16)) {
        y = 0;
    }

    uint32_t mask = XCB_CW_BACK_PIXEL | XCB_CW_OVERRIDE_REDIRECT | XCB_CW_EVENT_MASK;
    uint32_t vals[] = {
        BWM_COLOR_EXIT_BG,
        1,
        XCB_EVENT_MASK_BUTTON_PRESS | XCB_EVENT_MASK_EXPOSURE
    };
    xcb_create_window(wm->conn, XCB_COPY_FROM_PARENT, wm->exit_button, wm->root,
                      x, y, width, height, 0,
                      XCB_WINDOW_CLASS_INPUT_OUTPUT, wm->screen->root_visual, mask, vals);
    xcb_map_window(wm->conn, wm->exit_button);
    uint32_t stack = XCB_STACK_MODE_ABOVE;
    xcb_configure_window(wm->conn, wm->exit_button,
                         XCB_CONFIG_WINDOW_STACK_MODE, &stack);
    draw_exit_button(wm);
    xcb_flush(wm->conn);

    fprintf(stdout, "[bwm] exit button enabled via BWM_ENABLE_EXIT_BUTTON\n");
    fflush(stdout);
}

/* -------------------------------------------------------------------------
 * Init / destroy
 * ---------------------------------------------------------------------- */

int bwm_init(BwmWM *wm)
{
    memset(wm, 0, sizeof(*wm));
    wm->exit_button = XCB_NONE;
    wm->exit_button_enabled = env_flag("BWM_ENABLE_EXIT_BUTTON");

    int screen_index = 0;
    wm->conn = xcb_connect(NULL, &screen_index);
    if (wm->conn == NULL || xcb_connection_has_error(wm->conn)) {
        fprintf(stderr, "[bwm] cannot connect to X display ($DISPLAY=%s)\n",
                getenv("DISPLAY") ? getenv("DISPLAY") : "(unset)");
        return 1;
    }

    xcb_screen_iterator_t it = xcb_setup_roots_iterator(xcb_get_setup(wm->conn));
    for (int i = 0; i < screen_index; ++i) xcb_screen_next(&it);
    wm->screen = it.data;
    wm->root   = wm->screen->root;
    wm->root_w = wm->screen->width_in_pixels;
    wm->root_h = wm->screen->height_in_pixels;
    bwm_set_default_config(wm);

    /* cursor starts centred */
    wm->cursor_x = wm->root_w * 0.5f;
    wm->cursor_y = wm->root_h * 0.5f;

    wm->atom_wm_delete_window = bwm_intern_atom(wm->conn, "WM_DELETE_WINDOW");
    wm->atom_wm_protocols     = bwm_intern_atom(wm->conn, "WM_PROTOCOLS");
    wm->atom_wm_state         = bwm_intern_atom(wm->conn, "WM_STATE");
    wm->atom_net_wm_name      = bwm_intern_atom(wm->conn, "_NET_WM_NAME");
    wm->atom_utf8_string      = bwm_intern_atom(wm->conn, "UTF8_STRING");

    uint32_t root_events = XCB_EVENT_MASK_SUBSTRUCTURE_REDIRECT |
                           XCB_EVENT_MASK_SUBSTRUCTURE_NOTIFY   |
                           XCB_EVENT_MASK_BUTTON_PRESS          |
                           XCB_EVENT_MASK_FOCUS_CHANGE;

    xcb_void_cookie_t ck = xcb_change_window_attributes_checked(
        wm->conn, wm->root, XCB_CW_EVENT_MASK, &root_events);
    xcb_generic_error_t *err = xcb_request_check(wm->conn, ck);
    if (err != NULL) {
        fprintf(stderr, "[bwm] another window manager is already running (error %d)\n",
                err->error_code);
        free(err);
        return 1;
    }

    xcb_atom_t wm_s0 = bwm_intern_atom(wm->conn, "WM_S0");
    if (wm_s0 != XCB_ATOM_NONE) {
        xcb_set_selection_owner(wm->conn, wm->root, wm_s0, XCB_CURRENT_TIME);
    }

    bwm_load_config(wm, getenv("BWM_CONFIG"));
    bwm_apply_root_background(wm);

    /* Create a 6x6 red square cursor window */
    wm->cursor_win = xcb_generate_id(wm->conn);
    uint32_t cursor_mask = XCB_CW_BACK_PIXEL | XCB_CW_OVERRIDE_REDIRECT;
    uint32_t cursor_vals[] = { 0xFF0000, 1 }; /* bright red, override_redirect = 1 */
    xcb_create_window(wm->conn, XCB_COPY_FROM_PARENT, wm->cursor_win, wm->root,
                      (int16_t)wm->cursor_x, (int16_t)wm->cursor_y,
                      6, 6, 0, XCB_WINDOW_CLASS_INPUT_OUTPUT,
                      wm->screen->root_visual, cursor_mask, cursor_vals);
    xcb_map_window(wm->conn, wm->cursor_win);
    uint32_t cursor_stack = XCB_STACK_MODE_ABOVE;
    xcb_configure_window(wm->conn, wm->cursor_win,
                         XCB_CONFIG_WINDOW_STACK_MODE, &cursor_stack);

    create_exit_button(wm);
    xcb_flush(wm->conn);

    fprintf(stdout, "[bwm] running on display %s (%ux%u)\n",
            getenv("DISPLAY") ? getenv("DISPLAY") : ":0",
            wm->root_w, wm->root_h);
    fflush(stdout);
    return 0;
}

void bwm_destroy(BwmWM *wm)
{
    if (wm->exit_button != XCB_NONE) {
        xcb_destroy_window(wm->conn, wm->exit_button);
        wm->exit_button = XCB_NONE;
    }

    while (wm->clients != NULL) {
        BwmClient *c = wm->clients;
        bwm_client_remove(wm, c);
        xcb_reparent_window(wm->conn, c->client, wm->root, c->x, c->y);
        xcb_map_window(wm->conn, c->client);
        xcb_destroy_window(wm->conn, c->titlebar);
        xcb_destroy_window(wm->conn, c->frame);
        free(c);
    }
    if (wm->conn != NULL && wm->root != XCB_NONE) {
        uint32_t pixel = wm->config.root_color;
        xcb_change_window_attributes(wm->conn, wm->root, XCB_CW_BACK_PIXEL, &pixel);
        xcb_clear_area(wm->conn, 0, wm->root, 0, 0, 0, 0);
    }
    if (wm->conn != NULL) {
        xcb_flush(wm->conn);
        xcb_disconnect(wm->conn);
        wm->conn = NULL;
    }
}
