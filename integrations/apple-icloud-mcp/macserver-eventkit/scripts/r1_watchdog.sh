#!/usr/bin/env bash
# r1_watchdog.sh — independent absolute-deadline watchdog for the R1 window.
#
# Reuses the pattern already validated by the AG-05 recovery drills
# (resident-tunnel/scripts/run-resident-tunnel.sh): a detached process, an
# absolute DEADLINE_EPOCH persisted on disk, pid + launch-identity metadata for
# safe reuse/kill decisions, and a failure state file that is never reported as
# success.
#
# It is started BEFORE any gate change and is not a child of the window
# script's shell (macOS has no setsid, so nohup + disown is used), so a crash, a
# SIGKILL of the window process, or a blocked read cannot take the deadline
# protection with it.
#
# Two independent limits are enforced:
#   * whole-window absolute deadline  (--deadline-epoch)
#   * cumulative gate-open budget     (--open-budget, measured from the
#                                      gate_open_since stamp written on open)
#
# A restore is not "call close and hope": r1_gate.sh always re-verifies the
# endpoint after reloading, and FIRED_RESTORED is written only when the gate
# operation returned 0 AND the receipt says verification PASS. A failed or
# unverifiable restore is recorded as FIRED_RESTORE_FAILED and exits 6; it is
# retried a bounded number of times and is never reported as success.
#
# Exit codes: 0 window disarmed normally, 2 usage, 4 state directory unusable
#             (nothing was armed), 6 restore FAILED (state kept).
#
# Usage:
#   r1_watchdog.sh --state-dir D --deadline-epoch E --open-budget S
#                  --plist P --config-file F --token-file T --endpoint U
#                  [--list-id ID] [--require-no-enumeration]
#                  [--poll 2] [--restore-attempts 3] [--restore-delay 2]
#
# --list-id switches the restore's verification to the single-ID probe, so a
# restore fired while the window process is already dead still touches no
# account-wide endpoint. The close then runs through r1_probe_close.sh, which
# requires that id and appends --require-no-enumeration itself; there is no
# argument here that could drop either.

set -uo pipefail

STATE_DIR=""; DEADLINE=""; BUDGET=""; PLIST=""; CONFIG_FILE=""; TOKEN_FILE=""
ENDPOINT="http://127.0.0.1:18765"; POLL="${R1_POLL_SECONDS:-2}"
LIST_ID=""; NO_ENUM=0
MAX_ATTEMPTS="${R1_RESTORE_ATTEMPTS:-3}"
RETRY_DELAY="${R1_RESTORE_DELAY:-2}"
PYTHON="${PYTHON_BIN:-python3}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GATE="$HERE/r1_gate.sh"
CLOSE="$HERE/r1_probe_close.sh"

while [ $# -gt 0 ]; do
  case "$1" in
    --state-dir) STATE_DIR="$2"; shift 2 ;;
    --deadline-epoch) DEADLINE="$2"; shift 2 ;;
    --open-budget) BUDGET="$2"; shift 2 ;;
    --plist) PLIST="$2"; shift 2 ;;
    --config-file) CONFIG_FILE="$2"; shift 2 ;;
    --token-file) TOKEN_FILE="$2"; shift 2 ;;
    --endpoint) ENDPOINT="$2"; shift 2 ;;
    --list-id) LIST_ID="$2"; shift 2 ;;
    --require-no-enumeration) NO_ENUM=1; shift ;;
    --poll) POLL="$2"; shift 2 ;;
    --restore-attempts) MAX_ATTEMPTS="$2"; shift 2 ;;
    --restore-delay) RETRY_DELAY="$2"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

[ -n "$STATE_DIR" ] && [ -n "$DEADLINE" ] && [ -n "$BUDGET" ] && [ -n "$PLIST" ] && [ -n "$TOKEN_FILE" ] \
  || { echo "usage: r1_watchdog.sh --state-dir --deadline-epoch --open-budget --plist --token-file" >&2; exit 2; }

if [ "$NO_ENUM" -eq 1 ] && [ -z "$LIST_ID" ]; then
  echo "usage: --require-no-enumeration needs --list-id (the legacy restore enumerates)" >&2
  exit 2
fi

# With a target ID the restore goes through r1_probe_close.sh rather than
# r1_gate.sh: that wrapper cannot be called without a list id and appends
# --require-no-enumeration itself, so the emergency path cannot lose the two
# flags between here and the gate. Without a list id this is an R1 replay and
# keeps the enumeration-based close it was written against.
if [ -n "$LIST_ID" ] && [ ! -f "$CLOSE" ]; then
  echo "[watchdog] FATAL: $CLOSE is missing; refusing to arm without a close path" >&2
  exit 4
fi

# The deadline protection is only real if its state can be recorded. A watchdog
# that starts without a writable state directory would look armed and silently
# fail to fire, so it refuses to run instead (the caller aborts the window).
if ! mkdir -p "$STATE_DIR" 2>/dev/null; then
  echo "[watchdog] FATAL: cannot create the state directory: $STATE_DIR" >&2
  exit 4
fi
if ! chmod 700 "$STATE_DIR" 2>/dev/null; then
  echo "[watchdog] FATAL: cannot restrict the state directory to 0700: $STATE_DIR" >&2
  exit 4
fi
if ! : > "$STATE_DIR/.r1-write-probe.$$" 2>/dev/null; then
  echo "[watchdog] FATAL: state directory is not writable: $STATE_DIR" >&2
  exit 4
