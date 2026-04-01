# Applicator

A cross-platform userland layer that provides a unified runtime for executing binaries across operating systems. Runs a JavaScriptCore+WASM kernel, and abstracts the host filesystem behind its own virtual layer.

Currently developed on macOS with Linux and Windows targets planned.

## Building

```sh
./quick.sh
```

Requires CMake, Ninja, and Xcode command line tools.

## License

GPLv3 — see [LICENSE](LICENSE).
