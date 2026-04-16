#pragma once

#include <stdbool.h>

#define APPLICATOR_LUA_FONT_FILE_ENV "APPLICATOR_FONT_FILE"
#define APPLICATOR_LUA_FONT_FAMILY_ENV "APPLICATOR_FONT_FAMILY"

bool applicator_lua_config_load_patches(const char *path, const char *log_prefix);
bool applicator_lua_config_load_server(const char *path, const char *log_prefix);
