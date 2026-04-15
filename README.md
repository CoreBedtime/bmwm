# bmwm

bmwm is a macOS-focused experiment built around a Frida-backed loader, an X11 render-server bridge, and a small AppLaunch helper.

## Dependencies

To build the project you need:

- macOS
- Xcode Command Line Tools
- CMake 3.20 or newer
- Ninja
- Python 3
- `codesign`
- `frida-compile`
- a Frida core devkit, either:
  - let CMake download it automatically, or
  - set `FRIDA_CORE_DEVKIT_ROOT` to an unpacked devkit
- XQuartz, which provides `/opt/X11/bin/Xorg`, `/opt/X11/bin/cvt`, and `/opt/X11/bin/gtf`
- MacPorts, plus the ports that provide:
  - LuaJIT (`luajit.h`, `libluajit-5.1`)
  - XCB and related libraries (`xcb`, `xcb-composite`, `xcb-damage`, `xcb-xtest`, `xcb-render`, `xcb-xfixes`)
  - X11 (`X11`)
  - Xcursor (`Xcursor`)

If you use `scripts/basic.sh`, you will also need `xterm` and `thunar`.

CMake looks for the third-party headers and libraries in `/opt/local/include` and `/opt/local/lib`.

## Building

```sh
./quick.sh
```

`quick.sh` configures a Ninja build in `.build/ninja` by default. You can override `BUILD_DIR`, `BUILD_TYPE`, or `JOBS` in the environment if needed.

## Running

`scripts/basic.sh` is a local convenience script for starting the built loader and a couple of test apps. It expects `loader-macos` to already be built at `.build/ninja/osx/loader-macos`.

## License

GPLv3 - see [LICENSE.txt](LICENSE.txt).
