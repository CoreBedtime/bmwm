#define _POSIX_C_SOURCE 200809L

#include "bwm.h"
#include "lua_config.h"

#include <stdio.h>

void bwm_load_config(BwmWM *wm, const char *path)
{
    if (path == NULL || *path == '\0') {
        return;
    }

    ApplicatorLuaConfig config;
    applicator_lua_config_init(&config);

    if (!applicator_lua_config_load_file(path, &config, "[bwm]")) {
        return;
    }

    if (config.has_background_color) {
        wm->config.root_color = config.background_color;
    }
    if (config.has_titlebar_color) {
        wm->config.titlebar_color = config.titlebar_color;
    }
    if (config.has_titlebar_focus_color) {
        wm->config.titlebar_focus_color = config.titlebar_focus_color;
    }
    if (config.has_x11_width) {
        wm->config.x11_width = config.x11_width;
        wm->config.has_x11_width = true;
    }
    if (config.has_x11_height) {
        wm->config.x11_height = config.x11_height;
        wm->config.has_x11_height = true;
    }
}

void bwm_apply_root_background(BwmWM *wm)
{
    if (wm->conn == NULL) {
        return;
    }

    uint32_t pixel = wm->config.root_color;
    xcb_change_window_attributes(wm->conn, wm->root, XCB_CW_BACK_PIXEL, &pixel);
    xcb_clear_area(wm->conn, 0, wm->root, 0, 0, 0, 0);
    xcb_flush(wm->conn);
}
