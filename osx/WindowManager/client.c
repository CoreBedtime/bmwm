#define _POSIX_C_SOURCE 200809L

#include "bwm.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <xcb/xcb.h>

/* -------------------------------------------------------------------------
 * Client list
 * ---------------------------------------------------------------------- */

void bwm_client_insert(BwmWM *wm, BwmClient *c)
{
    c->next     = wm->clients;
    wm->clients = c;
}

void bwm_client_remove(BwmWM *wm, BwmClient *c)
{
    if (wm->clients == c) { wm->clients = c->next; return; }
    for (BwmClient *p = wm->clients; p != NULL; p = p->next) {
        if (p->next == c) { p->next = c->next; return; }
    }
}

BwmClient *bwm_find_by_frame(BwmWM *wm, xcb_window_t w)
{
    for (BwmClient *c = wm->clients; c; c = c->next)
        if (c->frame == w) return c;
    return NULL;
}

BwmClient *bwm_find_by_titlebar(BwmWM *wm, xcb_window_t w)
{
    for (BwmClient *c = wm->clients; c; c = c->next)
        if (c->titlebar == w) return c;
    return NULL;
}

BwmClient *bwm_find_by_client(BwmWM *wm, xcb_window_t w)
{
    for (BwmClient *c = wm->clients; c; c = c->next)
        if (c->client == w) return c;
    return NULL;
}

BwmClient *bwm_find_by_button(BwmWM *wm, xcb_window_t w, BwmButton *which_out)
{
    for (BwmClient *c = wm->clients; c; c = c->next) {
        for (int b = 0; b < BWM_BTN_COUNT; ++b) {
            if (c->buttons[b] == w) {
                if (which_out) *which_out = (BwmButton)b;
                return c;
            }
        }
    }
    return NULL;
}

/* -------------------------------------------------------------------------
 * Geometry helpers
 * ---------------------------------------------------------------------- */

uint16_t bwm_frame_w(uint16_t client_w)
{
    return client_w + 2 * BWM_BORDER_WIDTH;
}

uint16_t bwm_frame_h(uint16_t client_h)
{
    return client_h + BWM_TITLEBAR_HEIGHT + 2 * BWM_BORDER_WIDTH;
}

/* Button x positions, right-aligned: close(0) max(2) min(1) from the right */
int16_t bwm_btn_x(BwmClient *c, int b)
{
    int slot;
    switch (b) {
        case BWM_BTN_CLOSE:    slot = 0; break;
        case BWM_BTN_MAXIMISE: slot = 1; break;
        case BWM_BTN_MINIMISE: slot = 2; break;
        default:               slot = b; break;
    }
    return (int16_t)(c->client_w - BWM_BTN_MARGIN
                     - (slot + 1) * (BWM_BTN_SIZE + BWM_BTN_MARGIN));
}

int16_t bwm_btn_y(void)
{
    return (int16_t)((BWM_TITLEBAR_HEIGHT - BWM_BTN_SIZE) / 2);
}

/* -------------------------------------------------------------------------
 * Drawing
 * ---------------------------------------------------------------------- */

static xcb_gcontext_t make_gc(BwmWM *wm, uint32_t colour)
{
    xcb_gcontext_t gc = xcb_generate_id(wm->conn);
    uint32_t mask = XCB_GC_FOREGROUND | XCB_GC_BACKGROUND | XCB_GC_GRAPHICS_EXPOSURES;
    uint32_t vals[] = { colour, colour, 0 };
    xcb_create_gc(wm->conn, gc, wm->root, mask, vals);
    return gc;
}

static void fill_rect(BwmWM *wm, xcb_drawable_t d, xcb_gcontext_t gc,
                      int16_t x, int16_t y, uint16_t w, uint16_t h)
{
    xcb_rectangle_t r = { x, y, w, h };
    xcb_poly_fill_rectangle(wm->conn, d, gc, 1, &r);
}

