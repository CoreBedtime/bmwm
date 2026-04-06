#!/usr/bin/env bash

set -euo pipefail

setup_x11_socket_dir() {
    if [ ! -d /tmp/.X11-unix ] || [ "$(stat -f '%u' /tmp/.X11-unix)" != "0" ]; then
        rm -rf /tmp/.X11-unix
        mkdir -m 1777 /tmp/.X11-unix
    fi
}
setup_x11_socket_dir

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
LOADER="${ROOT_DIR}/.build/ninja/osx/loader-macos"
LOG_FILE="${LOG_FILE:-/tmp/applicator-mainuserspace.log}"

if [ ! -x "$LOADER" ]; then
    printf 'start-xclock.sh: %s is missing or not executable\n' "$LOADER" >&2
    exit 1
fi

rm -f "$LOG_FILE"

sudo env BWM_CONFIG="${ROOT_DIR}/dev-config/bwm.lua" "$LOADER" >"$LOG_FILE" 2>&1 &
LOADER_PID=$!

cleanup() {
    if kill -0 "$LOADER_PID" >/dev/null 2>&1; then
        kill "$LOADER_PID" >/dev/null 2>&1 || true
    fi
}

trap cleanup EXIT INT TERM

DISPLAY_VALUE=""
for _ in $(seq 1 200); do
    if ! kill -0 "$LOADER_PID" >/dev/null 2>&1; then
        printf 'start-xclock.sh: loader exited unexpectedly\n' >&2
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
    printf 'start-xclock.sh: render server did not report a ready X display\n' >&2
    printf 'Last log lines:\n' >&2
    tail -n 40 "$LOG_FILE" >&2 || true
    exit 1
fi

printf 'start-xclock.sh: using DISPLAY=%s\n' "$DISPLAY_VALUE"
DISPLAY="$DISPLAY_VALUE" exec /opt/X11/bin/xclock -geometry 180x180+20+20
