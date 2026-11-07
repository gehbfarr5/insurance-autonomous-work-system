#!/bin/bash
# uninstall.sh — MacServer EventKit Bridge Rollback / Teardown Script
# AG-02 Candidate Package | Version 1.1.0

set -euo pipefail

CURRENT_UID=$(id -u)
TARGET_CONFIG_DIR="${TARGET_CONFIG_DIR:-$HOME/.config/muse-macserver}"
STATE_DIR="${TARGET_STATE_DIR:-$TARGET_CONFIG_DIR/state}"
RECEIPT_FILE="$STATE_DIR/install_receipt.json"
SNAPSHOT_FILE="$STATE_DIR/pre_install_snapshot.json"
SKIP_LAUNCHCTL="${SKIP_LAUNCHCTL:-false}"
RESET_TCC=false

for arg in "$@"; do
    case "$arg" in
        --reset-tcc)
            RESET_TCC=true
            shift
            ;;
        *)
            ;;
    esac
done

echo "=========================================================="
echo " MacServer EventKit Bridge Rollback & Teardown Protocol   "
echo "=========================================================="

if [ ! -f "$RECEIPT_FILE" ]; then
    echo "WARNING: No installation receipt found at $RECEIPT_FILE."
    echo "To prevent accidental deletion of unmanaged system files, refusing broad deletion."
    echo "If manual removal is needed, remove only known files."
    exit 0
fi

# 1. Read receipt metadata
BINARY_PATH=$(grep '"binary_path":' "$RECEIPT_FILE" | awk -F '"' '{print $4}')
PLIST_PATH=$(grep '"plist_path":' "$RECEIPT_FILE" | awk -F '"' '{print $4}')
CONFIG_PATH=$(grep '"config_path":' "$RECEIPT_FILE" | awk -F '"' '{print $4}')
PORT=$(grep '"port":' "$RECEIPT_FILE" | awk '{print $2}' | tr -d ',')

# 2. Boot out exact LaunchAgent daemon
echo "[1/4] Booting out LaunchAgent daemon from gui/$CURRENT_UID..."
if [ "$SKIP_LAUNCHCTL" != "true" ]; then
    if launchctl print "gui/$CURRENT_UID/com.muse.macserver-eventkit" > /dev/null 2>&1; then
        launchctl bootout "gui/$CURRENT_UID/com.muse.macserver-eventkit" 2>/dev/null || true
        echo "  -> Service booted out via label com.muse.macserver-eventkit."
    elif [ -f "$PLIST_PATH" ]; then
        launchctl bootout "gui/$CURRENT_UID" "$PLIST_PATH" 2>/dev/null || true
        echo "  -> Plist booted out."
    else
        echo "  -> Service was not active in launchd."
    fi

    # Targeted PID check (NO broad pkill!)
    if [ -n "$PORT" ] && lsof -i :"$PORT" > /dev/null 2>&1; then
        SPECIFIC_PID=$(lsof -t -i :"$PORT" 2>/dev/null || true)
        if [ -n "$SPECIFIC_PID" ]; then
            echo "  -> Terminating exact listener PID $SPECIFIC_PID on port $PORT..."
            kill -TERM "$SPECIFIC_PID" 2>/dev/null || true
            sleep 0.3
        fi
    fi
fi

# 3. Clean up deployed files according to pre-install snapshot
echo "[2/4] Restoring pre-install file state..."
BIN_EXISTED="false"
PLIST_EXISTED="false"
CONFIG_EXISTED="false"

if [ -f "$SNAPSHOT_FILE" ]; then
    BIN_EXISTED=$(grep '"binary_existed":' "$SNAPSHOT_FILE" | awk '{print $2}' | tr -d ',')
    PLIST_EXISTED=$(grep '"plist_existed":' "$SNAPSHOT_FILE" | awk '{print $2}' | tr -d ',')
    CONFIG_EXISTED=$(grep '"config_existed":' "$SNAPSHOT_FILE" | awk '{print $2}' | tr -d ',')
fi

if [ "$PLIST_EXISTED" = "false" ] && [ -f "$PLIST_PATH" ]; then
    rm -f "$PLIST_PATH"
    echo "  -> Removed installed LaunchAgent plist: $PLIST_PATH"
fi

if [ "$BIN_EXISTED" = "false" ] && [ -f "$BINARY_PATH" ]; then
    rm -f "$BINARY_PATH"
    echo "  -> Removed installed binary: $BINARY_PATH"
fi

if [ "$CONFIG_EXISTED" = "false" ] && [ -f "$CONFIG_PATH" ]; then
    rm -f "$CONFIG_PATH"
    echo "  -> Removed generated credential file: $CONFIG_PATH"
fi

# 4. Optional TCC Permission Reset (ONLY on explicit request, never by default)
echo "[3/4] Checking TCC Reminders state..."
if [ "$RESET_TCC" = true ]; then
    echo "  -> Explicit --reset-tcc passed. Resetting TCC Reminders for com.muse.macserver-eventkit..."
    tccutil reset Reminders com.muse.macserver-eventkit 2>/dev/null || true
else
    echo "  -> Skipping TCC reset (preserved by default, as requested)."
fi

# 5. Clean receipts & verify port release
echo "[4/4] Verifying port release and removing receipts..."
rm -f "$RECEIPT_FILE" "$SNAPSHOT_FILE"

if [ -n "$PORT" ] && lsof -i :"$PORT" > /dev/null 2>&1; then
    echo "ERROR: Port $PORT remains bound after rollback!" >&2
    lsof -i :"$PORT" >&2
    exit 1
else
    echo "  -> Port $PORT is completely free."
fi

echo "=== Rollback complete. Original state restored. ==="
