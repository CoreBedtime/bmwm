/*
 * input.c — HID mouse and keyboard handling for bwm
 *
 * Uses IOHIDManager to receive raw events from all mice and keyboards,
 * then injects them into Xorg via xcb_test_fake_input (XTest extension).
 *
 * Mouse:
 *   - Relative X/Y axes are accumulated and converted to absolute root
 *     coordinates (clamped to screen bounds), then injected as MotionNotify.
 *   - Button 1-5 events are injected as ButtonPress / ButtonRelease.
 *   - Scroll wheel (usage GD_Wheel / GD_Z) produces Button 4/5.
 *
 * Keyboard:
 *   - HID key-codes are mapped to X11 key-codes (HID + 8, the standard
 *     offset used by XKB for USB HID keyboards).
 *   - KeyPress / KeyRelease events are injected with detail = keycode.
 *
 * The IOHIDManager runs on a dedicated CFRunLoop thread.  Fake-input
 * calls are the only cross-thread operation; XCB is thread-safe for
 * write calls when no reply is needed.
 */

#define _POSIX_C_SOURCE 200809L

#include "bwm.h"

#include <math.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <IOKit/hid/IOHIDManager.h>
#include <IOKit/hid/IOHIDUsageTables.h>

#include <xcb/xcb.h>
#include <xcb/xtest.h>

/* -------------------------------------------------------------------------
 * Module state (single instance)
 * ---------------------------------------------------------------------- */

typedef struct {
    BwmWM          *wm;
    IOHIDManagerRef mgr;
    CFRunLoopRef    run_loop;
    pthread_t       thread;
    bool            running;
} BwmInput;

static BwmInput g_input;

/* -------------------------------------------------------------------------
 * Cursor helpers
 * ---------------------------------------------------------------------- */

static float clampf(float v, float lo, float hi)
{
    if (v < lo) return lo;
    if (v > hi) return hi;
    return v;
}

/* Inject an absolute MotionNotify at the current logical cursor position. */
static void inject_motion(BwmWM *wm)
{
    int16_t rx = (int16_t)wm->cursor_x;
    int16_t ry = (int16_t)wm->cursor_y;
    xcb_test_fake_input(wm->conn,
                        XCB_MOTION_NOTIFY,
                        0,                   /* detail: 0 = normal move */
                        XCB_CURRENT_TIME,
                        wm->root,
                        rx, ry,
                        0);

    /* Move cursor window and keep it on top. Offset by 1 so clicks hit underneath. */
    uint32_t pos_vals[] = { (uint32_t)(rx + 1), (uint32_t)(ry + 1) };
    xcb_configure_window(wm->conn, wm->cursor_win,
                         XCB_CONFIG_WINDOW_X | XCB_CONFIG_WINDOW_Y, pos_vals);

    uint32_t stack_vals[] = { XCB_STACK_MODE_ABOVE };
    xcb_configure_window(wm->conn, wm->cursor_win,
                         XCB_CONFIG_WINDOW_STACK_MODE, stack_vals);

    xcb_flush(wm->conn);
}

/* -------------------------------------------------------------------------
 * Mouse event callback
 * ---------------------------------------------------------------------- */

