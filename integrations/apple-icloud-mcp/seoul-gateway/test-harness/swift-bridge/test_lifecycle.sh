#!/bin/bash
set -e

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SWIFT_BIN="$(cd "$DIR/../../../candidate-package/bin" && pwd)/EventKitBridgeServer"
TEST_DIR="/tmp/ag03-swift-lifecycle-test"
RECEIPT_FILE="$DIR/RECEIPT_SWIFT_BRIDGE_LIFECYCLE.json"

echo "=== [AG-03 Swift Bridge Lifecycle Test] Starting native Swift verification ==="
echo "Swift binary: $SWIFT_BIN"

if [ ! -f "$SWIFT_BIN" ]; then
  echo "Error: Swift binary not found at $SWIFT_BIN"
  exit 1
fi

rm -rf "$TEST_DIR"
mkdir -p "$TEST_DIR"
BRIDGE_ENV="$TEST_DIR/bridge.env"
TOKEN="ag03-test-token-at-least-32-chars-long!"
PORT=18777 # Use dedicated test port to avoid conflict

# Helper to wait for healthcheck
wait_for_health() {
  local target_port="$1"
  for i in {1..30}; do
    if curl -s "http://127.0.0.1:$target_port/health" >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.2
  done
  echo "Error: Timeout waiting for Swift Bridge on port $target_port"
  return 1
}

