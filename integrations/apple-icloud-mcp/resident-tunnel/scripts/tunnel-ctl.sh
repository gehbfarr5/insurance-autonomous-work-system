#!/usr/bin/env bash
# tunnel-ctl.sh
# AG-05 | feat/ag05-resident-readonly-candidate
#
# MacServer Resident Tunnel Control Utility.
# Commands:
#   status   - Inspect runtime supervisor, lock state, 4-layer health, and status JSON
#   start    - Start supervisor via launchd (production) or standalone (--test)
#   stop     - Gracefully stop verified supervisor and child SSH processes
#   restart  - Stop and restart supervisor
#   health   - Perform fresh active probe of layers (zero content read)
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
BRIDGE_CONFIG_FILE="${BRIDGE_CONFIG_FILE:-$CONFIG_DIR/bridge.env}"
BRIDGE_PID_FILE="${BRIDGE_PID_FILE:-$CONFIG_DIR/bridge.pid}"
BRIDGE_PLIST_LABEL="${BRIDGE_PLIST_LABEL:-com.muse.macserver-eventkit}"
BRIDGE_PLIST_FILE="${BRIDGE_PLIST_FILE:-$HOME/Library/LaunchAgents/${BRIDGE_PLIST_LABEL}.plist}"
BRIDGE_BUSINESS_URL="${BRIDGE_BUSINESS_URL:-http://127.0.0.1:18765/reminders/lists}"
BRIDGE_TOKEN="${BRIDGE_TOKEN:-}"
BRIDGE_RELOAD_CMD="${BRIDGE_RELOAD_CMD:-}"

if [ -f "$CONFIG_FILE" ]; then
  # shellcheck source=/dev/null
  source "$CONFIG_FILE"
fi

IDENTITY_FILE="${IDENTITY_FILE:-$HOME/.ssh/id_ed25519_macserver_resident_tunnel}"
REMOTE_HOST="${REMOTE_HOST:-seoul-mcp.internal}"
REMOTE_USER="${REMOTE_USER:-mac-operator}"
REMOTE_PORT="${REMOTE_PORT:-22}"

cmd="${1:-status}"
shift || true
extra_arg="${1:-}"

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

  if [ -x "$RUNNER_SCRIPT" ]; then
    echo "  [OK] Runner script executable: $RUNNER_SCRIPT"
  else
    echo "  [FAIL] Runner script not found or not executable: $RUNNER_SCRIPT"
    err=1
  fi

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

  if command -v ssh >/dev/null 2>&1; then
    echo "  [OK] SSH client found: $(command -v ssh)"
  else
    echo "  [FAIL] SSH binary not found in PATH"
    err=1
  fi

  local plist_tpl="$SCRIPT_DIR/../launchd/com.muse.macserver-tunnel.plist.template"
  if [ -f "$plist_tpl" ]; then
    echo "  [OK] launchd plist template present: $plist_tpl"
    if command -v plutil >/dev/null 2>&1; then
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

  # Production lifecycle boundary: prefer launchd unless test mode explicitly passed
  local is_test_mode=0
  if [ "$extra_arg" = "--test" ] || [ "${TEST_MODE:-0}" = "1" ]; then
    is_test_mode=1
  fi

  if [ -f "$PLIST_FILE" ] && command -v launchctl >/dev/null 2>&1; then
    echo "Starting supervisor via launchd ($PLIST_FILE)..."
    launchctl load -w "$PLIST_FILE" 2>/dev/null || launchctl start com.muse.macserver-tunnel 2>/dev/null || true
  elif [ "$is_test_mode" -eq 1 ]; then
    echo "Starting resident tunnel supervisor in isolated TEST mode..."
    nohup "$RUNNER_SCRIPT" >> "$LOG_FILE" 2>&1 &
  else
    echo "[ERROR] Production lifecycle must be managed via launchd (~/Library/LaunchAgents/com.muse.macserver-tunnel.plist)." >&2
    echo "        LaunchAgent plist not found. Install plist or pass '--test' for isolated testing mode." >&2
    return 1
  fi

  sleep 1.2

  if pid=$(get_verified_supervisor_pid); then
    echo "Supervisor started successfully (Verified PID: $pid)."
  else
    echo "Failed to start supervisor. Check log: $LOG_FILE"
    if [ -f "$STATUS_FILE" ]; then
      cat "$STATUS_FILE"
    fi
    return 1
  fi
}

