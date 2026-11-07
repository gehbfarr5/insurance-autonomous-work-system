#!/bin/bash
# uninstall.sh — MacServer EventKit Bridge Rollback / Teardown Script
# AG-02 Candidate Package | Version 1.2.0

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
    echo "ERROR: No installation receipt found at $RECEIPT_FILE." >&2
    echo "To protect unmanaged system files and external services, refusing teardown without valid receipt." >&2
    exit 1
fi

# 1. Read receipt metadata
BINARY_PATH=$(grep '"binary_path":' "$RECEIPT_FILE" | awk -F '"' '{print $4}')
PLIST_PATH=$(grep '"plist_path":' "$RECEIPT_FILE" | awk -F '"' '{print $4}')
CONFIG_PATH=$(grep '"config_path":' "$RECEIPT_FILE" | awk -F '"' '{print $4}')
PORT=$(grep '"port":' "$RECEIPT_FILE" | awk '{print $2}' | tr -d ',')
SERVICE_LABEL=$(grep '"service_label":' "$RECEIPT_FILE" | awk -F '"' '{print $4}')

# 2. Boot out confirmed LaunchAgent daemon
echo "[1/4] Booting out confirmed LaunchAgent daemon ($SERVICE_LABEL) from gui/$CURRENT_UID..."
if [ "$SKIP_LAUNCHCTL" != "true" ]; then
    if launchctl print "gui/$CURRENT_UID/$SERVICE_LABEL" > /dev/null 2>&1; then
        launchctl bootout "gui/$CURRENT_UID/$SERVICE_LABEL" 2>/dev/null || true
        echo "  -> Service $SERVICE_LABEL booted out."
    elif [ -f "$PLIST_PATH" ]; then
        launchctl bootout "gui/$CURRENT_UID" "$PLIST_PATH" 2>/dev/null || true
        echo "  -> Plist booted out."
    fi

    # Targeted PID check (Confirmed service only; external processes MUST NOT be killed)
    if [ -n "$PORT" ] && lsof -i :"$PORT" > /dev/null 2>&1; then
        LISTENER_PID=$(lsof -t -i :"$PORT" 2>/dev/null || true)
        if [ -n "$LISTENER_PID" ]; then
            LISTENER_CMD=$(ps -p "$LISTENER_PID" -o command= 2>/dev/null || true)
            if echo "$LISTENER_CMD" | grep -qE "($BINARY_PATH|EventKitBridgeServer)"; then
                echo "  -> Terminating confirmed service process (PID: $LISTENER_PID)..."
                kill -TERM "$LISTENER_PID" 2>/dev/null || true
                sleep 0.3
            else
                echo "ERROR: Port $PORT is occupied by an external/foreign process!" >&2
                echo "  PID: $LISTENER_PID" >&2
                echo "  CMD: $LISTENER_CMD" >&2
                echo "Refusing to terminate unconfirmed process. Port conflict reported." >&2
                exit 1
            fi
        fi
    fi
fi

# 3. Clean up deployed files recorded in receipt
echo "[2/4] Removing files recorded in installation receipt..."
rm -f "$PLIST_PATH" "$BINARY_PATH" "$CONFIG_PATH" "$RECEIPT_FILE" "$SNAPSHOT_FILE"
echo "  -> Removed: $PLIST_PATH"
echo "  -> Removed: $BINARY_PATH"
echo "  -> Removed: $CONFIG_PATH"

if [ -d "$STATE_DIR" ]; then
    rmdir "$STATE_DIR" 2>/dev/null || true
fi
if [ -d "$TARGET_CONFIG_DIR" ]; then
    rmdir "$TARGET_CONFIG_DIR" 2>/dev/null || true
fi

# 4. Optional TCC Permission Reset (ONLY on explicit request, never by default)
echo "[3/4] Checking TCC Reminders state..."
if [ "$RESET_TCC" = true ]; then
    echo "  -> Explicit --reset-tcc passed. Resetting TCC Reminders for $SERVICE_LABEL..."
    tccutil reset Reminders "$SERVICE_LABEL" 2>/dev/null || true
else
    echo "  -> Skipping TCC reset (preserved by default, as requested)."
fi

# 5. Verify port release
echo "[4/4] Verifying port release..."
if [ -n "$PORT" ] && lsof -i :"$PORT" > /dev/null 2>&1; then
    echo "ERROR: Port $PORT is still occupied by another process!" >&2
    lsof -i :"$PORT" >&2
    exit 1
else
    echo "  -> Port $PORT is free."
fi

echo "=== Rollback complete. Original state restored. ==="
