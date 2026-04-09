#define _POSIX_C_SOURCE 200809L

#include "lua_config.h"

#include <lua.h>
#include <lauxlib.h>
#include <lualib.h>

#include <stdio.h>
#include <string.h>

static const char *applicator_log_prefix(const char *log_prefix)
{
    return log_prefix != NULL ? log_prefix : "[config]";
}

void applicator_lua_config_init(ApplicatorLuaConfig *config)
{
    if (config == NULL) {
        return;
    }

    memset(config, 0, sizeof(*config));
}

static ApplicatorLuaConfig *applicator_lua_config_from_upvalue(lua_State *L)
{
    return (ApplicatorLuaConfig *)lua_touserdata(L, lua_upvalueindex(1));
}

static uint32_t applicator_lua_check_u32(lua_State *L, int index, const char *name)
{
    lua_Integer value = luaL_checkinteger(L, index);
    luaL_argcheck(L, value >= 0 && (uint64_t)value <= UINT32_MAX, index, name);
    return (uint32_t)value;
}

static int16_t applicator_lua_check_i16(lua_State *L, int index, const char *name)
{
    lua_Integer value = luaL_checkinteger(L, index);
    luaL_argcheck(L, value >= INT16_MIN && value <= INT16_MAX, index, name);
    return (int16_t)value;
}

static uint16_t applicator_lua_check_u16(lua_State *L, int index, const char *name)
{
    lua_Integer value = luaL_checkinteger(L, index);
    luaL_argcheck(L, value >= 0 && value <= UINT16_MAX, index, name);
    return (uint16_t)value;
}

static uint8_t applicator_lua_check_u8(lua_State *L, int index, const char *name)
{
    lua_Integer value = luaL_checkinteger(L, index);
    luaL_argcheck(L, value >= 0 && value <= UINT8_MAX, index, name);
    return (uint8_t)value;
}

static void applicator_lua_store_string(char *dst, size_t dst_len, const char *value)
{
    if (dst == NULL || dst_len == 0) {
        return;
    }

    if (value == NULL) {
        dst[0] = '\0';
        return;
    }

    snprintf(dst, dst_len, "%s", value);
}

static int applicator_lua_background_color(lua_State *L)
{
    ApplicatorLuaConfig *config = applicator_lua_config_from_upvalue(L);
    config->background_color = applicator_lua_check_u32(L, 1, "background_color expects a 32-bit ARGB integer");
    config->has_background_color = true;
    return 0;
}

static int applicator_lua_background_image(lua_State *L)
{
    ApplicatorLuaConfig *config = applicator_lua_config_from_upvalue(L);
    applicator_lua_store_string(config->background_image,
                                sizeof(config->background_image),
                                luaL_checkstring(L, 1));
    config->has_background_image = true;
    return 0;
}

static int applicator_lua_titlebar_color(lua_State *L)
{
    ApplicatorLuaConfig *config = applicator_lua_config_from_upvalue(L);
    config->titlebar_color = applicator_lua_check_u32(L, 1, "titlebar_color expects a 32-bit ARGB integer");
    config->has_titlebar_color = true;
    return 0;
}

static int applicator_lua_titlebar_focus_color(lua_State *L)
{
    ApplicatorLuaConfig *config = applicator_lua_config_from_upvalue(L);
    config->titlebar_focus_color = applicator_lua_check_u32(L, 1, "titlebar_focus_color expects a 32-bit ARGB integer");
    config->has_titlebar_focus_color = true;
    return 0;
}

static int applicator_lua_shadow_enabled(lua_State *L)
{
    ApplicatorLuaConfig *config = applicator_lua_config_from_upvalue(L);
    luaL_checkany(L, 1);
    config->shadow_enabled = lua_toboolean(L, 1) != 0;
    config->has_shadow_enabled = true;
    return 0;
}

