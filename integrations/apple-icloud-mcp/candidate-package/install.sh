#!/bin/bash
# install.sh — MacServer EventKit Bridge Installation Script
# Target: Intel MacServer (macOS 13+, x86_64) | gui/$(id -u) domain
# AG-02 Candidate Package | Version 1.2.0

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DRY_RUN=false
INJECT_FAILURE="${INJECT_INSTALL_FAILURE:-}"

while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --inject-failure=*)
            INJECT_FAILURE="${1#*=}"
            shift
            ;;
        --inject-failure)
            INJECT_FAILURE="$2"
            shift 2
            ;;
        *)
            shift
            ;;
    esac
done

echo "=========================================================="
echo " MacServer EventKit Readonly Bridge Installation Protocol "
echo "=========================================================="

# 0. Directory and Path Resolution (permits isolated testing overrides)
TARGET_BIN_DIR="${TARGET_BIN_DIR:-/Users/shared/bin}"
TARGET_LOG_DIR="${TARGET_LOG_DIR:-/Users/shared/log}"
TARGET_LAUNCHAGENTS_DIR="${TARGET_LAUNCHAGENTS_DIR:-$HOME/Library/LaunchAgents}"
TARGET_CONFIG_DIR="${TARGET_CONFIG_DIR:-$HOME/.config/muse-macserver}"
STATE_DIR="${TARGET_STATE_DIR:-$TARGET_CONFIG_DIR/state}"
SKIP_LAUNCHCTL="${SKIP_LAUNCHCTL:-false}"

TARGET_BIN="$TARGET_BIN_DIR/EventKitBridgeServer"
TARGET_PLIST="$TARGET_LAUNCHAGENTS_DIR/com.muse.macserver-eventkit.plist"
TARGET_CONFIG="$TARGET_CONFIG_DIR/bridge.env"
RECEIPT_FILE="$STATE_DIR/install_receipt.json"
SNAPSHOT_FILE="$STATE_DIR/pre_install_snapshot.json"

CURRENT_UID=$(id -u)
PORT="${EVENTKIT_BRIDGE_PORT:-18765}"

# 1. Pre-flight Environment Checks
echo "[1/6] Checking target platform and GUI domain..."
OS_NAME=$(uname -s)
ARCH_NAME=$(uname -m)

if [ "$OS_NAME" != "Darwin" ]; then
    echo "ERROR: Target OS must be Darwin (macOS), got: $OS_NAME" >&2
    exit 1
fi

if [ "$ARCH_NAME" != "x86_64" ]; then
    echo "WARNING: Expected x86_64 architecture for Intel MacServer, got: $ARCH_NAME" >&2
fi

if [ "$SKIP_LAUNCHCTL" != "true" ]; then
    if ! launchctl print "gui/$CURRENT_UID" > /dev/null 2>&1; then
        echo "ERROR: Active graphical login session 'gui/$CURRENT_UID' not found!" >&2
        echo "EventKit requires an active Aqua graphical login session for TCC authorization." >&2
        exit 1
    fi
fi
echo "  -> OS: $OS_NAME ($ARCH_NAME), User UID: $CURRENT_UID (GUI session active)"

# 2. Port conflict check
echo "[2/6] Checking port $PORT availability..."
if lsof -i :"$PORT" > /dev/null 2>&1; then
    echo "ERROR: Port $PORT is already in use by another process!" >&2
    lsof -i :"$PORT" >&2
    exit 1
fi
echo "  -> Port $PORT is free."

# 3. Binary Integrity & Code Signing Verification (Audited Original Artifact)
echo "[3/6] Verifying original signed binary integrity and digest..."
BINARY_SRC="$SCRIPT_DIR/bin/EventKitBridgeServer"
if [ ! -f "$BINARY_SRC" ]; then
    echo "ERROR: Source binary not found at $BINARY_SRC" >&2
    exit 1
fi

# Extract expected digest from MANIFEST.json
MANIFEST_FILE="$SCRIPT_DIR/MANIFEST.json"
if [ -f "$MANIFEST_FILE" ]; then
    EXPECTED_SHA256=$(grep -E '"sha256":' "$MANIFEST_FILE" | head -n 1 | awk -F '"' '{print $4}')
else
    EXPECTED_SHA256="7a507e8442a0c6ffecf0b67599ade980b71638d8d4cad0b418281907ff3ed2e9"
fi

ACTUAL_SHA256=$(shasum -a 256 "$BINARY_SRC" | awk '{print $1}')
if [ "$ACTUAL_SHA256" != "$EXPECTED_SHA256" ]; then
    echo "ERROR: Binary SHA-256 verification FAILED!" >&2
    echo "  Expected: $EXPECTED_SHA256" >&2
    echo "  Actual:   $ACTUAL_SHA256" >&2
    echo "Installation aborted to prevent deploying tampered or unverified artifacts." >&2
    exit 1
