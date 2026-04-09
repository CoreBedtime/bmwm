/*
 * input.c — HID mouse, touch, and keyboard handling for bwm
 *
 * Uses IOHIDManager for mice, keyboards, and touchscreen digitizer contact
 * state, and uses MultitouchSupport for the built-in trackpad motion stream.
 * Both paths inject into Xorg via xcb_test_fake_input (XTest extension).
 *
 * Mouse:
 *   - Relative X/Y axes are accumulated and converted to absolute root
 *     coordinates (clamped to screen bounds), then injected as MotionNotify.
 *   - Button 1-5 events are injected as ButtonPress / ButtonRelease.
 *   - Scroll wheel (usage GD_Wheel / GD_Z) produces Button 4/5.
 *
 * Touchscreens:
 *   - Digitizer touch/contact state is translated into button 1 press/release.
 *
 * Trackpads:
 *   - Multitouch contact frames drive cursor motion from one active finger.
 *   - The HID path still stays available as a fallback if MultitouchSupport
 *     is unavailable at runtime.
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
#include <dlfcn.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <IOKit/hid/IOHIDManager.h>
#include <IOKit/hid/IOHIDDevice.h>
#include <IOKit/hid/IOHIDUsageTables.h>

#include <xcb/xcb.h>
#include <xcb/xtest.h>

/* -------------------------------------------------------------------------
 * Module state (single instance)
 * ---------------------------------------------------------------------- */

typedef struct BwmHidDeviceState BwmHidDeviceState;
typedef struct BwmMtDeviceState BwmMtDeviceState;

typedef struct {
    BwmWM          *wm;
    IOHIDManagerRef mgr;
    CFRunLoopRef    run_loop;
    pthread_t       thread;
    bool            running;
    BwmHidDeviceState *devices;
    BwmMtDeviceState *mt_states;
    void           *mt_library;
    bool            mt_backend_active;
    bool            mt_motion_live;
} BwmInput;

static BwmInput g_input;

typedef CFTypeRef MTDeviceRef;

typedef struct {
    float x;
    float y;
} BwmMtPoint;

typedef struct {
    BwmMtPoint position;
    BwmMtPoint velocity;
} BwmMtVector;

typedef struct {
    int32_t     frame;
    double      timestamp;
    int32_t     path_index;
    int32_t     state;
    int32_t     finger_id;
    int32_t     hand_id;
    BwmMtVector normalized;
    float       size;
    int32_t     reserved_0;
    float       angle;
    float       major_axis;
    float       minor_axis;
    BwmMtVector mm;
    int32_t     reserved_1;
    int32_t     reserved_2;
    float       density;
} BwmMtTouch;

typedef void (*BwmMtContactCallback)(MTDeviceRef device,
                                     const BwmMtTouch *touches,
                                     size_t num_touches,
                                     double timestamp,
                                     size_t frame);

typedef struct BwmMtDeviceState {
    MTDeviceRef device;
    bool        started;
    bool        internal;
    bool        relative_coordinates;
    bool        have_last_contact;
    float       last_contact_x;
    float       last_contact_y;
    struct BwmMtDeviceState *next;
} BwmMtDeviceState;

typedef struct BwmMtApi {
    CFArrayRef (*create_list)(void);
    MTDeviceRef (*create_default)(void);
    void (*register_contact_callback)(MTDeviceRef, BwmMtContactCallback);
    int32_t (*schedule_on_run_loop)(MTDeviceRef, CFRunLoopRef, CFStringRef);
    int32_t (*start)(MTDeviceRef, int);
    int32_t (*stop)(MTDeviceRef);
    void (*release_device)(MTDeviceRef);
    bool (*is_built_in)(MTDeviceRef);
    void (*get_transport_method)(MTDeviceRef, int *);
    bool (*should_dispatch_relative_coordinates)(MTDeviceRef);
} BwmMtApi;

static BwmMtApi g_mt;

typedef struct BwmHidDeviceState {
    IOHIDDeviceRef device;
    bool           is_keyboard;
    bool           is_pointer;
    bool           is_touchscreen;
    bool           is_touchpad;
    bool           is_built_in;
    bool           contact_down;
    bool           have_last_abs_x;
    bool           have_last_abs_y;
    float          last_abs_x;
    float          last_abs_y;
    struct BwmHidDeviceState *next;
} BwmHidDeviceState;

