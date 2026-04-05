# Applicator

Applicator is a macOS-focused experiment around IOMFB-backed rendering, an X11 render-server bridge, and an optional external X11 window manager.

## Current State

The repo currently builds three binaries:

- `loader-macos`, which patches the runtime environment and launches `MainUserspace`
- `MainUserspace`, which opens the local IOMFB display stack through `FramebufferLib`, creates IOSurfaces for presentation, and starts the local X server/render path
- `bwm`, a standalone reparenting X11 window manager used when the external-WM path is enabled

The current runtime flow is:

- the loader runs first
- `MainUserspace` brings up the local X server and render path
- `RENDER_SERVER_EXTERNAL_WM=1` tells the render server to skip claiming `SubstructureRedirect`
- `bwm` takes over window management in that mode

Wallpaper rendering now lives in the render-server backdrop path. `background_image` is applied there, and `bwm` only applies the solid root color fallback.

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
sudo port install xorg-libXcomposite
sudo port install luajit
```

## Runtime Dependencies

The current render-server bridge expects these X11 tools to be available locally:

- `/opt/X11/bin/Xorg`
- `/opt/X11/bin/cvt`
- `/opt/X11/bin/gtf`

These binaries come from the XQuartz package, not MacPorts. The code uses them to start a headless X server and to generate a mode line that matches the active display size.

## Running

- `./scripts/start-xclock.sh` starts the loader, waits for the X display, and launches `/opt/X11/bin/xclock`
- `./scripts/start-thunar.sh` starts the loader and launches Thunar on the created X display
- `./scripts/start-bwm.sh` starts the loader with `RENDER_SERVER_EXTERNAL_WM=1`, then launches `bwm`
- `./scripts/start-thunar-bwm.sh` starts the loader with `RENDER_SERVER_EXTERNAL_WM=1`, then launches `bwm` and Thunar
- `./scripts/start-thunar-xterm-bwm.sh` starts the loader with `RENDER_SERVER_EXTERNAL_WM=1`, then launches `bwm`, Thunar, and xterm

## License

GPLv3 — see [LICENSE](LICENSE).
