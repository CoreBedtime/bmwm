#!/usr/bin/env bash
# install-bwm-plist.sh — install the launchd plist for applaunch-bwm

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"
PLIST_SRC="${ROOT_DIR}/dev-config/com.bedtime.bwm.plist"
PLIST_DST="/Library/LaunchDaemons/com.bedtime.bwm.plist"
CONF_SRC="${ROOT_DIR}/dev-config"
CONF_DST="/var/bwm-conf"
START_SCRIPT="${ROOT_DIR}/scripts/start-applaunch-bwm.sh"
CONF_PATH="${CONF_DST}/dev-config/bwm.lua"

if [ ! -f "$PLIST_SRC" ]; then
    printf 'install-bwm-plist.sh: source plist not found: %s\n' "$PLIST_SRC" >&2
    exit 1
fi

if [ "$EUID" -ne 0 ]; then
    printf 'install-bwm-plist.sh: must be run as root (sudo)\n' >&2
    exit 1
fi

mkdir -p /Library/LaunchDaemons
mkdir -p "$CONF_DST"

printf 'Installing %s -> %s\n' "$PLIST_SRC" "$PLIST_DST"
rm -rf "${CONF_DST}/dev-config"
cp -R "$CONF_SRC" "$CONF_DST/"
cp "$PLIST_SRC" "$PLIST_DST"

# Keep launchd pointed at the checkout script, but use the installed config copy.
printf -v PLIST_COMMAND 'BWM_CONFIG=%q %q %q' "$CONF_PATH" "$START_SCRIPT" "/System/Applications/Utilities/Terminal.app"
/usr/libexec/PlistBuddy -c "Set :ProgramArguments:2 ${PLIST_COMMAND}" "$PLIST_DST"

chown root:wheel "$PLIST_DST"

launchctl unload -w "$PLIST_DST" 2>/dev/null || true
launchctl load -w "$PLIST_DST"
printf 'Successfully installed and loaded com.bedtime.bwm.plist\n'
