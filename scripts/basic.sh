#!/bin/bash
set -e

export DISPLAY=:0

FONTCONFIG_DIR="/tmp/applicator-fontconfig"
GTK_CONFIG_HOME="/tmp/applicator-gtk"
FONTCONFIG_FILE="$FONTCONFIG_DIR/fonts.conf"
GTK_SETTINGS_DIR="$GTK_CONFIG_HOME/gtk-3.0"
mkdir -p "$FONTCONFIG_DIR"
mkdir -p "$GTK_SETTINGS_DIR"
cat > "$FONTCONFIG_FILE" <<'EOF'
<?xml version="1.0"?>
<!DOCTYPE fontconfig SYSTEM "urn:fontconfig:fonts.dtd">
<fontconfig>
  <include ignore_missing="yes">/opt/local/etc/fonts/fonts.conf</include>
  <match target="pattern">
    <edit name="family" mode="assign" binding="same">
      <string>ComicShannsMono Nerd Font Mono</string>
    </edit>
  </match>
</fontconfig>
EOF
cat > "$GTK_SETTINGS_DIR/settings.ini" <<'EOF'
[Settings]
gtk-font-name=ComicShannsMono Nerd Font Mono 12
EOF
export FONTCONFIG_FILE
export FONTCONFIG_PATH="$FONTCONFIG_DIR"
export XDG_CONFIG_HOME="$GTK_CONFIG_HOME"

sudo echo "Starting Applicator..."
sudo "/Volumes/Bedtime/Developer/Applicator/.build/ninja/osx/loader-macos" &
LOADER_PID=$!

sleep 2

echo "Launching xterm..."
/opt/X11/bin/xterm -fa "ComicShannsMono Nerd Font Mono" -fs 12 &
XTERM_PID=$!

echo "Launching thunar..."
/opt/local/bin/thunar &
THUNAR_PID=$!

echo "Launching sysmon..."
.build/ninja/osx/AppLaunch /System/Applications/Utilities/Terminal.app &
LAUNCHER_PID=$!

echo "Waiting for loader to exit..."
wait $LOADER_PID
EXIT_CODE=$?

echo "Loader exited. Cleaning up..."
kill $XTERM_PID 2>/dev/null
kill $THUNAR_PID 2>/dev/null
kill $LAUNCHER_PID 2>/dev/null

echo "Done"
exit $EXIT_CODE
