#!/bin/bash
# test_deployment_package.sh — Candidate Package Admission & Safety Test Suite
# AG-02 Admission Verification | Version 1.2.0
#
# Validates:
# 1. Clean installation & permission matrix (0600/0700/0755/0644, zero re-signing)
# 2. Rejection of any existing binary, plist, or config (clean install only)
# 3. Dry-run zero-write verification (zero filesystem modifications)
# 4. Mid-flight failure injection and exact pre-install state restoration
# 5. Uninstall safety and external port conflict protection (no killing foreign processes)
# 6. Verification modes: unauthorized-check (expects 403) and readonly-acceptance (403 fails)
# 7. Digest mismatch rejection on tampered binary

set -euo pipefail

PACKAGE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_ROOT=$(mktemp -d /tmp/ag02_test_sandbox_XXXXXX)
trap 'rm -rf "$TEST_ROOT"' EXIT

echo "=========================================================="
echo " MacServer Candidate Package Isolation Test Harness       "
echo " Sandbox: $TEST_ROOT"
echo "=========================================================="

PASSED=0
TOTAL=7

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

# Test server running briefly using the generated config to test verify.sh
echo "EVENTKIT_BRIDGE_PORT=18781" >> "$TARGET_CONFIG_DIR/bridge.env"
echo "EVENTKIT_BRIDGE_MODE=TEST" >> "$TARGET_CONFIG_DIR/bridge.env"
echo "EVENTKIT_BRIDGE_ALLOWED_LIST_IDS=fake-list-icloud-001" >> "$TARGET_CONFIG_DIR/bridge.env"
echo "EVENTKIT_BRIDGE_BINDINGS=fake-list-icloud-001:src-icloud-primary:calDAV:iCloud" >> "$TARGET_CONFIG_DIR/bridge.env"

"$TARGET_BIN_DIR/EventKitBridgeServer" --config-file "$TARGET_CONFIG_DIR/bridge.env" > /dev/null 2>&1 &
SERVER_PID=$!

for i in {1..20}; do
    if curl -s "http://127.0.0.1:18781/health" > /dev/null 2>&1; then
        break
    fi
    sleep 0.1
done

# Run verify.sh with readonly-acceptance mode
"$PACKAGE_DIR/verify.sh" --mode=readonly-acceptance --port=18781 --config="$TARGET_CONFIG_DIR/bridge.env"

kill -TERM "$SERVER_PID" 2>/dev/null || true
wait "$SERVER_PID" 2>/dev/null || true

echo "-> PASS: Clean installation verified with complete permission matrix."
PASSED=$((PASSED + 1))

# -------------------------------------------------------------
# Test 2: Rejection of Existing Resources (Clean Install Only)
# -------------------------------------------------------------
echo ""
echo "=== Test 2: Rejection of Existing Resources ==="
T2_DIR="$TEST_ROOT/test2"
mkdir -p "$T2_DIR/bin" "$T2_DIR/LaunchAgents" "$T2_DIR/config"

export TARGET_BIN_DIR="$T2_DIR/bin"
export TARGET_LOG_DIR="$T2_DIR/log"
export TARGET_LAUNCHAGENTS_DIR="$T2_DIR/LaunchAgents"
export TARGET_CONFIG_DIR="$T2_DIR/config"
export TARGET_STATE_DIR="$T2_DIR/config/state"
export SKIP_LAUNCHCTL=true

# Place existing dummy binary
touch "$TARGET_BIN_DIR/EventKitBridgeServer"
set +e
"$PACKAGE_DIR/install.sh" > /dev/null 2>&1
EXIT_BIN=$?
set -e
[ "$EXIT_BIN" -ne 0 ]
rm -f "$TARGET_BIN_DIR/EventKitBridgeServer"

# Place existing dummy plist
touch "$TARGET_LAUNCHAGENTS_DIR/com.muse.macserver-eventkit.plist"
set +e
"$PACKAGE_DIR/install.sh" > /dev/null 2>&1
EXIT_PLIST=$?
set -e
[ "$EXIT_PLIST" -ne 0 ]
rm -f "$TARGET_LAUNCHAGENTS_DIR/com.muse.macserver-eventkit.plist"

# Place existing config
touch "$TARGET_CONFIG_DIR/bridge.env"
set +e
"$PACKAGE_DIR/install.sh" > /dev/null 2>&1
EXIT_CONF=$?
set -e
[ "$EXIT_CONF" -ne 0 ]
rm -f "$TARGET_CONFIG_DIR/bridge.env"

echo "-> PASS: Existing binary, plist, and config all rejected (clean-install-only enforced)."
PASSED=$((PASSED + 1))

# -------------------------------------------------------------
# Test 3: Dry-Run Zero-Write Verification
# -------------------------------------------------------------
echo ""
echo "=== Test 3: Dry-Run Zero-Write Verification ==="
T3_DIR="$TEST_ROOT/test3"
mkdir -p "$T3_DIR"

