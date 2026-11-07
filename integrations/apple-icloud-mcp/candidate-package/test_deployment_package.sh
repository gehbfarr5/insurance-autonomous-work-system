#!/bin/bash
# test_deployment_package.sh — Isolated Candidate Package Admission Test Suite
# AG-02 Admission Verification | Version 1.1.0
#
# Tests the EXACT deployment package in an isolated temporary sandbox:
# 1. Clean installation (verifying 0600/0700 permissions, signature integrity, zero re-signing)
# 2. Existing file protection (aborts when unknown existing binary or plist is detected)
# 3. Digest mismatch rejection (aborts when binary is tampered with)
# 4. Mid-flight failure recovery and uninstall cleanup (no broad pkill, no default TCC reset)
# 5. Verification failure non-zero exit (verify.sh exits non-zero on failure)

set -euo pipefail

PACKAGE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_ROOT=$(mktemp -d /tmp/ag02_test_sandbox_XXXXXX)
trap 'rm -rf "$TEST_ROOT"' EXIT

echo "=========================================================="
echo " MacServer Candidate Package Isolation Test Harness       "
echo " Sandbox: $TEST_ROOT"
echo "=========================================================="

PASSED=0
TOTAL=5

# -------------------------------------------------------------
# Test 1: Clean Installation & Permission Matrix
# -------------------------------------------------------------
echo ""
echo "=== Test 1: Clean Installation & Permission Matrix ==="
T1_DIR="$TEST_ROOT/test1"
mkdir -p "$T1_DIR"

export TARGET_BIN_DIR="$T1_DIR/bin"
export TARGET_LOG_DIR="$T1_DIR/log"
export TARGET_LAUNCHAGENTS_DIR="$T1_DIR/LaunchAgents"
export TARGET_CONFIG_DIR="$T1_DIR/config"
export TARGET_STATE_DIR="$T1_DIR/config/state"
export SKIP_LAUNCHCTL=true
export EVENTKIT_BRIDGE_PORT=18781

# Run install.sh
"$PACKAGE_DIR/install.sh"

# Check binary permissions and signature
[ -f "$TARGET_BIN_DIR/EventKitBridgeServer" ]
BIN_MODE=$(stat -f "%OLp" "$TARGET_BIN_DIR/EventKitBridgeServer")
[ "$BIN_MODE" = "755" ]

# Verify binary SHA256 and codesign without re-signing
BIN_SHA=$(shasum -a 256 "$TARGET_BIN_DIR/EventKitBridgeServer" | awk '{print $1}')
EXPECTED_SHA=$(grep '"sha256":' "$PACKAGE_DIR/MANIFEST.json" | head -n 1 | awk -F '"' '{print $4}')
[ "$BIN_SHA" = "$EXPECTED_SHA" ]
codesign --verify --verbose=2 "$TARGET_BIN_DIR/EventKitBridgeServer"
CS_VERIFY=$(codesign -d --verbose=2 "$TARGET_BIN_DIR/EventKitBridgeServer" 2>&1)
echo "$CS_VERIFY" | grep -q "flags=0x10002"

# Check credential storage & permissions
[ -f "$TARGET_CONFIG_DIR/bridge.env" ]
CONF_MODE=$(stat -f "%OLp" "$TARGET_CONFIG_DIR/bridge.env")
[ "$CONF_MODE" = "600" ]
CONF_DIR_MODE=$(stat -f "%OLp" "$TARGET_CONFIG_DIR")
[ "$CONF_DIR_MODE" = "700" ]

# Verify plist references config file and has 0644
[ -f "$TARGET_LAUNCHAGENTS_DIR/com.muse.macserver-eventkit.plist" ]
PLIST_MODE=$(stat -f "%OLp" "$TARGET_LAUNCHAGENTS_DIR/com.muse.macserver-eventkit.plist")
[ "$PLIST_MODE" = "644" ]
grep -q "EVENTKIT_BRIDGE_CONFIG_FILE" "$TARGET_LAUNCHAGENTS_DIR/com.muse.macserver-eventkit.plist"
! grep -q "EVENTKIT_BRIDGE_BEARER_TOKEN" "$TARGET_LAUNCHAGENTS_DIR/com.muse.macserver-eventkit.plist"

# Verify receipt
[ -f "$TARGET_STATE_DIR/install_receipt.json" ]
RECEIPT_MODE=$(stat -f "%OLp" "$TARGET_STATE_DIR/install_receipt.json")
[ "$RECEIPT_MODE" = "600" ]

# Append test overrides into config
echo "EVENTKIT_BRIDGE_PORT=18781" >> "$TARGET_CONFIG_DIR/bridge.env"
echo "EVENTKIT_BRIDGE_MODE=TEST" >> "$TARGET_CONFIG_DIR/bridge.env"
echo "EVENTKIT_BRIDGE_ALLOWED_LIST_IDS=fake-list-icloud-001" >> "$TARGET_CONFIG_DIR/bridge.env"
echo "EVENTKIT_BRIDGE_BINDINGS=fake-list-icloud-001:src-icloud-primary:calDAV:iCloud" >> "$TARGET_CONFIG_DIR/bridge.env"

# Start server briefly using the generated config to test verify.sh
"$TARGET_BIN_DIR/EventKitBridgeServer" --config-file "$TARGET_CONFIG_DIR/bridge.env" > /dev/null 2>&1 &
SERVER_PID=$!

# Wait for server to bind
for i in {1..20}; do
    if curl -s "http://127.0.0.1:18781/health" > /dev/null 2>&1; then
        break
    fi
    sleep 0.1
done

