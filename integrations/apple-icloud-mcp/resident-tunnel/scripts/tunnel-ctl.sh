#!/usr/bin/env bash
# tunnel-ctl.sh
# AG-05 | feat/ag05-resident-readonly-candidate
#
# MacServer Resident Tunnel Control Utility.
# Commands:
#   status   - Inspect runtime supervisor and child process status
#   start    - Start supervisor directly in background (or via launchd if configured)
#   stop     - Gracefully stop supervisor and any child SSH processes
#   restart  - Stop and restart supervisor
#   health   - Verify local loopback port and supervisor responsiveness
#   verify   - Validate config files, SSH key permissions, and binary presence

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="${CONFIG_DIR:-$HOME/.config/muse-macserver}"
CONFIG_FILE="${CONFIG_FILE:-$CONFIG_DIR/tunnel.conf}"
PID_FILE="${PID_FILE:-$CONFIG_DIR/tunnel.pid}"
STATUS_FILE="${STATUS_FILE:-$CONFIG_DIR/tunnel_status.json}"
LOG_FILE="${LOG_FILE:-$CONFIG_DIR/tunnel.log}"
RUNNER_SCRIPT="${RUNNER_SCRIPT:-$SCRIPT_DIR/run-resident-tunnel.sh}"

if [ -f "$CONFIG_FILE" ]; then
  # shellcheck source=/dev/null
  source "$CONFIG_FILE"
fi

IDENTITY_FILE="${IDENTITY_FILE:-$HOME/.ssh/id_ed25519_macserver_resident_tunnel}"
REMOTE_HOST="${REMOTE_HOST:-100.82.240.43}"
REMOTE_USER="${REMOTE_USER:-mac-operator}"
REMOTE_PORT="${REMOTE_PORT:-22}"

cmd="${1:-status}"

get_pid() {
  if [ -f "$PID_FILE" ]; then
    cat "$PID_FILE" 2>/dev/null || true
  fi
}

cmd_status() {
  local pid
  pid=$(get_pid)
  local is_running=false

  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    is_running=true
  fi

  if [ -f "$STATUS_FILE" ]; then
    echo "=== Tunnel Status (from $STATUS_FILE) ==="
    cat "$STATUS_FILE"
    echo ""
  fi

  if [ "$is_running" = true ]; then
    echo "[STATUS] Supervisor is RUNNING (PID: $pid)."
  else
    echo "[STATUS] Supervisor is NOT RUNNING."
  fi
}

cmd_verify() {
  echo "=== Validating MacServer Resident Tunnel Environment ==="
  local err=0

  # Check runner script
  if [ -x "$RUNNER_SCRIPT" ]; then
    echo "  [OK] Runner script executable: $RUNNER_SCRIPT"
  else
    echo "  [FAIL] Runner script not found or not executable: $RUNNER_SCRIPT"
    err=1
  fi

  # Check identity file permissions if it exists
  if [ -f "$IDENTITY_FILE" ]; then
    local perms
    perms=$(stat -f "%OLp" "$IDENTITY_FILE" 2>/dev/null || stat -c "%a" "$IDENTITY_FILE" 2>/dev/null || echo "unknown")
    if [ "$perms" = "600" ] || [ "$perms" = "400" ]; then
      echo "  [OK] Identity file permissions secure ($perms): $IDENTITY_FILE"
    else
      echo "  [WARN] Identity file permissions should be 0600 or 0400 (current: $perms): $IDENTITY_FILE"
    fi
  else
    echo "  [INFO] Identity file not found at default: $IDENTITY_FILE (ensure generated before deployment)"
  fi

  # Check SSH client
  if command -v ssh >/dev/null 2>&1; then
    echo "  [OK] SSH client found: $(command -v ssh)"
  else
    echo "  [FAIL] SSH binary not found in PATH"
    err=1
  fi

  # Check launchd plist template
  local plist_tpl="$SCRIPT_DIR/../launchd/com.muse.macserver-tunnel.plist.template"
  if [ -f "$plist_tpl" ]; then
    echo "  [OK] launchd plist template present: $plist_tpl"
  else
    echo "  [WARN] launchd plist template missing: $plist_tpl"
  fi

  if [ "$err" -eq 0 ]; then
    echo "=== Verification PASSED ==="
    return 0
  else
    echo "=== Verification FAILED ==="
    return 1
  fi
}

cmd_start() {
  local pid
  pid=$(get_pid)
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    echo "Supervisor is already running with PID $pid."
    return 0
  fi

  mkdir -p "$CONFIG_DIR"
  echo "Starting resident tunnel supervisor in background..."
  nohup "$RUNNER_SCRIPT" >> "$LOG_FILE" 2>&1 &
  sleep 1

  pid=$(get_pid)
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    echo "Supervisor started successfully (PID: $pid)."
  else
    echo "Failed to start supervisor. Check log: $LOG_FILE"
    return 1
  fi
}

cmd_stop() {
  local pid
  pid=$(get_pid)
  if [ -z "$pid" ] || ! kill -0 "$pid" 2>/dev/null; then
    echo "Supervisor is not running."
    rm -f "$PID_FILE"
    return 0
  fi

  echo "Stopping supervisor (PID: $pid)..."
  kill -TERM "$pid" 2>/dev/null || true

  local waited=0
  while kill -0 "$pid" 2>/dev/null && [ "$waited" -lt 15 ]; do
    sleep 0.5
    waited=$((waited + 1))
  done

  if kill -0 "$pid" 2>/dev/null; then
    echo "Supervisor did not exit in 7.5s, sending SIGKILL..."
    kill -KILL "$pid" 2>/dev/null || true
  fi

  rm -f "$PID_FILE"
  echo "Supervisor stopped."
}

cmd_restart() {
  cmd_stop
  sleep 1
  cmd_start
}

cmd_health() {
  local pid
  pid=$(get_pid)
  if [ -z "$pid" ] || ! kill -0 "$pid" 2>/dev/null; then
    echo "HEALTH: CRITICAL - Supervisor not running."
    return 2
  fi

  if [ ! -f "$STATUS_FILE" ]; then
    echo "HEALTH: WARNING - Status file missing."
    return 1
  fi

  local status
  status=$(grep '"status"' "$STATUS_FILE" | head -n1 | cut -d'"' -f4 || echo "unknown")
  echo "HEALTH: Supervisor PID $pid, status: $status"

  if [ "$status" = "connected" ]; then
    echo "HEALTH: OK"
    return 0
  elif [ "$status" = "connecting" ] || [ "$status" = "reconnecting" ]; then
    echo "HEALTH: WARNING - Tunnel in $status state"
    return 1
  else
    echo "HEALTH: DEGRADED - Tunnel state $status"
    return 2
  fi
}

case "$cmd" in
  status)  cmd_status ;;
  start)   cmd_start ;;
  stop)    cmd_stop ;;
  restart) cmd_restart ;;
  health)  cmd_health ;;
  verify)  cmd_verify ;;
  *)
    echo "Usage: $0 {status|start|stop|restart|health|verify}"
    exit 1
    ;;
esac
