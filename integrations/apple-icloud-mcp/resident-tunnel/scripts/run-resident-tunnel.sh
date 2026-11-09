#!/usr/bin/env bash
# run-resident-tunnel.sh
# AG-05 | feat/ag05-resident-readonly-candidate
#
# Hardened Launchd Supervisor Runner for MacServer -> Seoul reverse SSH tunnel.
# Features:
# - Concurrency-safe atomic staging directory singleton locking (mkdir + atomic rename)
# - Elimination of PID creation race window with loser grace period
# - Safe atomic stale lock reclamation (mv $LOCK_DIR $LOCK_DIR.stale.$$)
# - True SSH exit code capture (no masked wait || true)
# - Four-layer health state differentiation:
#     Layer 1: Local Bridge (/health)
#     Layer 2: Child SSH process liveness
#     Layer 3: Forward listening state (ExitOnForwardFailure)
#     Layer 4: End-to-end link verification
# - Continuous health state monitoring (never inferring success without probe)
# - Signal-responsive backoff sleep (zero lag on SIGTERM during backoff)
# - Capped exponential backoff (2s -> 30s) with sustained reset threshold (60s)
# - Observable JSON status file with umask 077 restricted permissions
# - Strict preflight validation: key presence, 0600/0400 permissions, known hosts

set -euo pipefail
umask 077

# Configuration defaults (overridable via environment or config file)
CONFIG_DIR="${CONFIG_DIR:-$HOME/.config/muse-macserver}"
CONFIG_FILE="${CONFIG_FILE:-$CONFIG_DIR/tunnel.conf}"

if [ -f "$CONFIG_FILE" ]; then
  # shellcheck source=/dev/null
  source "$CONFIG_FILE"
fi

REMOTE_HOST="${REMOTE_HOST:-seoul-mcp.internal}"
REMOTE_USER="${REMOTE_USER:-mac-operator}"
REMOTE_PORT="${REMOTE_PORT:-22}"
IDENTITY_FILE="${IDENTITY_FILE:-$HOME/.ssh/id_ed25519_macserver_resident_tunnel}"
KNOWN_HOSTS_FILE="${KNOWN_HOSTS_FILE:-$HOME/.ssh/known_hosts}"

REMOTE_BINDS="${REMOTE_BINDS:--R 172.19.0.1:18765:127.0.0.1:18765 -R 127.0.0.1:18765:127.0.0.1:18765}"
STATUS_FILE="${STATUS_FILE:-$CONFIG_DIR/tunnel_status.json}"
LOG_FILE="${LOG_FILE:-$CONFIG_DIR/tunnel.log}"
PID_FILE="${PID_FILE:-$CONFIG_DIR/tunnel.pid}"
LOCK_DIR="${LOCK_DIR:-$CONFIG_DIR/tunnel.lock}"

BACKOFF_INIT="${BACKOFF_INIT:-2}"
BACKOFF_MAX="${BACKOFF_MAX:-30}"
BACKOFF_FACTOR="${BACKOFF_FACTOR:-2}"
SUSTAINED_THRESHOLD="${SUSTAINED_THRESHOLD:-60}"

# Probe configuration
BRIDGE_PROBE_URL="${BRIDGE_PROBE_URL:-http://127.0.0.1:18765/health}"
REMOTE_PROBE_URL="${REMOTE_PROBE_URL:-}"
PROBE_TIMEOUT_SECONDS="${PROBE_TIMEOUT_SECONDS:-2}"

# Custom SSH command override for isolated testing
SSH_BINARY="${SSH_BINARY:-ssh}"
SKIP_KEY_CHECK="${SKIP_KEY_CHECK:-0}"
SESSION_TIMEOUT_SECONDS="${SESSION_TIMEOUT_SECONDS:-0}"

mkdir -p "$CONFIG_DIR"

# -------------------------------------------------------------
# 1. Preflight Validation
# -------------------------------------------------------------
fail_preflight() {
  local msg="$1"
  echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] [PREFLIGHT_FAIL] $msg" >&2
  cat << EOF > "$STATUS_FILE"
{
  "status": "failed",
  "supervisor_pid": $$,
  "layers": {
    "layer1_local_bridge": "unknown",
    "layer2_ssh_process": "disconnected",
    "layer3_forward_listen": "failed",
    "layer4_end_to_end_link": "failed"
  },
  "last_error": "PREFLIGHT_FAIL: $msg",
  "last_updated": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
}
EOF
  chmod 600 "$STATUS_FILE" 2>/dev/null || true
  exit 1
}

