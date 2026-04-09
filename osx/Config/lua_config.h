#pragma once

#include <stdbool.h>
#include <limits.h>
#include <stdint.h>

typedef struct ApplicatorLuaConfig ApplicatorLuaConfig;
struct ApplicatorLuaConfig {
    bool     has_background_color;
    uint32_t background_color;

    bool     has_background_image;
    char     background_image[PATH_MAX];

    bool     has_titlebar_color;
    uint32_t titlebar_color;

    bool     has_titlebar_focus_color;
    uint32_t titlebar_focus_color;

    bool     has_shadow_enabled;
    bool     shadow_enabled;

    bool     has_shadow_x_offset;
    int16_t  shadow_x_offset;

    bool     has_shadow_y_offset;
    int16_t  shadow_y_offset;

    bool     has_shadow_spread;
    uint16_t shadow_spread;

    bool     has_shadow_opacity;
    uint8_t  shadow_opacity;

    bool     has_shadow_color;
    uint32_t shadow_color;

    bool     has_x11_width;
    uint16_t x11_width;

    bool     has_x11_height;
    uint16_t x11_height;
};

void applicator_lua_config_init(ApplicatorLuaConfig *config);
bool applicator_lua_config_load_file(const char *path,
                                     ApplicatorLuaConfig *config,
                                     const char *log_prefix);
