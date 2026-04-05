#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
MAIN_USERSPACE="${ROOT_DIR}/.build/ninja/osx/MainUserspace"
LOG_FILE="${LOG_FILE:-/tmp/applicator-mainuserspace.log}"

if [ ! -x "$MAIN_USERSPACE" ]; then
    printf 'start-thunar.sh: %s is missing or not executable\n' "$MAIN_USERSPACE" >&2
    exit 1
fi

if [ ! -x /opt/local/bin/thunar ]; then
    printf 'start-thunar.sh: /opt/local/bin/thunar is missing or not executable\n' >&2
    exit 1
fi

rm -f "$LOG_FILE"

"$MAIN_USERSPACE" >"$LOG_FILE" 2>&1 &
MAIN_PID=$!

cleanup() {
    if kill -0 "$MAIN_PID" >/dev/null 2>&1; then
        kill "$MAIN_PID" >/dev/null 2>&1 || true
    fi
}

trap cleanup EXIT INT TERM

DISPLAY_VALUE=""
for _ in $(seq 1 200); do
    if ! kill -0 "$MAIN_PID" >/dev/null 2>&1; then
        break
    fi

    if DISPLAY_VALUE="$(sed -n 's/.*X server ready on \(:[0-9][0-9]*\).*/\1/p' "$LOG_FILE" | tail -n 1)"; then
        if [ -n "$DISPLAY_VALUE" ]; then
            break
        fi
    fi

    sleep 1
done

if [ -z "$DISPLAY_VALUE" ]; then
    printf 'start-thunar.sh: render server did not report a ready X display\n' >&2
    printf 'Last log lines:\n' >&2
    tail -n 40 "$LOG_FILE" >&2 || true
    exit 1
fi

printf 'start-thunar.sh: using DISPLAY=%s\n' "$DISPLAY_VALUE"
DISPLAY="$DISPLAY_VALUE" exec /opt/local/bin/thunar
