import {
  errorToString,
  isNullValue,
  isZeroValue,
  normalizeFrame,
} from "./shared.js";
import { bridge, frameToX11Bounds, logOnce } from "./state.js";
import { cfNumberToInt, cfStringToJsString, coreGraphicsKey } from "./loaders.js";
import {
  destroyMirrorSurface,
  renderCoreGraphicsDescriptor,
  renderObjCDescriptor,
} from "./render.js";

export function selectMirrorInput(handle) {
  var eventMask =
    (1 << 0) |
    (1 << 1) |
    (1 << 2) |
    (1 << 3) |
    (1 << 4) |
    (1 << 5) |
    (1 << 6) |
    (1 << 7) |
    (1 << 8) |
    (1 << 9) |
    (1 << 10) |
    (1 << 15) |
    (1 << 17) |
    (1 << 21) |
    (1 << 22);

  bridge.x11.XSelectInput(bridge.display, handle, eventMask);
}

export function makeMirrorWindow(title, frame, raise) {
  var screen = bridge.x11.XDefaultScreen(bridge.display);
  var root = bridge.x11.XRootWindow(bridge.display, screen);
  var bounds = frameToX11Bounds(frame);
  var handle = bridge.x11.XCreateSimpleWindow(
    bridge.display,
    root,
    bounds.origin.x,
    bounds.origin.y,
    bounds.size.width,
    bounds.size.height,
    1,
    0x101010,
    0x2a2a2a,
  );

  if (isZeroValue(handle)) {
    throw new Error("XCreateSimpleWindow failed");
  }

  selectMirrorInput(handle);
  bridge.x11.XStoreName(bridge.display, handle, Memory.allocUtf8String(title));
  bridge.x11.XMapWindow(bridge.display, handle);
  if (raise && bridge.x11.XRaiseWindow != null) {
    bridge.x11.XRaiseWindow(bridge.display, handle);
  }
  bridge.x11.XFlush(bridge.display);
  return handle;
}

export function updateMirrorEntry(entry, title, frame, raise) {
  var bounds = frameToX11Bounds(frame);
  var geometryChanged =
    entry.x !== bounds.origin.x ||
    entry.y !== bounds.origin.y ||
    entry.width !== bounds.size.width ||
    entry.height !== bounds.size.height;
  var titleChanged = entry.title !== title;
  var shouldRaise = raise && !entry.raised;

  if (!entry.mapped) {
    bridge.x11.XMapWindow(bridge.display, entry.handle);
    entry.mapped = true;
  }

  if (geometryChanged) {
    bridge.x11.XMoveResizeWindow(
      bridge.display,
      entry.handle,
      bounds.origin.x,
      bounds.origin.y,
      bounds.size.width,
      bounds.size.height,
    );
  }
  if (titleChanged) {
    bridge.x11.XStoreName(
      bridge.display,
      entry.handle,
      Memory.allocUtf8String(title),
    );
  }
  if (shouldRaise && bridge.x11.XRaiseWindow != null) {
    bridge.x11.XRaiseWindow(bridge.display, entry.handle);
  }

  entry.x = bounds.origin.x;
  entry.y = bounds.origin.y;
  entry.width = bounds.size.width;
  entry.height = bounds.size.height;
  entry.title = title;
  entry.raised = raise;
}

export function destroyMirrorEntry(key) {
  var entry = bridge.windows.get(key);
  if (entry == null) {
    return;
  }

  destroyMirrorSurface(entry);
  if (entry.gc != null && !entry.gc.isNull()) {
    bridge.x11.XFreeGC(bridge.display, entry.gc);
    entry.gc = ptr(0);
  }

  if (!isZeroValue(entry.handle)) {
    bridge.x11.XDestroyWindow(bridge.display, entry.handle);
    bridge.x11.XFlush(bridge.display);
  }
  bridge.windows.delete(key);
}

