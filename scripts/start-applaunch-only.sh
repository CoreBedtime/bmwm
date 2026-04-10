#!/usr/bin/env bash
# start-applaunch-only.sh — launch AppLaunch directly without loader or bwm.

set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
APP_LAUNCH="${ROOT_DIR}/.build/ninja/osx/AppLaunch"

if [ "$#" -lt 1 ]; then
    printf 'Usage: %s /path/to/App.app|/path/to/binary [...]\n' "${BASH_SOURCE[0]}" >&2
    exit 1
fi

APPS=("$@")

if [ ! -x "$APP_LAUNCH" ]; then
    printf 'start-applaunch-only.sh: %s is missing or not executable - run quick.sh first\n' "$APP_LAUNCH" >&2
    exit 1
fi

DISPLAY_VALUE="${DISPLAY:-}"
if [ -z "$DISPLAY_VALUE" ]; then
    printf 'start-applaunch-only.sh: DISPLAY environment variable not set\n' >&2
    exit 1
fi

GUI_UID=501
LAUNCH_PIDS=()
for app in "${APPS[@]}"; do
    launchctl asuser "$GUI_UID" env DISPLAY="$DISPLAY_VALUE" "$APP_LAUNCH" "$app" &
    LAUNCH_PIDS+=($!)
done

set +e
for pid in "${LAUNCH_PIDS[@]}"; do
    wait "$pid"
done
set -e
