#!/usr/bin/env bash
# start-thunar-bwm.sh — launch the loader, then bwm and Thunar together.

set -euo pipefail

setup_x11_socket_dir() {
    if [ ! -d /tmp/.X11-unix ] || [ "$(stat -f '%u' /tmp/.X11-unix)" != "0" ]; then
        rm -rf /tmp/.X11-unix
        mkdir -m 1777 /tmp/.X11-unix
    fi
}
setup_x11_socket_dir

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
BWM="${ROOT_DIR}/.build/ninja/osx/bwm"
LOADER="${ROOT_DIR}/.build/ninja/osx/loader-macos"
LOG_FILE="${LOG_FILE:-/tmp/applicator-mainuserspace.log}"

if [ ! -x "$LOADER" ]; then
    printf 'start-thunar-bwm.sh: %s is missing or not executable\n' "$LOADER" >&2
    exit 1
fi

if [ ! -x "$BWM" ]; then
    printf 'start-thunar-bwm.sh: %s is missing or not executable — run quick.sh first\n' "$BWM" >&2
    exit 1
fi

if [ ! -x /opt/local/bin/thunar ]; then
    printf 'start-thunar-bwm.sh: /opt/local/bin/thunar is missing or not executable\n' >&2
    exit 1
fi

rm -f "$LOG_FILE"

sudo env BWM_CONFIG="${ROOT_DIR}/dev-config/bwm.lua" RENDER_SERVER_EXTERNAL_WM=1 "$LOADER" >"$LOG_FILE" 2>&1 &
LOADER_PID=$!

BWM_PID=""

cleanup() {
    if [ -n "$BWM_PID" ] && kill -0 "$BWM_PID" >/dev/null 2>&1; then
        kill "$BWM_PID" >/dev/null 2>&1 || true
    fi
    if kill -0 "$LOADER_PID" >/dev/null 2>&1; then
        kill "$LOADER_PID" >/dev/null 2>&1 || true
    fi
}

trap cleanup EXIT INT TERM

DISPLAY_VALUE=""
for _ in $(seq 1 200); do
    if ! kill -0 "$LOADER_PID" >/dev/null 2>&1; then
        printf 'start-thunar-bwm.sh: loader exited unexpectedly\n' >&2
        tail -n 40 "$LOG_FILE" >&2 || true
        exit 1
    fi

    if DISPLAY_VALUE="$(sed -n 's/.*X server ready on \(:[0-9][0-9]*\).*/\1/p' "$LOG_FILE" | tail -n 1)"; then
        if [ -n "$DISPLAY_VALUE" ]; then
            break
        fi
    fi

    sleep 1
done

if [ -z "$DISPLAY_VALUE" ]; then
    printf 'start-thunar-bwm.sh: render server did not report a ready X display\n' >&2
    printf 'Last log lines:\n' >&2
    tail -n 40 "$LOG_FILE" >&2 || true
    exit 1
fi

printf 'start-thunar-bwm.sh: using DISPLAY=%s\n' "$DISPLAY_VALUE"

BWM_CONFIG="${ROOT_DIR}/dev-config/bwm.lua" DISPLAY="$DISPLAY_VALUE" "$BWM" &
BWM_PID=$!

DISPLAY="$DISPLAY_VALUE" exec /opt/local/bin/thunar