export function syncMirrorWindow(descriptor) {
  var entry = bridge.windows.get(descriptor.key);
  var bounds = frameToX11Bounds(descriptor.frame);
  if (entry == null) {
    entry = {
      handle: makeMirrorWindow(
        descriptor.title,
        descriptor.frame,
        descriptor.raise,
      ),
      mapped: true,
      gc: ptr(0),
      image: ptr(0),
      imageData: ptr(0),
      bitmapContext: ptr(0),
      surfaceWidth: 0,
      surfaceHeight: 0,
      dataSize: 0,
      x: bounds.origin.x,
      y: bounds.origin.y,
      width: bounds.size.width,
      height: bounds.size.height,
      sourceFrame: descriptor.frame,
      window: descriptor.window != null ? descriptor.window : null,
      title: descriptor.title,
      raised: descriptor.raise,
      windowNumber: descriptor.windowNumber != null ? descriptor.windowNumber : null,
    };
    bridge.windows.set(descriptor.key, entry);
    return entry;
  }

  updateMirrorEntry(
    entry,
    descriptor.title,
    descriptor.frame,
    descriptor.raise,
  );
  entry.sourceFrame = descriptor.frame;
  entry.window = descriptor.window != null ? descriptor.window : null;
  entry.windowNumber =
    descriptor.windowNumber != null ? descriptor.windowNumber : null;
  return entry;
}

export function syncMirrors(descriptors) {
  var seen = {};

  for (var i = 0; i < descriptors.length; i++) {
    var descriptor = descriptors[i];
    seen[descriptor.key] = true;
    var entry = syncMirrorWindow(descriptor);
    if (bridge.mode === "objc") {
      renderObjCDescriptor(entry, descriptor);
    } else if (bridge.mode === "coregraphics") {
      renderCoreGraphicsDescriptor(entry, descriptor);
    }
  }

  bridge.windows.forEach(function (_, key) {
    if (!seen[key]) {
      destroyMirrorEntry(key);
    }
  });
}

export function appendObjCDescriptor(descriptors, window) {
  var frame;
  var visible = true;
  var miniaturized = false;
  var title = "AppLaunch";
  var raise = false;
  var key = null;

  try {
    frame = window.frame();
  } catch (e) {
    return;
  }

  frame = normalizeFrame(frame);
  if (frame == null) {
    logOnce(
      "invalid-window-frame",
      "skipping window with unsupported frame shape from bundled ObjC bridge",
    );
    return;
  }

  try {
    visible = window.isVisible();
  } catch (e) {
    visible = true;
  }

  try {
    miniaturized = window.isMiniaturized();
  } catch (e) {
    miniaturized = false;
  }

  if (!visible || miniaturized) {
    return;
  }

  try {
    var nsTitle = window.title();
    if (nsTitle != null) {
      title = nsTitle.toString();
    }
  } catch (e) {
    title = "AppLaunch";
  }

  try {
    raise = window.isKeyWindow() || window.isMainWindow();
  } catch (e) {
    raise = false;
  }

  try {
    var nativeId = window.windowNumber();
    if (!isZeroValue(nativeId)) {
      key = "objc:" + nativeId.toString();
    }
  } catch (e) {
    key = null;
  }

  if (key == null) {
    var handle = window.handle;
    if (isNullValue(handle)) {
      handle = window.$handle;
    }
    if (isNullValue(handle)) {
      return;
    }
    key = "objc-ptr:" + handle.toString();
  }

  descriptors.push({
    key: key,
    title: title,
    frame: frame,
    raise: raise,
    window: window,
  });
}

export function collectObjCDescriptorsFromApplication() {
  var descriptors = [];
  var app = ObjC.classes.NSApplication.sharedApplication();
  var windows = app.windows();
  var count = windows.count();

  for (var i = 0; i < count; i++) {
    var window = windows.objectAtIndex_(i);
    appendObjCDescriptor(descriptors, window);
  }

  return descriptors;
}

