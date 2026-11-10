#!/usr/bin/env bash
# r1_window.sh — bounded, self-closing read-only capture window on MAC-1.
#
# WHAT IT DOES
#   Opens the MacServer bridge business gate, runs N read-only capture passes
#   against the single bound list, and ALWAYS closes the gate again — on success,
#   on failure, on timeout, on Ctrl-C.
#
# WHAT IT REFUSES TO DO
#   * no writes to Apple data (the bridge is read-only; this script only GETs)
#   * no rebuild, no install, no signing change, no new TCC prompt
#   * no Seoul, tunnel, docker, firewall or sshd change
#   * will not run without --confirm, and will not run on a host whose binary
#     does not match the frozen SHA256
#
# USAGE (default is a dry run that changes nothing)
#   ./r1_window.sh --list-id <ID> --expect-title <T> --expect-notes <N> --out-dir <DIR>
#   ./r1_window.sh ... --confirm [--passes 2] [--interval 60] [--deadline 900]
#
# TOKEN
#   Read from $EVENTKIT_BRIDGE_TOKEN, or from $BRIDGE_ENV_FILE (only the single
#   matching line is read into a variable). It is never printed, never echoed,
#   never written to a receipt.
#
# EXIT CODES
#   0 window completed and gate verified closed
#   2 precondition failure (nothing was changed)
#   3 capture completed but gate-closed verification FAILED -> manual action
#   4 deadline reached; gate closed by trap (treat captures as partial)

set -uo pipefail

PLIST="${PLIST:-$HOME/Library/LaunchAgents/com.muse.macserver-eventkit.plist}"
BIN="${BIN:-/Users/shared/bin/EventKitBridgeServer}"
FROZEN_SHA256="${FROZEN_SHA256:-f78e24e533c2bf9a77161dc05eb154ce99687de9a5b881ad481bfbe2bbfb3074}"
LABEL="com.muse.macserver-eventkit"
DOMAIN="gui/$(id -u)"
ENDPOINT="${ENDPOINT:-http://127.0.0.1:18765}"
CAPTURE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/r1_capture_readonly.py"

LIST_ID=""
EXPECT_TITLE=""
EXPECT_NOTES=""
OUT_DIR=""
PASSES=2
INTERVAL=60
DEADLINE=900
CONFIRM=0
BRIDGE_ENV_FILE="${BRIDGE_ENV_FILE:-}"

while [ $# -gt 0 ]; do
  case "$1" in
    --list-id) LIST_ID="$2"; shift 2 ;;
    --expect-title) EXPECT_TITLE="$2"; shift 2 ;;
    --expect-notes) EXPECT_NOTES="$2"; shift 2 ;;
    --out-dir) OUT_DIR="$2"; shift 2 ;;
    --passes) PASSES="$2"; shift 2 ;;
    --interval) INTERVAL="$2"; shift 2 ;;
    --deadline) DEADLINE="$2"; shift 2 ;;
    --confirm) CONFIRM=1; shift ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

fail() { echo "PRECONDITION_FAIL: $*" >&2; exit 2; }

[ -n "$LIST_ID" ] || fail "--list-id is required"
[ -n "$EXPECT_TITLE" ] || fail "--expect-title is required"
[ -n "$EXPECT_NOTES" ] || fail "--expect-notes is required"
[ -n "$OUT_DIR" ] || fail "--out-dir is required"
[ -f "$CAPTURE" ] || fail "capture tool not found at $CAPTURE"
command -v python3 >/dev/null 2>&1 || fail "python3 is not available on this host"
command -v shasum >/dev/null 2>&1 || fail "shasum is not available on this host"
[ -f "$PLIST" ] || fail "LaunchAgent plist not found: $PLIST"

ACTUAL_SHA="$(shasum -a 256 "$BIN" 2>/dev/null | awk '{print $1}')"
[ "$ACTUAL_SHA" = "$FROZEN_SHA256" ] || fail "deployed binary sha256 $ACTUAL_SHA != frozen $FROZEN_SHA256"

if codesign --verify --strict --all-architectures "$BIN" >/dev/null 2>&1; then
  SIGNATURE="VALID"
else
  SIGNATURE="INVALID"
fi

# Resolve the token without ever printing it.
TOKEN="${EVENTKIT_BRIDGE_TOKEN:-}"
if [ -z "$TOKEN" ] && [ -n "$BRIDGE_ENV_FILE" ] && [ -r "$BRIDGE_ENV_FILE" ]; then
  TOKEN="$(awk -F= '/^EVENTKIT_BRIDGE_BEARER_TOKEN=/{sub(/^EVENTKIT_BRIDGE_BEARER_TOKEN=/, ""); print; exit}' "$BRIDGE_ENV_FILE")"
