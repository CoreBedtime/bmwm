#!/usr/bin/env bash
# install-bwm-plist.sh — install the launchd plist for applaunch-bwm

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"
PLIST_SRC="${ROOT_DIR}/dev-config/com.bedtime.bwm.plist"
PLIST_DST="/Library/LaunchDaemons/com.bedtime.bwm.plist"

if [ ! -f "$PLIST_SRC" ]; then
    printf 'install-bwm-plist.sh: source plist not found: %s\n' "$PLIST_SRC" >&2
    exit 1
fi

if [ "$EUID" -ne 0 ]; then
    printf 'install-bwm-plist.sh: must be run as root (sudo)\n' >&2
    exit 1
fi

mkdir -p /Library/LaunchDaemons

printf 'Installing %s -> %s\n' "$PLIST_SRC" "$PLIST_DST"
cp "$PLIST_SRC" "$PLIST_DST"
chown root:wheel "$PLIST_DST"

launchctl unload -w "$PLIST_DST" 2>/dev/null || true
launchctl load -w "$PLIST_DST"
printf 'Successfully installed and loaded com.bedtime.bwm.plist\n'