export TARGET_BIN_DIR="$T3_DIR/bin"
export TARGET_LOG_DIR="$T3_DIR/log"
export TARGET_LAUNCHAGENTS_DIR="$T3_DIR/LaunchAgents"
export TARGET_CONFIG_DIR="$T3_DIR/config"
export TARGET_STATE_DIR="$T3_DIR/config/state"
export SKIP_LAUNCHCTL=true

# Run dry-run
"$PACKAGE_DIR/install.sh" --dry-run > /dev/null

# Verify target directory remains completely empty (0 files, 0 subdirectories created)
ENTRY_COUNT=$(find "$T3_DIR" -mindepth 1 | wc -l | tr -d ' ')
[ "$ENTRY_COUNT" -eq 0 ]

echo "-> PASS: Dry-run performed zero disk writes (clean state verified)."
PASSED=$((PASSED + 1))

# -------------------------------------------------------------
# Test 4: Mid-Flight Failure Injection & Exact State Restoration
# -------------------------------------------------------------
echo ""
echo "=== Test 4: Mid-Flight Failure Injection & Exact Restoration ==="
T4_DIR="$TEST_ROOT/test4"
mkdir -p "$T4_DIR"

export TARGET_BIN_DIR="$T4_DIR/bin"
export TARGET_LOG_DIR="$T4_DIR/log"
export TARGET_LAUNCHAGENTS_DIR="$T4_DIR/LaunchAgents"
export TARGET_CONFIG_DIR="$T4_DIR/config"
export TARGET_STATE_DIR="$T4_DIR/config/state"
export SKIP_LAUNCHCTL=true

# Inject failure right before service bootstrap
set +e
"$PACKAGE_DIR/install.sh" --inject-failure=pre-bootstrap > /dev/null 2>&1
FAIL_EXIT=$?
set -e

[ "$FAIL_EXIT" -ne 0 ]

# Verify all installed files removed and clean pre-install state restored
[ ! -f "$TARGET_BIN_DIR/EventKitBridgeServer" ]
[ ! -f "$TARGET_LAUNCHAGENTS_DIR/com.muse.macserver-eventkit.plist" ]
[ ! -f "$TARGET_CONFIG_DIR/bridge.env" ]
[ ! -d "$TARGET_CONFIG_DIR" ]

echo "-> PASS: Injected failure triggered rollback; exact clean state restored."
PASSED=$((PASSED + 1))

# -------------------------------------------------------------
# Test 5: Uninstall Safety & Port Conflict Protection
# -------------------------------------------------------------
echo ""
echo "=== Test 5: Uninstall Safety & Port Conflict Protection ==="
# Part A: Normal uninstall of Test 1 environment
export TARGET_BIN_DIR="$T1_DIR/bin"
export TARGET_LOG_DIR="$T1_DIR/log"
export TARGET_LAUNCHAGENTS_DIR="$T1_DIR/LaunchAgents"
export TARGET_CONFIG_DIR="$T1_DIR/config"
export TARGET_STATE_DIR="$T1_DIR/config/state"
export SKIP_LAUNCHCTL=true

"$PACKAGE_DIR/uninstall.sh"

[ ! -f "$TARGET_BIN_DIR/EventKitBridgeServer" ]
[ ! -f "$TARGET_LAUNCHAGENTS_DIR/com.muse.macserver-eventkit.plist" ]
[ ! -f "$TARGET_CONFIG_DIR/bridge.env" ]

# Part B: External port conflict protection
# Create a dummy receipt claiming port 18783
T5_DIR="$TEST_ROOT/test5"
mkdir -p "$T5_DIR/config/state"
cat > "$T5_DIR/config/state/install_receipt.json" << EOF_R
{
  "binary_path": "$T5_DIR/bin/EventKitBridgeServer",
  "plist_path": "$T5_DIR/LaunchAgents/com.muse.macserver-eventkit.plist",
  "config_path": "$T5_DIR/config/bridge.env",
  "service_label": "com.muse.macserver-eventkit",
  "port": 18783
}
EOF_R

# Start a dummy netcat listener pretending to be an external foreign process
nc -l 127.0.0.1 18783 > /dev/null 2>&1 &
NC_PID=$!
sleep 0.2

export TARGET_CONFIG_DIR="$T5_DIR/config"
export TARGET_STATE_DIR="$T5_DIR/config/state"
export SKIP_LAUNCHCTL=false

set +e
"$PACKAGE_DIR/uninstall.sh" > /dev/null 2>&1
UNINSTALL_EXIT=$?
set -e

# Assert uninstall exited non-zero because port was held by an external process
[ "$UNINSTALL_EXIT" -ne 0 ]
# Assert external process was NOT killed
kill -0 "$NC_PID" 2>/dev/null
kill -9 "$NC_PID" 2>/dev/null || true
wait "$NC_PID" 2>/dev/null || true

echo "-> PASS: Uninstall cleanly removed confirmed files; foreign process on port protected without killing."
PASSED=$((PASSED + 1))

