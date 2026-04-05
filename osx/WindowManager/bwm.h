/*
 * bwm.h — shared types and public interfaces for bwm
 */

#pragma once

#define _POSIX_C_SOURCE 200809L

#include <stdbool.h>
#include <stdint.h>
#include <limits.h>

#include <xcb/xcb.h>
#include <xcb/xproto.h>
#include <xcb/xtest.h>

/* -------------------------------------------------------------------------
 * Tunables
 * ---------------------------------------------------------------------- */

#define BWM_TITLEBAR_HEIGHT   22
#define BWM_BORDER_WIDTH       1

#define BWM_COLOR_FRAME_BG    0xFF2D2D2D
#define BWM_COLOR_TITLE_BG    0xFF3C3F41
#define BWM_COLOR_TITLE_FOCUS 0xFF214283
#define BWM_COLOR_BORDER      0xFF555555

#define BWM_MIN_CLIENT_W      80
#define BWM_MIN_CLIENT_H      40

/* -------------------------------------------------------------------------
 * Config
 * ---------------------------------------------------------------------- */

typedef struct BwmConfig BwmConfig;
struct BwmConfig {
    uint32_t root_color;
    uint32_t titlebar_color;
    uint32_t titlebar_focus_color;
    char     root_image[PATH_MAX];
};

/* -------------------------------------------------------------------------
 * Client
 * ---------------------------------------------------------------------- */

typedef struct BwmClient BwmClient;
struct BwmClient {
    xcb_window_t frame;
    xcb_window_t titlebar;
    xcb_window_t client;

    int16_t  x, y;
    uint16_t w, h;
    uint16_t client_w;
    uint16_t client_h;

    bool     focused;
    bool     mapped;
    bool     maximised;

    int16_t  saved_x, saved_y;
    uint16_t saved_w, saved_h;

    /* title-bar drag state */
    bool     dragging;
    int16_t  drag_ptr_x;
    int16_t  drag_ptr_y;
    int16_t  drag_frame_x;
    int16_t  drag_frame_y;

    BwmClient *next;
};

/* -------------------------------------------------------------------------
 * Top-level WM state
 * ---------------------------------------------------------------------- */

typedef struct BwmWM BwmWM;
struct BwmWM {
    xcb_connection_t *conn;
    xcb_screen_t     *screen;
    xcb_window_t      root;
    xcb_window_t      cursor_win;
    xcb_pixmap_t      root_background;

    /* atoms */
    xcb_atom_t atom_wm_delete_window;
    xcb_atom_t atom_wm_protocols;
    xcb_atom_t atom_wm_state;
    xcb_atom_t atom_net_wm_name;
    xcb_atom_t atom_utf8_string;

    BwmClient *focused;
    BwmClient *clients;
    BwmConfig   config;

    uint16_t root_w;
    uint16_t root_h;

    /* current logical cursor position (updated by HID input) */
    float cursor_x;
    float cursor_y;
};

/* -------------------------------------------------------------------------
 * bwm_wm.c — init / destroy
 * ---------------------------------------------------------------------- */

int  bwm_init(BwmWM *wm);
void bwm_destroy(BwmWM *wm);
void bwm_load_config(BwmWM *wm, const char *path);
void bwm_apply_root_background(BwmWM *wm);

/* -------------------------------------------------------------------------
 * client.c — client list, frame creation/destruction, geometry, draw
 * ---------------------------------------------------------------------- */

void       bwm_client_insert(BwmWM *wm, BwmClient *c);
void       bwm_client_remove(BwmWM *wm, BwmClient *c);
BwmClient *bwm_find_by_frame(BwmWM *wm, xcb_window_t w);
BwmClient *bwm_find_by_titlebar(BwmWM *wm, xcb_window_t w);
BwmClient *bwm_find_by_client(BwmWM *wm, xcb_window_t w);

BwmClient *bwm_frame_window(BwmWM *wm, xcb_window_t client_win, bool already_mapped);
void       bwm_unframe(BwmWM *wm, BwmClient *c);

void       bwm_redraw_titlebar(BwmWM *wm, BwmClient *c);
void       bwm_move_frame(BwmWM *wm, BwmClient *c, int16_t x, int16_t y);
void       bwm_resize_frame(BwmWM *wm, BwmClient *c, uint16_t cw, uint16_t ch);
void       bwm_toggle_maximise(BwmWM *wm, BwmClient *c);
void       bwm_close_client(BwmWM *wm, BwmClient *c);

void       bwm_adopt_existing_windows(BwmWM *wm);

uint16_t   bwm_frame_w(uint16_t client_w);
uint16_t   bwm_frame_h(uint16_t client_h);

/* -------------------------------------------------------------------------
 * focus.c — focus management
 * ---------------------------------------------------------------------- */

void bwm_set_focus(BwmWM *wm, BwmClient *c);

/* -------------------------------------------------------------------------
 * events.c — XCB event loop
 * ---------------------------------------------------------------------- */

int bwm_run(BwmWM *wm);

/* -------------------------------------------------------------------------
 * input.c — IOHIDManager mouse + keyboard
 * ---------------------------------------------------------------------- */

int  bwm_input_start(BwmWM *wm);
void bwm_input_stop(void);
