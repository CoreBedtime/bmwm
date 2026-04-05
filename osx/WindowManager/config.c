#define _POSIX_C_SOURCE 200809L

#include "bwm.h"

#include <lua.h>
#include <lauxlib.h>
#include <lualib.h>

#include <stdio.h>

static bool load_number_field(lua_State *L, int table_index, const char *name, uint32_t *dst)
{
    lua_getfield(L, table_index, name);
    if (lua_isnumber(L, -1)) {
        *dst = (uint32_t)lua_tointeger(L, -1);
        lua_pop(L, 1);
        return true;
    }
    lua_pop(L, 1);
    return false;
}

static void load_number_field_alias(lua_State *L,
                                    int table_index,
                                    const char *primary,
                                    const char *legacy,
                                    uint32_t *dst)
{
    if (load_number_field(L, table_index, primary, dst)) {
        return;
    }

    if (legacy != NULL) {
        (void)load_number_field(L, table_index, legacy, dst);
    }
}

static void load_config_table(lua_State *L, BwmWM *wm)
{
    load_number_field_alias(L, -1, "background_color", "root_color", &wm->config.root_color);
    load_number_field(L, -1, "titlebar_color", &wm->config.titlebar_color);
    load_number_field(L, -1, "titlebar_focus_color", &wm->config.titlebar_focus_color);
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

    uint32_t pixel = wm->config.root_color;
    xcb_change_window_attributes(wm->conn, wm->root, XCB_CW_BACK_PIXEL, &pixel);
    xcb_clear_area(wm->conn, 0, wm->root, 0, 0, 0, 0);
    xcb_flush(wm->conn);
}
