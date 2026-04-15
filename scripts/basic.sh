#!/bin/bash
set -e

export DISPLAY=:0

echo "Starting Applicator..."
sudo "/Volumes/Bedtime/Developer/Applicator/.build/ninja/osx/loader-macos" &
LOADER_PID=$!

sleep 2

echo "Launching xterm..."
xterm &
XTERM_PID=$!

echo "Launching thunar..."
/opt/local/bin/thunar &
THUNAR_PID=$!

echo "Waiting for loader to exit..."
wait $LOADER_PID
EXIT_CODE=$?

echo "Loader exited. Cleaning up..."
kill $XTERM_PID 2>/dev/null
kill $THUNAR_PID 2>/dev/null

echo "Done"
exit $EXIT_CODE
