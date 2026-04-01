#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="${BUILD_DIR:-${ROOT_DIR}/.build/ninja}"
BUILD_TYPE="${BUILD_TYPE:-RelWithDebInfo}"
JOBS="${JOBS:-$(sysctl -n hw.ncpu 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || echo 8)}"

if ! command -v ninja >/dev/null 2>&1; then
    printf 'quick.sh: ninja is required but was not found in PATH\n' >&2
    exit 1
fi

printf 'Configuring %s with Ninja in %s\n' "$BUILD_TYPE" "$BUILD_DIR"
cmake -S "$ROOT_DIR" -B "$BUILD_DIR" -G Ninja \
    -DCMAKE_BUILD_TYPE="$BUILD_TYPE" \
    -DCMAKE_EXPORT_COMPILE_COMMANDS=ON

printf 'Building with ninja -j %s\n' "$JOBS"
ninja -C "$BUILD_DIR" -j "$JOBS" "$@"