static int applicator_lua_shadow_offset(lua_State *L)
{
    ApplicatorLuaConfig *config = applicator_lua_config_from_upvalue(L);
    config->shadow_x_offset = applicator_lua_check_i16(L, 1, "shadow_offset x must fit in int16");
    config->shadow_y_offset = applicator_lua_check_i16(L, 2, "shadow_offset y must fit in int16");
    config->has_shadow_x_offset = true;
    config->has_shadow_y_offset = true;
    return 0;
}

static int applicator_lua_shadow_x_offset(lua_State *L)
{
    ApplicatorLuaConfig *config = applicator_lua_config_from_upvalue(L);
    config->shadow_x_offset = applicator_lua_check_i16(L, 1, "shadow_x_offset must fit in int16");
    config->has_shadow_x_offset = true;
    return 0;
}

static int applicator_lua_shadow_y_offset(lua_State *L)
{
    ApplicatorLuaConfig *config = applicator_lua_config_from_upvalue(L);
    config->shadow_y_offset = applicator_lua_check_i16(L, 1, "shadow_y_offset must fit in int16");
    config->has_shadow_y_offset = true;
    return 0;
}

static int applicator_lua_shadow_spread(lua_State *L)
{
    ApplicatorLuaConfig *config = applicator_lua_config_from_upvalue(L);
    config->shadow_spread = applicator_lua_check_u16(L, 1, "shadow_spread must fit in uint16");
    config->has_shadow_spread = true;
    return 0;
}

static int applicator_lua_shadow_opacity(lua_State *L)
{
    ApplicatorLuaConfig *config = applicator_lua_config_from_upvalue(L);
    config->shadow_opacity = applicator_lua_check_u8(L, 1, "shadow_opacity must be between 0 and 255");
    config->has_shadow_opacity = true;
    return 0;
}

static int applicator_lua_shadow_color(lua_State *L)
{
    ApplicatorLuaConfig *config = applicator_lua_config_from_upvalue(L);
    config->shadow_color = applicator_lua_check_u32(L, 1, "shadow_color expects a 32-bit ARGB integer");
    config->has_shadow_color = true;
    return 0;
}

static int applicator_lua_x11_width(lua_State *L)
{
    ApplicatorLuaConfig *config = applicator_lua_config_from_upvalue(L);
    config->x11_width = applicator_lua_check_u16(L, 1, "x11_width must fit in uint16");
    config->has_x11_width = true;
    return 0;
}

static int applicator_lua_x11_height(lua_State *L)
{
    ApplicatorLuaConfig *config = applicator_lua_config_from_upvalue(L);
    config->x11_height = applicator_lua_check_u16(L, 1, "x11_height must fit in uint16");
    config->has_x11_height = true;
    return 0;
}

static void applicator_lua_register_function(lua_State *L,
                                             ApplicatorLuaConfig *config,
                                             const char *name,
                                             lua_CFunction fn)
{
    lua_pushlightuserdata(L, config);
    lua_pushcclosure(L, fn, 1);
    lua_setglobal(L, name);
}

static void applicator_lua_register_api(lua_State *L, ApplicatorLuaConfig *config)
{
    applicator_lua_register_function(L, config, "background_color", applicator_lua_background_color);
    applicator_lua_register_function(L, config, "background_image", applicator_lua_background_image);
    applicator_lua_register_function(L, config, "root_color", applicator_lua_background_color);
    applicator_lua_register_function(L, config, "root_image", applicator_lua_background_image);
    applicator_lua_register_function(L, config, "titlebar_color", applicator_lua_titlebar_color);
    applicator_lua_register_function(L, config, "titlebar_focus_color", applicator_lua_titlebar_focus_color);
    applicator_lua_register_function(L, config, "shadow_enabled", applicator_lua_shadow_enabled);
    applicator_lua_register_function(L, config, "shadow_offset", applicator_lua_shadow_offset);
    applicator_lua_register_function(L, config, "shadow_x_offset", applicator_lua_shadow_x_offset);
    applicator_lua_register_function(L, config, "shadow_y_offset", applicator_lua_shadow_y_offset);
    applicator_lua_register_function(L, config, "shadow_spread", applicator_lua_shadow_spread);
    applicator_lua_register_function(L, config, "shadow_opacity", applicator_lua_shadow_opacity);
    applicator_lua_register_function(L, config, "shadow_color", applicator_lua_shadow_color);
    applicator_lua_register_function(L, config, "x11_width", applicator_lua_x11_width);
    applicator_lua_register_function(L, config, "x11_height", applicator_lua_x11_height);
}