/* -------------------------------------------------------------------------
 * Cursor helpers
 * ---------------------------------------------------------------------- */

static float clampf(float v, float lo, float hi)
{
    if (v < lo) return lo;
    if (v > hi) return hi;
    return v;
}

static bool device_conforms_to(IOHIDDeviceRef device, uint32_t usage_page, uint32_t usage)
{
    if (device == NULL) {
        return false;
    }

    CFTypeRef usage_pairs_ref = IOHIDDeviceGetProperty(device, CFSTR(kIOHIDDeviceUsagePairsKey));
    if (usage_pairs_ref != NULL && CFGetTypeID(usage_pairs_ref) == CFArrayGetTypeID()) {
        CFArrayRef usage_pairs = (CFArrayRef)usage_pairs_ref;
        CFIndex count = CFArrayGetCount(usage_pairs);

        for (CFIndex i = 0; i < count; ++i) {
            CFTypeRef pair_ref = CFArrayGetValueAtIndex(usage_pairs, i);
            if (pair_ref == NULL || CFGetTypeID(pair_ref) != CFDictionaryGetTypeID()) {
                continue;
            }

            CFDictionaryRef pair = (CFDictionaryRef)pair_ref;
            CFTypeRef page_ref = CFDictionaryGetValue(pair, CFSTR(kIOHIDDeviceUsagePageKey));
            CFTypeRef usage_ref = CFDictionaryGetValue(pair, CFSTR(kIOHIDDeviceUsageKey));
            if (page_ref == NULL || usage_ref == NULL) {
                continue;
            }
            if (CFGetTypeID(page_ref) != CFNumberGetTypeID() ||
                CFGetTypeID(usage_ref) != CFNumberGetTypeID()) {
                continue;
            }

            int32_t pair_page = 0;
            int32_t pair_usage = 0;
            if (CFNumberGetValue((CFNumberRef)page_ref, kCFNumberSInt32Type, &pair_page) &&
                CFNumberGetValue((CFNumberRef)usage_ref, kCFNumberSInt32Type, &pair_usage) &&
                pair_page == usage_page &&
                pair_usage == usage) {
                return true;
            }
        }
    }

    CFTypeRef primary_page_ref = IOHIDDeviceGetProperty(device, CFSTR(kIOHIDPrimaryUsagePageKey));
    CFTypeRef primary_usage_ref = IOHIDDeviceGetProperty(device, CFSTR(kIOHIDPrimaryUsageKey));
    if (primary_page_ref != NULL &&
        primary_usage_ref != NULL &&
        CFGetTypeID(primary_page_ref) == CFNumberGetTypeID() &&
        CFGetTypeID(primary_usage_ref) == CFNumberGetTypeID()) {
        int32_t primary_page = 0;
        int32_t primary_usage = 0;
        if (CFNumberGetValue((CFNumberRef)primary_page_ref, kCFNumberSInt32Type, &primary_page) &&
            CFNumberGetValue((CFNumberRef)primary_usage_ref, kCFNumberSInt32Type, &primary_usage) &&
            primary_page == (int32_t)usage_page &&
            primary_usage == (int32_t)usage) {
            return true;
        }
    }

    return IOHIDDeviceConformsTo(device, usage_page, usage);
}

static bool device_is_keyboard(IOHIDDeviceRef device)
{
    return device_conforms_to(device, kHIDPage_GenericDesktop, kHIDUsage_GD_Keyboard) ||
           device_conforms_to(device, kHIDPage_GenericDesktop, kHIDUsage_GD_Keypad);
}

static bool device_is_pointer(IOHIDDeviceRef device)
{
    return device_conforms_to(device, kHIDPage_GenericDesktop, kHIDUsage_GD_Mouse) ||
           device_conforms_to(device, kHIDPage_GenericDesktop, kHIDUsage_GD_Pointer);
}

static bool device_is_touchscreen(IOHIDDeviceRef device)
{
    return device_conforms_to(device, kHIDPage_Digitizer, kHIDUsage_Dig_TouchScreen);
}

static bool device_is_touchpad(IOHIDDeviceRef device)
{
    return device_conforms_to(device, kHIDPage_Digitizer, kHIDUsage_Dig_TouchPad) ||
           device_conforms_to(device, kHIDPage_Digitizer, kHIDUsage_Dig_MultiplePointDigitizer);
}