void bwm_redraw_titlebar(BwmWM *wm, BwmClient *c)
{
    uint32_t bg = c->focused ? BWM_COLOR_TITLE_FOCUS : BWM_COLOR_TITLE_BG;
    xcb_gcontext_t gc = make_gc(wm, bg);
    fill_rect(wm, c->titlebar, gc, 0, 0, c->client_w, BWM_TITLEBAR_HEIGHT);
    xcb_free_gc(wm->conn, gc);

    static const uint32_t btn_colours[BWM_BTN_COUNT] = {
        BWM_COLOR_BTN_CLOSE,
        BWM_COLOR_BTN_MIN,
        BWM_COLOR_BTN_MAX,
    };
    for (int b = 0; b < BWM_BTN_COUNT; ++b) {
        xcb_gcontext_t bgc = make_gc(wm, btn_colours[b]);
        fill_rect(wm, c->buttons[b], bgc, 0, 0, BWM_BTN_SIZE, BWM_BTN_SIZE);
        xcb_free_gc(wm->conn, bgc);
    }
    xcb_flush(wm->conn);
}

/* -------------------------------------------------------------------------
 * Move / resize
 * ---------------------------------------------------------------------- */

void bwm_move_frame(BwmWM *wm, BwmClient *c, int16_t x, int16_t y)
{
    c->x = x; c->y = y;
    uint32_t vals[] = { (uint32_t)x, (uint32_t)y };
    xcb_configure_window(wm->conn, c->frame,
                         XCB_CONFIG_WINDOW_X | XCB_CONFIG_WINDOW_Y, vals);
    xcb_flush(wm->conn);
}

void bwm_resize_frame(BwmWM *wm, BwmClient *c, uint16_t cw, uint16_t ch)
{
    if (cw < BWM_MIN_CLIENT_W) cw = BWM_MIN_CLIENT_W;
    if (ch < BWM_MIN_CLIENT_H) ch = BWM_MIN_CLIENT_H;

    c->client_w = cw; c->client_h = ch;
    c->w = bwm_frame_w(cw); c->h = bwm_frame_h(ch);

    uint32_t fv[] = { c->w, c->h };
    xcb_configure_window(wm->conn, c->frame,
                         XCB_CONFIG_WINDOW_WIDTH | XCB_CONFIG_WINDOW_HEIGHT, fv);

    uint32_t tv[] = { cw, (uint32_t)BWM_TITLEBAR_HEIGHT };
    xcb_configure_window(wm->conn, c->titlebar,
                         XCB_CONFIG_WINDOW_WIDTH | XCB_CONFIG_WINDOW_HEIGHT, tv);

    for (int b = 0; b < BWM_BTN_COUNT; ++b) {
        uint32_t bv[] = { (uint32_t)bwm_btn_x(c, b), (uint32_t)bwm_btn_y() };
        xcb_configure_window(wm->conn, c->buttons[b],
                             XCB_CONFIG_WINDOW_X | XCB_CONFIG_WINDOW_Y, bv);
    }

    uint32_t cv[] = { cw, ch };
    xcb_configure_window(wm->conn, c->client,
                         XCB_CONFIG_WINDOW_WIDTH | XCB_CONFIG_WINDOW_HEIGHT, cv);

    xcb_flush(wm->conn);
    bwm_redraw_titlebar(wm, c);
}

/* -------------------------------------------------------------------------
 * Maximise / restore
 * ---------------------------------------------------------------------- */

void bwm_toggle_maximise(BwmWM *wm, BwmClient *c)
{
    if (!c->maximised) {
        c->saved_x = c->x; c->saved_y = c->y;
        c->saved_w = c->client_w; c->saved_h = c->client_h;
        c->maximised = true;
        uint16_t nw = (uint16_t)(wm->root_w - 2 * BWM_BORDER_WIDTH);
        uint16_t nh = (uint16_t)(wm->root_h - BWM_TITLEBAR_HEIGHT - 2 * BWM_BORDER_WIDTH);
        bwm_move_frame(wm, c, 0, 0);
        bwm_resize_frame(wm, c, nw, nh);
    } else {
        c->maximised = false;
        bwm_move_frame(wm, c, c->saved_x, c->saved_y);
        bwm_resize_frame(wm, c, c->saved_w, c->saved_h);
    }
}

/* -------------------------------------------------------------------------
 * Close
 * ---------------------------------------------------------------------- */