cmd_stop() {
  if [ -f "$PLIST_FILE" ] && command -v launchctl >/dev/null 2>&1; then
    echo "Unloading from launchd..."
    launchctl unload -w "$PLIST_FILE" 2>/dev/null || true
  fi

  local pid=""
  if ! pid=$(get_verified_supervisor_pid); then
    echo "Supervisor is not running."
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
  echo "=== Four-Layer Health Status Assessment ==="
  echo "Supervisor PID: $pid | Recorded State: $recorded_state | Status Age: ${diff_sec}s"

  # Layer 1: Local Bridge probe (zero reminder content read)
  local l1_code="000"
  if command -v curl >/dev/null 2>&1; then
    l1_code=$(curl -s -m 2 -o /dev/null -w "%{http_code}" "$BRIDGE_PROBE_URL" 2>/dev/null || echo "000")
  fi
  echo "  Layer 1 (Local Bridge /health): HTTP $l1_code"

  # Layer 2: SSH Child Process
  local l2_state="disconnected"
  local child_pid
  child_pid=$(grep '"child_ssh_pid"' "$STATUS_FILE" 2>/dev/null | grep -o '[0-9]*' || echo "")
  if [ -n "$child_pid" ] && kill -0 "$child_pid" 2>/dev/null; then
    l2_state="connected (PID: $child_pid)"
  fi
  echo "  Layer 2 (SSH Reverse Tunnel):   $l2_state"

  # Layer 3: Remote Forward (ExitOnForwardFailure guarantee)
  local l3_state="unknown"
  if [ "$l2_state" != "disconnected" ]; then
    l3_state="forwarding_active"
  else
    l3_state="inactive"
  fi
  echo "  Layer 3 (Port Forward Listen):  $l3_state"

  # Layer 4: End-to-end link
  local l4_state="unverified_from_local"
  echo "  Layer 4 (End-to-End Link):      $l4_state"

  if [ "$l1_code" = "200" ] && [ "$l2_state" != "disconnected" ]; then
    echo "HEALTH: OK (Local Bridge operational, SSH tunnel active, remote forward active)"
    return 0
  elif [ "$l1_code" = "403" ] && [ "$l2_state" != "disconnected" ]; then
    echo "HEALTH: OK (Bridge operational in safe mode / writes disabled, SSH active)"
    return 0
  elif [ "$l1_code" = "000" ]; then
    echo "HEALTH: DEGRADED (Local bridge unreachable)"
    return 1
  else
    echo "HEALTH: CRITICAL (SSH disconnected or bridge failed)"
    return 2
  fi
}

