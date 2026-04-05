import {
  CG_LEFT_MOUSE_DOWN,
  CG_LEFT_MOUSE_DRAGGED,
  CG_LEFT_MOUSE_UP,
  CG_MOUSE_MOVED,
  CG_OTHER_MOUSE_DOWN,
  CG_OTHER_MOUSE_DRAGGED,
  CG_OTHER_MOUSE_UP,
  CG_RIGHT_MOUSE_DOWN,
  CG_RIGHT_MOUSE_DRAGGED,
  CG_RIGHT_MOUSE_UP,
  X11_BUTTON1_MASK,
  X11_BUTTON2_MASK,
  X11_BUTTON3_MASK,
  X11_BUTTON_PRESS,
  X11_BUTTON_RELEASE,
  X11_EVENT_BUFFER_SIZE,
  X11_EVENT_DETAIL_OFFSET,
  X11_EVENT_STATE_OFFSET,
  X11_EVENT_TYPE_OFFSET,
  X11_EVENT_WINDOW_OFFSET,
  X11_EVENT_X_OFFSET,
  X11_EVENT_Y_OFFSET,
  X11_KEY_PRESS,
  X11_KEY_RELEASE,
  X11_MOTION_NOTIFY,
  clampFrame,
  clampNumber,
  errorToString,
  isNullValue,
  x11KeycodeToMacKeycode,
  x11StateToCGFlags,
  x11WindowHandleToNumber,
} from "./shared.js";
import { bridge, logOnce } from "./state.js";

export function findMirrorEntryByHandle(handle) {
  var target = x11WindowHandleToNumber(handle);
  if (target == null) {
    return null;
  }

  var found = null;
  bridge.windows.forEach(function (entry) {
    if (found != null) {
      return;
    }
    if (x11WindowHandleToNumber(entry.handle) === target) {
      found = entry;
    }
  });
  return found;
}

export function postCGEvent(event) {
  if (event == null || event.isNull()) {
    return;
  }

  if (bridge.renderSupport.CGEventPost != null) {
    bridge.renderSupport.CGEventPost(
      bridge.renderSupport.kCGSessionEventTap,
      event,
    );
  } else {
    bridge.renderSupport.CGEventPostToPid(Process.id, event);
  }
  bridge.renderSupport.CFRelease(event);
}

export function currentEventTimestamp() {
  try {
    return Number(ObjC.classes.NSProcessInfo.processInfo().systemUptime());
  } catch (e) {
    return 0;
  }
}

export function activateEntryWindow(entry) {
  if (entry == null || entry.window == null) {
    return;
  }

  try {
    ObjC.classes.NSApplication.sharedApplication().activateIgnoringOtherApps_(
      1,
    );
  } catch (e) {}

  try {
    entry.window.makeKeyAndOrderFront_(ptr(0));
  } catch (e) {}

  try {
    entry.window.makeMainWindow();
  } catch (e) {}
}

export function x11EventToWindowPoint(entry, eventPtr) {
  if (entry == null || entry.sourceFrame == null) {
    return [0, 0];
  }

  var localX = eventPtr.add(X11_EVENT_X_OFFSET).readS32();
  var localY = eventPtr.add(X11_EVENT_Y_OFFSET).readS32();
  var frame = clampFrame(entry.sourceFrame);
  var boundedX = clampNumber(localX, 0, Math.max(0, frame.size.width - 1));
  var boundedY = clampNumber(localY, 0, Math.max(0, frame.size.height - 1));

  return [boundedX, Math.max(0, frame.size.height - boundedY - 1)];
}

export function postWindowMouseEvent(
  entry,
  eventType,
  state,
  eventPtr,
  clickCount,
  pressure,
) {
  if (entry == null || entry.window == null) {
    return false;
  }

  var event = null;
  try {
    entry.window.setAcceptsMouseMovedEvents_(1);
  } catch (e) {}

  try {
    event =
      ObjC.classes.NSEvent.mouseEventWithType_location_modifierFlags_timestamp_windowNumber_context_eventNumber_clickCount_pressure_(
        eventType,
        x11EventToWindowPoint(entry, eventPtr),
        x11StateToCGFlags(state),
        currentEventTimestamp(),
        Number(entry.window.windowNumber()),
        ptr(0),
        bridge.nextEventNumber++,
        clickCount,
        pressure,
      );
  } catch (e) {
    logOnce(
      "appkit-mouse-event-failed",
      "failed to create AppKit mouse event: " + errorToString(e),
    );
    return false;
  }

  if (isNullValue(event)) {
    return false;
  }

  try {
    ObjC.classes.NSApplication.sharedApplication().sendEvent_(event);
    return true;
  } catch (e) {}

  try {
    entry.window.sendEvent_(event);
    return true;
  } catch (e) {
    logOnce(
      "appkit-mouse-send-failed",
      "failed to deliver AppKit mouse event: " + errorToString(e),
    );
    return false;
  }
}

