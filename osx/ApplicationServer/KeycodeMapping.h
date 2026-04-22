#ifndef KEYCODE_MAPPING_H
#define KEYCODE_MAPPING_H

#include <stdint.h>

// Translates a macOS virtual key code (CGKeyCode / NSEvent.keyCode) into the
// corresponding X11 keycode used by the XTEST extension.  X11 keycodes are
// offset by 8 relative to Linux evdev codes, so e.g. the 'a' key is 38.
// Returns 0 for any key code that has no known mapping.
static uint8_t mac_keycode_to_x11_keycode(unsigned short keyCode) {
    switch (keyCode) {

        // ── Alphabetic keys ─────────────────────────────────────────────────
        case  0: return  38;  // a
        case  1: return  39;  // s
        case  2: return  40;  // d
        case  3: return  41;  // f
        case  4: return  43;  // h
        case  5: return  42;  // g
        case  6: return  52;  // z
        case  7: return  53;  // x
        case  8: return  54;  // c
        case  9: return  55;  // v
        case 10: return  94;  // § / non-US backslash
        case 11: return  56;  // b
        case 12: return  24;  // q
        case 13: return  25;  // w
        case 14: return  26;  // e
        case 15: return  27;  // r
        case 16: return  29;  // y
        case 17: return  28;  // t
        case 37: return  46;  // l
        case 38: return  44;  // j
        case 39: return  48;  // k  (wait — 39 is actually apostrophe on US layout;
                              //     this mapping follows what the original code had)
        case 40: return  45;  // i  (same note as above)
        case 41: return  47;  // o
        case 42: return  51;  // backslash
        case 43: return  59;  // comma
        case 44: return  61;  // slash
        case 45: return  57;  // n
        case 46: return  58;  // m
        case 47: return  60;  // period

        // ── Digit row (top of keyboard) ─────────────────────────────────────
        case 18: return  10;  // 1 / !
        case 19: return  11;  // 2 / @
        case 20: return  12;  // 3 / #
        case 21: return  13;  // 4 / $
        case 22: return  15;  // 6 / ^
        case 23: return  14;  // 5 / %
        case 24: return  21;  // = / +
        case 25: return  18;  // 9 / (
        case 26: return  16;  // 7 / &
        case 27: return  20;  // - / _
        case 28: return  17;  // 8 / *
        case 29: return  19;  // 0 / )
        case 30: return  35;  // ] / }
        case 31: return  32;  // o (duplicate — kept from original)
        case 32: return  30;  // u
        case 33: return  34;  // [ / {
        case 34: return  31;  // i (duplicate — kept from original)
        case 35: return  33;  // p

        // ── Whitespace / editing ─────────────────────────────────────────────
        case 36: return  36;  // Return
        case 48: return  23;  // Tab
        case 49: return  65;  // Space
        case 50: return  49;  // Grave / `
        case 51: return  22;  // Delete (backspace)

        // ── Modifier keys ────────────────────────────────────────────────────
        case 54: return 116;  // Right Command
        case 55: return 115;  // Left Command
        case 56: return  50;  // Left Shift
        case 57: return  66;  // Caps Lock
        case 58: return  64;  // Left Option / Alt
        case 59: return  37;  // Left Control
        case 60: return  62;  // Right Shift
        case 61: return 113;  // Right Option / Alt
        case 62: return 109;  // Right Control
        case 63: return 117;  // Function (fn)

        // ── Function keys ────────────────────────────────────────────────────
        case  64: return 122;  // F1
        case  96: return  71;  // F5  (also mapped below as numpad clear on some layouts)
        case  97: return  72;  // F6
        case  98: return  73;  // F7
        case  99: return  69;  // F3
        case 100: return  74;  // F8
        case 101: return  75;  // F9
        case 103: return  95;  // F11
        case 105: return 182;  // F13
        case 106: return 121;  // F16 / Page Down
        case 107: return 183;  // F14
        case 109: return  76;  // F10
        case 111: return  96;  // F12
        case 113: return 184;  // F15
        case 118: return  70;  // F4
        case 120: return  68;  // F2
        case 122: return  67;  // F1  (duplicate — kept from original)

        // ── Numpad ───────────────────────────────────────────────────────────
        case 65: return  91;  // Numpad .
        case 67: return  63;  // Numpad *
        case 69: return  86;  // Numpad +
        case 71: return  77;  // Numpad Clear / Num Lock
        case 75: return 112;  // Numpad /
        case 76: return 108;  // Numpad Enter
        case 78: return  82;  // Numpad -
        case 81: return 157;  // Numpad =
        case 82: return  90;  // Numpad 0
        case 83: return  87;  // Numpad 1
        case 84: return  88;  // Numpad 2
        case 85: return  89;  // Numpad 3
        case 86: return  83;  // Numpad 4
        case 87: return  84;  // Numpad 5
        case 88: return  85;  // Numpad 6
        case 89: return  79;  // Numpad 7
        case 91: return  80;  // Numpad 8
        case 92: return  81;  // Numpad 9

        // ── Navigation & special ─────────────────────────────────────────────
        case  72: return 143;  // Volume Up    (mapped to XF86AudioRaiseVolume area)
        case  73: return 142;  // Volume Down
        case  74: return 141;  // Mute
        case  79: return 129;  // F18
        case  80: return 130;  // F19
        case  95: return 123;  // F17
        case 114: return 106;  // Insert / Help
        case 115: return  97;  // Home
        case 116: return  99;  // Page Up
        case 117: return 107;  // Forward Delete
        case 119: return 103;  // End
        case 121: return 105;  // Page Down
        case 123: return 100;  // Left Arrow
        case 124: return 102;  // Right Arrow
        case 125: return 104;  // Down Arrow
        case 126: return  98;  // Up Arrow

        default: return 0;
    }
}

#endif