static void mouse_value_callback(void           *context,
                                 IOReturn        result,
                                 void           *sender,
                                 IOHIDValueRef   value)
{
    (void)result; (void)sender;
    BwmWM *wm = (BwmWM *)context;

    IOHIDElementRef elem  = IOHIDValueGetElement(value);
    uint32_t usage_page   = IOHIDElementGetUsagePage(elem);
    uint32_t usage        = IOHIDElementGetUsage(elem);
    CFIndex  int_val      = IOHIDValueGetIntegerValue(value);
    // printf("[bwm/input] mouse usage=%u int_val=%ld\n", usage, int_val);

    if (usage_page == kHIDPage_GenericDesktop) {
        switch (usage) {
            case kHIDUsage_GD_X:
                /* relative X delta */
                wm->cursor_x = clampf(wm->cursor_x + (float)int_val * 0.625f,
                                      0.0f, (float)(wm->root_w - 1));
                inject_motion(wm);
                break;

            case kHIDUsage_GD_Y:
                /* relative Y delta */
                wm->cursor_y = clampf(wm->cursor_y + (float)int_val * 0.625f,
                                      0.0f, (float)(wm->root_h - 1));
                inject_motion(wm);
                break;

            case kHIDUsage_GD_Wheel:   /* vertical scroll */
            case kHIDUsage_GD_Z: {
                if (int_val == 0) break;
                /* positive = scroll up (button 4), negative = scroll down (button 5) */
                uint8_t btn = (int_val > 0) ? 4 : 5;
                int16_t rx = (int16_t)wm->cursor_x;
                int16_t ry = (int16_t)wm->cursor_y;
                xcb_test_fake_input(wm->conn, XCB_BUTTON_PRESS,   btn,
                                    XCB_CURRENT_TIME, wm->root, rx, ry, 0);
                xcb_test_fake_input(wm->conn, XCB_BUTTON_RELEASE, btn,
                                    XCB_CURRENT_TIME, wm->root, rx, ry, 0);
                xcb_flush(wm->conn);
                break;
            }

            default:
                break;
        }
        return;
    }

    if (usage_page == kHIDPage_Button) {
        /* usage 1 = left, 2 = right, 3 = middle */
        if (usage < 1 || usage > 32) return;
        uint8_t btn  = (uint8_t)usage;
        int16_t rx   = (int16_t)wm->cursor_x;
        int16_t ry   = (int16_t)wm->cursor_y;
        uint8_t type = (int_val != 0) ? XCB_BUTTON_PRESS : XCB_BUTTON_RELEASE;
        xcb_test_fake_input(wm->conn, type, btn, XCB_CURRENT_TIME,
                            wm->root, rx, ry, 0);
        xcb_flush(wm->conn);
    }
}

/* -------------------------------------------------------------------------
 * Keyboard event callback
 * ---------------------------------------------------------------------- */

static void keyboard_value_callback(void           *context,
                                    IOReturn        result,
                                    void           *sender,
                                    IOHIDValueRef   value)
{
    (void)result; (void)sender;
    BwmWM *wm = (BwmWM *)context;

    IOHIDElementRef elem  = IOHIDValueGetElement(value);
    uint32_t usage_page   = IOHIDElementGetUsagePage(elem);
    uint32_t usage        = IOHIDElementGetUsage(elem);
    CFIndex  int_val      = IOHIDValueGetIntegerValue(value);
    // printf("[bwm/input] mouse usage=%u int_val=%ld\n", usage, int_val);

    if (usage_page != kHIDPage_KeyboardOrKeypad) return;
    if (usage < 4 || usage > 231) return;  /* skip reserved / modifier-only */

    /*
     * X11 key-code = HID usage + 8
     * This is the standard mapping used by XKB for USB HID keyboards.
     */
    uint8_t keycode = (uint8_t)(usage + 8);
    uint8_t type    = (int_val != 0) ? XCB_KEY_PRESS : XCB_KEY_RELEASE;

    xcb_test_fake_input(wm->conn, type, keycode, XCB_CURRENT_TIME,
                        wm->root, 0, 0, 0);
    xcb_flush(wm->conn);
}

/* -------------------------------------------------------------------------
 * Unified callback
 * ---------------------------------------------------------------------- */

static void unified_value_callback(void           *context,
                                   IOReturn        result,
                                   void           *sender,
                                   IOHIDValueRef   value)
{
    (void)result; (void)sender;
    IOHIDElementRef elem  = IOHIDValueGetElement(value);
    uint32_t usage_page   = IOHIDElementGetUsagePage(elem);

    if (usage_page == kHIDPage_GenericDesktop || usage_page == kHIDPage_Button) {
        mouse_value_callback(context, result, sender, value);
    } else if (usage_page == kHIDPage_KeyboardOrKeypad) {
        keyboard_value_callback(context, result, sender, value);
    }
}

/* -------------------------------------------------------------------------
 * Device matching dictionaries
 * ---------------------------------------------------------------------- */

