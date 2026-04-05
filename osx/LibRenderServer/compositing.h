#pragma once

#include <stdbool.h>
#include <stdint.h>

#include <xcb/xcb.h>

#include "iomfb.h"

typedef struct RenderServerCompositor RenderServerCompositor;

RenderServerCompositor *render_server_compositor_create(const char *config_path);
void render_server_compositor_destroy(RenderServerCompositor *compositor);

int render_server_prepare_initial_frame(RenderState *state,
                                        const RenderServerCompositor *compositor);
int render_server_enable_composite(xcb_connection_t *connection,
                                   xcb_screen_t     *screen,
                                   const char       *display_name,
                                   bool             *composite_enabled_out);
int render_server_compose_frame(RenderState *state,
                                xcb_connection_t *connection,
                                xcb_screen_t     *screen,
                                const RenderServerCompositor *compositor,
                                bool              composite_enabled,
                                uint16_t          width,
                                uint16_t          height);
