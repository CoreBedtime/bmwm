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

/* -------------------------------------------------------------------------
 * Init / destroy
 * ---------------------------------------------------------------------- */

int bwm_init(BwmWM *wm)
{
    memset(wm, 0, sizeof(*wm));

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

    xcb_flush(wm->conn);

    fprintf(stdout, "[bwm] running on display %s (%ux%u)\n",
            getenv("DISPLAY") ? getenv("DISPLAY") : ":0",
            wm->root_w, wm->root_h);
    fflush(stdout);
    return 0;
}

void bwm_destroy(BwmWM *wm)
{
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