export function forwardMouseEvent(eventPtr, pressed) {
  var entry = findMirrorEntryByHandle(
    eventPtr.add(X11_EVENT_WINDOW_OFFSET).readPointer(),
  );
  if (entry == null) {
    return;
  }

  var detail = eventPtr.add(X11_EVENT_DETAIL_OFFSET).readU32();
  var state = eventPtr.add(X11_EVENT_STATE_OFFSET).readU32();
  var eventType = null;
  var pressure = 0.0;

  switch (detail) {
    case 1:
      eventType = pressed ? CG_LEFT_MOUSE_DOWN : CG_LEFT_MOUSE_UP;
      pressure = pressed ? 1.0 : 0.0;
      break;
    case 2:
      eventType = pressed ? CG_OTHER_MOUSE_DOWN : CG_OTHER_MOUSE_UP;
      pressure = pressed ? 1.0 : 0.0;
      break;
    case 3:
      eventType = pressed ? CG_RIGHT_MOUSE_DOWN : CG_RIGHT_MOUSE_UP;
      pressure = pressed ? 1.0 : 0.0;
      break;
    default:
      return;
  }

  activateEntryWindow(entry);
  postWindowMouseEvent(entry, eventType, state, eventPtr, 1, pressure);
}

export function forwardMotionEvent(eventPtr) {
  var entry = findMirrorEntryByHandle(
    eventPtr.add(X11_EVENT_WINDOW_OFFSET).readPointer(),
  );
  if (entry == null) {
    return;
  }

  var state = eventPtr.add(X11_EVENT_STATE_OFFSET).readU32();
  var eventType = CG_MOUSE_MOVED;

  if ((state & X11_BUTTON1_MASK) !== 0) {
    eventType = CG_LEFT_MOUSE_DRAGGED;
  } else if ((state & X11_BUTTON2_MASK) !== 0) {
    eventType = CG_OTHER_MOUSE_DRAGGED;
  } else if ((state & X11_BUTTON3_MASK) !== 0) {
    eventType = CG_RIGHT_MOUSE_DRAGGED;
  }

  postWindowMouseEvent(entry, eventType, state, eventPtr, 0, 0.0);
}

export function forwardKeyEvent(eventPtr, pressed) {
  var entry = findMirrorEntryByHandle(
    eventPtr.add(X11_EVENT_WINDOW_OFFSET).readPointer(),
  );
  if (entry == null) {
    return;
  }

  var state = eventPtr.add(X11_EVENT_STATE_OFFSET).readU32();
  var keycode = eventPtr.add(X11_EVENT_DETAIL_OFFSET).readU32();
  var macKeyCode = x11KeycodeToMacKeycode(keycode);
  if (macKeyCode == null) {
    return;
  }

  activateEntryWindow(entry);

  var keyEvent = bridge.renderSupport.CGEventCreateKeyboardEvent(
    bridge.renderSupport.inputSource,
    macKeyCode & 0xffff,
    pressed ? 1 : 0,
  );
  if (keyEvent.isNull()) {
    throw new Error("CGEventCreateKeyboardEvent failed");
  }

  bridge.renderSupport.CGEventSetFlags(keyEvent, x11StateToCGFlags(state));
  postCGEvent(keyEvent);
}

export function pumpBridgeInput() {
  if (
    bridge.display == null ||
    bridge.display.isNull() ||
    bridge.x11 == null ||
    bridge.renderSupport == null
  ) {
    return;
  }

  while (bridge.x11.XPending(bridge.display) > 0) {
    var eventPtr = Memory.alloc(X11_EVENT_BUFFER_SIZE);
    bridge.x11.XNextEvent(bridge.display, eventPtr);

    switch (eventPtr.add(X11_EVENT_TYPE_OFFSET).readS32()) {
      case X11_KEY_PRESS:
        forwardKeyEvent(eventPtr, true);
        break;
      case X11_KEY_RELEASE:
        forwardKeyEvent(eventPtr, false);
        break;
      case X11_BUTTON_PRESS:
        forwardMouseEvent(eventPtr, true);
        break;
      case X11_BUTTON_RELEASE:
        forwardMouseEvent(eventPtr, false);
        break;
      case X11_MOTION_NOTIFY:
        forwardMotionEvent(eventPtr);
        break;
      default:
        break;
    }
  }
}
