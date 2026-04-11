#!/usr/bin/env bash
# start-dbus-xfce.sh — Start X server, bwm, then dbus and xfce4-panel (no AppLaunch).

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

setup_dbus_socket_dir() {
    local dbus_dir="/tmp/dbus"
    if [ ! -d "$dbus_dir" ]; then
        mkdir -p "$dbus_dir"
        chmod 1777 "$dbus_dir"
    fi
}
setup_dbus_socket_dir

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
BWM="${ROOT_DIR}/.build/ninja/osx/bwm"
LOADER="${ROOT_DIR}/.build/ninja/osx/loader-macos"
LOG_FILE="${LOG_FILE:-/tmp/applicator-mainuserspace.log}"
GUI_UID=501
BWM_CONFIG="${BWM_CONFIG:-${ROOT_DIR}/dev-config/bwm.lua}"

DBUS_SOCKET_DIR="/tmp/dbus"
DBUS_SOCKET="${DBUS_SOCKET_DIR}/$(whoami).session.usock"

if [ ! -x "$LOADER" ]; then
    printf 'start-dbus-xfce.sh: %s is missing or not executable\n' "$LOADER" >&2
    exit 1
fi

if [ ! -x "$BWM" ]; then
    printf 'start-dbus-xfce.sh: %s is missing or not executable - run quick.sh first\n' "$BWM" >&2
    exit 1
fi

DBUS_DAEMON="/opt/local/bin/dbus-daemon"
XFCE4_PANEL="/opt/local/bin/xfce4-panel"

if [ ! -x "$DBUS_DAEMON" ]; then
    printf 'start-dbus-xfce.sh: %s is missing or not executable\n' "$DBUS_DAEMON" >&2
    exit 1
fi

if [ ! -x "$XFCE4_PANEL" ]; then
    printf 'start-dbus-xfce.sh: %s is missing or not executable\n' "$XFCE4_PANEL" >&2
    exit 1
fi

rm -f "$DBUS_SOCKET"

sudo rm -f "$LOG_FILE"
touch "$LOG_FILE"

sudo env BWM_CONFIG="$BWM_CONFIG" RENDER_SERVER_EXTERNAL_WM=1 "$LOADER" 2>&1 | tee -a "$LOG_FILE" &
LOADER_PID=$!
BWM_PID=""
DBUS_PID=""
XFCE_PID=""

cleanup() {
    if [ -n "$XFCE_PID" ] && kill -0 "$XFCE_PID" >/dev/null 2>&1; then
        kill "$XFCE_PID" >/dev/null 2>&1 || true
    fi
    if [ -n "$DBUS_PID" ] && kill -0 "$DBUS_PID" >/dev/null 2>&1; then
        kill "$DBUS_PID" >/dev/null 2>&1 || true
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
        printf 'start-dbus-xfce.sh: loader exited unexpectedly\n' >&2
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
    printf 'start-dbus-xfce.sh: render server did not report a ready X display\n' >&2
    printf 'Last log lines:\n' >&2
    tail -n 40 "$LOG_FILE" >&2 || true
    exit 1
fi

printf 'start-dbus-xfce.sh: using DISPLAY=%s\n' "$DISPLAY_VALUE"

launchctl asuser "$GUI_UID" launchctl setenv DISPLAY "$DISPLAY_VALUE"
launchctl setenv DISPLAY "$DISPLAY_VALUE"

sudo BWM_CONFIG="$BWM_CONFIG" DISPLAY="$DISPLAY_VALUE" "$BWM" &
BWM_PID=$!

sleep 1
if ! kill -0 "$BWM_PID" >/dev/null 2>&1; then
    printf 'start-dbus-xfce.sh: bwm exited unexpectedly\n' >&2
    tail -n 40 "$LOG_FILE" >&2 || true
    exit 1
fi

DBUS_SESSION_BUS_ADDRESS="unix:path=${DBUS_SOCKET}"

sudo "$DBUS_DAEMON" --session --address "$DBUS_SESSION_BUS_ADDRESS" --nofork &
DBUS_PID=$!

sleep 1
if ! kill -0 "$DBUS_PID" >/dev/null 2>&1; then
    printf 'start-dbus-xfce.sh: dbus-daemon exited unexpectedly\n' >&2
    exit 1
fi

export DBUS_SESSION_BUS_ADDRESS

launchctl asuser "$GUI_UID" launchctl setenv DBUS_SESSION_BUS_ADDRESS "$DBUS_SESSION_BUS_ADDRESS"
launchctl setenv DBUS_SESSION_BUS_ADDRESS "$DBUS_SESSION_BUS_ADDRESS"

launchctl asuser "$GUI_UID" env DISPLAY="$DISPLAY_VALUE" DBUS_SESSION_BUS_ADDRESS="$DBUS_SESSION_BUS_ADDRESS" "$XFCE4_PANEL" &
XFCE_PID=$!

sleep 1
if ! kill -0 "$XFCE_PID" >/dev/null 2>&1; then
    printf 'start-dbus-xfce.sh: xfce4-panel exited unexpectedly\n' >&2
    exit 1
fi

printf 'start-dbus-xfce.sh: running — dbus and xfce4-panel started\n'

wait "$LOADER_PID"