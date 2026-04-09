#!/usr/bin/env bash
# start-applaunch-bwm.sh — launch the loader, then bwm, then AppLaunch on the same X display.
#
# This mirrors the existing X11 startup flow, but leaves the foreground launch to
# AppLaunch so it can attach Frida before the target app resumes.

set -euo pipefail

setup_x11_socket_dir() {
    for i in $(seq 0 99); do
        sudo rm -f "/tmp/.X${i}-lock" 2>/dev/null || true
    done
    if [ ! -d /tmp/.X11-unix ] || [ "$(stat -f '%u' /tmp/.X11-unix)" != "0" ]; then
        sudo rm -rf /tmp/.X11-unix
        sudo mkdir -m 1777 /tmp/.X11-unix
        sudo chown 0 /tmp/.X11-unix
    fi
}
setup_x11_socket_dir

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
APP_LAUNCH="${ROOT_DIR}/.build/ninja/osx/AppLaunch"
BWM="${ROOT_DIR}/.build/ninja/osx/bwm"
LOADER="${ROOT_DIR}/.build/ninja/osx/loader-macos"
LOG_FILE="${LOG_FILE:-/tmp/applicator-mainuserspace.log}"
GUI_UID=501
BWM_CONFIG="${BWM_CONFIG:-${ROOT_DIR}/dev-config/bwm.lua}"
XTERM="${XTERM:-/opt/X11/bin/xterm}"

if [ "$#" -lt 1 ]; then
    printf 'Usage: %s /path/to/App.app|/path/to/binary [...]\n' "${BASH_SOURCE[0]}" >&2
    exit 1
fi

APPS=("$@")

if [ ! -x "$LOADER" ]; then
    printf 'start-applaunch-bwm.sh: %s is missing or not executable\n' "$LOADER" >&2
    exit 1
fi

if [ ! -x "$BWM" ]; then
    printf 'start-applaunch-bwm.sh: %s is missing or not executable - run quick.sh first\n' "$BWM" >&2
    exit 1
fi

if [ ! -x "$APP_LAUNCH" ]; then
    printf 'start-applaunch-bwm.sh: %s is missing or not executable - run quick.sh first\n' "$APP_LAUNCH" >&2
    exit 1
fi

sudo rm -f "$LOG_FILE"

touch "$LOG_FILE"
sudo env BWM_CONFIG="$BWM_CONFIG" RENDER_SERVER_EXTERNAL_WM=1 "$LOADER" 2>&1 | tee -a "$LOG_FILE" &
LOADER_PID=$!
BWM_PID=""
APP_LAUNCH_PID=""

cleanup() {
    if [ -n "$APP_LAUNCH_PID" ] && kill -0 "$APP_LAUNCH_PID" >/dev/null 2>&1; then
        kill "$APP_LAUNCH_PID" >/dev/null 2>&1 || true
    fi
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
        printf 'start-applaunch-bwm.sh: loader exited unexpectedly\n' >&2
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
    printf 'start-applaunch-bwm.sh: render server did not report a ready X display\n' >&2
    printf 'Last log lines:\n' >&2
    tail -n 40 "$LOG_FILE" >&2 || true
    exit 1
fi

printf 'start-applaunch-bwm.sh: using DISPLAY=%s\n' "$DISPLAY_VALUE"

launchctl asuser "$GUI_UID" launchctl setenv DISPLAY "$DISPLAY_VALUE"
launchctl setenv DISPLAY "$DISPLAY_VALUE"

sudo BWM_CONFIG="$BWM_CONFIG" DISPLAY="$DISPLAY_VALUE" "$BWM" &
BWM_PID=$!

sleep 1
if ! kill -0 "$BWM_PID" >/dev/null 2>&1; then
    printf 'start-applaunch-bwm.sh: bwm exited unexpectedly\n' >&2
    tail -n 40 "$LOG_FILE" >&2 || true
    exit 1
fi

# Launch xterm for visual debugging (optional, can be disabled via XTERM=)
if [ -n "${XTERM:-}" ] && [ -x "$XTERM" ]; then
    printf 'start-applaunch-bwm.sh: launching xterm for debugging\n'
    launchctl asuser "$GUI_UID" env DISPLAY="$DISPLAY_VALUE" "$XTERM" -geometry 80x24+10+10 &
fi

LAUNCH_PIDS=()
for app in "${APPS[@]}"; do
    # AppLaunch needs the GUI user's bootstrap namespace.
    launchctl asuser "$GUI_UID" env DISPLAY="$DISPLAY_VALUE" "$APP_LAUNCH" "$app" &
    LAUNCH_PIDS+=($!)
done

set +e
for pid in "${LAUNCH_PIDS[@]}"; do
    wait "$pid"
done
set -e