static bool applicator_lua_load_u32_field(lua_State *L, int table_index, const char *name, uint32_t *dst)
{
    bool loaded = false;

    lua_getfield(L, table_index, name);
    if (lua_isnumber(L, -1)) {
        lua_Integer value = lua_tointeger(L, -1);
        if (value >= 0 && (uint64_t)value <= UINT32_MAX) {
            *dst = (uint32_t)value;
            loaded = true;
        }
    }
    lua_pop(L, 1);

    return loaded;
}

static bool applicator_lua_load_i16_field(lua_State *L, int table_index, const char *name, int16_t *dst)
{
    bool loaded = false;

    lua_getfield(L, table_index, name);
    if (lua_isnumber(L, -1)) {
        lua_Integer value = lua_tointeger(L, -1);
        if (value >= INT16_MIN && value <= INT16_MAX) {
            *dst = (int16_t)value;
            loaded = true;
        }
    }
    lua_pop(L, 1);

    return loaded;
}

static bool applicator_lua_load_u16_field(lua_State *L, int table_index, const char *name, uint16_t *dst)
{
    bool loaded = false;

    lua_getfield(L, table_index, name);
    if (lua_isnumber(L, -1)) {
        lua_Integer value = lua_tointeger(L, -1);
        if (value >= 0 && value <= UINT16_MAX) {
            *dst = (uint16_t)value;
            loaded = true;
        }
    }
    lua_pop(L, 1);

    return loaded;
}

static bool applicator_lua_load_u8_field(lua_State *L, int table_index, const char *name, uint8_t *dst)
{
    bool loaded = false;

    lua_getfield(L, table_index, name);
    if (lua_isnumber(L, -1)) {
        lua_Integer value = lua_tointeger(L, -1);
        if (value >= 0 && value <= UINT8_MAX) {
            *dst = (uint8_t)value;
            loaded = true;
        }
    }
    lua_pop(L, 1);

    return loaded;
}

static bool applicator_lua_load_bool_field(lua_State *L, int table_index, const char *name, bool *dst)
{
    bool loaded = false;

    lua_getfield(L, table_index, name);
    if (lua_isboolean(L, -1)) {
        *dst = lua_toboolean(L, -1) != 0;
        loaded = true;
    }
    lua_pop(L, 1);

    return loaded;
}

static bool applicator_lua_load_string_field(lua_State *L,
                                             int table_index,
                                             const char *name,
                                             char *dst,
                                             size_t dst_len)
{
    bool loaded = false;

    lua_getfield(L, table_index, name);
    if (lua_isstring(L, -1)) {
        applicator_lua_store_string(dst, dst_len, lua_tostring(L, -1));
        loaded = true;
    }
    lua_pop(L, 1);

    return loaded;
}