fi
rm -f "$STATE_DIR/.r1-write-probe.$$" 2>/dev/null || true
STATUS="$STATE_DIR/watchdog_status.env"
LOG="$STATE_DIR/watchdog.log"

write_status() {
  local state="$1" reason="$2" rc="${3:-0}"
  {
    echo "WATCHDOG_STATE=$state"
    echo "WATCHDOG_REASON=$reason"
    echo "RESTORE_EXIT_CODE=$rc"
    echo "FIRED_AT_EPOCH=$(date +%s)"
    echo "DEADLINE_EPOCH=$DEADLINE"
    echo "OPEN_BUDGET_SECONDS=$BUDGET"
  } > "$STATUS.tmp" && mv -f "$STATUS.tmp" "$STATUS"
  chmod 600 "$STATUS" 2>/dev/null || true
}

# Publish identity so a later reader can prove which process this is.
{
  echo "WATCHDOG_PID=$$"
  echo "WATCHDOG_UID=$UID"
  echo "WATCHDOG_STATE_DIR=\"$STATE_DIR\""
  echo "WATCHDOG_DEADLINE_EPOCH=$DEADLINE"
  echo "WATCHDOG_LSTART=\"$(ps -p $$ -o lstart= 2>/dev/null | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')\""
} > "$STATE_DIR/watchdog_meta.env"
chmod 600 "$STATE_DIR/watchdog_meta.env" 2>/dev/null || true
echo $$ > "$STATE_DIR/watchdog.pid"
chmod 600 "$STATE_DIR/watchdog.pid" 2>/dev/null || true
write_status RUNNING none 0
echo "[watchdog $$] armed until $DEADLINE, open budget ${BUDGET}s" >> "$LOG"

# A restore only counts when the gate operation itself verified the endpoint.
# Exit 0 from r1_gate.sh already implies that, but the receipt is read as well so
# a future change to the gate cannot silently downgrade this guarantee.
receipt_verified() {
  [ -f "$1" ] || return 1
  "$PYTHON" - "$1" <<'PYEOF' >/dev/null 2>&1
import json, sys
try:
    with open(sys.argv[1], encoding="utf-8") as fh:
        data = json.load(fh)
except Exception:
    sys.exit(1)
sys.exit(0 if data.get("verification") == "PASS" else 1)
PYEOF
}

restore() {
  local reason="$1" attempt=1 rc=0 receipt=""
  echo "[watchdog $$] FIRING reason=$reason at $(date +%s)" >> "$LOG"
  while [ "$attempt" -le "$MAX_ATTEMPTS" ]; do
    receipt="$STATE_DIR/gate_close_${reason}_attempt${attempt}.json"
    # The mutex lives inside r1_gate.sh, so a restore can never overlap the
    # window's own close or an operator's emergency close. A busy lock is a
    # bounded failure, not a reason to write concurrently.
    #
    # The restore is verified through the same single-ID probe the window uses,
    # so the close path touches no account-wide endpoint even when the window
    # itself is already dead. It is also a close and nothing else: retrying here
    # never re-sends the open-phase probe.
    if [ -n "$LIST_ID" ]; then
      "$CLOSE" --plist "$PLIST" --config-file "$CONFIG_FILE" \
        --token-file "$TOKEN_FILE" --endpoint "$ENDPOINT" \
        --list-id "$LIST_ID" --purpose "watchdog:$reason" \
        --lock-wait 15 --out "$receipt" >> "$LOG" 2>&1
    else
      "$GATE" close --plist "$PLIST" --config-file "$CONFIG_FILE" \
        --token-file "$TOKEN_FILE" --endpoint "$ENDPOINT" \
        --purpose "watchdog:$reason" --lock-wait 15 --out "$receipt" >> "$LOG" 2>&1
    fi
    rc=$?
    if [ "$rc" -eq 0 ] && receipt_verified "$receipt"; then
      write_status FIRED_RESTORED "$reason" 0
      echo "[watchdog $$] restore VERIFIED (reason=$reason, attempt=$attempt)" >> "$LOG"
      return 0
    fi
    echo "[watchdog $$] attempt $attempt failed rc=$rc (reason=$reason); see $receipt" >> "$LOG"
    attempt=$((attempt + 1))
    [ "$attempt" -le "$MAX_ATTEMPTS" ] && sleep "$RETRY_DELAY"
  done
  # Never report success, never keep hammering: the last receipt carries the
  # real state and the operator has to step in.
  write_status FIRED_RESTORE_FAILED "$reason" "$rc"
  echo "[watchdog $$] CRITICAL restore NOT verified after $MAX_ATTEMPTS attempts (rc=$rc, reason=$reason)" >> "$LOG"
  return 1
}

while :; do
  now=$(date +%s)
  if [ -f "$STATE_DIR/stop" ]; then
    write_status DISARMED_BY_MAIN none 0
    echo "[watchdog $$] disarmed by main at $now" >> "$LOG"
    exit 0
  fi
  if [ "$now" -ge "$DEADLINE" ]; then
    restore deadline || exit 6
    exit 0
  fi
  if [ -f "$STATE_DIR/gate_open_since" ]; then
    opened="$(cat "$STATE_DIR/gate_open_since" 2>/dev/null || echo 0)"
    case "$opened" in ''|*[!0-9]*) opened=0 ;; esac
    if [ "$opened" -gt 0 ] && [ $(( now - opened )) -gt "$BUDGET" ]; then
      restore open_budget || exit 6
      exit 0
    fi
  fi
  sleep "$POLL"
done