static bool device_is_built_in(IOHIDDeviceRef device)
{
    CFTypeRef built_in_ref = IOHIDDeviceGetProperty(device, CFSTR("Built-In"));
    if (built_in_ref != NULL && CFGetTypeID(built_in_ref) == CFBooleanGetTypeID()) {
        return CFBooleanGetValue((CFBooleanRef)built_in_ref);
    }

    return false;
}

static BwmHidDeviceState *device_state_for(IOHIDDeviceRef device, bool create)
{
    if (device == NULL) {
        return NULL;
    }

    for (BwmHidDeviceState *state = g_input.devices; state != NULL; state = state->next) {
        if (state->device == device) {
            return state;
        }
    }

    if (!create) {
        return NULL;
    }

    BwmHidDeviceState *state = (BwmHidDeviceState *)calloc(1, sizeof(*state));
    if (state == NULL) {
        return NULL;
    }

    state->device = device;
    CFRetain(device);
    state->is_keyboard = device_is_keyboard(device);
    state->is_pointer = device_is_pointer(device);
    state->is_touchscreen = device_is_touchscreen(device);
    state->is_touchpad = device_is_touchpad(device);
    state->is_built_in = device_is_built_in(device);
    state->next = g_input.devices;
    g_input.devices = state;
    return state;
}

static void device_state_remove(IOHIDDeviceRef device)
{
    if (device == NULL) {
        return;
    }

    BwmHidDeviceState **link = &g_input.devices;
    while (*link != NULL) {
        BwmHidDeviceState *state = *link;
        if (state->device == device) {
            *link = state->next;
            CFRelease(state->device);
            free(state);
            return;
        }
        link = &state->next;
    }
}

static void device_state_clear_all(void)
{
    BwmHidDeviceState *state = g_input.devices;
    g_input.devices = NULL;

    while (state != NULL) {
        BwmHidDeviceState *next = state->next;
        if (state->device != NULL) {
            CFRelease(state->device);
        }
        free(state);
        state = next;
    }
}

static void device_attach(IOHIDDeviceRef device, BwmWM *wm);

static void device_attach_existing(BwmWM *wm)
{
    if (g_input.mgr == NULL) {
        return;
    }

    CFSetRef devices = IOHIDManagerCopyDevices(g_input.mgr);
    if (devices == NULL) {
        return;
    }

    CFIndex count = CFSetGetCount(devices);
    if (count > 0) {
        const void **values = (const void **)calloc((size_t)count, sizeof(*values));
        if (values != NULL) {
            CFSetGetValues(devices, values);
            for (CFIndex i = 0; i < count; ++i) {
                device_attach((IOHIDDeviceRef)values[i], wm);
            }
            free(values);
        }
    }

    CFRelease(devices);
}

static float absolute_axis_to_cursor(IOHIDElementRef elem, CFIndex value, float max_coord)
{
    CFIndex logical_min = IOHIDElementGetLogicalMin(elem);
    CFIndex logical_max = IOHIDElementGetLogicalMax(elem);

    if (logical_max <= logical_min) {
        return clampf((float)value, 0.0f, max_coord);
    }

    float normalized = (float)(value - logical_min) / (float)(logical_max - logical_min);
    return clampf(normalized * max_coord, 0.0f, max_coord);
}

static void inject_button_event(BwmWM *wm, uint8_t btn, uint8_t type)
{
    int16_t rx = (int16_t)wm->cursor_x;
    int16_t ry = (int16_t)wm->cursor_y;
    xcb_test_fake_input(wm->conn, type, btn, XCB_CURRENT_TIME,
                        wm->root, rx, ry, 0);
    xcb_flush(wm->conn);
}

static bool update_cursor_axis_relative(CFIndex int_val,
                                        float *cursor,
                                        float max_coord)
{
    if (int_val == 0) {
        return false;
    }

    *cursor = clampf(*cursor + (float)int_val * 0.625f, 0.0f, max_coord);
    return true;
}

