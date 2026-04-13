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
  CG_SCROLL_WHEEL,
  CG_FLAGS_CHANGED,
  X11_BUTTON1_MASK,
  X11_BUTTON2_MASK,
  X11_BUTTON3_MASK,
  X11_BUTTON_PRESS,
  X11_BUTTON_RELEASE,
  X11_CONFIGURE_NOTIFY,
  X11_ENTER_NOTIFY,
  X11_EVENT_BUFFER_SIZE,
  X11_EVENT_DETAIL_OFFSET,
  X11_EVENT_STATE_OFFSET,
  X11_EVENT_TYPE_OFFSET,
  X11_EVENT_WINDOW_OFFSET,
  X11_EVENT_X_OFFSET,
  X11_EVENT_Y_OFFSET,
  X11_EVENT_X_ROOT_OFFSET,
  X11_EVENT_Y_ROOT_OFFSET,
  X11_FOCUS_IN,
  X11_FOCUS_OUT,
  X11_KEY_PRESS,
  X11_KEY_RELEASE,
  X11_LEAVE_NOTIFY,
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

export function postWindowKeyboardEvent(entry, eventPtr, pressed) {
  if (entry == null || entry.window == null) {
    return false;
  }

  var state = eventPtr.add(X11_EVENT_STATE_OFFSET).readU32();
  var keycode = eventPtr.add(X11_EVENT_DETAIL_OFFSET).readU32();
  var macKeyCode = x11KeycodeToMacKeycode(keycode);
  if (macKeyCode == null) {
    return false;
  }

  activateEntryWindow(entry);

  // Keep the key event local to AppKit; posting it globally would echo back
  // through XQuartz/X11 and produce a duplicate keystroke.
  var cgEvent = bridge.renderSupport.CGEventCreateKeyboardEvent(
    bridge.renderSupport.inputSource,
    macKeyCode & 0xffff,
    pressed ? 1 : 0,
  );
  if (isNullValue(cgEvent)) {
    logOnce("keyboard-create-failed", "CGEventCreateKeyboardEvent failed");
    return false;
  }

  try {
    bridge.renderSupport.CGEventSetFlags(cgEvent, x11StateToCGFlags(state));

    var event = null;
    try {
      event = ObjC.classes.NSEvent.eventWithCGEvent_(cgEvent);
    } catch (e) {}

    if (isNullValue(event)) {
      logOnce(
        "keyboard-nsevent-failed",
        "failed to bridge CGEvent into an AppKit keyboard event",
      );
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
        "appkit-key-send-failed",
        "failed to deliver AppKit keyboard event: " + errorToString(e),
      );
      return false;
    }
  } finally {
    bridge.renderSupport.CFRelease(cgEvent);
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

export function forwardScrollEvent(eventPtr, pressed) {
  var entry = findMirrorEntryByHandle(
    eventPtr.add(X11_EVENT_WINDOW_OFFSET).readPointer(),
  );
  if (entry == null) {
    return;
  }

  var detail = eventPtr.add(X11_EVENT_DETAIL_OFFSET).readU32();
  var state = eventPtr.add(X11_EVENT_STATE_OFFSET).readU32();
  var point = x11EventToWindowPoint(entry, eventPtr);

  var scrollX = 0;
  var scrollY = 0;
  var isContinuous = 0;

  switch (detail) {
    case 4:
      scrollY = 1;
      break;
    case 5:
      scrollY = -1;
      break;
    case 6:
      scrollX = -1;
      break;
    case 7:
      scrollX = 1;
      break;
    default:
      return;
  }

  activateEntryWindow(entry);

  var scrollEvent = bridge.renderSupport.CGEventCreateScrollWheelEvent2(
    bridge.renderSupport.inputSource,
    0,
    2,
    scrollY,
    scrollX,
  );
  if (scrollEvent.isNull()) {
    logOnce("scroll-create-failed", "CGEventCreateScrollWheelEvent failed");
    return;
  }

  bridge.renderSupport.CGEventSetDoubleValueField(
    scrollEvent,
    bridge.renderSupport.kCGScrollWheelEventFixedPtDeltaAxis1,
    scrollY,
  );
  bridge.renderSupport.CGEventSetDoubleValueField(
    scrollEvent,
    bridge.renderSupport.kCGScrollWheelEventFixedPtDeltaAxis2,
    scrollX,
  );
  bridge.renderSupport.CGEventSetDoubleValueField(
    scrollEvent,
    bridge.renderSupport.kCGScrollWheelEventPointDeltaAxis1,
    scrollY * 10.0,
  );
  bridge.renderSupport.CGEventSetDoubleValueField(
    scrollEvent,
    bridge.renderSupport.kCGScrollWheelEventPointDeltaAxis2,
    scrollX * 10.0,
  );
  bridge.renderSupport.CGEventSetIntegerValueField(
    scrollEvent,
    bridge.renderSupport.kCGScrollWheelEventIsContinuous,
    isContinuous,
  );

  postCGEvent(scrollEvent);
}

export function forwardContinuousScrollEvent(eventPtr) {
  var entry = findMirrorEntryByHandle(
    eventPtr.add(X11_EVENT_WINDOW_OFFSET).readPointer(),
  );
  if (entry == null) {
    return;
  }

  var state = eventPtr.add(X11_EVENT_STATE_OFFSET).readU32();
  var point = x11EventToWindowPoint(entry, eventPtr);

  var scrollX = eventPtr.add(X11_EVENT_X_OFFSET).readS32() / 100.0;
  var scrollY = eventPtr.add(X11_EVENT_Y_OFFSET).readS32() / 100.0;

  if (scrollX === 0 && scrollY === 0) {
    return;
  }

  activateEntryWindow(entry);

  var scrollEvent = bridge.renderSupport.CGEventCreateScrollWheelEvent(
    bridge.renderSupport.inputSource,
    0,
    2,
    Math.round(scrollY),
    Math.round(scrollX),
  );
  if (scrollEvent.isNull()) {
    return;
  }

  bridge.renderSupport.CGEventSetDoubleValueField(
    scrollEvent,
    bridge.renderSupport.kCGScrollWheelEventFixedPtDeltaAxis1,
    scrollY,
  );
  bridge.renderSupport.CGEventSetDoubleValueField(
    scrollEvent,
    bridge.renderSupport.kCGScrollWheelEventFixedPtDeltaAxis2,
    scrollX,
  );
  bridge.renderSupport.CGEventSetDoubleValueField(
    scrollEvent,
    bridge.renderSupport.kCGScrollWheelEventPointDeltaAxis1,
    scrollY * 10.0,
  );
  bridge.renderSupport.CGEventSetDoubleValueField(
    scrollEvent,
    bridge.renderSupport.kCGScrollWheelEventPointDeltaAxis2,
    scrollX * 10.0,
  );
  bridge.renderSupport.CGEventSetIntegerValueField(
    scrollEvent,
    bridge.renderSupport.kCGScrollWheelEventIsContinuous,
    1,
  );

  postCGEvent(scrollEvent);
}

export function forwardEnterNotify(eventPtr) {
  var entry = findMirrorEntryByHandle(
    eventPtr.add(X11_EVENT_WINDOW_OFFSET).readPointer(),
  );
  if (entry == null) {
    return;
  }

  var state = eventPtr.add(X11_EVENT_STATE_OFFSET).readU32();
  activateEntryWindow(entry);
  postWindowMouseEvent(entry, CG_MOUSE_MOVED, state, eventPtr, 0, 0.0);
}

export function forwardLeaveNotify(eventPtr) {
  var entry = findMirrorEntryByHandle(
    eventPtr.add(X11_EVENT_WINDOW_OFFSET).readPointer(),
  );
  if (entry == null) {
    return;
  }

  var state = eventPtr.add(X11_EVENT_STATE_OFFSET).readU32();
  postWindowMouseEvent(entry, CG_MOUSE_MOVED, state, eventPtr, 0, 0.0);
}

export function forwardFocusIn(eventPtr) {
  var entry = findMirrorEntryByHandle(
    eventPtr.add(X11_EVENT_WINDOW_OFFSET).readPointer(),
  );
  if (entry == null) {
    return;
  }

  try {
    activateEntryWindow(entry);
  } catch (e) {}

  try {
    entry.window.makeKeyAndOrderFront_(ptr(0));
  } catch (e) {}
}

export function forwardFocusOut(eventPtr) {
  var entry = findMirrorEntryByHandle(
    eventPtr.add(X11_EVENT_WINDOW_OFFSET).readPointer(),
  );
  if (entry == null) {
    return;
  }

  try {
    entry.window.orderOut_(ptr(0));
  } catch (e) {}
}

export function forwardConfigureNotify(eventPtr) {
  var entry = findMirrorEntryByHandle(
    eventPtr.add(X11_EVENT_WINDOW_OFFSET).readPointer(),
  );
  if (entry == null) {
    return;
  }

  var width = eventPtr.add(X11_EVENT_X_OFFSET).readS32();
  var height = eventPtr.add(X11_EVENT_Y_OFFSET).readS32();

  if (width > 0 && height > 0 && entry.window != null) {
    try {
      entry.window.setFrame_display_animate_(
        {
          origin: entry.window.frame().origin,
          size: { width: width, height: height },
        },
        1,
        0,
      );
    } catch (e) {}
  }
}

export function forwardKeyEvent(eventPtr, pressed) {
  var entry = findMirrorEntryByHandle(
    eventPtr.add(X11_EVENT_WINDOW_OFFSET).readPointer(),
  );
  if (entry == null) {
    return;
  }

  postWindowKeyboardEvent(entry, eventPtr, pressed);
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
        var detail = eventPtr.add(X11_EVENT_DETAIL_OFFSET).readU32();
        if (detail >= 4) {
          forwardScrollEvent(eventPtr, true);
        } else {
          forwardMouseEvent(eventPtr, true);
        }
        break;
      case X11_BUTTON_RELEASE:
        var releaseDetail = eventPtr.add(X11_EVENT_DETAIL_OFFSET).readU32();
        if (releaseDetail >= 4) {
          forwardScrollEvent(eventPtr, false);
        } else {
          forwardMouseEvent(eventPtr, false);
        }
        break;
      case X11_MOTION_NOTIFY:
        forwardMotionEvent(eventPtr);
        break;
      case X11_ENTER_NOTIFY:
        forwardEnterNotify(eventPtr);
        break;
      case X11_LEAVE_NOTIFY:
        forwardLeaveNotify(eventPtr);
        break;
      case X11_FOCUS_IN:
        forwardFocusIn(eventPtr);
        break;
      case X11_FOCUS_OUT:
        forwardFocusOut(eventPtr);
        break;
      case X11_CONFIGURE_NOTIFY:
        forwardConfigureNotify(eventPtr);
        break;
      default:
        break;
    }
  }
}