static void applicator_lua_apply_legacy_shadow_table(lua_State *L,
                                                     int table_index,
                                                     ApplicatorLuaConfig *config)
{
    lua_getfield(L, table_index, "shadow");
    if (!lua_istable(L, -1)) {
        lua_pop(L, 1);
        return;
    }

    if (applicator_lua_load_bool_field(L, -1, "enabled", &config->shadow_enabled)) {
        config->has_shadow_enabled = true;
    }
    if (applicator_lua_load_i16_field(L, -1, "x_offset", &config->shadow_x_offset) ||
        applicator_lua_load_i16_field(L, -1, "x", &config->shadow_x_offset)) {
        config->has_shadow_x_offset = true;
    }
    if (applicator_lua_load_i16_field(L, -1, "y_offset", &config->shadow_y_offset) ||
        applicator_lua_load_i16_field(L, -1, "y", &config->shadow_y_offset)) {
        config->has_shadow_y_offset = true;
    }
    if (applicator_lua_load_u16_field(L, -1, "spread", &config->shadow_spread)) {
        config->has_shadow_spread = true;
    }
    if (applicator_lua_load_u8_field(L, -1, "opacity", &config->shadow_opacity)) {
        config->has_shadow_opacity = true;
    }
    if (applicator_lua_load_u32_field(L, -1, "color", &config->shadow_color)) {
        config->has_shadow_color = true;
    }

    lua_pop(L, 1);
}

static void applicator_lua_apply_legacy_table(lua_State *L,
                                              int table_index,
                                              ApplicatorLuaConfig *config)
{
    if (applicator_lua_load_u32_field(L, table_index, "background_color", &config->background_color) ||
        applicator_lua_load_u32_field(L, table_index, "root_color", &config->background_color)) {
        config->has_background_color = true;
    }

    if (applicator_lua_load_string_field(L, table_index, "background_image",
                                         config->background_image,
                                         sizeof(config->background_image)) ||
        applicator_lua_load_string_field(L, table_index, "root_image",
                                         config->background_image,
                                         sizeof(config->background_image))) {
        config->has_background_image = true;
    }

    if (applicator_lua_load_u32_field(L, table_index, "titlebar_color", &config->titlebar_color)) {
        config->has_titlebar_color = true;
    }

    if (applicator_lua_load_u32_field(L, table_index, "titlebar_focus_color", &config->titlebar_focus_color)) {
        config->has_titlebar_focus_color = true;
    }

    if (applicator_lua_load_bool_field(L, table_index, "shadow_enabled", &config->shadow_enabled)) {
        config->has_shadow_enabled = true;
    }
    if (applicator_lua_load_i16_field(L, table_index, "shadow_x_offset", &config->shadow_x_offset)) {
        config->has_shadow_x_offset = true;
    }
    if (applicator_lua_load_i16_field(L, table_index, "shadow_y_offset", &config->shadow_y_offset)) {
        config->has_shadow_y_offset = true;
    }
    if (applicator_lua_load_u16_field(L, table_index, "shadow_spread", &config->shadow_spread)) {
        config->has_shadow_spread = true;
    }
    if (applicator_lua_load_u8_field(L, table_index, "shadow_opacity", &config->shadow_opacity)) {
        config->has_shadow_opacity = true;
    }
    if (applicator_lua_load_u32_field(L, table_index, "shadow_color", &config->shadow_color)) {
        config->has_shadow_color = true;
    }

    if (applicator_lua_load_u16_field(L, table_index, "x11_width", &config->x11_width)) {
        config->has_x11_width = true;
    }
    if (applicator_lua_load_u16_field(L, table_index, "x11_height", &config->x11_height)) {
        config->has_x11_height = true;
    }

    applicator_lua_apply_legacy_shadow_table(L, table_index, config);
}

bool applicator_lua_config_load_file(const char *path,
                                     ApplicatorLuaConfig *config,
                                     const char *log_prefix)
{
    if (config == NULL) {
        return false;
    }

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
    applicator_lua_register_api(L, config);

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

    if (lua_gettop(L) > 0) {
        if (lua_istable(L, -1)) {
            applicator_lua_apply_legacy_table(L, -1, config);
        } else {
            fprintf(stderr, "%s warning: config %s returned a non-table value that was ignored\n",
                    applicator_log_prefix(log_prefix),
                    path);
        }
    }

    lua_close(L);
    return true;
}