# -------------------------------------------------------------
# Test 6: Verification Modes (Unauthorized vs Real-Read)
# -------------------------------------------------------------
echo ""
echo "=== Test 6: Verification Modes (Unauthorized vs Real-Read) ==="
T6_DIR="$TEST_ROOT/test6"
mkdir -p "$T6_DIR/config"
TOKEN_6="test-verify-token-001"
echo "EVENTKIT_BRIDGE_BEARER_TOKEN=\"$TOKEN_6\"" > "$T6_DIR/config/bridge.env"
chmod 0600 "$T6_DIR/config/bridge.env"

# Case A: Start server in unauthorized mode (force 403 on lists)
# In production mode without authorization flag, lists return 403 PERMISSION_DENIED
export EVENTKIT_BRIDGE_PORT=18785
export EVENTKIT_BRIDGE_MODE="PRODUCTION"
export EVENTKIT_BRIDGE_ALLOWED_LIST_IDS="test-list-uuid"
export EVENTKIT_BRIDGE_BINDINGS="test-list-uuid:src-uuid:calDAV:iCloud"
export EVENTKIT_BRIDGE_BEARER_TOKEN="$TOKEN_6"
export EVENTKIT_BRIDGE_PRODUCTION_AUTHORIZED="false"

"$PACKAGE_DIR/bin/EventKitBridgeServer" > /dev/null 2>&1 &
UNAUTH_PID=$!

for i in {1..20}; do
    if curl -s "http://127.0.0.1:18785/health" > /dev/null 2>&1; then
        break
    fi
    sleep 0.1
done

# In unauthorized mode: --unauthorized-check MUST pass
"$PACKAGE_DIR/verify.sh" --mode=unauthorized-check --port=18785 --config="$T6_DIR/config/bridge.env" > /dev/null

# In unauthorized mode: --readonly-acceptance MUST FAIL (non-zero)
set +e
"$PACKAGE_DIR/verify.sh" --mode=readonly-acceptance --port=18785 --config="$T6_DIR/config/bridge.env" > /dev/null 2>&1
ACCEPT_FAIL=$?
set -e
[ "$ACCEPT_FAIL" -ne 0 ]

kill -TERM "$UNAUTH_PID" 2>/dev/null || true
wait "$UNAUTH_PID" 2>/dev/null || true

# Case B: Start server in Fake authorized mode (returns 200)
export EVENTKIT_BRIDGE_MODE="TEST"
"$PACKAGE_DIR/bin/EventKitBridgeServer" > /dev/null 2>&1 &
AUTH_PID=$!

for i in {1..20}; do
    if curl -s "http://127.0.0.1:18785/health" > /dev/null 2>&1; then
        break
    fi
    sleep 0.1
done

# In authorized mode: --readonly-acceptance MUST pass
"$PACKAGE_DIR/verify.sh" --mode=readonly-acceptance --port=18785 --config="$T6_DIR/config/bridge.env" > /dev/null

# In authorized mode: --unauthorized-check MUST FAIL (non-zero) because 200 was received instead of 403
set +e
"$PACKAGE_DIR/verify.sh" --mode=unauthorized-check --port=18785 --config="$T6_DIR/config/bridge.env" > /dev/null 2>&1
UNAUTH_FAIL=$?
set -e
[ "$UNAUTH_FAIL" -ne 0 ]

kill -TERM "$AUTH_PID" 2>/dev/null || true
wait "$AUTH_PID" 2>/dev/null || true

echo "-> PASS: Verification modes strictly differentiated; 403 fails real-read; 200 fails unauthorized-check."
PASSED=$((PASSED + 1))

# -------------------------------------------------------------
# Test 7: Digest Mismatch Rejection
# -------------------------------------------------------------
echo ""
echo "=== Test 7: Digest Mismatch Rejection ==="
T7_DIR="$TEST_ROOT/test7"
mkdir -p "$T7_DIR"
cp -r "$PACKAGE_DIR" "$T7_DIR/tampered-package"

# Tamper binary by appending 1 byte
echo "Z" >> "$T7_DIR/tampered-package/bin/EventKitBridgeServer"

export TARGET_BIN_DIR="$T7_DIR/target/bin"
export TARGET_LOG_DIR="$T7_DIR/target/log"
export TARGET_LAUNCHAGENTS_DIR="$T7_DIR/target/LaunchAgents"
export TARGET_CONFIG_DIR="$T7_DIR/target/config"
export TARGET_STATE_DIR="$T7_DIR/target/config/state"
export SKIP_LAUNCHCTL=true

set +e
"$T7_DIR/tampered-package/install.sh" > /dev/null 2>&1
TAMPER_EXIT=$?
set -e

[ "$TAMPER_EXIT" -ne 0 ]
[ ! -f "$TARGET_BIN_DIR/EventKitBridgeServer" ]

echo "-> PASS: Tampered binary detected by digest mismatch; aborted with zero target files created."
PASSED=$((PASSED + 1))

# -------------------------------------------------------------
# Final Summary
# -------------------------------------------------------------
echo ""
echo "=========================================================="
echo " All $PASSED/$TOTAL Candidate Package Tests PASSED (100%)"
echo "=========================================================="
exit 0
