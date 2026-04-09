#!/usr/bin/env bash
# uninstall-bwm-plist.sh — uninstall the launchd plist for applaunch-bwm

set -euo pipefail

PLIST_DST="/Library/LaunchDaemons/com.bedtime.bwm.plist"

if [ "$EUID" -ne 0 ]; then
    printf 'uninstall-bwm-plist.sh: must be run as root (sudo)\n' >&2
    exit 1
fi

if [ -f "$PLIST_DST" ]; then
    launchctl unload "$PLIST_DST" 2>/dev/null || true
    rm -f "$PLIST_DST"
    printf 'Uninstalled com.bedtime.bwm.plist\n'
else
    printf 'com.bedtime.bwm.plist not found\n'
fi