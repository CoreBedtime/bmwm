import {
  errorToString,
  isNullValue,
  resolveExport,
} from "./shared.js";
import {
  bridge,
  getLoaderApiCache,
  getObjCMsgSendVoidCache,
  logOnce,
  setLoaderApiCache,
  setObjCMsgSendVoidCache,
} from "./state.js";

export function getLoaderApi() {
  var loaderApi = getLoaderApiCache();
  if (loaderApi != null) {
    return loaderApi;
  }

  loaderApi = {
    dlopen: new NativeFunction(resolveExport(null, "dlopen"), "pointer", [
      "pointer",
      "int",
    ]),
    dlerror: new NativeFunction(resolveExport(null, "dlerror"), "pointer", []),
    RTLD_NOW: 0x2,
    RTLD_GLOBAL: 0x8,
  };

  setLoaderApiCache(loaderApi);
  return loaderApi;
}

export function loadSharedLibrary(path) {
  var api = getLoaderApi();
  api.dlerror();
  var handle = api.dlopen(
    Memory.allocUtf8String(path),
    api.RTLD_NOW | api.RTLD_GLOBAL,
  );
  if (handle.isNull()) {
    var errorPtr = api.dlerror();
    var dlopenError = "dlopen failed for " + path;
    if (errorPtr != null && !errorPtr.isNull()) {
      dlopenError += ": " + errorPtr.readUtf8String();
    }
    throw new Error(dlopenError);
  }
  return {
    modulePath: path,
    handle: handle,
  };
}

export function preloadX11Dependencies(baseDir) {
  [baseDir + "/libXau.6.dylib", baseDir + "/libxcb.1.dylib"].forEach(
    function (dependencyPath) {
      loadSharedLibrary(dependencyPath);
    },
  );
}

export function loadXplugin() {
  if (bridge.xpluginLoadAttempted) {
    return bridge.xplugin;
  }

  bridge.xpluginLoadAttempted = true;

  try {
    var xpluginModule = loadSharedLibrary("/usr/lib/libXplugin.1.dylib");
    bridge.xplugin = {
      modulePath: xpluginModule.modulePath,
      xpApiVersion: new NativeFunction(
        resolveExport(null, "xp_api_version"),
        "uint32",
        [],
      ),
    };
    return bridge.xplugin;
  } catch (e) {
    bridge.xpluginLoadError = errorToString(e);
    logOnce(
      "xplugin-load-failed",
      "failed to load /usr/lib/libXplugin.1.dylib: " + bridge.xpluginLoadError,
    );
    bridge.xplugin = null;
    return null;
  }
}

