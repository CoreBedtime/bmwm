import { errorToString, clampFrame, isNullValue } from "./shared.js";
import { bridge, logOnce } from "./state.js";
import { loadRenderSupport, loadX11, renderLayerInContext } from "./loaders.js";

export function ensureX11() {
  if (bridge.display != null && !bridge.display.isNull()) {
    return true;
  }

  if (bridge.displayName == null || bridge.displayName.length === 0) {
    bridge.bootstrapFatal = true;
    logOnce("display-unset", "DISPLAY is unset, skipping X11 bridge");
    return false;
  }

  bridge.x11 = loadX11();
  if (bridge.x11 == null) {
    bridge.bootstrapFatal = true;
    logOnce("x11-load-failed", "failed to load libX11: " + bridge.x11LoadError);
    return false;
  }

  bridge.display = bridge.x11.XOpenDisplay(
    Memory.allocUtf8String(bridge.displayName),
  );
  if (bridge.display.isNull()) {
    logOnce(
      "x11-open-failed:" + bridge.displayName,
      "failed to open X11 display " + bridge.displayName,
    );
    bridge.display = ptr(0);
    return false;
  }

  try {
    bridge.displayHeight = bridge.x11.XDisplayHeight(
      bridge.display,
      bridge.x11.XDefaultScreen(bridge.display),
    );
  } catch (e) {
    bridge.displayHeight = 0;
  }

  logOnce(
    "x11-connected",
    "connected to X11 display " +
      bridge.displayName +
      " via " +
      bridge.x11.modulePath,
  );
  if (bridge.xplugin != null) {
    try {
      logOnce(
        "xplugin-version",
        "detected Xplugin API v" + bridge.xplugin.xpApiVersion(),
      );
    } catch (e) {
      logOnce(
        "xplugin-version-failed",
        "detected Xplugin but failed to query version: " + errorToString(e),
      );
    }
  }
  return true;
}

export function destroyMirrorSurface(entry) {
  if (entry == null) {
    return;
  }

  if (entry.bitmapContext != null && !entry.bitmapContext.isNull()) {
    bridge.renderSupport.CGContextRelease(entry.bitmapContext);
    entry.bitmapContext = ptr(0);
  }

  if (entry.image != null && !entry.image.isNull()) {
    bridge.x11.XDestroyImage(entry.image);
    entry.image = ptr(0);
    entry.imageData = ptr(0);
  }
}

export function ensureMirrorSurface(entry, bounds) {
  var width = bounds.size.width;
  var height = bounds.size.height;

  if (entry.gc == null || entry.gc.isNull()) {
    entry.gc = bridge.x11.XCreateGC(bridge.display, entry.handle, 0, ptr(0));
    if (entry.gc.isNull()) {
      throw new Error("XCreateGC failed");
    }
  }

  if (
    entry.bitmapContext != null &&
    !entry.bitmapContext.isNull() &&
    entry.surfaceWidth === width &&
    entry.surfaceHeight === height
  ) {
    return;
  }

  destroyMirrorSurface(entry);

  var renderSupport = loadRenderSupport();
  var bytesPerRow = width * 4;
  var dataSize = bytesPerRow * height;
  var screen = bridge.x11.XDefaultScreen(bridge.display);
  var visual = bridge.x11.XDefaultVisual(bridge.display, screen);
  var depth = bridge.x11.XDefaultDepth(bridge.display, screen);
  var imageData = renderSupport.malloc(dataSize);
  if (imageData.isNull()) {
    throw new Error("malloc failed for " + dataSize + " bytes");
  }

  renderSupport.memset(imageData, 0, dataSize);

  var image = bridge.x11.XCreateImage(
    bridge.display,
    visual,
    depth,
    renderSupport.kZPixmap,
    0,
    imageData,
    width,
    height,
    32,
    bytesPerRow,
  );
  if (image.isNull()) {
    throw new Error("XCreateImage failed");
  }

  var bitmapContext = renderSupport.CGBitmapContextCreate(
    imageData,
    width,
    height,
    8,
    bytesPerRow,
    renderSupport.colorSpace,
    renderSupport.kCGBitmapByteOrder32Little |
      renderSupport.kCGImageAlphaPremultipliedFirst,
  );
  if (bitmapContext.isNull()) {
    bridge.x11.XDestroyImage(image);
    throw new Error("CGBitmapContextCreate failed");
  }

  entry.image = image;
  entry.imageData = imageData;
  entry.bitmapContext = bitmapContext;
  entry.surfaceWidth = width;
  entry.surfaceHeight = height;
  entry.bytesPerRow = bytesPerRow;
  entry.dataSize = dataSize;
}

