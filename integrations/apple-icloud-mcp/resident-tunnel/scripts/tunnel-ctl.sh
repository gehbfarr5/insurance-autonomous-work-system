#!/usr/bin/env bash
# tunnel-ctl.sh
# AG-05 | feat/ag05-resident-readonly-candidate
#
# MacServer Resident Tunnel Control Utility.
# Commands:
#   status   - Inspect runtime supervisor, lock state, and status JSON
#   start    - Start supervisor via launchd (or standalone background process)
#   stop     - Gracefully stop verified supervisor and child SSH processes
#   restart  - Stop and restart supervisor
#   health   - Perform fresh active probe (HTTP 200/403 on /health, zero content read)
#   verify   - Validate config files, SSH key permissions, and binaries

set -euo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="${CONFIG_DIR:-$HOME/.config/muse-macserver}"
CONFIG_FILE="${CONFIG_FILE:-$CONFIG_DIR/tunnel.conf}"
PID_FILE="${PID_FILE:-$CONFIG_DIR/tunnel.pid}"
LOCK_DIR="${LOCK_DIR:-$CONFIG_DIR/tunnel.lock}"
STATUS_FILE="${STATUS_FILE:-$CONFIG_DIR/tunnel_status.json}"
LOG_FILE="${LOG_FILE:-$CONFIG_DIR/tunnel.log}"
RUNNER_SCRIPT="${RUNNER_SCRIPT:-$SCRIPT_DIR/run-resident-tunnel.sh}"
PLIST_FILE="${HOME}/Library/LaunchAgents/com.muse.macserver-tunnel.plist"
BRIDGE_PROBE_URL="${BRIDGE_PROBE_URL:-http://127.0.0.1:18765/health}"

if [ -f "$CONFIG_FILE" ]; then
  # shellcheck source=/dev/null
  source "$CONFIG_FILE"
fi

IDENTITY_FILE="${IDENTITY_FILE:-$HOME/.ssh/id_ed25519_macserver_resident_tunnel}"
REMOTE_HOST="${REMOTE_HOST:-seoul-mcp.internal}"
REMOTE_USER="${REMOTE_USER:-mac-operator}"
REMOTE_PORT="${REMOTE_PORT:-22}"

cmd="${1:-status}"

get_verified_supervisor_pid() {
  local candidate_pid=""
  if [ -f "$LOCK_DIR/pid" ]; then
    candidate_pid=$(cat "$LOCK_DIR/pid" 2>/dev/null || true)
  elif [ -f "$PID_FILE" ]; then
    candidate_pid=$(cat "$PID_FILE" 2>/dev/null || true)
  fi

  if [ -n "$candidate_pid" ] && kill -0 "$candidate_pid" 2>/dev/null; then
    local cmd_args
    cmd_args=$(ps -p "$candidate_pid" -o args= 2>/dev/null || echo "")
    if echo "$cmd_args" | grep -q "run-resident-tunnel.sh"; then
      echo "$candidate_pid"
      return 0
    fi
  fi
  return 1
}

cmd_status() {
  local pid=""
  if pid=$(get_verified_supervisor_pid); then
    echo "[STATUS] Supervisor is RUNNING (Verified PID: $pid)."
  else
    echo "[STATUS] Supervisor is NOT RUNNING."
  fi

  if [ -d "$LOCK_DIR" ]; then
    echo "  [LOCK] Active lock directory present: $LOCK_DIR"
  fi

  if [ -f "$STATUS_FILE" ]; then
    echo "=== Tunnel Status (from $STATUS_FILE) ==="
    cat "$STATUS_FILE"
    echo ""
  else
    echo "  [STATUS_FILE] No status file found at $STATUS_FILE"
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

  # Check identity file permissions if exists
  if [ -f "$IDENTITY_FILE" ]; then
    local perms
    perms=$(stat -f "%OLp" "$IDENTITY_FILE" 2>/dev/null || stat -c "%a" "$IDENTITY_FILE" 2>/dev/null || echo "unknown")
    if [ "$perms" = "600" ] || [ "$perms" = "400" ]; then
      echo "  [OK] Identity file permissions secure ($perms): $IDENTITY_FILE"
    else
      echo "  [FAIL] Identity file permissions insecure ($perms, must be 0600 or 0400): $IDENTITY_FILE"
      err=1
    fi
  else
    echo "  [INFO] Identity file not found at default: $IDENTITY_FILE"
  fi

  # Check SSH binary
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
    if command -v plutil >/dev/null 2>&1; then
      # Test template with dummy substitutions
      local tmp_plist
      tmp_plist=$(mktemp)
      sed -e "s|__RUNNER_SCRIPT_PATH__|$RUNNER_SCRIPT|g" \
          -e "s|__CONFIG_DIR__|$CONFIG_DIR|g" "$plist_tpl" > "$tmp_plist"
      if plutil -lint "$tmp_plist" >/dev/null 2>&1; then
        echo "  [OK] Plist XML syntax valid"
      else
        echo "  [FAIL] Plist XML syntax invalid"
        err=1
      fi
      rm -f "$tmp_plist"
    fi
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
  local pid=""
  if pid=$(get_verified_supervisor_pid); then
    echo "Supervisor is already running with verified PID $pid."
    return 0
  fi

  mkdir -p "$CONFIG_DIR"

  # If LaunchAgent plist is installed, prefer launchctl
  if [ -f "$PLIST_FILE" ] && command -v launchctl >/dev/null 2>&1; then
    echo "Starting supervisor via launchd ($PLIST_FILE)..."
    launchctl load -w "$PLIST_FILE" 2>/dev/null || launchctl start com.muse.macserver-tunnel 2>/dev/null || true
  else
    echo "Starting resident tunnel supervisor in standalone background mode..."
    nohup "$RUNNER_SCRIPT" >> "$LOG_FILE" 2>&1 &
  fi

  sleep 1.2

  if pid=$(get_verified_supervisor_pid); then
    echo "Supervisor started successfully (Verified PID: $pid)."
  else
    echo "Failed to start supervisor or preflight rejected. Check log: $LOG_FILE"
    if [ -f "$STATUS_FILE" ]; then
      cat "$STATUS_FILE"
    fi
    return 1
  fi
}