export function loadX11() {
  if (bridge.x11 != null) {
    return bridge.x11;
  }
  if (bridge.x11LoadAttempted) {
    return null;
  }

  bridge.x11LoadAttempted = true;

  var candidates = [
    "/opt/X11/lib/libX11.dylib",
    "/opt/X11/lib/libX11.6.dylib",
    "/usr/X11/lib/libX11.dylib",
    "/usr/X11/lib/libX11.6.dylib",
  ];
  var errors = [];

  for (var i = 0; i < candidates.length; i++) {
    try {
      var candidate = candidates[i];
      preloadX11Dependencies(
        candidate.substring(0, candidate.lastIndexOf("/")),
      );
      var x11Module = loadSharedLibrary(candidate);

      bridge.x11 = {
        modulePath: x11Module.modulePath,
        XOpenDisplay: new NativeFunction(
          resolveExport(null, "XOpenDisplay"),
          "pointer",
          ["pointer"],
        ),
        XDefaultScreen: new NativeFunction(
          resolveExport(null, "XDefaultScreen"),
          "int",
          ["pointer"],
        ),
        XDisplayHeight: new NativeFunction(
          resolveExport(null, "XDisplayHeight"),
          "int",
          ["pointer", "int"],
        ),
        XDefaultVisual: new NativeFunction(
          resolveExport(null, "XDefaultVisual"),
          "pointer",
          ["pointer", "int"],
        ),
        XDefaultDepth: new NativeFunction(
          resolveExport(null, "XDefaultDepth"),
          "int",
          ["pointer", "int"],
        ),
        XRootWindow: new NativeFunction(
          resolveExport(null, "XRootWindow"),
          "uint64",
          ["pointer", "int"],
        ),
        XCreateSimpleWindow: new NativeFunction(
          resolveExport(null, "XCreateSimpleWindow"),
          "uint64",
          [
            "pointer",
            "uint64",
            "int",
            "int",
            "uint32",
            "uint32",
            "uint32",
            "uint64",
            "uint64",
          ],
        ),
        XCreateGC: new NativeFunction(
          resolveExport(null, "XCreateGC"),
          "pointer",
          ["pointer", "uint64", "uint64", "pointer"],
        ),
        XFreeGC: new NativeFunction(resolveExport(null, "XFreeGC"), "int", [
          "pointer",
          "pointer",
        ]),
        XCreateImage: new NativeFunction(
          resolveExport(null, "XCreateImage"),
          "pointer",
          [
            "pointer",
            "pointer",
            "uint32",
            "int",
            "int",
            "pointer",
            "uint32",
            "uint32",
            "int",
            "int",
          ],
        ),
        XDestroyImage: new NativeFunction(
          resolveExport(null, "XDestroyImage"),
          "int",
          ["pointer"],
        ),
        XPutImage: new NativeFunction(resolveExport(null, "XPutImage"), "int", [
          "pointer",
          "uint64",
          "pointer",
          "pointer",
          "int",
          "int",
          "int",
          "int",
          "uint32",
          "uint32",
        ]),
        XMoveResizeWindow: new NativeFunction(
          resolveExport(null, "XMoveResizeWindow"),
          "int",
          ["pointer", "uint64", "int", "int", "uint32", "uint32"],
        ),
        XMapWindow: new NativeFunction(
          resolveExport(null, "XMapWindow"),
          "int",
          ["pointer", "uint64"],
        ),
        XUnmapWindow: new NativeFunction(
          resolveExport(null, "XUnmapWindow"),
          "int",
          ["pointer", "uint64"],
        ),
        XDestroyWindow: new NativeFunction(
          resolveExport(null, "XDestroyWindow"),
          "int",
          ["pointer", "uint64"],
        ),
        XRaiseWindow: new NativeFunction(
          resolveExport(null, "XRaiseWindow"),
          "int",
          ["pointer", "uint64"],
        ),
        XStoreName: new NativeFunction(
          resolveExport(null, "XStoreName"),
          "int",
          ["pointer", "uint64", "pointer"],
        ),
        XSelectInput: new NativeFunction(
          resolveExport(null, "XSelectInput"),
          "int",
          ["pointer", "uint64", "ulong"],
        ),
        XPending: new NativeFunction(resolveExport(null, "XPending"), "int", [
          "pointer",
        ]),
        XNextEvent: new NativeFunction(
          resolveExport(null, "XNextEvent"),
          "int",
          ["pointer", "pointer"],
        ),
        XFlush: new NativeFunction(resolveExport(null, "XFlush"), "int", [
          "pointer",
        ]),
        XSync: new NativeFunction(resolveExport(null, "XSync"), "int", [
          "pointer",
          "bool",
        ]),
      };
      loadXplugin();
      return bridge.x11;
    } catch (e) {
      errors.push(candidates[i] + ": " + errorToString(e));
    }
  }

  bridge.x11LoadError =
    errors.length === 0
      ? "no libX11 candidates were configured"
      : errors.join(" | ");
  return null;
}

