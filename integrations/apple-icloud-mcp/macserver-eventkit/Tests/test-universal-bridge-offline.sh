#!/usr/bin/env bash
# test-universal-bridge-offline.sh
# Comprehensive offline verification of Universal EventKitBridgeServer binary.
# Verifies strict multi-architecture code signing, embedded Info.plist,
# and performs startup, read-only protocol, write rejection, graceful shutdown,
# and restart cycles for BOTH x86_64 and arm64 architectures with Fake Store.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MACSERVER_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BINARY="$MACSERVER_DIR/.build/release/EventKitBridgeServer"
TEST_PORT=18789

echo "=== EventKitBridgeServer Offline & Multi-Architecture Validation ==="
echo "Testing binary: $BINARY"

if [ ! -f "$BINARY" ]; then
  echo "FAIL: Binary does not exist at $BINARY" >&2
  exit 1
fi

# 1. Architecture and binary checks
echo "--> 1. Architecture Check (file & lipo)"
file "$BINARY"
lipo -info "$BINARY"

# 2. Strict Codesign Check on ALL architectures
echo "--> 2. Strict Codesign Check (--verify --strict --all-architectures)"
if ! codesign --verify --strict --all-architectures -vvv "$BINARY"; then
  echo "FAIL: Code signing verification failed on $BINARY" >&2
  exit 1
fi
echo "  [PASS] All architectures strictly valid on disk and satisfy Designated Requirement"

echo "--> 3. Designated Requirement & CDHash Inspection"
codesign -d -r- "$BINARY" 2>&1
echo "x86_64 CDHash: $(codesign -dvvv --arch=x86_64 "$BINARY" 2>&1 | grep '^CDHash=' | cut -d= -f2)"
echo "arm64  CDHash: $(codesign -dvvv --arch=arm64 "$BINARY" 2>&1 | grep '^CDHash=' | cut -d= -f2)"

echo "--> 4. Embedded Info.plist Verification (__TEXT,__info_plist)"
X86_PLIST=$(otool -arch x86_64 -l "$BINARY" | grep -c "sectname __info_plist" || true)
ARM_PLIST=$(otool -arch arm64 -l "$BINARY" | grep -c "sectname __info_plist" || true)
if [ "$X86_PLIST" -lt 1 ] || [ "$ARM_PLIST" -lt 1 ]; then
  echo "FAIL: Embedded __info_plist missing in one or both architectures!" >&2
  exit 1
fi
echo "  [PASS] Embedded __info_plist present in both x86_64 and arm64"

echo "--> 5. SHA256 Checksum"
BINARY_SHA=$(shasum -a 256 "$BINARY" | awk '{print $1}')
echo "SHA256: $BINARY_SHA"