fi

if ! codesign --verify --verbose=2 "$BINARY_SRC" > /dev/null 2>&1; then
    echo "ERROR: Source binary signature validation failed!" >&2
    exit 1
fi

CODESIGN_OUTPUT=$(codesign -d --verbose=2 "$BINARY_SRC" 2>&1)
if ! echo "$CODESIGN_OUTPUT" | grep -q "flags=0x10002"; then
    echo "ERROR: Hardened Runtime (flags=0x10002) not detected on binary!" >&2
    exit 1
fi
echo "  -> Audited binary verified: SHA-256 matches ($ACTUAL_SHA256), Hardened Runtime valid."

# 4. Strict Clean-Install Enforcement (Reject any existing binary, plist, config, or service)
echo "[4/6] Verifying target environment is clean (clean-installation only)..."

if [ -f "$TARGET_BIN" ]; then
    echo "ERROR: Target binary already exists at $TARGET_BIN!" >&2
    echo "First-round trial run is strictly restricted to clean installation only." >&2
    echo "Existing binary detected. Upgrade or overwrite is not permitted. Aborting." >&2
    exit 1
fi

if [ -f "$TARGET_PLIST" ]; then
    echo "ERROR: Target LaunchAgent plist already exists at $TARGET_PLIST!" >&2
    echo "First-round trial run is strictly restricted to clean installation only. Aborting." >&2
    exit 1
fi

if [ -f "$TARGET_CONFIG" ]; then
    echo "ERROR: Target configuration already exists at $TARGET_CONFIG!" >&2
    echo "First-round trial run is strictly restricted to clean installation only. Aborting." >&2
    exit 1
fi

if [ "$SKIP_LAUNCHCTL" != "true" ]; then
    if launchctl print "gui/$CURRENT_UID/com.muse.macserver-eventkit" > /dev/null 2>&1; then
        echo "ERROR: LaunchAgent service com.muse.macserver-eventkit is already active in launchd!" >&2
        echo "First-round trial run is strictly restricted to clean installation only. Aborting." >&2
        exit 1
    fi
fi
echo "  -> Verified clean install state: 0 existing binaries, 0 plists, 0 configs, 0 active services."

# ZERO-WRITE DRY RUN EXIT
if [ "$DRY_RUN" = true ]; then
    echo ""
    echo "=== DRY RUN SUCCESSFUL (Zero Disk Writes) ==="
    echo "Target Directories & Permissions Planned:"
    echo "  - Config:  $TARGET_CONFIG_DIR (mode 0700, owner $(whoami):staff)"
    echo "  - Token:   $TARGET_CONFIG (mode 0600, owner $(whoami):staff)"
    echo "  - Binary:  $TARGET_BIN (mode 0755, owner $(whoami):staff)"
    echo "  - Logs:    $TARGET_LOG_DIR (mode 0755)"
    echo "  - Plist:   $TARGET_PLIST (mode 0644)"
    echo "Pre-flight checks passed. Zero modifications made to the filesystem or services."
    exit 0
fi

# Track directory creation for exact rollback
CONFIG_DIR_CREATED_BY_US=false
STATE_DIR_CREATED_BY_US=false
if [ ! -d "$TARGET_CONFIG_DIR" ]; then CONFIG_DIR_CREATED_BY_US=true; fi
if [ ! -d "$STATE_DIR" ]; then STATE_DIR_CREATED_BY_US=true; fi

# Create state directory and snapshot
mkdir -p -m 0700 "$TARGET_CONFIG_DIR" "$STATE_DIR"

cat > "$SNAPSHOT_FILE" << SNAPSHOT_EOF
{
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "uid": $CURRENT_UID,
  "config_dir_created": $CONFIG_DIR_CREATED_BY_US,
  "state_dir_created": $STATE_DIR_CREATED_BY_US,
  "binary_path": "$TARGET_BIN",
  "plist_path": "$TARGET_PLIST",
  "config_path": "$TARGET_CONFIG"
}
SNAPSHOT_EOF
chmod 0600 "$SNAPSHOT_FILE"

# Define mid-flight rollback handler to restore exact pre-install state
rollback_on_failure() {
    echo "ERROR: Installation failed mid-flight! Rolling back to exact pre-install state..." >&2
    if [ "$SKIP_LAUNCHCTL" != "true" ]; then
        launchctl bootout "gui/$CURRENT_UID/com.muse.macserver-eventkit" > /dev/null 2>&1 || true
    fi
    rm -f "$TARGET_BIN" "$TARGET_PLIST" "$TARGET_CONFIG" "$RECEIPT_FILE" "$SNAPSHOT_FILE"
    if [ -d "$STATE_DIR" ]; then
        rmdir "$STATE_DIR" 2>/dev/null || true
    fi
    if [ "$CONFIG_DIR_CREATED_BY_US" = true ] && [ -d "$TARGET_CONFIG_DIR" ]; then
        rmdir "$TARGET_CONFIG_DIR" 2>/dev/null || true
    fi
    echo "Rollback completed. Exact pre-install clean state restored." >&2
}
trap rollback_on_failure ERR