cmd_stop() {
  # 1. Unload from launchd if active to prevent immediate respawn
  if [ -f "$PLIST_FILE" ] && command -v launchctl >/dev/null 2>&1; then
    echo "Unloading from launchd..."
    launchctl unload -w "$PLIST_FILE" 2>/dev/null || true
  fi

  local pid=""
  if ! pid=$(get_verified_supervisor_pid); then
    echo "Supervisor is not running."
    # Clean up stale locks if any
    rm -rf "$LOCK_DIR" "$PID_FILE"
    return 0
  fi

  echo "Stopping supervisor (Verified PID: $pid)..."
  kill -TERM "$pid" 2>/dev/null || true

  local waited=0
  while kill -0 "$pid" 2>/dev/null && [ "$waited" -lt 15 ]; do
    sleep 0.5
    waited=$((waited + 1))
  done

  if kill -0 "$pid" 2>/dev/null; then
    echo "Supervisor did not exit in 7.5s, sending SIGKILL to verified PID $pid..."
    kill -KILL "$pid" 2>/dev/null || true
  fi

  rm -rf "$LOCK_DIR" "$PID_FILE"
  echo "Supervisor stopped."
}

cmd_restart() {
  cmd_stop
  sleep 1
  cmd_start
}

cmd_health() {
  local pid=""
  if ! pid=$(get_verified_supervisor_pid); then
    echo "HEALTH: CRITICAL - Supervisor not running."
    return 2
  fi

  # Check status file freshness (must be modified within 60s)
  if [ ! -f "$STATUS_FILE" ]; then
    echo "HEALTH: CRITICAL - Status file missing."
    return 2
  fi

  local now_sec file_sec diff_sec
  now_sec=$(date +%s)
  file_sec=$(stat -f "%m" "$STATUS_FILE" 2>/dev/null || stat -c "%Y" "$STATUS_FILE" 2>/dev/null || echo 0)
  diff_sec=$((now_sec - file_sec))

  if [ "$diff_sec" -gt 60 ]; then
    echo "HEALTH: WARNING - Status file is stale ($diff_sec seconds old > 60s)."
  fi

  local recorded_state
  recorded_state=$(grep '"status"' "$STATUS_FILE" 2>/dev/null | head -n1 | cut -d'"' -f4 || echo "unknown")
  echo "[RECORDED STATE] $recorded_state (Supervisor PID: $pid, age: ${diff_sec}s)"

  # Active probe: strictly probe /health endpoint only; ZERO content read
  echo "Performing active non-invasive bridge probe: $BRIDGE_PROBE_URL ..."
  if ! command -v curl >/dev/null 2>&1; then
    echo "HEALTH: WARNING - curl binary unavailable for active probe"
    return 1
  fi

  local http_code
  http_code=$(curl -s -m 3 -o /dev/null -w "%{http_code}" "$BRIDGE_PROBE_URL" 2>/dev/null || echo "000")

  if [ "$http_code" = "200" ]; then
    echo "HEALTH: OK - Probe returned HTTP 200 (Bridge link operational, active requests accepted)"
    return 0
  elif [ "$http_code" = "403" ]; then
    echo "HEALTH: OK - Probe returned HTTP 403 (Bridge link operational in safe mode / writes disabled)"
    return 0
  else
    echo "HEALTH: CRITICAL - Probe failed (HTTP code: $http_code). Link or Bridge unreachable."
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