void bwm_close_client(BwmWM *wm, BwmClient *c)
{
    xcb_get_property_cookie_t ck = xcb_get_property(wm->conn, 0, c->client,
                                                     wm->atom_wm_protocols,
                                                     XCB_ATOM_ATOM, 0, 64);
    xcb_get_property_reply_t *rp = xcb_get_property_reply(wm->conn, ck, NULL);
    bool supports_delete = false;
    if (rp != NULL) {
        xcb_atom_t *atoms = (xcb_atom_t *)xcb_get_property_value(rp);
        int len = xcb_get_property_value_length(rp) / (int)sizeof(xcb_atom_t);
        for (int i = 0; i < len; ++i) {
            if (atoms[i] == wm->atom_wm_delete_window) { supports_delete = true; break; }
        }
        free(rp);
    }

    if (supports_delete) {
        xcb_client_message_event_t ev;
        memset(&ev, 0, sizeof(ev));
        ev.response_type  = XCB_CLIENT_MESSAGE;
        ev.format         = 32;
        ev.window         = c->client;
        ev.type           = wm->atom_wm_protocols;
        ev.data.data32[0] = wm->atom_wm_delete_window;
        ev.data.data32[1] = XCB_CURRENT_TIME;
        xcb_send_event(wm->conn, 0, c->client, XCB_EVENT_MASK_NO_EVENT, (const char *)&ev);
    } else {
        xcb_kill_client(wm->conn, c->client);
    }
    xcb_flush(wm->conn);
}

/* -------------------------------------------------------------------------
 * Frame / unframe
 * ---------------------------------------------------------------------- */

BwmClient *bwm_frame_window(BwmWM *wm, xcb_window_t client_win, bool already_mapped)
{
    xcb_get_geometry_cookie_t geo_ck = xcb_get_geometry(wm->conn, client_win);
    xcb_get_geometry_reply_t *geo    = xcb_get_geometry_reply(wm->conn, geo_ck, NULL);
    if (geo == NULL) return NULL;

    uint16_t cw = geo->width;
    uint16_t ch = geo->height;
    int16_t  cx = geo->x;
    int16_t  cy = geo->y;
    free(geo);

    if (cw < BWM_MIN_CLIENT_W) cw = BWM_MIN_CLIENT_W;
    if (ch < BWM_MIN_CLIENT_H) ch = BWM_MIN_CLIENT_H;

    BwmClient *c = (BwmClient *)calloc(1, sizeof(BwmClient));
    if (c == NULL) return NULL;

    c->client   = client_win;
    c->x        = cx; c->y = cy;
    c->client_w = cw; c->client_h = ch;
    c->w        = bwm_frame_w(cw); c->h = bwm_frame_h(ch);

    /* frame */
    c->frame = xcb_generate_id(wm->conn);
    uint32_t fm = XCB_CW_BACK_PIXEL | XCB_CW_BORDER_PIXEL | XCB_CW_EVENT_MASK;
    uint32_t fv[] = {
        BWM_COLOR_FRAME_BG, BWM_COLOR_BORDER,
        XCB_EVENT_MASK_SUBSTRUCTURE_REDIRECT | XCB_EVENT_MASK_SUBSTRUCTURE_NOTIFY |
        XCB_EVENT_MASK_BUTTON_PRESS | XCB_EVENT_MASK_BUTTON_RELEASE |
        XCB_EVENT_MASK_BUTTON_MOTION | XCB_EVENT_MASK_FOCUS_CHANGE | XCB_EVENT_MASK_EXPOSURE,
    };
    xcb_create_window(wm->conn, XCB_COPY_FROM_PARENT, c->frame, wm->root,
                      cx, cy, c->w, c->h, BWM_BORDER_WIDTH,
                      XCB_WINDOW_CLASS_INPUT_OUTPUT, wm->screen->root_visual, fm, fv);

    /* title bar */
    c->titlebar = xcb_generate_id(wm->conn);
    uint32_t tm = XCB_CW_BACK_PIXEL | XCB_CW_EVENT_MASK;
    uint32_t tv[] = {
        BWM_COLOR_TITLE_BG,
        XCB_EVENT_MASK_BUTTON_PRESS | XCB_EVENT_MASK_BUTTON_RELEASE |
        XCB_EVENT_MASK_BUTTON_MOTION | XCB_EVENT_MASK_EXPOSURE,
    };
    xcb_create_window(wm->conn, XCB_COPY_FROM_PARENT, c->titlebar, c->frame,
                      0, 0, cw, BWM_TITLEBAR_HEIGHT, 0,
                      XCB_WINDOW_CLASS_INPUT_OUTPUT, wm->screen->root_visual, tm, tv);

    /* buttons */
    static const uint32_t btn_colours[BWM_BTN_COUNT] = {
        BWM_COLOR_BTN_CLOSE, BWM_COLOR_BTN_MIN, BWM_COLOR_BTN_MAX,
    };
    for (int b = 0; b < BWM_BTN_COUNT; ++b) {
        c->buttons[b] = xcb_generate_id(wm->conn);
        uint32_t bm = XCB_CW_BACK_PIXEL | XCB_CW_EVENT_MASK;
        uint32_t bv[] = { btn_colours[b], XCB_EVENT_MASK_BUTTON_PRESS | XCB_EVENT_MASK_EXPOSURE };
        xcb_create_window(wm->conn, XCB_COPY_FROM_PARENT, c->buttons[b], c->titlebar,
                          bwm_btn_x(c, b), bwm_btn_y(), BWM_BTN_SIZE, BWM_BTN_SIZE, 0,
                          XCB_WINDOW_CLASS_INPUT_OUTPUT, wm->screen->root_visual, bm, bv);
        xcb_map_window(wm->conn, c->buttons[b]);
    }

    /* reparent */
    if (already_mapped) xcb_unmap_window(wm->conn, client_win);
    xcb_reparent_window(wm->conn, client_win, c->frame,
                        BWM_BORDER_WIDTH, BWM_TITLEBAR_HEIGHT + BWM_BORDER_WIDTH);

    uint32_t cm = XCB_CW_EVENT_MASK;
    uint32_t cv[] = { XCB_EVENT_MASK_PROPERTY_CHANGE | XCB_EVENT_MASK_STRUCTURE_NOTIFY };
    xcb_change_window_attributes(wm->conn, client_win, cm, cv);

    xcb_map_window(wm->conn, c->titlebar);
    xcb_map_window(wm->conn, c->frame);
    xcb_map_window(wm->conn, client_win);

    c->mapped = true;
    xcb_flush(wm->conn);
    bwm_redraw_titlebar(wm, c);
    return c;
}

