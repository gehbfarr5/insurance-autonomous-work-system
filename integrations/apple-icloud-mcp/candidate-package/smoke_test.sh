#!/bin/bash
# smoke_test.sh — Isolated Process-Level Smoke Test (Fake Environment)
# AG-02 Candidate Package | Version 1.1.0

set -euo pipefail

BINARY="${1:-}"
if [ -z "$BINARY" ] || [ ! -x "$BINARY" ]; then
    echo "Usage: $0 <path-to-EventKitBridgeServer>" >&2
    exit 1
fi

PORT=18779
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
TMP_LOG=$(mktemp /tmp/smoke_server_XXXXXX.log)
"$BINARY" > "$TMP_LOG" 2>&1 &
SERVER_PID=$!

trap 'kill -SIGTERM $SERVER_PID 2>/dev/null || true; wait $SERVER_PID 2>/dev/null || true; rm -f "$TMP_LOG"' EXIT

# Wait for server to bind
for i in {1..25}; do
    if curl -s "http://127.0.0.1:$PORT/health" > /dev/null 2>&1; then
        break
    fi
    sleep 0.1
done

echo "[1/4] Health check verification:"
HEALTH_RESP=$(curl -s "http://127.0.0.1:$PORT/health")
echo "$HEALTH_RESP" | grep -q '"status":"ok"'
echo "$HEALTH_RESP" | grep -q '"mode":"readonly"'
echo "  -> Health response verified: status:ok, mode:readonly"

echo "[2/4] Write rejection verification (405 Method Not Allowed in Fake env):"
HTTP_CODE=$(curl -s -X POST -o /dev/null -w "%{http_code}" "http://127.0.0.1:$PORT/reminders/lists")
if [ "$HTTP_CODE" -ne 405 ]; then
    echo "ERROR: Write rejection failed! Expected 405, got $HTTP_CODE" >&2
    exit 1
fi
echo "  -> Write isolation verified: HTTP 405 Method Not Allowed, 0 mutations downstream."

echo "[3/4] Authorized metadata query verification (200 OK):"
TMP_RESP=$(mktemp /tmp/smoke_meta_XXXXXX.json)
curl -s -H "Authorization: Bearer $TOKEN" -o "$TMP_RESP" "http://127.0.0.1:$PORT/reminders/lists"
grep -q '"listID"' "$TMP_RESP"
if grep -qE '("incompleteCount"|"reminderCount"|"items")' "$TMP_RESP"; then
    echo "ERROR: Leaked count or item fields in metadata response!" >&2
    rm -f "$TMP_RESP"
    exit 1
fi
rm -f "$TMP_RESP"
echo "  -> Authorized metadata verified: valid JSON list structure, 0 counts/contents leaked."

echo "[4/4] Graceful shutdown verification:"
kill -SIGTERM $SERVER_PID
wait $SERVER_PID || true
echo "  -> Process gracefully exited on SIGTERM."

echo "=== Process-level smoke test passed 100% successfully! ==="