static bool update_cursor_axis_absolute(BwmHidDeviceState *state,
                                        IOHIDElementRef elem,
                                        CFIndex int_val,
                                        bool is_x_axis,
                                        bool require_contact,
                                        float *cursor,
                                        float max_coord)
{
    float axis = absolute_axis_to_cursor(elem, int_val, max_coord);
    bool  *have_last = is_x_axis ? &state->have_last_abs_x : &state->have_last_abs_y;
    float *last      = is_x_axis ? &state->last_abs_x : &state->last_abs_y;

    if (require_contact && !state->contact_down) {
        *have_last = false;
        *last = axis;
        return false;
    }

    if (!*have_last) {
        *have_last = true;
        *last = axis;
        return false;
    }

    float delta = axis - *last;
    *last = axis;
    if (delta == 0.0f) {
        return false;
    }

    *cursor = clampf(*cursor + delta, 0.0f, max_coord);
    return true;
}

static void reset_touch_motion_tracking(BwmHidDeviceState *state)
{
    state->have_last_abs_x = false;
    state->have_last_abs_y = false;
}

static void set_touch_contact_state(BwmWM *wm, BwmHidDeviceState *state, bool down)
{
    if (state->contact_down == down) {
        return;
    }

    state->contact_down = down;
    reset_touch_motion_tracking(state);

    /*
     * Touchscreens behave like a pressed primary button while a finger is
     * down. Trackpads use contact state only to stabilize motion.
     */
    if (state->is_touchscreen) {
        inject_button_event(wm, 1, down ? XCB_BUTTON_PRESS : XCB_BUTTON_RELEASE);
    }
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
 * Multitouch trackpad backend
 * ---------------------------------------------------------------------- */

typedef struct {
    const char *path;
} MtLibraryPath;

static const MtLibraryPath k_mt_library_paths[] = {
    { "/System/Library/PrivateFrameworks/MultitouchSupport.framework/Versions/A/MultitouchSupport" },
    { "/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport" },
};

enum {
    BWM_MT_TOUCH_START = 1,
    BWM_MT_TOUCH_HOVER = 2,
    BWM_MT_TOUCH_MAKE  = 3,
    BWM_MT_TOUCH_MOVE  = 4,
    BWM_MT_TOUCH_END   = 5,
    BWM_MT_TOUCH_LINGER = 6,
    BWM_MT_TOUCH_OUT   = 7,
};

static void mt_release_device(MTDeviceRef device)
{
    if (device == NULL) {
        return;
    }

    if (g_mt.release_device != NULL) {
        g_mt.release_device(device);
    } else {
        CFRelease(device);
    }
}

static bool mt_load_library(void)
{
    if (g_input.mt_library != NULL) {
        return true;
    }

    for (size_t i = 0; i < sizeof(k_mt_library_paths) / sizeof(k_mt_library_paths[0]); ++i) {
        void *handle = dlopen(k_mt_library_paths[i].path, RTLD_LAZY | RTLD_LOCAL);
        if (handle == NULL) {
            continue;
        }

        memset(&g_mt, 0, sizeof(g_mt));
        g_input.mt_library = handle;
        g_mt.create_list = (CFArrayRef (*)(void))dlsym(handle, "MTDeviceCreateList");
        g_mt.create_default = (MTDeviceRef (*)(void))dlsym(handle, "MTDeviceCreateDefault");
        g_mt.register_contact_callback =
            (void (*)(MTDeviceRef, BwmMtContactCallback))dlsym(handle, "MTRegisterContactFrameCallback");
        g_mt.schedule_on_run_loop =
            (int32_t (*)(MTDeviceRef, CFRunLoopRef, CFStringRef))dlsym(handle, "MTDeviceScheduleOnRunLoop");
        g_mt.start = (int32_t (*)(MTDeviceRef, int))dlsym(handle, "MTDeviceStart");
        g_mt.stop = (int32_t (*)(MTDeviceRef))dlsym(handle, "MTDeviceStop");
        g_mt.release_device = (void (*)(MTDeviceRef))dlsym(handle, "MTDeviceRelease");
        g_mt.is_built_in = (bool (*)(MTDeviceRef))dlsym(handle, "MTDeviceIsBuiltIn");
        g_mt.get_transport_method =
            (void (*)(MTDeviceRef, int *))dlsym(handle, "MTDeviceGetTransportMethod");
        g_mt.should_dispatch_relative_coordinates =
            (bool (*)(MTDeviceRef))dlsym(handle, "MTDeviceShouldDispatchRelativeCoordinates");

        if (g_mt.create_list == NULL ||
            g_mt.register_contact_callback == NULL ||
            g_mt.start == NULL ||
            g_mt.stop == NULL) {
            dlclose(handle);
            g_input.mt_library = NULL;
            memset(&g_mt, 0, sizeof(g_mt));
            continue;
        }

        return true;
    }

    return false;
}

static BwmMtDeviceState *mt_device_state_for(MTDeviceRef device, bool create)
{
    if (device == NULL) {
        return NULL;
    }

    for (BwmMtDeviceState *state = g_input.mt_states; state != NULL; state = state->next) {
        if (state->device == device) {
            return state;
        }
    }

    if (!create) {
        return NULL;
    }

    BwmMtDeviceState *state = (BwmMtDeviceState *)calloc(1, sizeof(*state));
    if (state == NULL) {
        return NULL;
    }

    state->device = device;
    CFRetain(device);
    state->next = g_input.mt_states;
    g_input.mt_states = state;
    return state;
}

static void mt_state_reset_contact(BwmMtDeviceState *state)
{
    state->have_last_contact = false;
}

static bool mt_device_is_internal(MTDeviceRef device)
{
    if (device == NULL) {
        return false;
    }

    if (g_mt.is_built_in != NULL && g_mt.is_built_in(device)) {
        return true;
    }

    if (g_mt.get_transport_method != NULL) {
        int transport = -1;
        g_mt.get_transport_method(device, &transport);
        if (transport == 1) {
            return true;
        }
    }

    return false;
}

static void mt_move_cursor(BwmWM *wm, float dx, float dy)
{
    if (dx == 0.0f && dy == 0.0f) {
        return;
    }

    wm->cursor_x = clampf(wm->cursor_x + dx * (float)(wm->root_w - 1),
                          0.0f, (float)(wm->root_w - 1));
    /* MultitouchSupport Y is opposite the X11 root coordinate direction. */
    wm->cursor_y = clampf(wm->cursor_y - dy * (float)(wm->root_h - 1),
                          0.0f, (float)(wm->root_h - 1));
    inject_motion(wm);
    g_input.mt_motion_live = true;
}

static bool mt_touch_is_active(const BwmMtTouch *touch)
{
    if (touch == NULL) {
        return false;
    }

    return touch->state == BWM_MT_TOUCH_MAKE ||
           touch->state == BWM_MT_TOUCH_MOVE;
}

static void mt_contact_frame_callback(MTDeviceRef device,
                                      const BwmMtTouch *touches,
                                      size_t num_touches,
                                      double timestamp,
                                      size_t frame)
{
    (void)timestamp;
    (void)frame;

    BwmMtDeviceState *state = mt_device_state_for(device, true);
    if (state == NULL) {
        return;
    }

    BwmWM *wm = g_input.wm;
    if (wm == NULL) {
        return;
    }

    const BwmMtTouch *active_touch = NULL;
    size_t active_touches = 0;
    for (size_t i = 0; i < num_touches; ++i) {
        if (!mt_touch_is_active(&touches[i])) {
            continue;
        }

        active_touches++;
        active_touch = &touches[i];
        if (active_touches > 1) {
            break;
        }
    }

    if (active_touches != 1 || active_touch == NULL) {
        mt_state_reset_contact(state);
        return;
    }

    float x = active_touch->normalized.position.x;
    float y = active_touch->normalized.position.y;
    if (!state->have_last_contact) {
        state->have_last_contact = true;
        state->last_contact_x = x;
        state->last_contact_y = y;
        return;
    }

    float dx = x - state->last_contact_x;
    float dy = y - state->last_contact_y;
    if (state->relative_coordinates) {
        float vel_x = active_touch->normalized.velocity.x;
        float vel_y = active_touch->normalized.velocity.y;
        if (vel_x != 0.0f || vel_y != 0.0f) {
            dx = vel_x;
            dy = vel_y;
        }
    }
    state->last_contact_x = x;
    state->last_contact_y = y;

    mt_move_cursor(wm, dx, dy);
}

static bool mt_backend_start(BwmWM *wm)
{
    if (wm == NULL) {
        return false;
    }

    if (!mt_load_library()) {
        return false;
    }

    g_input.mt_motion_live = false;
    size_t started = 0;
    CFArrayRef devices = g_mt.create_list != NULL ? g_mt.create_list() : NULL;
    if (devices != NULL) {
        CFIndex count = CFArrayGetCount(devices);
        for (CFIndex i = 0; i < count; ++i) {
            MTDeviceRef device = (MTDeviceRef)CFArrayGetValueAtIndex(devices, i);
            if (device == NULL || !mt_device_is_internal(device)) {
                continue;
            }

            BwmMtDeviceState *state = mt_device_state_for(device, true);
            if (state == NULL || state->started) {
                continue;
            }

            state->internal = true;
            state->relative_coordinates =
                g_mt.should_dispatch_relative_coordinates != NULL &&
                g_mt.should_dispatch_relative_coordinates(device);
            g_mt.register_contact_callback(device, mt_contact_frame_callback);
            if (g_mt.schedule_on_run_loop != NULL && g_input.run_loop != NULL) {
                g_mt.schedule_on_run_loop(device, g_input.run_loop, kCFRunLoopDefaultMode);
            }
            if (g_mt.start(device, 0) == 0) {
                state->started = true;
                started++;
            }
        }
        CFRelease(devices);
    }

    if (started == 0 && g_mt.create_default != NULL) {
        MTDeviceRef device = g_mt.create_default();
        if (device != NULL) {
            BwmMtDeviceState *state = mt_device_state_for(device, true);
            if (state != NULL && !state->started) {
                state->internal = true;
                state->relative_coordinates =
                    g_mt.should_dispatch_relative_coordinates != NULL &&
                    g_mt.should_dispatch_relative_coordinates(device);
                g_mt.register_contact_callback(device, mt_contact_frame_callback);
                if (g_mt.schedule_on_run_loop != NULL && g_input.run_loop != NULL) {
                    g_mt.schedule_on_run_loop(device, g_input.run_loop, kCFRunLoopDefaultMode);
                }
                if (g_mt.start(device, 0) == 0) {
                    state->started = true;
                    started++;
                }
            }

            mt_release_device(device);
        } else if (device != NULL) {
            mt_release_device(device);
        }
    }

    g_input.mt_backend_active = started > 0;
    if (g_input.mt_backend_active) {
        fprintf(stdout, "[bwm/input] MultitouchSupport trackpad backend started\n");
        fflush(stdout);
    }

    return g_input.mt_backend_active;
}

static void mt_backend_stop(void)
{
    BwmMtDeviceState *state = g_input.mt_states;
    g_input.mt_states = NULL;
    g_input.mt_backend_active = false;
    g_input.mt_motion_live = false;

    while (state != NULL) {
        BwmMtDeviceState *next = state->next;
        if (state->started && g_mt.stop != NULL) {
            g_mt.stop(state->device);
        }
        mt_release_device(state->device);
        free(state);
        state = next;
    }

    if (g_input.mt_library != NULL) {
        dlclose(g_input.mt_library);
        g_input.mt_library = NULL;
        memset(&g_mt, 0, sizeof(g_mt));
    }
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
    IOHIDDeviceRef device = IOHIDElementGetDevice(elem);
    CFIndex  int_val      = IOHIDValueGetIntegerValue(value);
    // printf("[bwm/input] mouse usage=%u int_val=%ld\n", usage, int_val);

    /* Some Apple trackpad collections only classify correctly at the element level. */
    BwmHidDeviceState *state = device_state_for(device, true);

    if (usage_page == kHIDPage_GenericDesktop) {
        switch (usage) {
            case kHIDUsage_GD_X:
                if (state != NULL && state->is_touchpad && state->is_built_in &&
                    g_input.mt_motion_live) {
                    break;
                }
                if (IOHIDElementIsRelative(elem)) {
                    if (update_cursor_axis_relative(int_val, &wm->cursor_x,
                                                    (float)(wm->root_w - 1))) {
                        inject_motion(wm);
                    }
                } else if (state != NULL && state->is_touchscreen) {
                    if (!state->contact_down) {
                        break;
                    }
                    wm->cursor_x = absolute_axis_to_cursor(elem, int_val,
                                                           (float)(wm->root_w - 1));
                    inject_motion(wm);
                } else if (state != NULL &&
                           (state->is_pointer || state->is_touchpad) &&
                           update_cursor_axis_absolute(state, elem, int_val, true,
                                                       false,
                                                       &wm->cursor_x,
                                                       (float)(wm->root_w - 1))) {
                    inject_motion(wm);
                }
                break;

            case kHIDUsage_GD_Y:
                if (state != NULL && state->is_touchpad && state->is_built_in &&
                    g_input.mt_motion_live) {
                    break;
                }
                if (IOHIDElementIsRelative(elem)) {
                    if (update_cursor_axis_relative(int_val, &wm->cursor_y,
                                                    (float)(wm->root_h - 1))) {
                        inject_motion(wm);
                    }
                } else if (state != NULL && state->is_touchscreen) {
                    if (!state->contact_down) {
                        break;
                    }
                    wm->cursor_y = absolute_axis_to_cursor(elem, int_val,
                                                           (float)(wm->root_h - 1));
                    inject_motion(wm);
                } else if (state != NULL &&
                           (state->is_pointer || state->is_touchpad) &&
                           update_cursor_axis_absolute(state, elem, int_val, false,
                                                       false,
                                                       &wm->cursor_y,
                                                       (float)(wm->root_h - 1))) {
                    inject_motion(wm);
                }
                break;

            case kHIDUsage_GD_Wheel:   /* vertical scroll */
            case kHIDUsage_GD_Z: {
                if (int_val == 0) break;
                /* positive = scroll up (button 4), negative = scroll down (button 5) */
                uint8_t btn = (int_val > 0) ? 4 : 5;
                inject_button_event(wm, btn, XCB_BUTTON_PRESS);
                inject_button_event(wm, btn, XCB_BUTTON_RELEASE);
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
        uint8_t type = (int_val != 0) ? XCB_BUTTON_PRESS : XCB_BUTTON_RELEASE;
        inject_button_event(wm, btn, type);
    }
}

/* -------------------------------------------------------------------------
 * Touch surface event callback
 * ---------------------------------------------------------------------- */

static void touch_value_callback(void           *context,
                                 IOReturn        result,
                                 void           *sender,
                                 IOHIDValueRef   value)
{
    (void)result; (void)sender;
    BwmWM *wm = (BwmWM *)context;

    IOHIDElementRef elem  = IOHIDValueGetElement(value);
    IOHIDDeviceRef  device = IOHIDElementGetDevice(elem);
    uint32_t usage        = IOHIDElementGetUsage(elem);
    CFIndex  int_val      = IOHIDValueGetIntegerValue(value);

    BwmHidDeviceState *state = device_state_for(device, true);
    if (state == NULL) {
        return;
    }

    switch (usage) {
        case kHIDUsage_Dig_InRange:
        case kHIDUsage_Dig_TipSwitch:
        case kHIDUsage_Dig_Touch:
        case kHIDUsage_Dig_TouchValid:
        case kHIDUsage_Dig_SurfaceSwitch:
            set_touch_contact_state(wm, state, int_val != 0);
            break;

        case kHIDUsage_Dig_DataValid:
        case kHIDUsage_Dig_ContactCount:
            if (state->is_touchscreen) {
                set_touch_contact_state(wm, state, int_val != 0);
            }
            break;

        case kHIDUsage_Dig_Untouch:
            set_touch_contact_state(wm, state, false);
            break;

        default:
            break;
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
 * Unified HID callback
 * ---------------------------------------------------------------------- */

static void unified_value_callback(void           *context,
                                   IOReturn        result,
                                   void           *sender,
                                   IOHIDValueRef   value)
{
    (void)result;
    (void)sender;

    IOHIDElementRef elem  = IOHIDValueGetElement(value);
    uint32_t usage_page   = IOHIDElementGetUsagePage(elem);

    if (usage_page == kHIDPage_GenericDesktop || usage_page == kHIDPage_Button) {
        mouse_value_callback(context, result, sender, value);
    } else if (usage_page == kHIDPage_Digitizer) {
        touch_value_callback(context, result, sender, value);
    } else if (usage_page == kHIDPage_KeyboardOrKeypad) {
        keyboard_value_callback(context, result, sender, value);
    }
}

static void device_attach(IOHIDDeviceRef device, BwmWM *wm)
{
    (void)wm;

    if (device == NULL) {
        return;
    }

    BwmHidDeviceState *state = device_state_for(device, true);
    if (state == NULL) {
        return;
    }

    state->is_keyboard = device_is_keyboard(device);
    state->is_pointer = device_is_pointer(device);
    state->is_touchscreen = device_is_touchscreen(device);
    state->is_touchpad = device_is_touchpad(device);
    state->is_built_in = device_is_built_in(device);
}

static void device_matching_callback(void *context,
                                     IOReturn result,
                                     void *sender,
                                     IOHIDDeviceRef device)
{
    (void)result;
    (void)sender;

    device_attach(device, (BwmWM *)context);
}

static void device_removal_callback(void *context,
                                    IOReturn result,
                                    void *sender,
                                    IOHIDDeviceRef device)
{
    (void)context;
    (void)result;
    (void)sender;

    BwmWM *wm = (BwmWM *)context;
    BwmHidDeviceState *state = device_state_for(device, false);
    if (state != NULL && state->contact_down) {
        state->contact_down = false;
        reset_touch_motion_tracking(state);
        if (state->is_touchscreen) {
            inject_button_event(wm, 1, XCB_BUTTON_RELEASE);
        }
    }

    device_state_remove(device);
}

static void device_release_all_contacts(BwmWM *wm)
{
    if (wm == NULL) {
        return;
    }

    for (BwmHidDeviceState *state = g_input.devices; state != NULL; state = state->next) {
        if (!state->contact_down) {
            continue;
        }

        state->contact_down = false;
        reset_touch_motion_tracking(state);

        if (state->is_touchscreen) {
            inject_button_event(wm, 1, XCB_BUTTON_RELEASE);
        }
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
    IOReturn open_result = IOHIDManagerOpen(g_input.mgr, kIOHIDOptionsTypeNone);
    if (open_result != kIOReturnSuccess) {
        fprintf(stderr, "[bwm/input] failed to open IOHIDManager (%d)\n",
                (int)open_result);
    }
    device_attach_existing(g_input.wm);
    mt_backend_start(g_input.wm);

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

    /* Match pointer, keyboard, and touch surface collections */
    CFDictionaryRef mouse_dict = make_usage_dict(kHIDPage_GenericDesktop,
                                                 kHIDUsage_GD_Mouse);
    CFDictionaryRef pointer_dict = make_usage_dict(kHIDPage_GenericDesktop,
                                                   kHIDUsage_GD_Pointer);
    CFDictionaryRef kb_dict    = make_usage_dict(kHIDPage_GenericDesktop,
                                                 kHIDUsage_GD_Keyboard);
    CFDictionaryRef keypad_dict = make_usage_dict(kHIDPage_GenericDesktop,
                                                  kHIDUsage_GD_Keypad);
    CFDictionaryRef touchscreen_dict = make_usage_dict(kHIDPage_Digitizer,
                                                       kHIDUsage_Dig_TouchScreen);
    CFDictionaryRef touchpad_dict = make_usage_dict(kHIDPage_Digitizer,
                                                    kHIDUsage_Dig_TouchPad);
    CFDictionaryRef multi_touch_dict = make_usage_dict(kHIDPage_Digitizer,
                                                       kHIDUsage_Dig_MultiplePointDigitizer);
    CFDictionaryRef dicts[]    = {
        mouse_dict,
        pointer_dict,
        kb_dict,
        keypad_dict,
        touchscreen_dict,
        touchpad_dict,
        multi_touch_dict
    };
    CFArrayRef matching        = CFArrayCreate(kCFAllocatorDefault,
                                               (const void **)dicts, 7,
                                               &kCFTypeArrayCallBacks);
    IOHIDManagerSetDeviceMatchingMultiple(g_input.mgr, matching);
    CFRelease(matching);
    CFRelease(mouse_dict);
    CFRelease(pointer_dict);
    CFRelease(kb_dict);
    CFRelease(keypad_dict);
    CFRelease(touchscreen_dict);
    CFRelease(touchpad_dict);
    CFRelease(multi_touch_dict);

    /* Register manager-level callbacks for HID mouse/keyboard/touchscreen input */
    IOHIDManagerRegisterInputValueCallback(g_input.mgr, unified_value_callback, wm);
    IOHIDManagerRegisterDeviceMatchingCallback(g_input.mgr, device_matching_callback, wm);
    IOHIDManagerRegisterDeviceRemovalCallback(g_input.mgr, device_removal_callback, wm);

    g_input.running = true;
    if (pthread_create(&g_input.thread, NULL, input_thread, NULL) != 0) {
        fprintf(stderr, "[bwm/input] failed to create input thread\n");
        g_input.running = false;
        device_state_clear_all();
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
        mt_backend_stop();
        device_release_all_contacts(g_input.wm);
        device_state_clear_all();
        CFRelease(g_input.mgr);
        g_input.mgr = NULL;
    }

    fprintf(stdout, "[bwm/input] HID input stopped\n");
    fflush(stdout);
}