export function collectObjCDescriptorsFromChooseSync() {
  var descriptors = [];
  var windows = ObjC.chooseSync({ class: ObjC.classes.NSWindow });
  for (var i = 0; i < windows.length; i++) {
    appendObjCDescriptor(descriptors, windows[i]);
  }
  return descriptors;
}

export function collectObjCDescriptors() {
  try {
    return collectObjCDescriptorsFromApplication();
  } catch (e) {
    logOnce(
      "objc-window-list-failed",
      "ObjC window-list enumeration failed: " + errorToString(e),
    );
  }

  try {
    return collectObjCDescriptorsFromChooseSync();
  } catch (e) {
    logOnce(
      "objc-choose-failed",
      "ObjC chooseSync fallback failed: " + errorToString(e),
    );
    return [];
  }
}

export function collectCoreGraphicsDescriptors() {
  var cg = bridge.coreGraphics;
  var descriptors = [];
  var windows = cg.CGWindowListCopyWindowInfo(
    cg.kCGWindowListOptionOnScreenOnly,
    0,
  );

  if (windows == null || windows.isNull()) {
    return descriptors;
  }

  try {
    var count = cg.CFArrayGetCount(windows);
    for (var i = 0; i < count; i++) {
      var windowInfo = cg.CFArrayGetValueAtIndex(windows, i);
      if (windowInfo == null || windowInfo.isNull()) {
        continue;
      }

      var ownerPid = cfNumberToInt(
        cg,
        cg.CFDictionaryGetValue(
          windowInfo,
          coreGraphicsKey(cg, "kCGWindowOwnerPID"),
        ),
      );
      var windowNumber = cfNumberToInt(
        cg,
        cg.CFDictionaryGetValue(
          windowInfo,
          coreGraphicsKey(cg, "kCGWindowNumber"),
        ),
      );
      var layer = cfNumberToInt(
        cg,
        cg.CFDictionaryGetValue(
          windowInfo,
          coreGraphicsKey(cg, "kCGWindowLayer"),
        ),
      );

      if (
        ownerPid == null ||
        ownerPid !== Process.id ||
        windowNumber == null ||
        windowNumber === 0
      ) {
        continue;
      }
      if (layer != null && layer !== 0) {
        continue;
      }

      var title = cfStringToJsString(
        cg,
        cg.CFDictionaryGetValue(
          windowInfo,
          coreGraphicsKey(cg, "kCGWindowName"),
        ),
      );
      if (title == null || title.length === 0) {
        title = cfStringToJsString(
          cg,
          cg.CFDictionaryGetValue(
            windowInfo,
            coreGraphicsKey(cg, "kCGWindowOwnerName"),
          ),
        );
      }
      if (title == null || title.length === 0) {
        title = "AppLaunch";
      }

      var boundsRef = cg.CFDictionaryGetValue(
        windowInfo,
        coreGraphicsKey(cg, "kCGWindowBounds"),
      );
      if (boundsRef == null || boundsRef.isNull()) {
        continue;
      }

      var x = cfNumberToInt(
        cg,
        cg.CFDictionaryGetValue(boundsRef, coreGraphicsKey(cg, "X")),
      );
      var y = cfNumberToInt(
        cg,
        cg.CFDictionaryGetValue(boundsRef, coreGraphicsKey(cg, "Y")),
      );
      var width = cfNumberToInt(
        cg,
        cg.CFDictionaryGetValue(boundsRef, coreGraphicsKey(cg, "Width")),
      );
      var height = cfNumberToInt(
        cg,
        cg.CFDictionaryGetValue(boundsRef, coreGraphicsKey(cg, "Height")),
      );

      if (
        x == null ||
        y == null ||
        width == null ||
        height == null ||
        width <= 0 ||
        height <= 0
      ) {
        continue;
      }

      descriptors.push({
        key: "cg:" + windowNumber.toString(),
        windowNumber: windowNumber,
        title: title,
        frame: {
          origin: { x: x, y: y },
          size: { width: width, height: height },
        },
        raise: false,
      });
    }
  } finally {
    cg.CFRelease(windows);
  }

  return descriptors;
}
