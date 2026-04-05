#define _POSIX_C_SOURCE 200809L

#include "bwm.h"

#include <errno.h>
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <signal.h>

#include <xcb/xcb.h>
#include <xcb/xtest.h>

/* shared running flag, set by main via signal */
extern volatile sig_atomic_t g_bwm_running;

/* -------------------------------------------------------------------------
 * Individual event handlers
 * ---------------------------------------------------------------------- */

static void on_map_request(BwmWM *wm, const xcb_map_request_event_t *ev)
{
    if (bwm_find_by_client(wm, ev->window) != NULL) {
        xcb_map_window(wm->conn, ev->window);
        xcb_flush(wm->conn);
        return;
    }

    xcb_get_window_attributes_cookie_t ck = xcb_get_window_attributes(wm->conn, ev->window);
    xcb_get_window_attributes_reply_t *at = xcb_get_window_attributes_reply(wm->conn, ck, NULL);
    if (at != NULL) {
        bool skip = at->override_redirect != 0;
        free(at);
        if (skip) {
            xcb_map_window(wm->conn, ev->window);
            xcb_flush(wm->conn);
            return;
        }
    }

    BwmClient *c = bwm_frame_window(wm, ev->window, false);
    if (c != NULL) {
        bwm_client_insert(wm, c);
        bwm_set_focus(wm, c);
    }
}

static void on_unmap_notify(BwmWM *wm, const xcb_unmap_notify_event_t *ev)
{
    BwmClient *c = bwm_find_by_client(wm, ev->window);
    if (c == NULL || !c->mapped) return;
    c->mapped = false;
    xcb_unmap_window(wm->conn, c->frame);
    xcb_flush(wm->conn);
}

static void on_destroy_notify(BwmWM *wm, const xcb_destroy_notify_event_t *ev)
{
    BwmClient *c = bwm_find_by_client(wm, ev->window);
    if (c != NULL) bwm_unframe(wm, c);
}

static void on_configure_request(BwmWM *wm, const xcb_configure_request_event_t *ev)
{
    BwmClient *c = bwm_find_by_client(wm, ev->window);

    if (c == NULL) {
        uint32_t vals[7];
        uint16_t mask = ev->value_mask;
        unsigned int n = 0;
        if (mask & XCB_CONFIG_WINDOW_X)            vals[n++] = (uint32_t)ev->x;
        if (mask & XCB_CONFIG_WINDOW_Y)            vals[n++] = (uint32_t)ev->y;
        if (mask & XCB_CONFIG_WINDOW_WIDTH)        vals[n++] = ev->width;
        if (mask & XCB_CONFIG_WINDOW_HEIGHT)       vals[n++] = ev->height;
        if (mask & XCB_CONFIG_WINDOW_BORDER_WIDTH) vals[n++] = ev->border_width;
        if (mask & XCB_CONFIG_WINDOW_SIBLING)      vals[n++] = ev->sibling;
        if (mask & XCB_CONFIG_WINDOW_STACK_MODE)   vals[n++] = ev->stack_mode;
        xcb_configure_window(wm->conn, ev->window, mask, vals);
        xcb_flush(wm->conn);
        return;
    }

    uint16_t nw = c->client_w, nh = c->client_h;
    int16_t  nx = c->x,        ny = c->y;
    if (ev->value_mask & XCB_CONFIG_WINDOW_WIDTH)  nw = ev->width;
    if (ev->value_mask & XCB_CONFIG_WINDOW_HEIGHT) nh = ev->height;
    if (ev->value_mask & XCB_CONFIG_WINDOW_X)      nx = ev->x;
    if (ev->value_mask & XCB_CONFIG_WINDOW_Y)      ny = ev->y;

    if (nx != c->x || ny != c->y) bwm_move_frame(wm, c, nx, ny);
    if (nw != c->client_w || nh != c->client_h) bwm_resize_frame(wm, c, nw, nh);

    xcb_configure_notify_event_t note;
    memset(&note, 0, sizeof(note));
    note.response_type   = XCB_CONFIGURE_NOTIFY;
    note.event           = c->client;
    note.window          = c->client;
    note.x               = (int16_t)(c->x + BWM_BORDER_WIDTH);
    note.y               = (int16_t)(c->y + BWM_TITLEBAR_HEIGHT + BWM_BORDER_WIDTH);
    note.width           = c->client_w;
    note.height          = c->client_h;
    note.border_width    = 0;
    note.override_redirect = 0;
    xcb_send_event(wm->conn, 0, c->client,
                   XCB_EVENT_MASK_STRUCTURE_NOTIFY, (const char *)&note);
    xcb_flush(wm->conn);
}