# Function to test an architecture
run_arch_lifecycle_test() {
  local TARGET_ARCH="$1"
  echo "------------------------------------------------------------"
  echo "--> Running Lifecycle Test for architecture: $TARGET_ARCH"
  echo "------------------------------------------------------------"

  local LOG_FILE="/tmp/eventkit-bridge-test-${TARGET_ARCH}.log"
  rm -f "$LOG_FILE"

  export EVENTKIT_BRIDGE_MODE="TEST"
  export EVENTKIT_BRIDGE_PORT="$TEST_PORT"
  export EVENTKIT_BRIDGE_HOST="127.0.0.1"
  export EVENTKIT_BRIDGE_BEARER_TOKEN="test-offline-token-12345"
  export EVENTKIT_BRIDGE_PRODUCTION_AUTHORIZED="1"
  export EVENTKIT_BRIDGE_ALLOWED_LIST_IDS="fake-list-icloud-rich"
  export EVENTKIT_BRIDGE_BINDINGS="fake-list-icloud-rich:src-icloud-primary:calDAV:iCloud"

  # Step A: First Startup
  echo "  [Step A] Starting arch -$TARGET_ARCH server..."
  arch -"$TARGET_ARCH" "$BINARY" > "$LOG_FILE" 2>&1 &
  local SERVER_PID=$!

  cleanup_trap() {
    if [ -n "${SERVER_PID:-}" ] && kill -0 "$SERVER_PID" 2>/dev/null; then
      kill -TERM "$SERVER_PID" 2>/dev/null || true
      wait "$SERVER_PID" 2>/dev/null || true
    fi
    rm -f "$LOG_FILE"
  }
  trap cleanup_trap EXIT INT TERM

  local waited=0
  while [ "$waited" -lt 40 ]; do
    if curl -s -f "http://127.0.0.1:${TEST_PORT}/health" >/dev/null 2>&1; then
      break
    fi
    sleep 0.1
    waited=$((waited + 1))
  done

  if ! curl -s -f "http://127.0.0.1:${TEST_PORT}/health" >/dev/null 2>&1; then
    echo "FAIL ($TARGET_ARCH): Server did not respond to /health on port $TEST_PORT" >&2
    cat "$LOG_FILE"
    exit 1
  fi
  echo "  [PASS] ($TARGET_ARCH) /health responded 200 OK"

  # Step B: Read-only protocol verification
  local LISTS_RESP
  LISTS_RESP=$(curl -s -H "Authorization: Bearer test-offline-token-12345" "http://127.0.0.1:${TEST_PORT}/reminders/lists")
  if ! echo "$LISTS_RESP" | grep -q "fake-list-icloud-rich"; then
    echo "FAIL ($TARGET_ARCH): /reminders/lists did not return fake-list-icloud-rich! Response: $LISTS_RESP" >&2
    exit 1
  fi
  echo "  [PASS] ($TARGET_ARCH) /reminders/lists returned lists metadata"

  # Step B2: Read-only items from allowlisted list
  local ITEMS_RESP
  ITEMS_RESP=$(curl -s -H "Authorization: Bearer test-offline-token-12345" "http://127.0.0.1:${TEST_PORT}/reminders/lists/fake-list-icloud-rich/items")
  if ! echo "$ITEMS_RESP" | grep -q "fake-list-icloud-rich"; then
    echo "FAIL ($TARGET_ARCH): /reminders/lists/fake-list-icloud-rich/items failed! Response: $ITEMS_RESP" >&2
    exit 1
  fi
  echo "  [PASS] ($TARGET_ARCH) /reminders/lists/{id}/items returned items from allowlisted list"

  # Step B3: Reject non-allowlisted list
  local FORBIDDEN_CODE
  FORBIDDEN_CODE=$(curl -s -o /dev/null -w "%{http_code}" -H "Authorization: Bearer test-offline-token-12345" "http://127.0.0.1:${TEST_PORT}/reminders/lists/fake-list-unbound-001/items")
  if [ "$FORBIDDEN_CODE" != "403" ]; then
    echo "FAIL ($TARGET_ARCH): Non-allowlisted list was not rejected with 403! Got: $FORBIDDEN_CODE" >&2
    exit 1
  fi
  echo "  [PASS] ($TARGET_ARCH) Non-allowlisted list correctly rejected with HTTP 403"

  # Step C: Write rejection verification (405 Method Not Allowed)
  local POST_CODE PUT_CODE DELETE_CODE
  POST_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST -H "Authorization: Bearer test-offline-token-12345" "http://127.0.0.1:${TEST_PORT}/reminders/lists")
  PUT_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X PUT -H "Authorization: Bearer test-offline-token-12345" "http://127.0.0.1:${TEST_PORT}/reminders/lists")
  DELETE_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X DELETE -H "Authorization: Bearer test-offline-token-12345" "http://127.0.0.1:${TEST_PORT}/reminders/lists")
  if [ "$POST_CODE" != "405" ] || [ "$PUT_CODE" != "405" ] || [ "$DELETE_CODE" != "405" ]; then
    echo "FAIL ($TARGET_ARCH): Write verbs not blocked with 405! Got: POST=$POST_CODE PUT=$PUT_CODE DELETE=$DELETE_CODE" >&2
    exit 1
  fi
  echo "  [PASS] ($TARGET_ARCH) Write rejection verified (POST=$POST_CODE, PUT=$PUT_CODE, DELETE=$DELETE_CODE)"

  # Step D: Graceful Shutdown
  echo "  [Step D] Gracefully terminating server ($SERVER_PID) with SIGTERM..."
  kill -TERM "$SERVER_PID"
  wait "$SERVER_PID" 2>/dev/null || true
  sleep 0.5
  if curl -s "http://127.0.0.1:${TEST_PORT}/health" >/dev/null 2>&1; then
    echo "FAIL ($TARGET_ARCH): Server still listening after SIGTERM!" >&2
    exit 1
  fi
  echo "  [PASS] ($TARGET_ARCH) Server stopped cleanly, port released"

  # Step E: Restart verification
  echo "  [Step E] Restarting arch -$TARGET_ARCH server to verify clean restart..."
  arch -"$TARGET_ARCH" "$BINARY" > "$LOG_FILE" 2>&1 &
  SERVER_PID=$!

  waited=0
  while [ "$waited" -lt 40 ]; do
    if curl -s -f "http://127.0.0.1:${TEST_PORT}/health" >/dev/null 2>&1; then
      break
    fi
    sleep 0.1
    waited=$((waited + 1))
  done

  if ! curl -s -f "http://127.0.0.1:${TEST_PORT}/health" >/dev/null 2>&1; then
    echo "FAIL ($TARGET_ARCH): Server restart failed to respond on port $TEST_PORT" >&2
    cat "$LOG_FILE"
    exit 1
  fi
  echo "  [PASS] ($TARGET_ARCH) Server restart successful, /health responded 200 OK"

  # Final stop of restarted instance
  kill -TERM "$SERVER_PID"
  wait "$SERVER_PID" 2>/dev/null || true
  rm -f "$LOG_FILE"
  trap - EXIT INT TERM
  echo "  [PASS] ($TARGET_ARCH) Lifecycle test (start -> read-only -> write block -> stop -> restart -> stop) completed 100% OK"
}

# 6. Execute for x86_64 (Intel MacServer emulation under Rosetta)
run_arch_lifecycle_test "x86_64"

# 7. Execute for arm64 (Apple Silicon native)
run_arch_lifecycle_test "arm64"

echo "=========================================================="
echo "=== Offline Multi-Architecture Verification 100% SUCCESS ==="
echo "=========================================================="
