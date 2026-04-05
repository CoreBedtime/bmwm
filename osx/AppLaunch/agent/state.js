import { clampFrame, getEnv, log } from "./shared.js";

export const bridge = {
  displayName: getEnv("DISPLAY"),
  x11: null,
  xplugin: null,
  x11LoadAttempted: false,
  x11LoadError: null,
  xpluginLoadAttempted: false,
  xpluginLoadError: null,
  coreGraphicsLoadAttempted: false,
  coreGraphicsLoadError: null,
  renderSupport: null,
  display: ptr(0),
  displayHeight: 0,
  mode: null,
  coreGraphics: null,
  windows: new Map(),
  installed: false,
  installTimer: null,
  refreshTimer: null,
  hooksInstalled: false,
  bootstrapFatal: false,
  frameScheduled: false,
  nextEventNumber: 1,
  retainedCallbacks: [],
  logged: {},
};

let loaderApi = null;
let objcMsgSendVoid = null;

export function getLoaderApiCache() {
  return loaderApi;
}

export function setLoaderApiCache(value) {
  loaderApi = value;
}

export function getObjCMsgSendVoidCache() {
  return objcMsgSendVoid;
}

export function setObjCMsgSendVoidCache(value) {
  objcMsgSendVoid = value;
}

export function logOnce(key, message) {
  if (bridge.logged[key]) {
    return;
  }
  bridge.logged[key] = true;
  log(message);
}

export function frameToX11Bounds(frame) {
  var bounds = clampFrame(frame);
  var displayHeight = bridge.displayHeight || 0;

  if (displayHeight > 0) {
    bounds.origin.y = Math.max(
      0,
      displayHeight - bounds.origin.y - bounds.size.height,
    );
  }

  return bounds;
}

export function x11PointToCGPoint(x, y) {
  var cgY = y;
  if (bridge.displayHeight > 0) {
    cgY = Math.max(0, bridge.displayHeight - y - 1);
  }
  return [x, cgY];
}
