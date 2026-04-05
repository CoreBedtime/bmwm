export function log(message) {
  console.log("[applaunch] " + message);
}

export function errorToString(error) {
  if (error == null) {
    return "unknown error";
  }
  if (typeof error === "string") {
    return error;
  }
  try {
    if (error.message != null) {
      return error.message.toString();
    }
  } catch (e) {}
  try {
    return error.toString();
  } catch (e) {
    return "unknown error";
  }
}

export function resolveExport(moduleName, symbolName) {
  if (typeof Module.findExportByName === "function") {
    return Module.findExportByName(moduleName, symbolName);
  }
  if (
    typeof Module.getGlobalExportByName === "function" &&
    moduleName === null
  ) {
    return Module.getGlobalExportByName(symbolName);
  }
  throw new Error("No export lookup function available");
}

export function getEnv(name) {
  var getenv = new NativeFunction(resolveExport(null, "getenv"), "pointer", [
    "pointer",
  ]);
  var value = getenv(Memory.allocUtf8String(name));
  if (value.isNull()) {
    return null;
  }
  return value.readUtf8String();
}

export function isZeroValue(value) {
  if (value == null) {
    return true;
  }
  if (typeof value === "number") {
    return value === 0;
  }
  if (typeof value === "string") {
    return value === "0" || value === "0x0";
  }
  try {
    return value.toString() === "0";
  } catch (e) {
    return false;
  }
}

export function isNullValue(value) {
  if (value == null) {
    return true;
  }
  if (typeof value.isNull === "function") {
    try {
      return value.isNull();
    } catch (e) {
      return false;
    }
  }
  if (typeof value === "number") {
    return value === 0;
  }
  if (typeof value === "string") {
    return value === "0" || value === "0x0";
  }
  return false;
}

export const X11_KEY_PRESS = 2;
export const X11_KEY_RELEASE = 3;
export const X11_BUTTON_PRESS = 4;
export const X11_BUTTON_RELEASE = 5;
export const X11_MOTION_NOTIFY = 6;

export const X11_SHIFT_MASK = 1 << 0;
export const X11_LOCK_MASK = 1 << 1;
export const X11_CONTROL_MASK = 1 << 2;
export const X11_MOD1_MASK = 1 << 3;
export const X11_MOD2_MASK = 1 << 4;
export const X11_MOD4_MASK = 1 << 6;
export const X11_BUTTON1_MASK = 1 << 8;
export const X11_BUTTON2_MASK = 1 << 9;
export const X11_BUTTON3_MASK = 1 << 10;

export const X11_EVENT_TYPE_OFFSET = 0;
export const X11_EVENT_WINDOW_OFFSET = 32;
export const X11_EVENT_ROOT_OFFSET = 40;
export const X11_EVENT_X_OFFSET = 64;
export const X11_EVENT_Y_OFFSET = 68;
export const X11_EVENT_X_ROOT_OFFSET = 72;
export const X11_EVENT_Y_ROOT_OFFSET = 76;
export const X11_EVENT_STATE_OFFSET = 80;
export const X11_EVENT_DETAIL_OFFSET = 84;
export const X11_EVENT_BUFFER_SIZE = 256;

export const CG_LEFT_MOUSE_DOWN = 1;
export const CG_LEFT_MOUSE_UP = 2;
export const CG_RIGHT_MOUSE_DOWN = 3;
export const CG_RIGHT_MOUSE_UP = 4;
export const CG_MOUSE_MOVED = 5;
export const CG_LEFT_MOUSE_DRAGGED = 6;
export const CG_RIGHT_MOUSE_DRAGGED = 7;
export const CG_KEY_DOWN = 10;
export const CG_KEY_UP = 11;
export const CG_OTHER_MOUSE_DOWN = 25;
export const CG_OTHER_MOUSE_UP = 26;
export const CG_OTHER_MOUSE_DRAGGED = 27;
export const CG_MOUSE_LEFT = 0;
export const CG_MOUSE_RIGHT = 1;
export const CG_MOUSE_CENTER = 2;

export const X11_TO_MAC_KEYCODE = {
  10: 18,
  11: 19,
  12: 20,
  13: 21,
  14: 23,
  15: 22,
  16: 26,
  17: 28,
  18: 25,
  19: 29,
  20: 27,
  21: 24,
  22: 51,
  23: 48,
  24: 12,
  25: 13,
  26: 14,
  27: 15,
  28: 17,
  29: 16,
  30: 32,
  31: 34,
  32: 31,
  33: 35,
  34: 33,
  35: 30,
  36: 36,
  37: 59,
  38: 0,
  39: 1,
  40: 2,
  41: 3,
  42: 5,
  43: 4,
  44: 38,
  45: 40,
  46: 37,
  47: 41,
  48: 39,
  49: 50,
  50: 56,
  51: 42,
  52: 6,
  53: 7,
  54: 8,
  55: 9,
  56: 11,
  57: 45,
  58: 46,
  59: 43,
  60: 47,
  61: 44,
  62: 60,
  63: 67,
  64: 58,
  65: 49,
  66: 57,
  67: 122,
  68: 120,
  69: 99,
  70: 118,
  71: 96,
  72: 97,
  73: 98,
  74: 100,
  75: 101,
  76: 109,
  77: 71,
  79: 89,
  80: 91,
  81: 92,
  82: 78,
  83: 86,
  84: 87,
  85: 88,
  86: 69,
  87: 83,
  88: 84,
  89: 85,
  90: 82,
  91: 65,
  94: 10,
  95: 103,
  96: 111,
  97: 115,
  98: 126,
  99: 116,
  100: 123,
  102: 124,
  103: 119,
  104: 125,
  105: 121,
  106: 114,
  107: 117,
  108: 76,
  109: 62,
  110: 114,
  112: 75,
  113: 61,
  115: 55,
  116: 54,
  117: 63,
  121: 106,
  122: 64,
  123: 95,
  129: 79,
  130: 80,
  141: 74,
  142: 73,
  143: 72,
  144: 114,
  157: 81,
  182: 105,
  183: 107,
  184: 113,
};