fi
[ -n "$TOKEN" ] || fail "no bearer token available (set EVENTKIT_BRIDGE_TOKEN or --bridge-env via BRIDGE_ENV_FILE)"

echo "== R1 window plan =="
echo "  plist       : $PLIST"
echo "  binary      : $BIN"
echo "  sha256      : $ACTUAL_SHA (matches frozen)"
echo "  signature   : $SIGNATURE"
echo "  endpoint    : $ENDPOINT (loopback only)"
echo "  passes      : $PASSES, interval ${INTERVAL}s, deadline ${DEADLINE}s"
echo "  receipts    : $OUT_DIR"
echo "  gate at start: $(plutil -extract EnvironmentVariables.EVENTKIT_BRIDGE_PRODUCTION_AUTHORIZED raw "$PLIST" 2>/dev/null || echo 'UNREADABLE')"

if [ "$CONFIRM" -ne 1 ]; then
  echo
  echo "DRY RUN: nothing was changed. Re-run with --confirm inside the approved window."
  exit 0
fi

[ "$SIGNATURE" = "VALID" ] || fail "refusing to open the gate for an unsigned or invalid binary"
mkdir -p "$OUT_DIR" || fail "cannot create $OUT_DIR"

BACKUP="$PLIST.r1-backup-$(date +%s)"
cp -p "$PLIST" "$BACKUP" || fail "cannot back up plist"
echo "plist backup: $BACKUP"

START_EPOCH=$(date +%s)
GATE_OPEN=0
FAILED_CLOSE=0

restore_gate() {
  if [ "$GATE_OPEN" -eq 1 ]; then
    echo "--> restoring gate to false"
    if ! plutil -replace EnvironmentVariables.EVENTKIT_BRIDGE_PRODUCTION_AUTHORIZED -string false "$PLIST"; then
      echo "RESTORE_FAIL: could not rewrite the plist" >&2
      FAILED_CLOSE=1
      return
    fi
    launchctl kickstart -k "$DOMAIN/$LABEL" >/dev/null 2>&1
    sleep 3
    GATE_OPEN=0
    local code
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 -H "Authorization: Bearer $TOKEN" \
      "$ENDPOINT/reminders/lists" 2>/dev/null)"
    if [ "$code" = "403" ]; then
      echo "  [PASS] business endpoint restored to 403"
    else
      echo "  [FAIL] business endpoint returned $code instead of 403" >&2
      FAILED_CLOSE=1
    fi
  fi
}
trap 'restore_gate; exit 130' INT TERM
trap 'restore_gate' EXIT

echo "--> opening gate (temporary, this script closes it again)"
plutil -replace EnvironmentVariables.EVENTKIT_BRIDGE_PRODUCTION_AUTHORIZED -string true "$PLIST" \
  || fail "could not set the gate"
GATE_OPEN=1
launchctl kickstart -k "$DOMAIN/$LABEL" >/dev/null 2>&1 || fail "kickstart failed"
sleep 3

for pass in $(seq 1 "$PASSES"); do
  elapsed=$(( $(date +%s) - START_EPOCH ))
  if [ "$elapsed" -ge "$DEADLINE" ]; then
    echo "DEADLINE reached before pass $pass; closing gate" >&2
    trap - EXIT
    restore_gate
    exit 4
  fi
  out="$OUT_DIR/r1_pass_${pass}.json"
  echo "--> capture pass $pass -> $out"
  EVENTKIT_BRIDGE_TOKEN="$TOKEN" python3 "$CAPTURE" \
    --endpoint "$ENDPOINT" \
    --list-id "$LIST_ID" \
    --expect-title "$EXPECT_TITLE" \
    --expect-notes "$EXPECT_NOTES" \
    --out "$out" \
    --label "r1-window-pass-${pass}"
  if [ "$pass" -lt "$PASSES" ]; then sleep "$INTERVAL"; fi
done

echo "--> closing gate"
trap - EXIT
restore_gate

if [ "$FAILED_CLOSE" -ne 0 ]; then
  echo "WINDOW_RESULT: CAPTURE_OK_GATE_CLOSE_FAILED — manual restore required, do not retry blindly" >&2
  exit 3
fi
echo "WINDOW_RESULT: CAPTURE_OK_GATE_CLOSED_VERIFIED"
echo "receipts: $OUT_DIR"
echo "backup to keep until verified: $BACKUP"
