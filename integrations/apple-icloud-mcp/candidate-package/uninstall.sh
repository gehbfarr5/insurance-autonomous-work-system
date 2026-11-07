#!/bin/bash
# uninstall.sh — MacServer EventKit Bridge Rollback / Teardown Script
# AG-02 Candidate Package | Version 1.3.0

set -euo pipefail

CURRENT_UID=$(id -u)
TARGET_CONFIG_DIR="${TARGET_CONFIG_DIR:-$HOME/.config/muse-macserver}"
STATE_DIR="${TARGET_STATE_DIR:-$TARGET_CONFIG_DIR/state}"
RECEIPT_FILE="$STATE_DIR/install_receipt.json"
SNAPSHOT_FILE="$STATE_DIR/pre_install_snapshot.txt"
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

# 2. Boot out confirmed LaunchAgent daemon (exact service only, zero killing by port)
echo "[1/4] Booting out confirmed LaunchAgent daemon ($SERVICE_LABEL) from gui/$CURRENT_UID..."
if [ "$SKIP_LAUNCHCTL" != "true" ]; then
    if launchctl print "gui/$CURRENT_UID/$SERVICE_LABEL" > /dev/null 2>&1; then
        launchctl bootout "gui/$CURRENT_UID/$SERVICE_LABEL" 2>/dev/null || true
        echo "  -> Service $SERVICE_LABEL booted out."
    elif [ -f "$PLIST_PATH" ]; then
        launchctl bootout "gui/$CURRENT_UID" "$PLIST_PATH" 2>/dev/null || true
        echo "  -> Plist booted out."
    fi

    # Check for lingering or foreign listener on port:
    # RULE: Do NOT kill processes. If port remains bound, report conflict and preserve all files/receipt!
    if [ -n "$PORT" ] && lsof -i :"$PORT" > /dev/null 2>&1; then
        LISTENER_PID=$(lsof -t -i :"$PORT" 2>/dev/null || true)
        LISTENER_CMD=$(ps -p "$LISTENER_PID" -o command= 2>/dev/null || true)
        echo "ERROR: Port $PORT remains occupied after booting out LaunchAgent!" >&2
        echo "  Listener PID: $LISTENER_PID" >&2
        echo "  Listener CMD: $LISTENER_CMD" >&2
        echo "Port conflict or lingering listener detected. Refusing to kill foreign/lingering process." >&2
        echo "Preserving all installation files and receipt for investigation at $RECEIPT_FILE" >&2
        exit 1
    fi
fi

# 3. Clean up deployed files recorded in receipt and restore directory states
echo "[2/4] Removing installed files and restoring directory states..."
rm -f "$PLIST_PATH" "$BINARY_PATH" "$CONFIG_PATH"
echo "  -> Removed: $PLIST_PATH"
echo "  -> Removed: $BINARY_PATH"
echo "  -> Removed: $CONFIG_PATH"

# Restore pre-install directory permissions and remove only created directories
if [ -f "$SNAPSHOT_FILE" ]; then
    tail -r "$SNAPSHOT_FILE" 2>/dev/null | while IFS='|' read -r type path mode || [ -n "$type" ]; do
        case "$type" in
            DIR_CREATED)
                if [ -d "$path" ]; then
                    rmdir "$path" 2>/dev/null || true
                    echo "  -> Removed created directory: $path"
                fi
                ;;
            DIR_EXISTED)
                if [ -d "$path" ] && [ -n "$mode" ]; then
                    chmod "$mode" "$path" 2>/dev/null || true
                    echo "  -> Restored original directory permissions ($mode) for: $path"
                fi
                ;;
        esac
    done
    rm -f "$SNAPSHOT_FILE"
fi

rm -f "$RECEIPT_FILE"

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
    echo "ERROR: Port $PORT remains bound!" >&2
    exit 1
else
    echo "  -> Port $PORT is free."
fi

echo "=== Teardown complete. Exact pre-install state restored. ==="
