# Applicator

Applicator is a macOS-focused experiment around IOMFB-backed rendering and an X11 render-server bridge.

## Current State

The repo currently builds a `MainUserspace` binary that:

- opens the local IOMFB display stack through `FramebufferLib`
- creates IOSurfaces for presentation
- starts a local Xorg server for the chosen display size
- connects to that X server over XCB
- copies the X root window into the IOSurface-backed render path

This is still an active prototype. The X server bridge is intentionally minimal and is aimed at proving the IOMFB integration path, not providing a complete desktop environment.

## Building

```sh
./quick.sh
```

Requires CMake, Ninja, and the Xcode command line tools.

```bash
sudo port install cmake
sudo port install ninja
sudo port install xorg-libxcb
```

## Runtime Dependencies

The current render-server bridge expects these X11 tools to be available locally:

- `/opt/X11/bin/Xorg`
- `/opt/X11/bin/cvt`
- `/opt/X11/bin/gtf`

These binaries come from the XQuartz package, not MacPorts. The code uses them to start a headless X server and to generate a mode line that matches the active display size.

## Testing

To start the render server and launch `xclock` against the X display it creates:

```sh
./scripts/start-xclock.sh
```

The helper waits for `MainUserspace` to report the display number, exports `DISPLAY`, and then runs `/opt/X11/bin/xclock`.
## License

GPLv3 — see [LICENSE](LICENSE).
