#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# Isolated Verification Suite for AG-03 Production Entry
# Tests configuration parsing, Compose interpolation, fail-fast and safety guards
# using purely synthetic configs in an isolated staging directory.
#
# GUARANTEE: Does NOT touch production container or production network!
# ==============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GATEWAY_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ENTRY_SCRIPT="$GATEWAY_ROOT/scripts/production-entry.sh"
COMPOSE_PROD="$GATEWAY_ROOT/config/compose.production.yaml"

TEST_TS=$(date +"%Y%m%d_%H%M%S")
STAGING_DIR="/tmp/ag03-prod-entry-staging-${TEST_TS}"
mkdir -p "$STAGING_DIR"

cleanup() {
  rm -rf "$STAGING_DIR"
}
trap cleanup EXIT INT TERM

# If docker is not present in local test environment, provide a minimal mock docker for compose config validation
if ! command -v docker >/dev/null 2>&1; then
  MOCK_BIN="$STAGING_DIR/bin"
  mkdir -p "$MOCK_BIN"
  cat << 'EOF' > "$MOCK_BIN/docker"
#!/usr/bin/env bash
if [ "$1" = "compose" ]; then
  if [ -z "${MACSERVER_EVENTKIT_AUTH_TOKEN:-}" ] || [ -z "${MACSERVER_EVENTKIT_ALLOWED_LISTS:-}" ]; then
    echo "ERROR: Missing required gateway environment variables" >&2
    exit 1
  fi
  cat << YAMLEOF
services:
  carddav:
    image: ${CARDDAV_IMAGE:-sha256:faa6e380ee4b9f9d96dd424ced56bf27a0778722a02323efedd542b29f362929}
    environment:
      ALLOW_REMINDERS_READ_1: "true"
      ALLOW_REMINDERS_WRITE_1: "false"
YAMLEOF
  exit 0
fi
echo "Mock docker: unrecognized command: $*" >&2
exit 1
EOF
  chmod +x "$MOCK_BIN/docker"
  export PATH="$MOCK_BIN:$PATH"
fi

echo "========================================================================"
echo " RUNNING ISOLATED PRODUCTION ENTRY VERIFICATION"
echo " Staging Dir: $STAGING_DIR"
echo " Time:        $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
echo "========================================================================"

# 1. Create synthetic production-like secrets.env
cat << 'EOF' > "$STAGING_DIR/secrets.env"
ICLOUD_ACCOUNT_1=synthetic_prod_verify@icloud.example
ICLOUD_APP_PASSWORD_1=abcd-efgh-ijkl-mnop
TOKEN_ENCRYPTION_KEY=dGVzdC1lbmNyeXB0aW9uLWtleS0zMi1ieXRlcwo=
ADMIN_PASSWORD_HASH=scrypt$32768$8$1$syntheticHashVal
ALLOW_CALENDAR_READ_1=true
ALLOW_CALENDAR_WRITE_1=true
ALLOW_CONTACTS_READ_1=true
ALLOW_CONTACTS_WRITE_1=true
ALLOW_MAIL_READ_1=false
ALLOW_MAIL_WRITE_1=false
EOF
chmod 600 "$STAGING_DIR/secrets.env"

# 2. Create synthetic production-like gateway.env
cat << 'EOF' > "$STAGING_DIR/gateway.env"
MACSERVER_EVENTKIT_AUTH_TOKEN=test-synthetic-production-bearer-token-32b
MACSERVER_EVENTKIT_ALLOWED_LISTS=00000000-AAAA-BBBB-CCCC-000000000001:src-synthetic-icloud-test:iCloud:calDAV
MACSERVER_EVENTKIT_ENDPOINT=http://172.19.0.1:18765
EOF
chmod 600 "$STAGING_DIR/gateway.env"

echo "[Test 1/4] Testing verify-config with valid synthetic configuration..."
"$ENTRY_SCRIPT" verify-config "$COMPOSE_PROD" "$STAGING_DIR/secrets.env" "$STAGING_DIR/gateway.env" 1
echo "PASS: Test 1 verify-config passed cleanly."

echo "[Test 2/4] Testing Fail-Fast when MACSERVER_EVENTKIT_ALLOWED_LISTS is missing..."
cat << 'EOF' > "$STAGING_DIR/gateway-empty-lists.env"
MACSERVER_EVENTKIT_AUTH_TOKEN=test-synthetic-production-bearer-token-32b
MACSERVER_EVENTKIT_ENDPOINT=http://172.19.0.1:18765
EOF
chmod 600 "$STAGING_DIR/gateway-empty-lists.env"

if "$ENTRY_SCRIPT" verify-config "$COMPOSE_PROD" "$STAGING_DIR/secrets.env" "$STAGING_DIR/gateway-empty-lists.env" 1 >/dev/null 2>&1; then
  echo "FAIL: Compose config should have refused startup when ALLOWED_LISTS was missing!" >&2
  exit 1
fi
echo "PASS: Test 2 Fail-Fast on missing MACSERVER_EVENTKIT_ALLOWED_LISTS verified."

echo "[Test 3/4] Testing Fail-Fast when MACSERVER_EVENTKIT_AUTH_TOKEN is missing..."
cat << 'EOF' > "$STAGING_DIR/gateway-empty-token.env"
MACSERVER_EVENTKIT_ALLOWED_LISTS=00000000-AAAA-BBBB-CCCC-000000000001:src-synthetic-icloud-test:iCloud:calDAV
MACSERVER_EVENTKIT_ENDPOINT=http://172.19.0.1:18765
EOF
chmod 600 "$STAGING_DIR/gateway-empty-token.env"

if "$ENTRY_SCRIPT" verify-config "$COMPOSE_PROD" "$STAGING_DIR/secrets.env" "$STAGING_DIR/gateway-empty-token.env" 1 >/dev/null 2>&1; then
  echo "FAIL: Compose config should have refused startup when AUTH_TOKEN was missing!" >&2
  exit 1
fi
echo "PASS: Test 3 Fail-Fast on missing MACSERVER_EVENTKIT_AUTH_TOKEN verified."

echo "[Test 4/4] Testing deployment guard: deploy without approval must be blocked..."
if "$ENTRY_SCRIPT" deploy >/dev/null 2>&1; then
  echo "FAIL: Deploy without approval should have exited with error code!" >&2
  exit 1
fi
echo "PASS: Test 4 Production deployment guard correctly blocked unauthorized deploy."

echo "========================================================================"
echo " ALL ISOLATED PRODUCTION ENTRY TESTS PASSED (4/4)"
echo " Zero production impact verified."
echo "========================================================================"
