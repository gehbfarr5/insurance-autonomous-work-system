#!/bin/bash
set -euo pipefail

BINARY="$1"
PORT=18769
TOKEN="smoke-test-token-$(date +%s)"
LIST_ID="smoke-list-uuid-001"
SOURCE_ID="smoke-source-uuid-001"

echo "=== Starting process-level smoke test for $BINARY ==="
export EVENTKIT_BRIDGE_MODE="TEST"
export EVENTKIT_BRIDGE_PORT="$PORT"
export EVENTKIT_BRIDGE_ALLOWED_LIST_IDS="$LIST_ID"
export EVENTKIT_BRIDGE_BINDINGS="$LIST_ID:$SOURCE_ID:calDAV:iCloud"
export EVENTKIT_BRIDGE_BEARER_TOKEN="$TOKEN"
export EVENTKIT_BRIDGE_MAX_CONCURRENT="10"
export EVENTKIT_BRIDGE_MAX_STORE_OPS="10"
export EVENTKIT_BRIDGE_TIMEOUT="5.0"
export EVENTKIT_BRIDGE_PRODUCTION_AUTHORIZED="false"

# Launch binary in background
"$BINARY" > /tmp/smoke_server.log 2>&1 &
SERVER_PID=$!

trap "kill -SIGTERM $SERVER_PID 2>/dev/null || true; wait $SERVER_PID 2>/dev/null || true" EXIT

# Wait for server to bind
for i in {1..20}; do
    if curl -s "http://127.0.0.1:$PORT/health" > /dev/null 2>&1; then
        break
    fi
    sleep 0.1
done

echo "1. Health check verification:"
HEALTH_RESP=$(curl -s "http://127.0.0.1:$PORT/health")
echo "Health: $HEALTH_RESP"
echo "$HEALTH_RESP" | grep -q '"status":"ok"'

echo "2. Write rejection verification (405):"
HTTP_CODE=$(curl -s -X POST -o /dev/null -w "%{http_code}" "http://127.0.0.1:$PORT/reminders/lists")
echo "Write HTTP Code: $HTTP_CODE"
[ "$HTTP_CODE" -eq 405 ]

echo "3. Authorized metadata query verification (200):"
METADATA_RESP=$(curl -s -H "Authorization: Bearer $TOKEN" "http://127.0.0.1:$PORT/reminders/lists")
echo "Metadata: $METADATA_RESP"
echo "$METADATA_RESP" | grep -q '"fake-list-icloud-001"'

echo "4. Graceful shutdown verification:"
kill -SIGTERM $SERVER_PID
wait $SERVER_PID || true
echo "=== Smoke test passed successfully! ==="