# 5. Restricted Credential Storage & Target Deployment
echo "[5/6] Deploying restricted credentials and application artifacts..."
mkdir -p -m 0700 "$TARGET_CONFIG_DIR"
chmod 0700 "$TARGET_CONFIG_DIR"

SECURE_TOKEN=$(openssl rand -hex 32)
cat > "$TARGET_CONFIG" << EOF_CONF
# Restricted Configuration for MacServer EventKit Bridge
# AG-02 Candidate
EVENTKIT_BRIDGE_BEARER_TOKEN="$SECURE_TOKEN"
EOF_CONF
chmod 0600 "$TARGET_CONFIG"
echo "  -> Created restricted credential store at $TARGET_CONFIG (mode 0600, parent 0700)"

# Binary deployment: Copy original audited artifact WITHOUT re-signing
mkdir -p -m 0755 "$TARGET_BIN_DIR" "$TARGET_LOG_DIR" "$TARGET_LAUNCHAGENTS_DIR"
cp -p "$BINARY_SRC" "$TARGET_BIN"
chmod 0755 "$TARGET_BIN"

# Verify destination binary matches original digest exactly
DEST_SHA256=$(shasum -a 256 "$TARGET_BIN" | awk '{print $1}')
if [ "$DEST_SHA256" != "$EXPECTED_SHA256" ]; then
    echo "ERROR: Destination binary digest mismatch after copy!" >&2
    exit 1
fi
if ! codesign --verify --verbose=2 "$TARGET_BIN" > /dev/null 2>&1; then
    echo "ERROR: Destination binary signature invalid after copy!" >&2
    exit 1
fi
echo "  -> Deployed audited binary to $TARGET_BIN (mode 0755, original signature intact, zero re-signing)."

# Plist deployment
PLIST_SRC="$SCRIPT_DIR/com.muse.macserver-eventkit.plist.template"
sed -e "s|/Users/shared/bin/EventKitBridgeServer|$TARGET_BIN|g" \
    -e "s|/Users/shared/log|$TARGET_LOG_DIR|g" \
    -e "s|/Users/jin/.config/muse-macserver/bridge.env|$TARGET_CONFIG|g" \
    -e "s|18765|$PORT|g" \
    "$PLIST_SRC" > "$TARGET_PLIST"
chmod 0644 "$TARGET_PLIST"
echo "  -> Installed LaunchAgent configuration to $TARGET_PLIST (mode 0644)"

# Check failure injection point
if [ "$INJECT_FAILURE" = "pre-bootstrap" ]; then
    echo "INJECTED FAILURE: Simulating unexpected failure prior to service bootstrap..." >&2
    false
fi

# 6. Service Bootstrap & Health Verification
echo "[6/6] Bootstrapping LaunchAgent daemon into gui/$CURRENT_UID..."
if [ "$SKIP_LAUNCHCTL" != "true" ]; then
    launchctl bootstrap "gui/$CURRENT_UID" "$TARGET_PLIST"

    if [ "$INJECT_FAILURE" = "post-bootstrap" ]; then
        echo "INJECTED FAILURE: Simulating failure immediately after bootstrap..." >&2
        false
    fi

    # Wait for service to bind and respond to health check
    echo "Waiting for service to bind on http://127.0.0.1:$PORT/health..."
    HEALTHY=false
    for i in {1..30}; do
        if curl -s "http://127.0.0.1:$PORT/health" > /dev/null 2>&1; then
            HEALTHY=true
            break
        fi
        sleep 0.2
    done

    if [ "$HEALTHY" = true ]; then
        echo "SUCCESS: MacServer EventKit Bridge is live and healthy!"
        HEALTH_OUT=$(curl -s "http://127.0.0.1:$PORT/health")
        echo "  -> Health response: $HEALTH_OUT"
    else
        echo "ERROR: Service did not respond on http://127.0.0.1:$PORT/health within 6 seconds." >&2
        exit 1
    fi
fi

# Write official installation receipt
cat > "$RECEIPT_FILE" << RECEIPT_EOF
{
  "installed_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "uid": $CURRENT_UID,
  "binary_path": "$TARGET_BIN",
  "binary_sha256": "$DEST_SHA256",
  "plist_path": "$TARGET_PLIST",
  "config_path": "$TARGET_CONFIG",
  "service_label": "com.muse.macserver-eventkit",
  "port": $PORT
}
RECEIPT_EOF
chmod 0600 "$RECEIPT_FILE"

# Cancel rollback trap on success
trap - ERR

echo ""
echo "=== Installation completed successfully ==="
echo "Receipt: $RECEIPT_FILE (mode 0600)"
