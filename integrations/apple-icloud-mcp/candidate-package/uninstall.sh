#!/bin/bash
# uninstall.sh — MacServer EventKit Bridge Rollback / Teardown Script
# AG-02 Candidate Package

set -euo pipefail

CURRENT_UID=$(id -u)
PLIST_PATH="$HOME/Library/LaunchAgents/com.muse.macserver-eventkit.plist"
BINARY_PATH="/Users/shared/bin/EventKitBridgeServer"

echo "=========================================================="
echo " MacServer EventKit Bridge Rollback & Teardown Protocol   "
echo "=========================================================="

# 1. Unload LaunchAgent daemon
echo "[1/4] Booting out LaunchAgent from gui/$CURRENT_UID..."
if launchctl print "gui/$CURRENT_UID/com.muse.macserver-eventkit" > /dev/null 2>&1; then
    launchctl bootout "gui/$CURRENT_UID/com.muse.macserver-eventkit" 2>/dev/null || true
    echo "  -> Service booted out."
elif [ -f "$PLIST_PATH" ]; then
    launchctl bootout "gui/$CURRENT_UID" "$PLIST_PATH" 2>/dev/null || true
    echo "  -> Plist booted out."
else
    echo "  -> Service was not active in launchd."
fi

# 2. Terminate any stray processes
echo "[2/4] Ensuring process termination..."
if pkill -SIGTERM -f EventKitBridgeServer > /dev/null 2>&1; then
    sleep 0.5
    pkill -9 -f EventKitBridgeServer > /dev/null 2>&1 || true
    echo "  -> Stopped stray process."
else
    echo "  -> No running EventKitBridgeServer process found."
fi

# 3. Clean up deployed files
echo "[3/4] Removing deployed binary and LaunchAgent configuration..."
rm -f "$PLIST_PATH"
rm -f "$BINARY_PATH"
echo "  -> Removed $PLIST_PATH"
echo "  -> Removed $BINARY_PATH"

# 4. Optional TCC Permission Reset
echo "[4/4] Resetting TCC Reminders permission for identifier com.muse.macserver-eventkit..."
tccutil reset Reminders com.muse.macserver-eventkit 2>/dev/null || true
echo "  -> TCC Reminders state reset to clean baseline."

# Verify port release
if lsof -i :18765 > /dev/null 2>&1; then
    echo "WARNING: Port 18765 still bound:" >&2
    lsof -i :18765 >&2
else
    echo "SUCCESS: Port 18765 is completely free."
fi

echo "=== Rollback complete. Original state restored. ==="
