#!/bin/bash
# install.sh — MacServer EventKit Bridge Installation Script
# Target: Intel MacServer (macOS 13+, x86_64) | gui/$(id -u) domain
# AG-02 Candidate Package

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DRY_RUN=false

for arg in "$@"; do
    case "$arg" in
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        *)
            ;;
    esac
done

echo "=========================================================="
echo " MacServer EventKit Readonly Bridge Installation Protocol "
echo "=========================================================="

# 1. Pre-flight Environment Checks
echo "[1/5] Checking target environment..."
OS_NAME=$(uname -s)
ARCH_NAME=$(uname -m)
CURRENT_UID=$(id -u)

if [ "$OS_NAME" != "Darwin" ]; then
    echo "ERROR: Target OS must be Darwin (macOS), got: $OS_NAME" >&2
    exit 1
fi

if [ "$ARCH_NAME" != "x86_64" ]; then
    echo "WARNING: Expected x86_64 architecture for Intel MacServer, got: $ARCH_NAME" >&2
fi

if ! launchctl print "gui/$CURRENT_UID" > /dev/null 2>&1; then
    echo "ERROR: Active graphical login session 'gui/$CURRENT_UID' not found!" >&2
    echo "EventKit requires a graphical login session for TCC authorization." >&2
    exit 1
fi
echo "  -> OS: $OS_NAME ($ARCH_NAME), User UID: $CURRENT_UID (GUI session active)"

# 2. Port conflict check
echo "[2/5] Checking port 18765 availability..."
if lsof -i :18765 > /dev/null 2>&1; then
    echo "ERROR: Port 18765 is already in use by another process!" >&2
    lsof -i :18765 >&2
    exit 1
fi
echo "  -> Port 18765 is free."

# 3. Binary Integrity & Code Signing Verification
echo "[3/5] Verifying binary integrity..."
BINARY_SRC="$SCRIPT_DIR/bin/EventKitBridgeServer"
if [ ! -f "$BINARY_SRC" ]; then
    echo "ERROR: Source binary not found at $BINARY_SRC" >&2
    exit 1
fi

EXPECTED_SHA256="223d624c8bf455543f36499fc448c072a5b34087c119e4b8d4a15829f95df8d4"
ACTUAL_SHA256=$(shasum -a 256 "$BINARY_SRC" | awk '{print $1}')
if [ "$ACTUAL_SHA256" != "$EXPECTED_SHA256" ]; then
    echo "WARNING: Binary SHA-256 ($ACTUAL_SHA256) differs from baseline digest ($EXPECTED_SHA256)." >&2
fi

if ! codesign -v "$BINARY_SRC" 2>&1; then
    echo "ERROR: Source binary signature validation failed!" >&2
    exit 1
fi
echo "  -> Binary signature valid. SHA-256: $ACTUAL_SHA256"

if [ "$DRY_RUN" = true ]; then
    echo ""
    echo "=== DRY RUN SUCCESSFUL ==="
    echo "Target Directories:"
    echo "  - Binary: /Users/shared/bin/EventKitBridgeServer (mode 0755, owner $(whoami):staff)"
    echo "  - Logs:   /Users/shared/log/ (mode 0755)"
    echo "  - Plist:  $HOME/Library/LaunchAgents/com.muse.macserver-eventkit.plist (mode 0644)"
    echo "No modifications were made to the system."
    exit 0
fi

# 4. Target Paths & Permissions Setup
echo "[4/5] Deploying binary and LaunchAgent configuration..."
mkdir -p /Users/shared/bin /Users/shared/log "$HOME/Library/LaunchAgents"

install -m 755 "$BINARY_SRC" /Users/shared/bin/EventKitBridgeServer

# Re-affirm Hardened Runtime code signature at destination
codesign --force --sign - \
  --identifier "com.muse.macserver-eventkit" \
  --options runtime \
  /Users/shared/bin/EventKitBridgeServer

# Prepare plist configuration
PLIST_SRC="$SCRIPT_DIR/com.muse.macserver-eventkit.plist.template"
PLIST_DEST="$HOME/Library/LaunchAgents/com.muse.macserver-eventkit.plist"

if [ ! -f "$PLIST_DEST" ]; then
    cp "$PLIST_SRC" "$PLIST_DEST"
    chmod 644 "$PLIST_DEST"
    echo "  -> Installed LaunchAgent template to $PLIST_DEST"
else
    echo "  -> LaunchAgent plist already exists at $PLIST_DEST (preserved)"
fi

# 5. Bootstrap Daemon in User GUI Session
echo "[5/5] Bootstrapping LaunchAgent daemon into gui/$CURRENT_UID..."
launchctl bootstrap "gui/$CURRENT_UID" "$PLIST_DEST"

# Verification
echo "Waiting for service to bind on http://127.0.0.1:18765/health..."
HEALTHY=false
for i in {1..30}; do
    if curl -s http://127.0.0.1:18765/health > /dev/null 2>&1; then
        HEALTHY=true
        break
    fi
    sleep 0.2
done

if [ "$HEALTHY" = true ]; then
    echo "SUCCESS: MacServer EventKit Bridge is live and healthy!"
    curl -s http://127.0.0.1:18765/health
    echo ""
else
    echo "WARNING: Service did not respond on /health within 6 seconds. Check logs at /Users/shared/log/" >&2
    exit 1
fi