export function loadRenderSupport() {
  if (bridge.renderSupport != null) {
    return bridge.renderSupport;
  }

  var module = loadSharedLibrary(
    "/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics",
  );
  var renderSupport = {
    modulePath: module.modulePath,
    malloc: new NativeFunction(resolveExport(null, "malloc"), "pointer", [
      "ulong",
    ]),
    memset: new NativeFunction(resolveExport(null, "memset"), "pointer", [
      "pointer",
      "int",
      "ulong",
    ]),
    CGColorSpaceCreateDeviceRGB: new NativeFunction(
      resolveExport(null, "CGColorSpaceCreateDeviceRGB"),
      "pointer",
      [],
    ),
    CGBitmapContextCreate: new NativeFunction(
      resolveExport(null, "CGBitmapContextCreate"),
      "pointer",
      ["pointer", "ulong", "ulong", "ulong", "ulong", "pointer", "uint32"],
    ),
    CGContextTranslateCTM: new NativeFunction(
      resolveExport(null, "CGContextTranslateCTM"),
      "void",
      ["pointer", "double", "double"],
    ),
    CGContextScaleCTM: new NativeFunction(
      resolveExport(null, "CGContextScaleCTM"),
      "void",
      ["pointer", "double", "double"],
    ),
    CGContextRelease: new NativeFunction(
      resolveExport(null, "CGContextRelease"),
      "void",
      ["pointer"],
    ),
    CGColorSpaceRelease: new NativeFunction(
      resolveExport(null, "CGColorSpaceRelease"),
      "void",
      ["pointer"],
    ),
    CFRelease: new NativeFunction(resolveExport(null, "CFRelease"), "void", [
      "pointer",
    ]),
    CGEventSourceCreate: new NativeFunction(
      resolveExport(null, "CGEventSourceCreate"),
      "pointer",
      ["int"],
    ),
    CGEventSourceSetLocalEventsSuppressionInterval: new NativeFunction(
      resolveExport(null, "CGEventSourceSetLocalEventsSuppressionInterval"),
      "void",
      ["pointer", "double"],
    ),
    CGEventCreateMouseEvent: new NativeFunction(
      resolveExport(null, "CGEventCreateMouseEvent"),
      "pointer",
      ["pointer", "uint32", ["double", "double"], "uint32"],
    ),
    CGEventCreateKeyboardEvent: new NativeFunction(
      resolveExport(null, "CGEventCreateKeyboardEvent"),
      "pointer",
      ["pointer", "uint16", "bool"],
    ),
    CGEventSetFlags: new NativeFunction(
      resolveExport(null, "CGEventSetFlags"),
      "void",
      ["pointer", "uint64"],
    ),
    CGEventPost: new NativeFunction(
      resolveExport(null, "CGEventPost"),
      "void",
      ["uint32", "pointer"],
    ),
    CGEventPostToPid: new NativeFunction(
      resolveExport(null, "CGEventPostToPid"),
      "void",
      ["int", "pointer"],
    ),
    kCGBitmapByteOrder32Little: 0x2000,
    kCGImageAlphaPremultipliedFirst: 2,
    kCGEventSourceStateCombinedSessionState: 0,
    kCGSessionEventTap: 1,
    kZPixmap: 2,
  };

  renderSupport.colorSpace = renderSupport.CGColorSpaceCreateDeviceRGB();
  if (renderSupport.colorSpace.isNull()) {
    throw new Error("CGColorSpaceCreateDeviceRGB failed");
  }

  renderSupport.inputSource = renderSupport.CGEventSourceCreate(
    renderSupport.kCGEventSourceStateCombinedSessionState,
  );
  if (renderSupport.inputSource.isNull()) {
    throw new Error("CGEventSourceCreate failed");
  }
  try {
    renderSupport.CGEventSourceSetLocalEventsSuppressionInterval(
      renderSupport.inputSource,
      0.0,
    );
  } catch (e) {}

  bridge.renderSupport = renderSupport;
  return renderSupport;
}

