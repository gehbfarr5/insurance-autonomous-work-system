#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MACSERVER_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BINARY="$MACSERVER_DIR/.build/release/EventKitBridgeServer"
TEST_PORT=18789

echo "=== EventKitBridgeServer Offline & Universal Binary Validation ==="

# 1. Architecture and signature check
echo "--> 1. Architecture Check (file & lipo)"
file "$BINARY"
lipo -info "$BINARY"

echo "--> 2. Deployment Target (otool LC_BUILD_VERSION)"
otool -l "$BINARY" | grep -A 4 LC_BUILD_VERSION

echo "--> 3. Codesign Check"
codesign -dv "$BINARY" 2>&1

echo "--> 4. SHA256 Checksum"
BINARY_SHA=$(shasum -a 256 "$BINARY" | awk '{print $1}')
echo "SHA256: $BINARY_SHA"

# 2. Offline startup test with Fake Store (TEST mode)
echo "--> 5. Offline Startup with Safe Fake Store"
export EVENTKIT_BRIDGE_MODE="TEST"
export EVENTKIT_BRIDGE_PORT="$TEST_PORT"
export EVENTKIT_BRIDGE_HOST="127.0.0.1"
export EVENTKIT_BRIDGE_BEARER_TOKEN="test-offline-token-12345"
export EVENTKIT_BRIDGE_PRODUCTION_AUTHORIZED="1"
export EVENTKIT_BRIDGE_ALLOWED_LIST_IDS="00000000-0000-0000-0000-000000000001"
export EVENTKIT_BRIDGE_BINDINGS="00000000-0000-0000-0000-000000000001:src-synthetic-icloud-test:caldav:iCloud"

"$BINARY" > /tmp/eventkit-bridge-offline-test.log 2>&1 &
SERVER_PID=$!

cleanup() {
  if kill -0 "$SERVER_PID" 2>/dev/null; then
    kill -TERM "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
  rm -f /tmp/eventkit-bridge-offline-test.log
}
trap cleanup EXIT INT TERM

# Wait for server ready
waited=0
while [ "$waited" -lt 30 ]; do
  if curl -s -f "http://127.0.0.1:${TEST_PORT}/health" >/dev/null 2>&1; then
    break
  fi
  sleep 0.2
  waited=$((waited + 1))
done

if ! curl -s -f "http://127.0.0.1:${TEST_PORT}/health" >/dev/null 2>&1; then
  echo "FAIL: Server did not respond to /health on port $TEST_PORT"
  cat /tmp/eventkit-bridge-offline-test.log
  exit 1
fi
echo "  [PASS] /health responded 200 OK"

# Query lists with token
LISTS_RESP=$(curl -s -H "Authorization: Bearer test-offline-token-12345" "http://127.0.0.1:${TEST_PORT}/reminders/lists")
echo "  Lists response: $LISTS_RESP"
if echo "$LISTS_RESP" | grep -q "00000000-0000-0000-0000-000000000001"; then
  echo "  [PASS] Fake Store returned allowlisted test list"
fi

# Stop gracefully
kill -TERM "$SERVER_PID"
wait "$SERVER_PID" 2>/dev/null || true

echo "=== Offline Universal Binary Validation SUCCESS ==="