void bwm_unframe(BwmWM *wm, BwmClient *c)
{
    bwm_client_remove(wm, c);
    if (wm->focused == c) wm->focused = NULL;

    xcb_unmap_window(wm->conn, c->client);
    xcb_reparent_window(wm->conn, c->client, wm->root, c->x, c->y);
    for (int b = 0; b < BWM_BTN_COUNT; ++b)
        xcb_destroy_window(wm->conn, c->buttons[b]);
    xcb_destroy_window(wm->conn, c->titlebar);
    xcb_destroy_window(wm->conn, c->frame);
    xcb_flush(wm->conn);
    free(c);
}

/* -------------------------------------------------------------------------
 * Adopt pre-existing windows
 * ---------------------------------------------------------------------- */

void bwm_adopt_existing_windows(BwmWM *wm)
{
    xcb_query_tree_cookie_t ck = xcb_query_tree(wm->conn, wm->root);
    xcb_query_tree_reply_t *rp = xcb_query_tree_reply(wm->conn, ck, NULL);
    if (rp == NULL) return;

    xcb_window_t *children = xcb_query_tree_children(rp);
    int n = xcb_query_tree_children_length(rp);

    for (int i = 0; i < n; ++i) {
        xcb_get_window_attributes_cookie_t ac = xcb_get_window_attributes(wm->conn, children[i]);
        xcb_get_window_attributes_reply_t *at = xcb_get_window_attributes_reply(wm->conn, ac, NULL);
        if (at == NULL) continue;
        bool skip = at->override_redirect || at->map_state != XCB_MAP_STATE_VIEWABLE;
        free(at);
        if (skip) continue;

        BwmClient *c = bwm_frame_window(wm, children[i], true);
        if (c != NULL) bwm_client_insert(wm, c);
    }
    free(rp);
    xcb_flush(wm->conn);
}
