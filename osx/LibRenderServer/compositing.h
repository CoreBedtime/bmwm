#pragma once

#include <stdbool.h>
#include <stdint.h>

#include <xcb/xcb.h>

#include "iomfb.h"

typedef struct RenderServerCompositor RenderServerCompositor;

RenderServerCompositor *render_server_compositor_create(const char *config_path);
void render_server_compositor_destroy(RenderServerCompositor *compositor);

/* Call once after the XComposite redirect is established to register the
 * XDamage extension on the connection.  Returns false if XDamage is
 * unavailable; the compositor will fall back to full-frame redraws. */
bool render_server_compositor_setup_damage(RenderServerCompositor *compositor,
                                           xcb_connection_t       *connection);

int render_server_prepare_initial_frame(RenderState *state,
                                        RenderServerCompositor *compositor);
int render_server_enable_composite(xcb_connection_t *connection,
                                   xcb_screen_t     *screen,
                                   const char       *display_name,
                                   bool             *composite_enabled_out);

/* Notify the compositor that the window tree has changed (map/unmap/configure)
 * so it will re-query children on the next compose call. */
void render_server_compositor_invalidate_tree(RenderServerCompositor *compositor);

/* Update just the geometry of a known entry without a full tree re-sync.
 * If the window is not in the cache this is a no-op (tree_dirty stays as-is). */
void render_server_compositor_update_geometry(RenderServerCompositor *compositor,
                                              xcb_window_t            window,
                                              int16_t                 x,
                                              int16_t                 y,
                                              uint16_t                w,
                                              uint16_t                h);

/* Process a single XDamage or XComposite event already fetched from the
 * connection.  Returns true if the event was consumed (and freed). */
bool render_server_compositor_handle_event(RenderServerCompositor *compositor,
                                           xcb_connection_t       *connection,
                                           xcb_generic_event_t    *event);

int render_server_compose_frame(RenderState *state,
                                xcb_connection_t *connection,
                                xcb_screen_t     *screen,
                                RenderServerCompositor *compositor,
                                bool              composite_enabled,
                                uint16_t          width,
                                uint16_t          height,
                                int16_t           cursor_x,
                                int16_t           cursor_y);
