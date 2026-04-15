# bmwm

bmwm is a macOS-focused experiment with an  included X11 render-server bridge.

## Dependencies

bmwm currently depends on:

- macOS with the Xcode Command Line Tools
- CMake 3.20 or newer
- Ninja
- Python 3
- `codesign`
- `launchctl`
- `/usr/libexec/PlistBuddy`
- a `frida-compile` executable on `PATH`
- a Frida core devkit, either unpacked locally through `FRIDA_CORE_DEVKIT_ROOT` or downloaded from Frida releases
- XQuartz, for `/opt/X11/bin/Xorg`, `/opt/X11/bin/cvt`, and `/opt/X11/bin/gtf`

The build resolves these third-party libraries and headers directly:

- LuaJIT (`luajit.h`, `libluajit-5.1`)
- XCB (`xcb/xcb.h`, `xcb`, `xcb-composite`, `xcb-xtest`, `xcb-render`, `xcb-xfixes`)
- X11 (`X11`)
- Xcursor (`Xcursor`)

Use MacPorts! install the ports that provide the libraries above. The CMake files currently look in `/opt/local/include` and `/opt/local/lib` for the third-party dependencies.

## Building

```sh
./quick.sh
```

## License

GPLv3 — see [LICENSE](LICENSE).