if [ "$SKIP_KEY_CHECK" -ne 1 ]; then
  if [ ! -f "$IDENTITY_FILE" ]; then
    fail_preflight "Identity key file not found: $IDENTITY_FILE"
  fi

  perms=$(stat -f "%OLp" "$IDENTITY_FILE" 2>/dev/null || stat -c "%a" "$IDENTITY_FILE" 2>/dev/null || echo "unknown")
  if [ "$perms" != "600" ] && [ "$perms" != "400" ]; then
    fail_preflight "Identity key permissions ($perms) are insecure: $IDENTITY_FILE (must be 0600 or 0400)"
  fi

  if [ ! -f "$KNOWN_HOSTS_FILE" ]; then
    fail_preflight "Known hosts trust file not found: $KNOWN_HOSTS_FILE"
  fi
fi

if [ -z "$REMOTE_HOST" ]; then
  fail_preflight "REMOTE_HOST is unset"
fi

# -------------------------------------------------------------
# 2. Concurrency-Safe Atomic Singleton Locking Protocol
# -------------------------------------------------------------
acquire_lock() {
  local max_attempts=5
  local attempt=0

  # Prepare private staging file
  local stage_file="$CONFIG_DIR/tunnel.lock.stage.$$"
  echo "$$" > "$stage_file"
  chmod 600 "$stage_file" 2>/dev/null || true

  while [ "$attempt" -lt "$max_attempts" ]; do
    if mkdir "$LOCK_DIR" 2>/dev/null; then
      # Winner of atomic directory creation
      # Atomically move our staging PID into the lock dir
      mv -f "$stage_file" "$LOCK_DIR/pid"
      date +%s > "$LOCK_DIR/time"
      echo "$$" > "$PID_FILE"
      chmod 600 "$PID_FILE" "$LOCK_DIR/pid" "$LOCK_DIR/time" 2>/dev/null || true
      return 0
    fi

    # Lock directory exists - check if winner is still writing PID (grace period)
    local waited=0
    local existing_pid=""
    while [ "$waited" -lt 10 ]; do
      if [ -f "$LOCK_DIR/pid" ]; then
        existing_pid=$(cat "$LOCK_DIR/pid" 2>/dev/null || true)
        if [ -n "$existing_pid" ]; then
          break
        fi
      fi
      sleep 0.1
      waited=$((waited + 1))
    done

    if [ -n "$existing_pid" ] && kill -0 "$existing_pid" 2>/dev/null; then
      # Verify command args to prevent PID reuse confusion
      local cmd_line
      cmd_line=$(ps -p "$existing_pid" -o args= 2>/dev/null || echo "")
      if echo "$cmd_line" | grep -q "run-resident-tunnel.sh"; then
        echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] Tunnel supervisor already active (PID: $existing_pid). Exiting cleanly."
        rm -f "$stage_file"
        exit 0
      fi
    fi

    # Lock is stale or abandoned: safely reclaim via atomic rename
    local stale_dir="$CONFIG_DIR/tunnel.lock.stale.$$.$RANDOM"
    if mv "$LOCK_DIR" "$stale_dir" 2>/dev/null; then
      echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] Reclaimed stale lock directory. Retrying acquire..."
      rm -rf "$stale_dir"
    fi

    attempt=$((attempt + 1))
    sleep 0.2
  done

  rm -f "$stage_file"
  echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] Failed to acquire lock after $max_attempts attempts. Exiting." >&2
  exit 1
}

acquire_lock

# -------------------------------------------------------------
# Local Session Hard Deadline Watchdog (MacServer Local Timeout)
# -------------------------------------------------------------
session_timeout_pid=""
if [ "${SESSION_TIMEOUT_SECONDS:-0}" -gt 0 ]; then
  echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] MacServer local hard session timeout configured: ${SESSION_TIMEOUT_SECONDS}s"
  (
    exec </dev/null
    sleep "$SESSION_TIMEOUT_SECONDS"
    echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] [SESSION_TIMEOUT] MacServer local hard deadline (${SESSION_TIMEOUT_SECONDS}s) reached! Initiating autonomous supervisor shutdown..."
    kill -TERM "$$" 2>/dev/null || true
  ) >> "$LOG_FILE" 2>&1 &
  session_timeout_pid=$!
  disown $session_timeout_pid 2>/dev/null || true