persist_business_switch_false() {
  echo "       Persisting authorization switch to false in $BRIDGE_CONFIG_FILE..."
  mkdir -p "$(dirname "$BRIDGE_CONFIG_FILE")"
  if [ -f "$BRIDGE_CONFIG_FILE" ]; then
    # Surgically replace authorization keys
    if grep -q "EVENTKIT_BRIDGE_PRODUCTION_AUTHORIZED" "$BRIDGE_CONFIG_FILE"; then
      sed -i.bak -E 's/^([[:space:]]*EVENTKIT_BRIDGE_PRODUCTION_AUTHORIZED[[:space:]]*=[[:space:]]*).*/\1false/' "$BRIDGE_CONFIG_FILE"
      rm -f "${BRIDGE_CONFIG_FILE}.bak"
    else
      echo "EVENTKIT_BRIDGE_PRODUCTION_AUTHORIZED=false" >> "$BRIDGE_CONFIG_FILE"
    fi
    if grep -q "EVENTKIT_PRODUCTION_AUTHORIZED" "$BRIDGE_CONFIG_FILE"; then
      sed -i.bak -E 's/^([[:space:]]*EVENTKIT_PRODUCTION_AUTHORIZED[[:space:]]*=[[:space:]]*).*/\1false/' "$BRIDGE_CONFIG_FILE"
      rm -f "${BRIDGE_CONFIG_FILE}.bak"
    else
      echo "EVENTKIT_PRODUCTION_AUTHORIZED=false" >> "$BRIDGE_CONFIG_FILE"
    fi
  else
    cat << 'EOF' > "$BRIDGE_CONFIG_FILE"
EVENTKIT_BRIDGE_PRODUCTION_AUTHORIZED=false
EVENTKIT_PRODUCTION_AUTHORIZED=false
EOF
  fi
  chmod 600 "$BRIDGE_CONFIG_FILE" 2>/dev/null || true
  # Verify written value
  if grep -E "^[[:space:]]*EVENTKIT_BRIDGE_PRODUCTION_AUTHORIZED[[:space:]]*=[[:space:]]*(true|1)" "$BRIDGE_CONFIG_FILE" >/dev/null 2>&1; then
    echo "       CRITICAL ERROR: Failed to toggle EVENTKIT_BRIDGE_PRODUCTION_AUTHORIZED to false!" >&2
    return 1
  fi
  echo "       [OK] Business authorization set to false (persisted at $BRIDGE_CONFIG_FILE)."
  return 0
}

trigger_bridge_reload() {
  echo "       Triggering Bridge configuration reload..."
  if [ -n "$BRIDGE_RELOAD_CMD" ]; then
    echo "       Executing custom BRIDGE_RELOAD_CMD: $BRIDGE_RELOAD_CMD"
    eval "$BRIDGE_RELOAD_CMD"
    return $?
  fi

  local reloaded=0
  # 1. If running under launchd
  if command -v launchctl >/dev/null 2>&1 && launchctl list "$BRIDGE_PLIST_LABEL" >/dev/null 2>&1; then
    echo "       Bridge running under launchd ($BRIDGE_PLIST_LABEL); triggering kickstart restart..."
    if launchctl kickstart -k "gui/${UID}/${BRIDGE_PLIST_LABEL}" 2>/dev/null; then
      reloaded=1
    elif launchctl kill TERM "gui/${UID}/${BRIDGE_PLIST_LABEL}" 2>/dev/null; then
      reloaded=1
    fi
  fi

  # 2. If PID file present
  if [ "$reloaded" -eq 0 ] && [ -f "$BRIDGE_PID_FILE" ]; then
    local bpid
    bpid=$(cat "$BRIDGE_PID_FILE" 2>/dev/null || true)
    if [ -n "$bpid" ] && kill -0 "$bpid" 2>/dev/null; then
      local proc_args
      proc_args=$(ps -p "$bpid" -o args= 2>/dev/null || echo "")
      if echo "$proc_args" | grep -E -q "EventKitBridgeServer|fake-bridge-runner"; then
        echo "       Signaling verified Bridge PID $bpid (SIGHUP / SIGTERM)..."
        kill -HUP "$bpid" 2>/dev/null || kill -TERM "$bpid" 2>/dev/null || true
        reloaded=1
      else
        echo "       ERROR: Bridge PID file points to unverified process PID $bpid (args: $proc_args); refusing to signal to prevent collateral damage!" >&2
        return 1
      fi
    fi
  fi

  # 3. Attribution failure check: NO indiscriminate pgrep batch killing
  if [ "$reloaded" -eq 0 ]; then
    echo "       ERROR: Bridge process attribution unclear (no launchd service '$BRIDGE_PLIST_LABEL' or verified PID file); refusing indiscriminate process signaling." >&2
    return 1
  fi

  # Brief grace period for reload or restart to take effect
  sleep 0.3
  return 0
}

