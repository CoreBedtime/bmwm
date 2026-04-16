#define _POSIX_C_SOURCE 200809L

#include "lua_config.h"

#include <lua.h>
#include <lauxlib.h>
#include <lualib.h>

#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static const char *applicator_log_prefix(const char *log_prefix)
{
    return log_prefix != NULL ? log_prefix : "[config]";
}

static int applicator_lua_set_font_file(lua_State *L)
{
    const char *value = luaL_checkstring(L, 1);
    luaL_argcheck(L, value[0] != '\0', 1, "SetFontFile expects a non-empty string");

    if (setenv(APPLICATOR_LUA_FONT_FILE_ENV, value, 1) != 0) {
        int err = errno;
        return luaL_error(L, "SetFontFile failed to update %s: %s",
                          APPLICATOR_LUA_FONT_FILE_ENV,
                          strerror(err));
    }

    return 0;
}

static int applicator_lua_set_font_family(lua_State *L)
{
    const char *value = luaL_checkstring(L, 1);
    luaL_argcheck(L, value[0] != '\0', 1, "SetFontFamily expects a non-empty string");

    if (setenv(APPLICATOR_LUA_FONT_FAMILY_ENV, value, 1) != 0) {
        int err = errno;
        return luaL_error(L, "SetFontFamily failed to update %s: %s",
                          APPLICATOR_LUA_FONT_FAMILY_ENV,
                          strerror(err));
    }

    return 0;
}

static void applicator_lua_register_patch_api(lua_State *L)
{
    lua_pushcfunction(L, applicator_lua_set_font_file);
    lua_setglobal(L, "SetFontFile");

    lua_pushcfunction(L, applicator_lua_set_font_family);
    lua_setglobal(L, "SetFontFamily");
}

static bool applicator_lua_execute_file(const char *path,
                                        bool register_patch_api,
                                        const char *log_prefix)
{
    if (path == NULL || *path == '\0') {
        return true;
    }

    lua_State *L = luaL_newstate();
    if (L == NULL) {
        fprintf(stderr, "%s warning: could not allocate Lua state for %s\n",
                applicator_log_prefix(log_prefix),
                path);
        return false;
    }

    luaL_openlibs(L);
    if (register_patch_api) {
        applicator_lua_register_patch_api(L);
    }

    if (luaL_loadfile(L, path) != LUA_OK) {
        fprintf(stderr, "%s warning: could not load config %s: %s\n",
                applicator_log_prefix(log_prefix),
                path,
                lua_tostring(L, -1));
        lua_close(L);
        return false;
    }

    if (lua_pcall(L, 0, LUA_MULTRET, 0) != LUA_OK) {
        fprintf(stderr, "%s warning: config %s failed: %s\n",
                applicator_log_prefix(log_prefix),
                path,
                lua_tostring(L, -1));
        lua_close(L);
        return false;
    }

    lua_close(L);
    return true;
}

bool applicator_lua_config_load_patches(const char *path, const char *log_prefix)
{
    return applicator_lua_execute_file(path, true, log_prefix);
}

bool applicator_lua_config_load_server(const char *path, const char *log_prefix)
{
    return applicator_lua_execute_file(path, false, log_prefix);
}
