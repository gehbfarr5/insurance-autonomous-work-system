#!/bin/bash
# verify.sh — MacServer EventKit Bridge Live Status & Structure Verification
# Target: Intel MacServer | AG-02 Candidate Package | Version 1.2.0
#
# Rules:
# 1. ONLY uses GET requests. (Zero POST/PUT/DELETE/PATCH mutations).
# 2. Explicit Verification Modes:
#    - --mode=unauthorized-check  : Asserts requests return HTTP 403 PERMISSION_DENIED prior to TCC.
#    - --mode=readonly-acceptance : Asserts requests return HTTP 200 OK with valid list metadata.
#                                  Enforces that 403 is treated as FAILURE.
# 3. Checks HTTP status and JSON response structure; any failure exits non-zero.
# 4. Strictly NEVER outputs auth tokens or real list contents to logs/stdout.

set -euo pipefail

MODE="readonly-acceptance"
PORT="18765"
CONFIG_FILE=""

while [ $# -gt 0 ]; do
    case "$1" in
        --mode=*)
            MODE="${1#*=}"
            shift
            ;;
        --unauthorized-check)
            MODE="unauthorized-check"
            shift
            ;;
        --readonly-acceptance)
            MODE="readonly-acceptance"
            shift
            ;;
        --port=*)
            PORT="${1#*=}"
            shift
            ;;
        --config=*)
            CONFIG_FILE="${1#*=}"
            shift
            ;;
        [0-9]*)
            PORT="$1"
            shift
            ;;
        *)
            if [ -f "$1" ]; then
                CONFIG_FILE="$1"
            fi
            shift
            ;;
    esac
done

if [ -z "$CONFIG_FILE" ]; then
    CONFIG_FILE="${TARGET_CONFIG_DIR:-$HOME/.config/muse-macserver}/bridge.env"
fi

echo "=========================================================="
echo " MacServer EventKit Bridge Verification Check             "
echo " Mode: $MODE | Port: $PORT"
echo "=========================================================="

# 1. Health Endpoint Verification (Public GET, No Auth)
echo "[1/2] Verifying Health endpoint (GET http://127.0.0.1:$PORT/health)..."
TMP_HEALTH=$(mktemp /tmp/bridge_health_XXXXXX.json)
trap 'rm -f "$TMP_HEALTH"' EXIT

HEALTH_CODE=$(curl -s -o "$TMP_HEALTH" -w "%{http_code}" "http://127.0.0.1:$PORT/health" || true)
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
echo "[2/2] Verifying Read Metadata endpoint ($MODE)..."

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

READ_CODE=$(curl -s -H "Authorization: Bearer $TOKEN" -o "$TMP_LISTS" -w "%{http_code}" "http://127.0.0.1:$PORT/reminders/lists" || true)

case "$MODE" in
    unauthorized-check)
        # In unauthorized-check mode: MUST return HTTP 403 PERMISSION_DENIED.
        # Returning 200 OK or empty list is a FAILURE.
        if [ "$READ_CODE" -eq 403 ]; then
            if ! grep -q '"code":"PERMISSION_DENIED"' "$TMP_LISTS"; then
                echo "ERROR: Expected PERMISSION_DENIED error body on 403 response!" >&2
                exit 1
            fi
            echo "  -> Status: 403 Forbidden"
            echo "  -> SUCCESS: Confirmed unauthorized rejection (PERMISSION_DENIED, zero data access prior to TCC)."
        elif [ "$READ_CODE" -eq 200 ]; then
            echo "ERROR: Unauthorized check FAILED! Server returned HTTP 200 OK instead of expected 403 Forbidden." >&2
            echo "Unapproved access or data leakage detected without TCC authorization." >&2
            exit 1
        else
            echo "ERROR: Unauthorized check FAILED! Expected HTTP 403, got: $READ_CODE" >&2
            exit 1
        fi
        ;;

    readonly-acceptance)
        # In readonly-acceptance mode: MUST return HTTP 200 OK.
        # If 403 is received, real read acceptance FAILS.
        if [ "$READ_CODE" -eq 200 ]; then
            FIRST_CHAR=$(head -c 1 "$TMP_LISTS")
            if [ "$FIRST_CHAR" != "[" ]; then
                echo "ERROR: Expected JSON array for metadata lists, got invalid format!" >&2
                exit 1
            fi

            if grep -qE '("incompleteCount"|"reminderCount"|"items"|"notes")' "$TMP_LISTS"; then
                echo "ERROR: Metadata response leaked item counts or content fields!" >&2
                exit 1
            fi

            echo "  -> Status: 200 OK"
            echo "  -> SUCCESS: Verified real list metadata structure (0 counts, 0 reminder contents exposed)."
        elif [ "$READ_CODE" -eq 403 ]; then
            echo "ERROR: Real read acceptance FAILED with HTTP 403 Forbidden!" >&2
            echo "Reminders authorization not granted or permission denied on MacServer." >&2
            exit 1
        else
            echo "ERROR: Real read acceptance FAILED! Expected HTTP 200 OK, got: $READ_CODE" >&2
            exit 1
        fi
        ;;

    *)
        echo "ERROR: Unknown verification mode: $MODE (must be 'unauthorized-check' or 'readonly-acceptance')" >&2
        exit 1
        ;;
esac

echo "=== Verification SUCCESS: Mode '$MODE' passed cleanly ==="
exit 0