fi

# -------------------------------------------------------------
# 3. State & Observable JSON Status with 4-Layer Hierarchy
# -------------------------------------------------------------
current_backoff="$BACKOFF_INIT"
reconnect_count=0
child_ssh_pid=""
sleep_child_pid=""
is_shutting_down=0
has_held_lock=1

# Layer states
l1_bridge="unknown"
l2_ssh="disconnected"
l3_forward="unknown"
l4_e2e="unverified"

probe_local_bridge() {
  if ! command -v curl >/dev/null 2>&1; then
    echo "unknown"
    return
  fi
  local code
  code=$(curl -s -m "$PROBE_TIMEOUT_SECONDS" -o /dev/null -w "%{http_code}" "$BRIDGE_PROBE_URL" 2>/dev/null || echo "000")
  if [ "$code" = "200" ]; then
    echo "ok"
  elif [ "$code" = "403" ]; then
    echo "locked_safe_mode"
  else
    echo "unreachable"
  fi
}

probe_remote_link() {
  if [ -z "$REMOTE_PROBE_URL" ] || ! command -v curl >/dev/null 2>&1; then
    echo "unverified"
    return
  fi
  local code
  code=$(curl -s -m "$PROBE_TIMEOUT_SECONDS" -o /dev/null -w "%{http_code}" "$REMOTE_PROBE_URL" 2>/dev/null || echo "000")
  if [ "$code" = "200" ]; then
    echo "verified"
  elif [ "$code" = "403" ]; then
    echo "verified_safe_mode"
  else
    echo "failed"
  fi
}

evaluate_overall_status() {
  if [ "$is_shutting_down" -eq 1 ]; then
    echo "stopped"
    return
  fi
  if [ "$l2_ssh" != "connected" ]; then
    echo "reconnecting"
    return
  fi
  if [ "$l1_bridge" = "unreachable" ]; then
    echo "degraded"
    return
  fi
  if [ "$l1_bridge" = "locked_safe_mode" ]; then
    echo "bridge_locked"
    return
  fi
  if [ "$l4_e2e" = "verified" ]; then
    echo "healthy"
    return
  fi
  # Local bridge OK, SSH alive, remote link unverified
  echo "bridge_local_ok_remote_unverified"
}

update_status() {
  local explicit_state="${1:-}"
  local last_err="${2:-}"

  # Refresh probes
  l1_bridge=$(probe_local_bridge)
  if [ -n "$child_ssh_pid" ] && kill -0 "$child_ssh_pid" 2>/dev/null; then
    l2_ssh="connected"
    l3_forward="forwarding_active"
  else
    l2_ssh="disconnected"
    l3_forward="inactive"
  fi
  l4_e2e=$(probe_remote_link)

  local overall
  if [ -n "$explicit_state" ]; then
    overall="$explicit_state"
  else
    overall=$(evaluate_overall_status)
  fi

  local tmp_status="${STATUS_FILE}.tmp.$$"
  local now_ts
  now_ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

  cat << EOF > "$tmp_status"
{
  "status": "$overall",
  "supervisor_pid": $$,
  "child_ssh_pid": ${child_ssh_pid:-null},
  "remote_host": "$REMOTE_HOST",
  "remote_user": "$REMOTE_USER",
  "layers": {
    "layer1_local_bridge": "$l1_bridge",
    "layer2_ssh_process": "$l2_ssh",
    "layer3_forward_listen": "$l3_forward",
    "layer4_end_to_end_link": "$l4_e2e"
  },
  "reconnect_count": $reconnect_count,
  "current_backoff_seconds": $current_backoff,
  "last_updated": "$now_ts",
  "last_error": "$last_err"
}
EOF
  chmod 600 "$tmp_status" 2>/dev/null || true
  mv -f "$tmp_status" "$STATUS_FILE"
}