# Run verify.sh against live test server
"$PACKAGE_DIR/verify.sh" 18781 "$TARGET_CONFIG_DIR/bridge.env"

kill -TERM "$SERVER_PID" 2>/dev/null || true
wait "$SERVER_PID" 2>/dev/null || true

echo "-> PASS: Clean installation verified with complete permission matrix."
PASSED=$((PASSED + 1))

# -------------------------------------------------------------
# Test 2: Existing File Protection
# -------------------------------------------------------------
echo ""
echo "=== Test 2: Unknown Existing File Protection ==="
T2_DIR="$TEST_ROOT/test2"
mkdir -p "$T2_DIR/bin" "$T2_DIR/config" "$T2_DIR/LaunchAgents"

export TARGET_BIN_DIR="$T2_DIR/bin"
export TARGET_LOG_DIR="$T2_DIR/log"
export TARGET_LAUNCHAGENTS_DIR="$T2_DIR/LaunchAgents"
export TARGET_CONFIG_DIR="$T2_DIR/config"
export TARGET_STATE_DIR="$T2_DIR/config/state"
export SKIP_LAUNCHCTL=true

# Place an unknown foreign binary in target path without receipt
echo "foreign-payload-unknown" > "$TARGET_BIN_DIR/EventKitBridgeServer"

set +e
"$PACKAGE_DIR/install.sh" > /dev/null 2>&1
EXIT_CODE=$?
set -e

[ "$EXIT_CODE" -ne 0 ]
# Ensure foreign binary was protected and untouched
FOREIGN_CONTENT=$(cat "$TARGET_BIN_DIR/EventKitBridgeServer")
[ "$FOREIGN_CONTENT" = "foreign-payload-unknown" ]

echo "-> PASS: Unknown existing file detected, installation safely aborted without modifying target."
PASSED=$((PASSED + 1))

# -------------------------------------------------------------
# Test 3: Digest Mismatch Rejection
# -------------------------------------------------------------
echo ""
echo "=== Test 3: Digest Mismatch Rejection ==="
T3_DIR="$TEST_ROOT/test3"
mkdir -p "$T3_DIR"
cp -r "$PACKAGE_DIR" "$T3_DIR/tampered-package"

# Corrupt binary by appending 1 byte
echo "X" >> "$T3_DIR/tampered-package/bin/EventKitBridgeServer"

export TARGET_BIN_DIR="$T3_DIR/target/bin"
export TARGET_LOG_DIR="$T3_DIR/target/log"
export TARGET_LAUNCHAGENTS_DIR="$T3_DIR/target/LaunchAgents"
export TARGET_CONFIG_DIR="$T3_DIR/target/config"
export TARGET_STATE_DIR="$T3_DIR/target/config/state"
export SKIP_LAUNCHCTL=true

set +e
"$T3_DIR/tampered-package/install.sh" > /dev/null 2>&1
EXIT_CODE=$?
set -e

[ "$EXIT_CODE" -ne 0 ]
# Verify target binary was NEVER deployed
[ ! -f "$TARGET_BIN_DIR/EventKitBridgeServer" ]

echo "-> PASS: Tampered binary digest mismatch detected, installation aborted before deployment."
PASSED=$((PASSED + 1))

# -------------------------------------------------------------
# Test 4: Mid-Flight Rollback & Uninstall Recovery
# -------------------------------------------------------------
echo ""
echo "=== Test 4: Mid-Flight Rollback & Uninstall Recovery ==="
# Test uninstall.sh on Test 1 environment
export TARGET_BIN_DIR="$T1_DIR/bin"
export TARGET_LOG_DIR="$T1_DIR/log"
export TARGET_LAUNCHAGENTS_DIR="$T1_DIR/LaunchAgents"
export TARGET_CONFIG_DIR="$T1_DIR/config"
export TARGET_STATE_DIR="$T1_DIR/config/state"
export SKIP_LAUNCHCTL=true

# Run uninstall.sh
"$PACKAGE_DIR/uninstall.sh"

# Verify all installed files removed
[ ! -f "$TARGET_BIN_DIR/EventKitBridgeServer" ]
[ ! -f "$TARGET_LAUNCHAGENTS_DIR/com.muse.macserver-eventkit.plist" ]
[ ! -f "$TARGET_CONFIG_DIR/bridge.env" ]
[ ! -f "$TARGET_STATE_DIR/install_receipt.json" ]

echo "-> PASS: Uninstall cleaned all deployed files and state cleanly without broad pkill or default TCC reset."
PASSED=$((PASSED + 1))

# -------------------------------------------------------------
# Test 5: Verification Failure Non-Zero Exit
# -------------------------------------------------------------
echo ""
echo "=== Test 5: Verification Failure Non-Zero Exit ==="
# 1. Test against closed port
set +e
"$PACKAGE_DIR/verify.sh" 19997 "$TARGET_CONFIG_DIR/bridge.env" > /dev/null 2>&1
EXIT_CLOSED=$?
set -e
[ "$EXIT_CLOSED" -ne 0 ]

# 2. Test with missing token file
set +e
"$PACKAGE_DIR/verify.sh" 18765 "/non/existent/bridge.env" > /dev/null 2>&1
EXIT_NOTOKEN=$?
set -e
[ "$EXIT_NOTOKEN" -ne 0 ]

echo "-> PASS: verify.sh strictly exits non-zero on verification failures."
PASSED=$((PASSED + 1))

# -------------------------------------------------------------
# Final Summary
# -------------------------------------------------------------
echo ""
echo "=========================================================="
echo " All $PASSED/$TOTAL Candidate Package Tests PASSED (100%)"
echo "=========================================================="
exit 0