export function loadCoreGraphics() {
  if (bridge.coreGraphics != null) {
    return bridge.coreGraphics;
  }
  if (bridge.coreGraphicsLoadAttempted) {
    return null;
  }

  bridge.coreGraphicsLoadAttempted = true;

  try {
    var module = loadSharedLibrary(
      "/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics",
    );
    bridge.coreGraphics = {
      modulePath: module.modulePath,
      CGWindowListCopyWindowInfo: new NativeFunction(
        resolveExport(null, "CGWindowListCopyWindowInfo"),
        "pointer",
        ["uint32", "uint32"],
      ),
      CGWindowListCreateImage: new NativeFunction(
        resolveExport(null, "CGWindowListCreateImage"),
        "pointer",
        [
          ["double", "double", "double", "double"],
          "uint32",
          "uint32",
          "uint32",
        ],
      ),
      CGImageGetWidth: new NativeFunction(
        resolveExport(null, "CGImageGetWidth"),
        "ulong",
        ["pointer"],
      ),
      CGImageGetHeight: new NativeFunction(
        resolveExport(null, "CGImageGetHeight"),
        "ulong",
        ["pointer"],
      ),
      CGImageGetBytesPerRow: new NativeFunction(
        resolveExport(null, "CGImageGetBytesPerRow"),
        "ulong",
        ["pointer"],
      ),
      CGImageGetDataProvider: new NativeFunction(
        resolveExport(null, "CGImageGetDataProvider"),
        "pointer",
        ["pointer"],
      ),
      CGDataProviderCopyData: new NativeFunction(
        resolveExport(null, "CGDataProviderCopyData"),
        "pointer",
        ["pointer"],
      ),
      CFArrayGetCount: new NativeFunction(
        resolveExport(null, "CFArrayGetCount"),
        "long",
        ["pointer"],
      ),
      CFArrayGetValueAtIndex: new NativeFunction(
        resolveExport(null, "CFArrayGetValueAtIndex"),
        "pointer",
        ["pointer", "long"],
      ),
      CFDataGetBytePtr: new NativeFunction(
        resolveExport(null, "CFDataGetBytePtr"),
        "pointer",
        ["pointer"],
      ),
      CFDataGetLength: new NativeFunction(
        resolveExport(null, "CFDataGetLength"),
        "long",
        ["pointer"],
      ),
      CFDictionaryGetValue: new NativeFunction(
        resolveExport(null, "CFDictionaryGetValue"),
        "pointer",
        ["pointer", "pointer"],
      ),
      CFNumberGetValue: new NativeFunction(
        resolveExport(null, "CFNumberGetValue"),
        "bool",
        ["pointer", "int", "pointer"],
      ),
      CFStringCreateWithCString: new NativeFunction(
        resolveExport(null, "CFStringCreateWithCString"),
        "pointer",
        ["pointer", "pointer", "uint32"],
      ),
      CFStringGetCString: new NativeFunction(
        resolveExport(null, "CFStringGetCString"),
        "bool",
        ["pointer", "pointer", "long", "uint32"],
      ),
      CFRelease: new NativeFunction(resolveExport(null, "CFRelease"), "void", [
        "pointer",
      ]),
      CGImageRelease: new NativeFunction(
        resolveExport(null, "CGImageRelease"),
        "void",
        ["pointer"],
      ),
      kCGWindowListOptionOnScreenOnly: 1,
      kCGWindowListOptionIncludingWindow: 8,
      kCGWindowImageDefault: 0,
      kCGWindowImageBoundsIgnoreFraming: 1,
      kCFNumberSInt32Type: 3,
      kCFStringEncodingUTF8: 0x08000100,
      keys: {},
    };
    return bridge.coreGraphics;
  } catch (e) {
    bridge.coreGraphicsLoadError = errorToString(e);
    logOnce(
      "coregraphics-load-failed",
      "failed to load CoreGraphics: " + bridge.coreGraphicsLoadError,
    );
    return null;
  }
}

export function cfStringToJsString(cg, cfString) {
  if (cg == null || cfString == null || cfString.isNull()) {
    return null;
  }

  var buffer = Memory.alloc(1024);
  if (
    !cg.CFStringGetCString(cfString, buffer, 1024, cg.kCFStringEncodingUTF8)
  ) {
    return null;
  }
  return buffer.readUtf8String();
}

export function cfNumberToInt(cg, cfNumber) {
  if (cg == null || cfNumber == null || cfNumber.isNull()) {
    return null;
  }

  var storage = Memory.alloc(4);
  if (!cg.CFNumberGetValue(cfNumber, cg.kCFNumberSInt32Type, storage)) {
    return null;
  }
  return storage.readS32();
}

export function coreGraphicsKey(cg, name) {
  if (cg.keys[name] == null) {
    cg.keys[name] = cg.CFStringCreateWithCString(
      ptr(0),
      Memory.allocUtf8String(name),
      cg.kCFStringEncodingUTF8,
    );
  }
  return cg.keys[name];
}

export function getObjCMsgSendVoid() {
  var objcMsgSendVoid = getObjCMsgSendVoidCache();
  if (objcMsgSendVoid != null) {
    return objcMsgSendVoid;
  }

  var rawMsgSend = ObjC.api.objc_msgSend;
  if (typeof rawMsgSend === "function") {
    objcMsgSendVoid = rawMsgSend;
  } else {
    objcMsgSendVoid = new NativeFunction(rawMsgSend, "void", [
      "pointer",
      "pointer",
      "pointer",
    ]);
  }

  setObjCMsgSendVoidCache(objcMsgSendVoid);
  return objcMsgSendVoid;
}

export function renderLayerInContext(layer, context) {
  var handle = null;
  try {
    handle = layer.$handle;
  } catch (e) {}
  if (handle == null) {
    try {
      handle = layer.handle;
    } catch (e) {}
  }
  if (isNullValue(handle)) {
    handle = null;
  }

  var renderError = null;

  if (handle != null) {
    try {
      getObjCMsgSendVoid()(handle, ObjC.selector("renderInContext:"), context);
      return;
    } catch (e) {
      renderError = e;
    }
  }

  if (layer != null && typeof layer.renderInContext_ === "function") {
    layer.renderInContext_(context);
    return;
  }

  if (renderError != null) {
    throw renderError;
  }

  throw new Error("CALayer renderInContext unavailable");
}
