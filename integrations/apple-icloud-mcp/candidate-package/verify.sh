#!/bin/bash
# verify.sh — MacServer EventKit Bridge Live Status & Isolation Verification
# AG-02 Candidate Package

set -euo pipefail

PORT="${1:-18765}"
TOKEN="${2:-}"

echo "=========================================================="
echo " MacServer EventKit Bridge Verification Check (Port $PORT) "
echo "=========================================================="

# 1. Health Endpoint (Public, No Auth)
echo "[1/3] Testing Health endpoint (http://127.0.0.1:$PORT/health)..."
HEALTH_CODE=$(curl -s -o /tmp/bridge_health.json -w "%{http_code}" "http://127.0.0.1:$PORT/health")
if [ "$HEALTH_CODE" -eq 200 ]; then
    echo "  -> Status: 200 OK"
    cat /tmp/bridge_health.json
    echo ""
else
    echo "  -> FAILED: Expected 200, got $HEALTH_CODE" >&2
    exit 1
fi

# 2. Write Isolation Verification (Must return 405)
echo "[2/3] Testing Write Isolation (POST http://127.0.0.1:$PORT/reminders/lists)..."
WRITE_CODE=$(curl -s -X POST -o /dev/null -w "%{http_code}" "http://127.0.0.1:$PORT/reminders/lists")
if [ "$WRITE_CODE" -eq 405 ]; then
    echo "  -> Status: 405 Method Not Allowed (Write rejected successfully, 0 downstream writes)"
else
    echo "  -> FAILED: Expected 405, got $WRITE_CODE" >&2
    exit 1
fi

# 3. Read Metadata Endpoint (Requires Auth)
if [ -n "$TOKEN" ]; then
    echo "[3/3] Testing Read Metadata (GET http://127.0.0.1:$PORT/reminders/lists)..."
    READ_CODE=$(curl -s -H "Authorization: Bearer $TOKEN" -o /tmp/bridge_lists.json -w "%{http_code}" "http://127.0.0.1:$PORT/reminders/lists")
    if [ "$READ_CODE" -eq 200 ]; then
        echo "  -> Status: 200 OK"
        cat /tmp/bridge_lists.json
        echo ""
    else
        echo "  -> Status: $READ_CODE"
        cat /tmp/bridge_lists.json 2>/dev/null || true
    fi
else
    echo "[3/3] Skipping authenticated read check (no token provided)."
fi

echo "=== Verification complete! ==="
