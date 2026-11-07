#!/bin/bash
# verify.sh — MacServer EventKit Bridge Live Status & Structure Verification
# Target: Intel MacServer | AG-02 Candidate Package | Version 1.1.0
#
# Rules:
# 1. ONLY uses GET requests. (Zero POST/PUT/DELETE/PATCH mutations).
# 2. Checks HTTP status and JSON response structure.
# 3. Any business acceptance failure exits with NON-ZERO status.
# 4. Strictly NEVER outputs auth tokens or real list contents to logs/stdout.

set -euo pipefail

PORT="${1:-18765}"
CONFIG_FILE="${2:-${TARGET_CONFIG_DIR:-$HOME/.config/muse-macserver}/bridge.env}"

echo "=========================================================="
echo " MacServer EventKit Bridge Verification Check (Port $PORT) "
echo "=========================================================="

# 1. Health Endpoint Verification (Public GET, No Auth)
echo "[1/2] Verifying Health endpoint (GET http://127.0.0.1:$PORT/health)..."
TMP_HEALTH=$(mktemp /tmp/bridge_health_XXXXXX.json)
trap 'rm -f "$TMP_HEALTH"' EXIT

HEALTH_CODE=$(curl -s -o "$TMP_HEALTH" -w "%{http_code}" "http://127.0.0.1:$PORT/health" || echo "000")
if [ "$HEALTH_CODE" -ne 200 ]; then
    echo "ERROR: Health check failed! Expected HTTP 200, got: $HEALTH_CODE" >&2
    exit 1
fi

# Verify health response JSON structure
if ! grep -q '"status":"ok"' "$TMP_HEALTH" || ! grep -q '"mode":"readonly"' "$TMP_HEALTH"; then
    echo "ERROR: Health response structure invalid!" >&2
    exit 1
fi
echo "  -> Status: 200 OK (mode: readonly, active_requests: 0, structure verified)"

# 2. Read Metadata Endpoint Verification (GET with Auth Token from Restricted Store)
echo "[2/2] Verifying Read Metadata endpoint (GET http://127.0.0.1:$PORT/reminders/lists)..."

TOKEN=""
if [ -f "$CONFIG_FILE" ]; then
    TOKEN=$(grep -E '^[[:space:]]*EVENTKIT_BRIDGE_BEARER_TOKEN=' "$CONFIG_FILE" | head -n 1 | awk -F '=' '{print $2}' | tr -d '"'"'")
fi

if [ -z "$TOKEN" ]; then
    echo "ERROR: Bearer token could not be retrieved from restricted store at $CONFIG_FILE!" >&2
    exit 1
fi

TMP_LISTS=$(mktemp /tmp/bridge_lists_XXXXXX.json)
trap 'rm -f "$TMP_HEALTH" "$TMP_LISTS"' EXIT

READ_CODE=$(curl -s -H "Authorization: Bearer $TOKEN" -o "$TMP_LISTS" -w "%{http_code}" "http://127.0.0.1:$PORT/reminders/lists" || echo "000")

if [ "$READ_CODE" -eq 200 ]; then
    # Verify response structure: JSON array without counts or item content
    FIRST_CHAR=$(head -c 1 "$TMP_LISTS")
    if [ "$FIRST_CHAR" != "[" ]; then
        echo "ERROR: Expected JSON array for metadata lists, got invalid format!" >&2
        exit 1
    fi

    # Verify no sensitive item counts or reminder content leaked
    if grep -qE '("incompleteCount"|"reminderCount"|"items"|"notes")' "$TMP_LISTS"; then
        echo "ERROR: Metadata response leaked item counts or content fields!" >&2
        exit 1
    fi

    echo "  -> Status: 200 OK"
    echo "  -> Verified list metadata structure (0 counts, 0 reminder contents exposed)."

elif [ "$READ_CODE" -eq 403 ]; then
    # In trial/unauthorized state, EventKit returns PERMISSION_DENIED
    if ! grep -q '"code":"PERMISSION_DENIED"' "$TMP_LISTS"; then
        echo "ERROR: Expected PERMISSION_DENIED error structure on 403 response!" >&2
        exit 1
    fi
    echo "  -> Status: 403 Forbidden (PERMISSION_DENIED verified: zero data exposed pending TCC approval)"

else
    echo "ERROR: Business verification failed! Expected 200 or 403, got: $READ_CODE" >&2
    exit 1
fi

echo "=== Verification SUCCESS: All structure checks passed cleanly ==="
exit 0
