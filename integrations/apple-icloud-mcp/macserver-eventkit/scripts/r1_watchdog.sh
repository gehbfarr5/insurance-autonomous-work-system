#!/usr/bin/env bash
# r1_watchdog.sh — independent absolute-deadline watchdog for the R1 window.
#
# Reuses the pattern already validated by the AG-05 recovery drills
# (resident-tunnel/scripts/run-resident-tunnel.sh): a detached process, an
# absolute DEADLINE_EPOCH persisted on disk, pid + launch-identity metadata for
# safe reuse/kill decisions, and a failure state file that is never reported as
# success.
#
# It is started BEFORE any gate change, and it is not a child of the window
# script's shell: it is launched with setsid so that a crash, a SIGKILL of the
# window process, or a blocked read cannot take the deadline protection with it.
#
# Two independent limits are enforced:
#   * whole-window absolute deadline  (--deadline-epoch)
#   * cumulative gate-open budget     (--open-budget, measured from the
#                                      gate_open_since stamp written on open)
#
# Exit codes: 0 window disarmed normally, 2 usage, 6 restore FAILED (state kept).
#
# Usage:
#   r1_watchdog.sh --state-dir D --deadline-epoch E --open-budget S
#                  --plist P --config-file F --token-file T --endpoint U
#                  [--poll 2]

set -uo pipefail

STATE_DIR=""; DEADLINE=""; BUDGET=""; PLIST=""; CONFIG_FILE=""; TOKEN_FILE=""
ENDPOINT="http://127.0.0.1:18765"; POLL="${R1_POLL_SECONDS:-2}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GATE="$HERE/r1_gate.sh"

while [ $# -gt 0 ]; do
  case "$1" in
    --state-dir) STATE_DIR="$2"; shift 2 ;;
    --deadline-epoch) DEADLINE="$2"; shift 2 ;;
    --open-budget) BUDGET="$2"; shift 2 ;;
    --plist) PLIST="$2"; shift 2 ;;
    --config-file) CONFIG_FILE="$2"; shift 2 ;;
    --token-file) TOKEN_FILE="$2"; shift 2 ;;
    --endpoint) ENDPOINT="$2"; shift 2 ;;
    --poll) POLL="$2"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

[ -n "$STATE_DIR" ] && [ -n "$DEADLINE" ] && [ -n "$BUDGET" ] && [ -n "$PLIST" ] && [ -n "$TOKEN_FILE" ] \
  || { echo "usage: r1_watchdog.sh --state-dir --deadline-epoch --open-budget --plist --token-file" >&2; exit 2; }

mkdir -p "$STATE_DIR" && chmod 700 "$STATE_DIR"
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

restore() {
  local reason="$1"
  echo "[watchdog $$] FIRING reason=$reason at $(date +%s)" >> "$LOG"
  local lock="$STATE_DIR/restore.lock"
  local waited=0
  while ! mkdir "$lock" 2>/dev/null; do
    # Another restorer owns the lock. Wait briefly, then proceed anyway: a
    # duplicated close is harmless, a missed close is not.
    sleep 0.2; waited=$((waited + 1))
    [ "$waited" -gt 25 ] && break
  done
  "$GATE" close \
    --plist "$PLIST" \
    --config-file "$CONFIG_FILE" \
    --token-file "$TOKEN_FILE" \
    --endpoint "$ENDPOINT" \
    --out "$STATE_DIR/gate_close_${reason}.json" >> "$LOG" 2>&1
  local rc=$?
  [ -d "$lock" ] && rmdir "$lock" 2>/dev/null
  if [ "$rc" -eq 0 ]; then
    write_status FIRED_RESTORED "$reason" 0
    echo "[watchdog $$] restore OK (reason=$reason)" >> "$LOG"
  else
    write_status FIRED_RESTORE_FAILED "$reason" "$rc"
    echo "[watchdog $$] CRITICAL restore FAILED rc=$rc (reason=$reason)" >> "$LOG"
  fi
  return "$rc"
}

while :; do
  now=$(date +%s)
  if [ -f "$STATE_DIR/stop" ]; then
    write_status DISARMED_BY_MAIN none 0
    echo "[watchdog $$] disarmed by main at $now" >> "$LOG"
    exit 0
  fi
  if [ "$now" -ge "$DEADLINE" ]; then
    restore deadline
    exit $(( $? == 0 ? 0 : 6 ))
  fi
  if [ -f "$STATE_DIR/gate_open_since" ]; then
    opened="$(cat "$STATE_DIR/gate_open_since" 2>/dev/null || echo 0)"
    case "$opened" in ''|*[!0-9]*) opened=0 ;; esac
    if [ "$opened" -gt 0 ] && [ $(( now - opened )) -gt "$BUDGET" ]; then
      restore open_budget
      exit $(( $? == 0 ? 0 : 6 ))
    fi
  fi
  sleep "$POLL"
done