export function x11StateToCGFlags(state) {
  var flags = 0;
  if ((state & X11_LOCK_MASK) !== 0) {
    flags |= 0x00010000;
  }
  if ((state & X11_SHIFT_MASK) !== 0) {
    flags |= 0x00020000;
  }
  if ((state & X11_CONTROL_MASK) !== 0) {
    flags |= 0x00040000;
  }
  if ((state & X11_MOD1_MASK) !== 0) {
    flags |= 0x00080000;
  }
  if ((state & X11_MOD4_MASK) !== 0) {
    flags |= 0x00100000;
  }
  return flags;
}

export function clampNumber(value, minValue, maxValue) {
  return Math.max(minValue, Math.min(maxValue, value));
}

export function x11KeycodeToMacKeycode(keycode) {
  if (!Object.prototype.hasOwnProperty.call(X11_TO_MAC_KEYCODE, keycode)) {
    return null;
  }

  var value = X11_TO_MAC_KEYCODE[keycode];
  if (value == null) {
    return null;
  }

  return value | 0;
}

export function x11WindowHandleToString(handle) {
  if (handle == null) {
    return null;
  }
  try {
    return handle.toString();
  } catch (e) {
    return null;
  }
}

export function x11WindowHandleToNumber(handle) {
  if (handle == null) {
    return null;
  }

  try {
    var value = Number(handle);
    return isFinite(value) ? value : null;
  } catch (e) {
    return null;
  }
}

export function clampFrame(frame) {
  var normalized = normalizeFrame(frame);
  if (normalized == null) {
    throw new Error("invalid frame");
  }

  return {
    origin: {
      x: Math.max(0, Math.round(normalized.origin.x)),
      y: Math.max(0, Math.round(normalized.origin.y)),
    },
    size: {
      width: Math.max(1, Math.round(normalized.size.width)),
      height: Math.max(1, Math.round(normalized.size.height)),
    },
  };
}

export function readNumericField(object, key) {
  if (object == null) {
    return null;
  }

  var value;
  try {
    value = object[key];
  } catch (e) {
    return null;
  }
  if (value == null) {
    return null;
  }

  if (typeof value === "number") {
    return isFinite(value) ? value : null;
  }

  try {
    var converted = Number(value);
    return isFinite(converted) ? converted : null;
  } catch (e) {
    return null;
  }
}

export function normalizeFrame(frame) {
  if (frame == null) {
    return null;
  }

  var fx = readNumericField(frame, 0);
  var fy = readNumericField(frame, 1);
  var fw = readNumericField(frame, 2);
  var fh = readNumericField(frame, 3);
  if (fx != null && fy != null && fw != null && fh != null) {
    return {
      origin: { x: fx, y: fy },
      size: { width: fw, height: fh },
    };
  }

  var originX = readNumericField(frame != null ? frame[0] : null, 0);
  var originY = readNumericField(frame != null ? frame[0] : null, 1);
  var sizeW = readNumericField(frame != null ? frame[1] : null, 0);
  var sizeH = readNumericField(frame != null ? frame[1] : null, 1);
  if (originX != null && originY != null && sizeW != null && sizeH != null) {
    return {
      origin: { x: originX, y: originY },
      size: { width: sizeW, height: sizeH },
    };
  }

  if (frame.origin != null && frame.size != null) {
    return frame;
  }

  if (
    frame.value != null &&
    frame.value.origin != null &&
    frame.value.size != null
  ) {
    return frame.value;
  }

  fx = readNumericField(frame.value, 0);
  fy = readNumericField(frame.value, 1);
  fw = readNumericField(frame.value, 2);
  fh = readNumericField(frame.value, 3);
  if (fx != null && fy != null && fw != null && fh != null) {
    return {
      origin: { x: fx, y: fy },
      size: { width: fw, height: fh },
    };
  }

  originX = readNumericField(frame.value != null ? frame.value[0] : null, 0);
  originY = readNumericField(frame.value != null ? frame.value[0] : null, 1);
  sizeW = readNumericField(frame.value != null ? frame.value[1] : null, 0);
  sizeH = readNumericField(frame.value != null ? frame.value[1] : null, 1);
  if (originX != null && originY != null && sizeW != null && sizeH != null) {
    return {
      origin: { x: originX, y: originY },
      size: { width: sizeW, height: sizeH },
    };
  }

  var x = readNumericField(frame, "x");
  var y = readNumericField(frame, "y");
  var width = readNumericField(frame, "width");
  var height = readNumericField(frame, "height");
  if (x != null && y != null && width != null && height != null) {
    return {
      origin: { x: x, y: y },
      size: { width: width, height: height },
    };
  }

  try {
    var text = String(frame);
    var matches = text.match(/-?\d+(?:\.\d+)?/g);
    if (matches != null && matches.length >= 4) {
      return {
        origin: {
          x: Number(matches[0]),
          y: Number(matches[1]),
        },
        size: {
          width: Number(matches[2]),
          height: Number(matches[3]),
        },
      };
    }
  } catch (e) {}

  return null;
}
