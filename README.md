# Applicator

Applicator is a macOS-focused experiment around IOMFB-backed rendering, an X11 render-server bridge, and an optional external X11 window manager.

## Current State

The shared `BWM_CONFIG` Lua file is API-based, and the loader also accepts a legacy returned table. It calls setters such as `background_image(...)`, `background_color(...)`, `titlebar_color(...)`, `titlebar_focus_color(...)`, and the compositor shadow setters (`shadow_enabled(...)`, `shadow_offset(...)`, `shadow_x_offset(...)`, `shadow_y_offset(...)`, `shadow_spread(...)`, `shadow_opacity(...)`, `shadow_color(...)`).

The same config can also pin the X11 root size the render server starts with. Use `x11_width(...)` and `x11_height(...)` if you want the X server to run at a fixed geometry instead of inheriting the selected framebuffer size.

```lua
x11_width(1920)
x11_height(1080)
```

The legacy table form also accepts `x11_width` and `x11_height` fields:

```lua
return {
    x11_width = 1920,
    x11_height = 1080,
}
```

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

To build `AppLaunch`, CMake will use `FRIDA_CORE_DEVKIT_ROOT` if you point it at an unpacked Frida devkit. Otherwise it downloads `frida-core-devkit-${FRIDA_CORE_VERSION}-${FRIDA_CORE_PLATFORM}.tar.xz` from the GitHub Frida releases page. You can override `FRIDA_CORE_VERSION` and `FRIDA_CORE_PLATFORM` from the CMake cache if you need a different release or architecture.

## Runtime Dependencies

The current render-server bridge expects these X11 tools to be available locally:

- `/opt/X11/bin/Xorg`
- `/opt/X11/bin/cvt`
- `/opt/X11/bin/gtf`

These binaries come from the XQuartz package, not MacPorts. The code uses them to start a headless X server and to generate a mode line that matches the active display size.

## Running (Will prompt for sudo)

- `./scripts/start-applaunch-bwm.sh /path/to/App.app [app-args...]` starts the loader with `RENDER_SERVER_EXTERNAL_WM=1`, then launches `bwm` and `AppLaunch` on the same X display
- `./.build/ninja/osx/AppLaunch /path/to/App.app [app-args...]` launches the app bundle executable and injects it with Frida before resume

## License

GPLv3 — see [LICENSE](LICENSE).
