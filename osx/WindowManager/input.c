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
 *   - HID key usages are translated directly into the X11/XKB core
 *     keycodes expected by the Xorg/XQuartz server.
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

#define HID_TO_X11_KEYCODE(hid_usage, x11_keycode) \
    case hid_usage: return (uint8_t)(x11_keycode)

static uint8_t hid_usage_to_x11_keycode(uint32_t usage)
{
    /*
     * This server is started without a keyboard device, so XTest input must use
     * the server's core keycodes, not Carbon virtual keycodes. The values below
     * match the installed XKB tables on macOS:
     *   - /opt/X11/share/X11/xkb/keycodes/xfree86
     *   - /opt/X11/share/X11/xkb/keycodes/macintosh
     */
    switch (usage) {
        HID_TO_X11_KEYCODE(kHIDUsage_KeyboardA, 38);
        HID_TO_X11_KEYCODE(kHIDUsage_KeyboardB, 56);
        HID_TO_X11_KEYCODE(kHIDUsage_KeyboardC, 54);
        HID_TO_X11_KEYCODE(kHIDUsage_KeyboardD, 40);
        HID_TO_X11_KEYCODE(kHIDUsage_KeyboardE, 26);
        HID_TO_X11_KEYCODE(kHIDUsage_KeyboardF, 41);
        HID_TO_X11_KEYCODE(kHIDUsage_KeyboardG, 42);
        HID_TO_X11_KEYCODE(kHIDUsage_KeyboardH, 43);
        HID_TO_X11_KEYCODE(kHIDUsage_KeyboardI, 31);
        HID_TO_X11_KEYCODE(kHIDUsage_KeyboardJ, 44);
        HID_TO_X11_KEYCODE(kHIDUsage_KeyboardK, 45);
        HID_TO_X11_KEYCODE(kHIDUsage_KeyboardL, 46);
        HID_TO_X11_KEYCODE(kHIDUsage_KeyboardM, 58);
        HID_TO_X11_KEYCODE(kHIDUsage_KeyboardN, 57);
        HID_TO_X11_KEYCODE(kHIDUsage_KeyboardO, 32);
        HID_TO_X11_KEYCODE(kHIDUsage_KeyboardP, 33);
        HID_TO_X11_KEYCODE(kHIDUsage_KeyboardQ, 24);
        HID_TO_X11_KEYCODE(kHIDUsage_KeyboardR, 27);
        HID_TO_X11_KEYCODE(kHIDUsage_KeyboardS, 39);
        HID_TO_X11_KEYCODE(kHIDUsage_KeyboardT, 28);
        HID_TO_X11_KEYCODE(kHIDUsage_KeyboardU, 30);
        HID_TO_X11_KEYCODE(kHIDUsage_KeyboardV, 55);
        HID_TO_X11_KEYCODE(kHIDUsage_KeyboardW, 25);
        HID_TO_X11_KEYCODE(kHIDUsage_KeyboardX, 53);
        HID_TO_X11_KEYCODE(kHIDUsage_KeyboardY, 29);
        HID_TO_X11_KEYCODE(kHIDUsage_KeyboardZ, 52);

        HID_TO_X11_KEYCODE(kHIDUsage_Keyboard1, 10);
        HID_TO_X11_KEYCODE(kHIDUsage_Keyboard2, 11);
        HID_TO_X11_KEYCODE(kHIDUsage_Keyboard3, 12);
        HID_TO_X11_KEYCODE(kHIDUsage_Keyboard4, 13);
        HID_TO_X11_KEYCODE(kHIDUsage_Keyboard5, 14);
        HID_TO_X11_KEYCODE(kHIDUsage_Keyboard6, 15);
        HID_TO_X11_KEYCODE(kHIDUsage_Keyboard7, 16);
        HID_TO_X11_KEYCODE(kHIDUsage_Keyboard8, 17);
        HID_TO_X11_KEYCODE(kHIDUsage_Keyboard9, 18);
        HID_TO_X11_KEYCODE(kHIDUsage_Keyboard0, 19);

        HID_TO_X11_KEYCODE(kHIDUsage_KeyboardReturnOrEnter, 36);
        HID_TO_X11_KEYCODE(kHIDUsage_KeyboardEscape, 9);
        HID_TO_X11_KEYCODE(kHIDUsage_KeyboardDeleteOrBackspace, 22);
        HID_TO_X11_KEYCODE(kHIDUsage_KeyboardTab, 23);
        HID_TO_X11_KEYCODE(kHIDUsage_KeyboardSpacebar, 65);
        HID_TO_X11_KEYCODE(kHIDUsage_KeyboardHyphen, 20);
        HID_TO_X11_KEYCODE(kHIDUsage_KeyboardEqualSign, 21);
        HID_TO_X11_KEYCODE(kHIDUsage_KeyboardOpenBracket, 34);
        HID_TO_X11_KEYCODE(kHIDUsage_KeyboardCloseBracket, 35);
        HID_TO_X11_KEYCODE(kHIDUsage_KeyboardBackslash, 51);
        HID_TO_X11_KEYCODE(kHIDUsage_KeyboardNonUSBackslash, 94);
        HID_TO_X11_KEYCODE(kHIDUsage_KeyboardNonUSPound, 94);
        HID_TO_X11_KEYCODE(kHIDUsage_KeyboardSemicolon, 47);
        HID_TO_X11_KEYCODE(kHIDUsage_KeyboardQuote, 48);
        HID_TO_X11_KEYCODE(kHIDUsage_KeyboardGraveAccentAndTilde, 49);
        HID_TO_X11_KEYCODE(kHIDUsage_KeyboardComma, 59);
        HID_TO_X11_KEYCODE(kHIDUsage_KeyboardPeriod, 60);
        HID_TO_X11_KEYCODE(kHIDUsage_KeyboardSlash, 61);

        HID_TO_X11_KEYCODE(kHIDUsage_KeyboardCapsLock, 66);
        HID_TO_X11_KEYCODE(kHIDUsage_KeyboardF1, 67);
        HID_TO_X11_KEYCODE(kHIDUsage_KeyboardF2, 68);
        HID_TO_X11_KEYCODE(kHIDUsage_KeyboardF3, 69);
        HID_TO_X11_KEYCODE(kHIDUsage_KeyboardF4, 70);
        HID_TO_X11_KEYCODE(kHIDUsage_KeyboardF5, 71);
        HID_TO_X11_KEYCODE(kHIDUsage_KeyboardF6, 72);
        HID_TO_X11_KEYCODE(kHIDUsage_KeyboardF7, 73);
        HID_TO_X11_KEYCODE(kHIDUsage_KeyboardF8, 74);
        HID_TO_X11_KEYCODE(kHIDUsage_KeyboardF9, 75);
        HID_TO_X11_KEYCODE(kHIDUsage_KeyboardF10, 76);
        HID_TO_X11_KEYCODE(kHIDUsage_KeyboardF11, 95);
        HID_TO_X11_KEYCODE(kHIDUsage_KeyboardF12, 96);
        HID_TO_X11_KEYCODE(kHIDUsage_KeyboardF13, 182);
        HID_TO_X11_KEYCODE(kHIDUsage_KeyboardF14, 183);
        HID_TO_X11_KEYCODE(kHIDUsage_KeyboardF15, 184);
        HID_TO_X11_KEYCODE(kHIDUsage_KeyboardF16, 121);
        HID_TO_X11_KEYCODE(kHIDUsage_KeyboardF17, 122);
        HID_TO_X11_KEYCODE(kHIDUsage_KeyboardF18, 129);
        HID_TO_X11_KEYCODE(kHIDUsage_KeyboardF19, 130);

        HID_TO_X11_KEYCODE(kHIDUsage_KeyboardPrintScreen, 111);
        HID_TO_X11_KEYCODE(kHIDUsage_KeyboardScrollLock, 78);
        HID_TO_X11_KEYCODE(kHIDUsage_KeyboardPause, 110);
        HID_TO_X11_KEYCODE(kHIDUsage_KeyboardInsert, 106);
        HID_TO_X11_KEYCODE(kHIDUsage_KeyboardHome, 97);
        HID_TO_X11_KEYCODE(kHIDUsage_KeyboardPageUp, 99);
        HID_TO_X11_KEYCODE(kHIDUsage_KeyboardDeleteForward, 107);
        HID_TO_X11_KEYCODE(kHIDUsage_KeyboardEnd, 103);
        HID_TO_X11_KEYCODE(kHIDUsage_KeyboardPageDown, 105);
        HID_TO_X11_KEYCODE(kHIDUsage_KeyboardRightArrow, 102);
        HID_TO_X11_KEYCODE(kHIDUsage_KeyboardLeftArrow, 100);
        HID_TO_X11_KEYCODE(kHIDUsage_KeyboardDownArrow, 104);
        HID_TO_X11_KEYCODE(kHIDUsage_KeyboardUpArrow, 98);

        HID_TO_X11_KEYCODE(kHIDUsage_KeyboardLeftControl, 37);
        HID_TO_X11_KEYCODE(kHIDUsage_KeyboardLeftShift, 50);
        HID_TO_X11_KEYCODE(kHIDUsage_KeyboardLeftAlt, 64);
        HID_TO_X11_KEYCODE(kHIDUsage_KeyboardLeftGUI, 115);
        HID_TO_X11_KEYCODE(kHIDUsage_KeyboardRightControl, 109);
        HID_TO_X11_KEYCODE(kHIDUsage_KeyboardRightShift, 62);
        HID_TO_X11_KEYCODE(kHIDUsage_KeyboardRightAlt, 113);
        HID_TO_X11_KEYCODE(kHIDUsage_KeyboardRightGUI, 116);

        HID_TO_X11_KEYCODE(kHIDUsage_KeyboardApplication, 117);
        HID_TO_X11_KEYCODE(kHIDUsage_KeyboardMenu, 117);
        HID_TO_X11_KEYCODE(kHIDUsage_KeyboardHelp, 144);
        HID_TO_X11_KEYCODE(kHIDUsage_KeyboardMute, 141);
        HID_TO_X11_KEYCODE(kHIDUsage_KeyboardVolumeDown, 142);
        HID_TO_X11_KEYCODE(kHIDUsage_KeyboardVolumeUp, 143);

        HID_TO_X11_KEYCODE(kHIDUsage_KeypadNumLock, 77);
        HID_TO_X11_KEYCODE(kHIDUsage_KeypadSlash, 112);
        HID_TO_X11_KEYCODE(kHIDUsage_KeypadAsterisk, 63);
        HID_TO_X11_KEYCODE(kHIDUsage_KeypadHyphen, 82);
        HID_TO_X11_KEYCODE(kHIDUsage_KeypadPlus, 86);
        HID_TO_X11_KEYCODE(kHIDUsage_KeypadEnter, 108);
        HID_TO_X11_KEYCODE(kHIDUsage_Keypad1, 87);
        HID_TO_X11_KEYCODE(kHIDUsage_Keypad2, 88);
        HID_TO_X11_KEYCODE(kHIDUsage_Keypad3, 89);
        HID_TO_X11_KEYCODE(kHIDUsage_Keypad4, 83);
        HID_TO_X11_KEYCODE(kHIDUsage_Keypad5, 84);
        HID_TO_X11_KEYCODE(kHIDUsage_Keypad6, 85);
        HID_TO_X11_KEYCODE(kHIDUsage_Keypad7, 79);
        HID_TO_X11_KEYCODE(kHIDUsage_Keypad8, 80);
        HID_TO_X11_KEYCODE(kHIDUsage_Keypad9, 81);
        HID_TO_X11_KEYCODE(kHIDUsage_Keypad0, 90);
        HID_TO_X11_KEYCODE(kHIDUsage_KeypadPeriod, 91);
        HID_TO_X11_KEYCODE(kHIDUsage_KeypadComma, 123);
        HID_TO_X11_KEYCODE(kHIDUsage_KeypadEqualSign, 157);

        default:
            return 0;
    }
}

#undef HID_TO_X11_KEYCODE

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

    uint8_t keycode = hid_usage_to_x11_keycode(usage);
    if (keycode == 0) {
        return;
    }

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