static void on_button_press(BwmWM *wm, const xcb_button_press_event_t *ev)
{
    BwmClient *tc = bwm_find_by_titlebar(wm, ev->event);
    if (tc != NULL && ev->detail == XCB_BUTTON_INDEX_1) {
        bwm_set_focus(wm, tc);
        tc->dragging     = true;
        tc->drag_ptr_x   = ev->root_x;
        tc->drag_ptr_y   = ev->root_y;
        tc->drag_frame_x = tc->x;
        tc->drag_frame_y = tc->y;
        tc->pending_x    = tc->x;
        tc->pending_y    = tc->y;
        tc->move_pending = false;
        xcb_grab_pointer(wm->conn, 0, wm->root,
                         XCB_EVENT_MASK_BUTTON_RELEASE | XCB_EVENT_MASK_POINTER_MOTION,
                         XCB_GRAB_MODE_ASYNC, XCB_GRAB_MODE_ASYNC,
                         XCB_NONE, XCB_NONE, XCB_CURRENT_TIME);
        xcb_flush(wm->conn);
        return;
    }

    BwmClient *fc = bwm_find_by_frame(wm, ev->event);
    if (fc == NULL) fc = bwm_find_by_client(wm, ev->event);
    if (fc != NULL) bwm_set_focus(wm, fc);
}

static void on_button_release(BwmWM *wm, const xcb_button_release_event_t *ev)
{
    (void)ev;
    for (BwmClient *c = wm->clients; c; c = c->next) {
        if (c->dragging) {
            c->dragging = false;
            xcb_ungrab_pointer(wm->conn, XCB_CURRENT_TIME);
            xcb_flush(wm->conn);
            break;
        }
    }
}

static void on_motion_notify(BwmWM *wm, const xcb_motion_notify_event_t *ev)
{
    for (BwmClient *c = wm->clients; c; c = c->next) {
        if (!c->dragging) continue;
        int16_t nx = (int16_t)(c->drag_frame_x + (ev->root_x - c->drag_ptr_x));
        int16_t ny = (int16_t)(c->drag_frame_y + (ev->root_y - c->drag_ptr_y));
        c->pending_x = nx;
        c->pending_y = ny;
        c->move_pending = true;
        break;
    }
}

static void on_expose(BwmWM *wm, const xcb_expose_event_t *ev)
{
    if (ev->count != 0) return;
    BwmClient *c = bwm_find_by_titlebar(wm, ev->window);
    if (c != NULL) bwm_redraw_titlebar(wm, c);
}

static void on_focus_in(BwmWM *wm, const xcb_focus_in_event_t *ev)
{
    BwmClient *c = bwm_find_by_client(wm, ev->event);
    if (c == NULL) c = bwm_find_by_frame(wm, ev->event);
    if (c != NULL && wm->focused != c) bwm_set_focus(wm, c);
}

/* -------------------------------------------------------------------------
 * Event loop
 * ---------------------------------------------------------------------- */

int bwm_run(BwmWM *wm)
{
    int x11_fd = xcb_get_file_descriptor(wm->conn);
    if (x11_fd < 0) {
        fprintf(stderr, "[bwm] failed to get X11 fd\n");
        return 1;
    }

    while (g_bwm_running) {
        struct pollfd pfd = { .fd = x11_fd, .events = POLLIN, .revents = 0 };
        int pr = poll(&pfd, 1, 16);
        if (pr < 0) {
            if (errno == EINTR) continue;
            fprintf(stderr, "[bwm] poll error: %s\n", strerror(errno));
            return 1;
        }
        if (pr == 0) continue;
        if (pfd.revents & (POLLERR | POLLHUP | POLLNVAL)) {
            fprintf(stderr, "[bwm] X11 connection closed\n");
            return 1;
        }

        xcb_generic_event_t *ev;
        while ((ev = xcb_poll_for_event(wm->conn)) != NULL) {
            uint8_t type = ev->response_type & 0x7F;
            switch (type) {
                case XCB_MAP_REQUEST:
                    on_map_request(wm, (xcb_map_request_event_t *)ev); break;
                case XCB_UNMAP_NOTIFY:
                    on_unmap_notify(wm, (xcb_unmap_notify_event_t *)ev); break;
                case XCB_DESTROY_NOTIFY:
                    on_destroy_notify(wm, (xcb_destroy_notify_event_t *)ev); break;
                case XCB_CONFIGURE_REQUEST:
                    on_configure_request(wm, (xcb_configure_request_event_t *)ev); break;
                case XCB_BUTTON_PRESS:
                    on_button_press(wm, (xcb_button_press_event_t *)ev); break;
                case XCB_BUTTON_RELEASE:
                    on_button_release(wm, (xcb_button_release_event_t *)ev); break;
                case XCB_MOTION_NOTIFY:
                    on_motion_notify(wm, (xcb_motion_notify_event_t *)ev); break;
                case XCB_EXPOSE:
                    on_expose(wm, (xcb_expose_event_t *)ev); break;
                case XCB_FOCUS_IN:
                    on_focus_in(wm, (xcb_focus_in_event_t *)ev); break;
                default:
                    break;
            }
            free(ev);
        }

        bwm_commit_motion_updates(wm);
        xcb_flush(wm->conn);

        if (xcb_connection_has_error(wm->conn)) {
            fprintf(stderr, "[bwm] X11 connection error\n");
            return 1;
        }
    }

    return 0;
}