export function renderObjCDescriptor(entry, descriptor) {
  if (entry == null || descriptor.window == null) {
    return;
  }

  var bounds = clampFrame(descriptor.frame);
  var contentView = null;

  try {
    contentView = descriptor.window.contentView().superview();
  } catch (e) {
    return;
  }

  if (isNullValue(contentView)) {
    return;
  }

  try {
    if (!contentView.wantsLayer()) {
      contentView.setWantsLayer_(1);
    }
  } catch (e) {}

  var layer = null;
  try {
    layer = contentView.layer();
  } catch (e) {
    return;
  }

  if (isNullValue(layer)) {
    return;
  }

  try {
    var presentationLayer = layer.presentationLayer();
    if (!isNullValue(presentationLayer)) {
      layer = presentationLayer;
    }
  } catch (e) {}

  // Sample the live presentation layer directly; forcing layout/display here
  // can kick the source window and produce flicker in the mirror.
  ensureMirrorSurface(entry, bounds);
  bridge.renderSupport.memset(entry.imageData, 0, entry.dataSize);
  renderLayerInContext(layer, entry.bitmapContext);
  bridge.x11.XPutImage(
    bridge.display,
    entry.handle,
    entry.gc,
    entry.image,
    0,
    0,
    0,
    0,
    entry.surfaceWidth,
    entry.surfaceHeight,
  );
}

export function renderCoreGraphicsDescriptor(entry, descriptor) {
  if (entry == null || descriptor.windowNumber == null) {
    return;
  }

  var cg = bridge.coreGraphics;
  var bounds = clampFrame(descriptor.frame);
  var image = cg.CGWindowListCreateImage(
    [bounds.origin.x, bounds.origin.y, bounds.size.width, bounds.size.height],
    cg.kCGWindowListOptionIncludingWindow,
    descriptor.windowNumber,
    cg.kCGWindowImageDefault | cg.kCGWindowImageBoundsIgnoreFraming,
  );
  if (image == null || image.isNull()) {
    return;
  }

  try {
    var width = Number(cg.CGImageGetWidth(image));
    var height = Number(cg.CGImageGetHeight(image));
    var bytesPerRow = Number(cg.CGImageGetBytesPerRow(image));
    if (width <= 0 || height <= 0 || bytesPerRow <= 0) {
      return;
    }

    ensureMirrorSurface(entry, {
      origin: bounds.origin,
      size: {
        width: width,
        height: height,
      },
    });

    var provider = cg.CGImageGetDataProvider(image);
    if (provider == null || provider.isNull()) {
      return;
    }

    var data = cg.CGDataProviderCopyData(provider);
    if (data == null || data.isNull()) {
      return;
    }

    try {
      var dataPtr = cg.CFDataGetBytePtr(data);
      var dataLength = Number(cg.CFDataGetLength(data));
      if (dataPtr == null || dataPtr.isNull() || dataLength <= 0) {
        return;
      }

      var targetRows = entry.surfaceHeight;
      var copyRows = Math.min(targetRows, height);
      var targetRowBytes = entry.bytesPerRow;
      var copyRowBytes = Math.min(targetRowBytes, bytesPerRow);

      bridge.renderSupport.memset(entry.imageData, 0, entry.dataSize);
      for (var row = 0; row < copyRows; row++) {
        Memory.copy(
          entry.imageData.add(row * targetRowBytes),
          dataPtr.add(row * bytesPerRow),
          copyRowBytes,
        );
      }

      bridge.x11.XPutImage(
        bridge.display,
        entry.handle,
        entry.gc,
        entry.image,
        0,
        0,
        0,
        0,
        entry.surfaceWidth,
        entry.surfaceHeight,
      );
    } finally {
      cg.CFRelease(data);
    }
  } finally {
    cg.CGImageRelease(image);
  }
}
