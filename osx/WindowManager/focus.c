#define _POSIX_C_SOURCE 200809L

#include "bwm.h"

#include <xcb/xcb.h>

void bwm_set_focus(BwmWM *wm, BwmClient *c)
{
    if (wm->focused == c) return;

    if (wm->focused != NULL) {
        wm->focused->focused = false;
        bwm_redraw_titlebar(wm, wm->focused);
    }

    wm->focused = c;

    if (c != NULL) {
        c->focused = true;
        bwm_redraw_titlebar(wm, c);

        uint32_t stack = XCB_STACK_MODE_ABOVE;
        xcb_configure_window(wm->conn, c->frame, XCB_CONFIG_WINDOW_STACK_MODE, &stack);
        xcb_configure_window(wm->conn, wm->cursor_win, XCB_CONFIG_WINDOW_STACK_MODE, &stack);
        xcb_set_input_focus(wm->conn, XCB_INPUT_FOCUS_POINTER_ROOT,
                            c->client, XCB_CURRENT_TIME);
    }

    xcb_flush(wm->conn);
}