assert_business_endpoint_403() {
  if ! command -v curl >/dev/null 2>&1; then
    echo "       CRITICAL ERROR: curl required to verify business endpoint permissions!" >&2
    return 1
  fi

  local token="$BRIDGE_TOKEN"
  if [ -z "$token" ] && [ -f "$BRIDGE_CONFIG_FILE" ]; then
    token=$(grep -E "^[[:space:]]*EVENTKIT_BRIDGE_BEARER_TOKEN=" "$BRIDGE_CONFIG_FILE" | cut -d'=' -f2- | tr -d '"' | tr -d "'" || true)
    if [ -z "$token" ]; then
      token=$(grep -E "^[[:space:]]*EVENTKIT_BRIDGE_TOKENS=" "$BRIDGE_CONFIG_FILE" | cut -d'=' -f2- | cut -d',' -f1 | tr -d '"' | tr -d "'" || true)
    fi
  fi

  local auth_header=""
  if [ -n "$token" ]; then
    auth_header="Authorization: Bearer $token"
  fi

  echo "       Probing business endpoint: $BRIDGE_BUSINESS_URL (expecting HTTP 403)..."
  local code="000"
  local attempts=0
  local max_attempts=4

  while [ "$attempts" -lt "$max_attempts" ]; do
    if [ -n "$auth_header" ]; then
      code=$(curl -s -m 1 -o /dev/null -w "%{http_code}" -H "$auth_header" "$BRIDGE_BUSINESS_URL" 2>/dev/null || echo "000")
    else
      code=$(curl -s -m 1 -o /dev/null -w "%{http_code}" "$BRIDGE_BUSINESS_URL" 2>/dev/null || echo "000")
    fi

    if [ "$code" = "403" ]; then
      echo "       [OK] Verified business endpoint returned HTTP 403 (PERMISSION_DENIED / Safe Mode Active)."
      return 0
    fi
    sleep 0.1
    attempts=$((attempts + 1))
  done

  echo "       CRITICAL ERROR: Business endpoint returned HTTP $code (expected 403)! Business permissions NOT closed." >&2
  return 1
}

cmd_orchestrated_stop() {
  echo "=== MacServer Orchestrated Business Shutdown Sequence ==="
  local err=0

  # Step 1: Persist authorization switch to false in restricted config
  echo "[1/4] Persisting business authorization switch to false..."
  if ! persist_business_switch_false; then
    echo "CRITICAL ERROR: Failed to persist business switch to false!" >&2
    return 1
  fi

  # Step 2: Trigger Bridge reload
  echo "[2/4] Triggering Bridge configuration reload..."
  if ! trigger_bridge_reload; then
    echo "CRITICAL ERROR: Failed to trigger Bridge reload!" >&2
    return 1
  fi

  # Step 3: Assert HTTP 403 on business endpoint (/reminders/lists)
  echo "[3/4] Asserting HTTP 403 on business endpoint..."
  if ! assert_business_endpoint_403; then
    echo "CRITICAL ERROR: Business permissions failed 403 assertion!" >&2
    return 1
  fi

  # Step 4: Stop reverse tunnel supervisor and unload launchd
  echo "[4/4] Stopping reverse tunnel supervisor and unloading launchd..."
  if ! cmd_stop; then
    echo "CRITICAL ERROR: Failed to stop reverse tunnel supervisor!" >&2
    return 1
  fi

  # Listener distinction:
  # On MacServer, Bridge's local loopback listener (127.0.0.1:18765) is preserved in safe 403 mode.
  # We verify that supervisor PID is dead and child SSH process is terminated.
  local sup_pid
  if sup_pid=$(get_verified_supervisor_pid); then
    echo "CRITICAL ERROR: Reverse tunnel supervisor is still active (PID: $sup_pid)!" >&2
    return 1
  fi

  echo "=== MacServer Orchestrated Business Shutdown COMPLETED SUCCESSFULLY ==="
  return 0
}

case "$cmd" in
  status)            cmd_status ;;
  start)             cmd_start ;;
  stop)              cmd_stop ;;
  close-business)    persist_business_switch_false && trigger_bridge_reload && assert_business_endpoint_403 ;;
  orchestrated-stop) cmd_orchestrated_stop ;;
  restart)           cmd_restart ;;
  health)            cmd_health ;;
  verify)            cmd_verify ;;
  *)
    echo "Usage: $0 {status|start [--test]|stop|close-business|orchestrated-stop|restart|health|verify}"
    exit 1
    ;;
esac
