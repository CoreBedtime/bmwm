import { errorToString, log } from "./shared.js";
import { bridge, logOnce } from "./state.js";
import { loadRenderSupport } from "./loaders.js";
import { pumpBridgeInput } from "./input.js";
import { ensureX11 } from "./render.js";
import { collectObjCDescriptors, syncMirrors } from "./windows.js";
import { installTitlebarPatch } from "./titlebar-patch.js";

export function refreshMirrors() {
  if (!ensureX11()) {
    return;
  }

  try {
    if (bridge.mode !== "objc") {
      return;
    }

    pumpBridgeInput();
    syncMirrors(collectObjCDescriptors());
    bridge.x11.XFlush(bridge.display);
  } catch (e) {
    log(
      "bridge refresh failed: " +
        errorToString(e) +
        (e != null && e.stack != null ? "\n" + e.stack : ""),
    );
  }
}

export function bridgeModeSupportsObjC() {
  if (typeof ObjC === "undefined" || ObjC == null) {
    return false;
  }
  if (!ObjC.available) {
    return false;
  }
  if (ObjC.classes == null) {
    return false;
  }
  return ObjC.classes.NSApplication != null && ObjC.classes.NSWindow != null;
}

export function scheduleRefresh() {
  if (bridge.mode !== "objc" || !bridgeModeSupportsObjC()) {
    return;
  }

  if (bridge.frameScheduled) {
    return;
  }

  bridge.frameScheduled = true;
  ObjC.schedule(ObjC.mainQueue, function () {
    bridge.frameScheduled = false;
    try {
      refreshMirrors();
    } catch (e) {
      log(
        "scheduled refresh failed: " +
          errorToString(e) +
          (e != null && e.stack != null ? "\n" + e.stack : ""),
      );
    }
  });
}

export function hookWindowSelector(selector) {
  var klass = ObjC.classes.NSWindow;
  if (klass == null || klass[selector] == null) {
    return;
  }

  Interceptor.attach(klass[selector].implementation, {
    onLeave: function () {
      ObjC.schedule(ObjC.mainQueue, function () {
        scheduleRefresh();
      });
    },
  });
}

export function hookBooleanSelector(klass, selector, argumentTypes, result) {
  if (klass == null || klass[selector] == null) {
    return;
  }

  var callback = new NativeCallback(
    function () {
      return result ? 1 : 0;
    },
    "bool",
    argumentTypes,
  );
  Interceptor.replace(klass[selector].implementation, callback);
  bridge.retainedCallbacks.push(callback);
}

export function installObjCHooks() {
  if (bridge.hooksInstalled) {
    return;
  }

  [
    "- makeKeyAndOrderFront:",
    "- orderFront:",
    "- orderFrontRegardless",
    "- setFrame:display:",
    "- setFrameOrigin:",
    "- setTitle:",
    "- miniaturize:",
    "- deminiaturize:",
    "- becomeKeyWindow",
    "- resignKeyWindow",
    "- orderOut:",
  ].forEach(function (selector) {
    hookWindowSelector(selector);
  });

  var appClass = ObjC.classes.NSApplication;
  if (appClass != null && appClass["- finishLaunching"] != null) {
    Interceptor.attach(appClass["- finishLaunching"].implementation, {
      onLeave: function () {
        ObjC.schedule(ObjC.mainQueue, function () {
          scheduleRefresh();
        });
      },
    });
  }

  hookBooleanSelector(appClass, "- isActive", ["pointer", "pointer"], true);
  hookBooleanSelector(appClass, "- _isActive", ["pointer", "pointer"], true);

  var windowClass = ObjC.classes.NSWindow;
  hookBooleanSelector(
    windowClass,
    "- isKeyWindow",
    ["pointer", "pointer"],
    true,
  );
  hookBooleanSelector(
    windowClass,
    "- isMainWindow",
    ["pointer", "pointer"],
    true,
  );
  hookBooleanSelector(
    windowClass,
    "- canBecomeKeyWindow",
    ["pointer", "pointer"],
    true,
  );
  hookBooleanSelector(
    windowClass,
    "- canBecomeMainWindow",
    ["pointer", "pointer"],
    true,
  );

  bridge.hooksInstalled = true;
}

export function installBridge() {
  if (bridge.installed) {
    return true;
  }

  if (!ensureX11()) {
    return false;
  }

  if (!bridgeModeSupportsObjC()) {
    logOnce("objc-wait", "waiting for ObjC/AppKit runtime for layer bridge");
    return false;
  }

  loadRenderSupport();
  bridge.mode = "objc";
  installObjCHooks();
  installTitlebarPatch();
  log("bridge mode: " + bridge.mode);

  bridge.refreshTimer = setInterval(
    function () {
      scheduleRefresh();
    },
    Math.floor(1000 / 60),
  );

  scheduleRefresh();
  bridge.installed = true;
  log("bridge installed at 60 fps");
  return true;
}

export function startBridgeBootstrap() {
  if (bridge.installTimer != null || bridge.installed) {
    return;
  }

  log("waiting for bridge runtime");
  bridge.installTimer = setInterval(function () {
    if (installBridge()) {
      clearInterval(bridge.installTimer);
      bridge.installTimer = null;
      return;
    }

    if (bridge.bootstrapFatal) {
      logOnce(
        "bootstrap-stopped",
        "bridge bootstrap stopped after a fatal initialization failure",
      );
      clearInterval(bridge.installTimer);
      bridge.installTimer = null;
    }
  }, 100);
}