# Cleanup trap
cleanup() {
  if [ -n "$BRIDGE_PID" ]; then
    kill -TERM "$BRIDGE_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT

# 1. Initial State: EVENTKIT_BRIDGE_PRODUCTION_AUTHORIZED=false
cat << EOF > "$BRIDGE_ENV"
EVENTKIT_BRIDGE_PORT=$PORT
EVENTKIT_BRIDGE_MODE=TEST
EVENTKIT_BRIDGE_USE_FAKE=true
EVENTKIT_BRIDGE_PRODUCTION_AUTHORIZED=false
EVENTKIT_BRIDGE_ALLOWED_LIST_IDS=9D9A****03F3
EVENTKIT_BRIDGE_BEARER_TOKEN=$TOKEN
EVENTKIT_BRIDGE_BINDINGS=9D9A****03F3:src-icloud-test-01:calDAV:iCloud
EOF

echo ""
echo "--- Step 1: Start Swift Bridge with authorized=false ---"
"$SWIFT_BIN" --config-file "$BRIDGE_ENV" > "$TEST_DIR/bridge.log" 2>&1 &
BRIDGE_PID=$!
wait_for_health "$PORT"
echo "Swift Bridge started (PID: $BRIDGE_PID). Probing /health..."
HEALTH_OUT=$(curl -s "http://127.0.0.1:$PORT/health")
echo "Health response: $HEALTH_OUT"

echo "Querying /reminders/lists with authorized=false..."
CODE_1=$(curl -s -o "$TEST_DIR/resp1.json" -w "%{http_code}" -H "Authorization: Bearer $TOKEN" "http://127.0.0.1:$PORT/reminders/lists")
echo "HTTP response code: $CODE_1"
cat "$TEST_DIR/resp1.json"
echo ""

if [ "$CODE_1" != "403" ]; then
  echo "CRITICAL FAILURE: Expected 403 when authorized=false, got $CODE_1"
  exit 1
fi
echo "Step 1 PASS: Closed switch strictly returns 403 PERMISSION_DENIED."

# 2. Reconfiguration: set authorized=true and reload/restart
echo ""
echo "--- Step 2: Update config to authorized=true and restart ---"
# Only update the target authorization key, preserving all tokens and bindings
sed -i '' 's/EVENTKIT_BRIDGE_PRODUCTION_AUTHORIZED=false/EVENTKIT_BRIDGE_PRODUCTION_AUTHORIZED=true/' "$BRIDGE_ENV"

kill -TERM "$BRIDGE_PID"
wait "$BRIDGE_PID" 2>/dev/null || true

"$SWIFT_BIN" --config-file "$BRIDGE_ENV" >> "$TEST_DIR/bridge.log" 2>&1 &
BRIDGE_PID=$!
wait_for_health "$PORT"

echo "Querying /reminders/lists with authorized=true..."
CODE_2=$(curl -s -o "$TEST_DIR/resp2.json" -w "%{http_code}" -H "Authorization: Bearer $TOKEN" "http://127.0.0.1:$PORT/reminders/lists")
echo "HTTP response code: $CODE_2"
cat "$TEST_DIR/resp2.json"
echo ""

if [ "$CODE_2" != "200" ]; then
  echo "CRITICAL FAILURE: Expected 200 when authorized=true, got $CODE_2"
  exit 1
fi
# Verify returned list contains 9D9A****03F3
if ! grep -q "9D9A\*\*\*\*03F3" "$TEST_DIR/resp2.json"; then
  echo "CRITICAL FAILURE: Bound list 9D9A****03F3 not found in response!"
  exit 1
fi
echo "Step 2 PASS: Re-opened switch strictly returns 200 OK with Fake Store data."

# 3. Persistent Closing: set authorized=false and restart
echo ""
echo "--- Step 3: Re-close switch in config and restart ---"
sed -i '' 's/EVENTKIT_BRIDGE_PRODUCTION_AUTHORIZED=true/EVENTKIT_BRIDGE_PRODUCTION_AUTHORIZED=false/' "$BRIDGE_ENV"

kill -TERM "$BRIDGE_PID"
wait "$BRIDGE_PID" 2>/dev/null || true

"$SWIFT_BIN" --config-file "$BRIDGE_ENV" >> "$TEST_DIR/bridge.log" 2>&1 &
BRIDGE_PID=$!
wait_for_health "$PORT"

echo "Querying /reminders/lists after re-closing..."
CODE_3=$(curl -s -o "$TEST_DIR/resp3.json" -w "%{http_code}" -H "Authorization: Bearer $TOKEN" "http://127.0.0.1:$PORT/reminders/lists")
echo "HTTP response code: $CODE_3"

if [ "$CODE_3" != "403" ]; then
  echo "CRITICAL FAILURE: Expected 403 after re-closing, got $CODE_3"
  exit 1
fi
echo "Step 3 PASS: Switch re-closed strictly returns 403."

# 4. Persistence verification: restart process WITHOUT touching config file
echo ""
echo "--- Step 4: Restart process without modifying config file (Persistence Check) ---"
kill -TERM "$BRIDGE_PID"
wait "$BRIDGE_PID" 2>/dev/null || true

"$SWIFT_BIN" --config-file "$BRIDGE_ENV" >> "$TEST_DIR/bridge.log" 2>&1 &
BRIDGE_PID=$!
wait_for_health "$PORT"

echo "Querying /reminders/lists after un-modified restart..."
CODE_4=$(curl -s -o "$TEST_DIR/resp4.json" -w "%{http_code}" -H "Authorization: Bearer $TOKEN" "http://127.0.0.1:$PORT/reminders/lists")
echo "HTTP response code: $CODE_4"

if [ "$CODE_4" != "403" ]; then
  echo "CRITICAL FAILURE: Expected 403 on un-modified restart, got $CODE_4"
  exit 1
fi
echo "Step 4 PASS: Bridge persists closed state across process restarts."

# Clean up process
kill -TERM "$BRIDGE_PID"
wait "$BRIDGE_PID" 2>/dev/null || true
BRIDGE_PID=""

# Generate raw receipt
cat << EOF > "$RECEIPT_FILE"
{
  "receiptType": "AG03_SWIFT_BRIDGE_LIFECYCLE",
  "timestamp": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
  "swiftBinary": "$SWIFT_BIN",
  "storeMode": "FakeEventKitStore (Native Swift)",
  "configFile": "$BRIDGE_ENV",
  "tests": [
    {
      "step": 1,
      "description": "Initial startup with EVENTKIT_BRIDGE_PRODUCTION_AUTHORIZED=false",
      "httpStatus": $CODE_1,
      "expectedStatus": 403,
      "result": "PASS"
    },
    {
      "step": 2,
      "description": "Config reload with EVENTKIT_BRIDGE_PRODUCTION_AUTHORIZED=true",
      "httpStatus": $CODE_2,
      "expectedStatus": 200,
      "dataVerified": "listID: 9D9A****03F3 present",
      "result": "PASS"
    },
    {
      "step": 3,
      "description": "Re-closing switch in config file and reloading",
      "httpStatus": $CODE_3,
      "expectedStatus": 403,
      "result": "PASS"
    },
    {
      "step": 4,
      "description": "Process restart without modifying config file (persistent closed state)",
      "httpStatus": $CODE_4,
      "expectedStatus": 403,
      "result": "PASS"
    }
  ],
  "overallResult": "PASS"
}
EOF

echo ""
echo "=== Swift Bridge Lifecycle Receipt Generated: $RECEIPT_FILE ==="
cat "$RECEIPT_FILE"