static CFDictionaryRef make_usage_dict(uint32_t usage_page, uint32_t usage)
{
    CFNumberRef page_num  = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &usage_page);
    CFNumberRef usage_num = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &usage);

    const void *keys[]   = { CFSTR(kIOHIDDeviceUsagePageKey), CFSTR(kIOHIDDeviceUsageKey) };
    const void *values[] = { page_num, usage_num };
    CFDictionaryRef dict = CFDictionaryCreate(kCFAllocatorDefault,
                                              keys, values, 2,
                                              &kCFTypeDictionaryKeyCallBacks,
                                              &kCFTypeDictionaryValueCallBacks);
    CFRelease(page_num);
    CFRelease(usage_num);
    return dict;
}

/* -------------------------------------------------------------------------
 * RunLoop thread
 * ---------------------------------------------------------------------- */

static void *input_thread(void *arg)
{
    (void)arg;
    g_input.run_loop = CFRunLoopGetCurrent();
    CFRetain(g_input.run_loop);

    IOHIDManagerScheduleWithRunLoop(g_input.mgr,
                                    g_input.run_loop,
                                    kCFRunLoopDefaultMode);
    IOHIDManagerOpen(g_input.mgr, kIOHIDOptionsTypeNone);

    CFRunLoopRun();

    IOHIDManagerUnscheduleFromRunLoop(g_input.mgr,
                                      g_input.run_loop,
                                      kCFRunLoopDefaultMode);
    IOHIDManagerClose(g_input.mgr, kIOHIDOptionsTypeNone);
    CFRelease(g_input.run_loop);
    g_input.run_loop = NULL;
    return NULL;
}

/* -------------------------------------------------------------------------
 * Public API
 * ---------------------------------------------------------------------- */

int bwm_input_start(BwmWM *wm)
{
    memset(&g_input, 0, sizeof(g_input));
    g_input.wm = wm;

    g_input.mgr = IOHIDManagerCreate(kCFAllocatorDefault, kIOHIDOptionsTypeNone);
    if (g_input.mgr == NULL) {
        fprintf(stderr, "[bwm/input] failed to create IOHIDManager\n");
        return 1;
    }

    /* Match mice and keyboards */
    CFDictionaryRef mouse_dict = make_usage_dict(kHIDPage_GenericDesktop,
                                                 kHIDUsage_GD_Mouse);
    CFDictionaryRef kb_dict    = make_usage_dict(kHIDPage_GenericDesktop,
                                                 kHIDUsage_GD_Keyboard);
    CFDictionaryRef dicts[]    = { mouse_dict, kb_dict };
    CFArrayRef matching        = CFArrayCreate(kCFAllocatorDefault,
                                               (const void **)dicts, 2,
                                               &kCFTypeArrayCallBacks);
    IOHIDManagerSetDeviceMatchingMultiple(g_input.mgr, matching);
    CFRelease(matching);
    CFRelease(mouse_dict);
    CFRelease(kb_dict);

    /* Register value callbacks — one per device class */
    IOHIDManagerRegisterInputValueCallback(g_input.mgr, unified_value_callback, wm);

    g_input.running = true;
    if (pthread_create(&g_input.thread, NULL, input_thread, NULL) != 0) {
        fprintf(stderr, "[bwm/input] failed to create input thread\n");
        CFRelease(g_input.mgr);
        g_input.mgr = NULL;
        return 1;
    }

    fprintf(stdout, "[bwm/input] HID input started\n");
    fflush(stdout);
    return 0;
}

void bwm_input_stop(void)
{
    if (!g_input.running) return;
    g_input.running = false;

    if (g_input.run_loop != NULL) {
        CFRunLoopStop(g_input.run_loop);
    }

    if (g_input.thread) {
        pthread_join(g_input.thread, NULL);
        g_input.thread = 0;
    }

    if (g_input.mgr != NULL) {
        CFRelease(g_input.mgr);
        g_input.mgr = NULL;
    }

    fprintf(stdout, "[bwm/input] HID input stopped\n");
    fflush(stdout);
}