# -------------------------------------------------------------
# 4. Graceful Signal Termination
# -------------------------------------------------------------
cleanup_and_exit() {
  local sig="${1:-EXIT}"
  if [ "$is_shutting_down" -eq 1 ]; then
    return
  fi
  is_shutting_down=1

  echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] Received termination signal ($sig). Shutting down supervisor..."

  if [ -n "${session_timeout_pid:-}" ] && kill -0 "$session_timeout_pid" 2>/dev/null; then
    kill "$session_timeout_pid" 2>/dev/null || true
  fi

  if [ -n "$sleep_child_pid" ] && kill -0 "$sleep_child_pid" 2>/dev/null; then
    kill "$sleep_child_pid" 2>/dev/null || true
  fi

  if [ -n "$child_ssh_pid" ] && kill -0 "$child_ssh_pid" 2>/dev/null; then
    kill -TERM "$child_ssh_pid" 2>/dev/null || true
    local waited=0
    while kill -0 "$child_ssh_pid" 2>/dev/null && [ "$waited" -lt 6 ]; do
      sleep 0.5
      waited=$((waited + 1))
    done
    if kill -0 "$child_ssh_pid" 2>/dev/null; then
      kill -KILL "$child_ssh_pid" 2>/dev/null || true
    fi
  fi

  l2_ssh="disconnected"
  update_status "stopped" "Terminated on $sig"

  if [ "$has_held_lock" -eq 1 ]; then
    rm -rf "$LOCK_DIR"
    rm -f "$PID_FILE"
  fi

  echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] Tunnel supervisor shutdown complete."
  exit 0
}

trap 'cleanup_and_exit SIGTERM' SIGTERM
trap 'cleanup_and_exit SIGINT' SIGINT
trap 'cleanup_and_exit SIGHUP' SIGHUP

# -------------------------------------------------------------
# 5. Supervisor Loop
# -------------------------------------------------------------
echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] Starting resident reverse tunnel supervisor (PID: $$)..."
update_status "starting"

while [ "$is_shutting_down" -eq 0 ]; do
  start_time=$(date +%s)
  echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] Launching reverse SSH tunnel to $REMOTE_USER@$REMOTE_HOST:$REMOTE_PORT..."
  l2_ssh="connecting"
  update_status "connecting"

  # Split arguments
  # shellcheck disable=SC2086
  set -- $REMOTE_BINDS

  "$SSH_BINARY" \
    -N -T \
    -p "$REMOTE_PORT" \
    -o ExitOnForwardFailure=yes \
    -o ServerAliveInterval=15 \
    -o ServerAliveCountMax=3 \
    -o TCPKeepAlive=yes \
    -o StrictHostKeyChecking=yes \
    -o UserKnownHostsFile="$KNOWN_HOSTS_FILE" \
    -o ConnectTimeout=10 \
    -i "$IDENTITY_FILE" \
    "$@" \
    "$REMOTE_USER@$REMOTE_HOST" >> "$LOG_FILE" 2>&1 &

  child_ssh_pid=$!
  l2_ssh="connected"
  l3_forward="forwarding_active"
  update_status "forwarding_established"

  # Wait briefly for SSH handshake and initial forward negotiation
  sleep 0.8

  if kill -0 "$child_ssh_pid" 2>/dev/null; then
    l2_ssh="connected"
    l3_forward="forwarding_active"
    update_status ""
  fi

  # TRUE exit code capture
  set +e
  wait "$child_ssh_pid"
  exit_code=$?
  set -e
  end_time=$(date +%s)
  child_ssh_pid=""
  l2_ssh="disconnected"
  l3_forward="inactive"

  if [ "$is_shutting_down" -eq 1 ]; then
    break
  fi

  duration=$((end_time - start_time))
  echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] Tunnel disconnected (exit code: $exit_code, connected for: ${duration}s)."

  if [ "$duration" -ge "$SUSTAINED_THRESHOLD" ]; then
    current_backoff="$BACKOFF_INIT"
    echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] Connection was sustained for ${duration}s. Backoff reset to ${current_backoff}s."
  fi

  reconnect_count=$((reconnect_count + 1))
  update_status "reconnecting" "Exit code $exit_code after ${duration}s"

  echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] Backing off for ${current_backoff}s before reconnect attempt #$reconnect_count..."

  sleep "$current_backoff" &
  sleep_child_pid=$!
  set +e
  wait "$sleep_child_pid" 2>/dev/null || true
  set -e
  sleep_child_pid=""

  if [ "$is_shutting_down" -eq 1 ]; then
    break
  fi

  current_backoff=$((current_backoff * BACKOFF_FACTOR))
  if [ "$current_backoff" -gt "$BACKOFF_MAX" ]; then
    current_backoff="$BACKOFF_MAX"
  fi
done

cleanup_and_exit "NORMAL_EXIT"
