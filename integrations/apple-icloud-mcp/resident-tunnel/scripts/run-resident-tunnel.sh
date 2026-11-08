#!/usr/bin/env bash
# run-resident-tunnel.sh
# AG-05 | feat/ag05-resident-readonly-candidate
#
# Hardened Launchd Supervisor Runner for MacServer -> Seoul reverse SSH tunnel.
# Features:
# - Concurrency-safe atomic directory singleton locking (mkdir)
# - Stale lock detection with PID reuse verification
# - True SSH exit code capture (no masked wait || true)
# - State differentiation: starting, connecting, forwarding_established, link_available, bridge_locked, reconnecting, stopped, failed
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

# Probe configuration for local bridge
BRIDGE_PROBE_URL="${BRIDGE_PROBE_URL:-http://127.0.0.1:18765/health}"
PROBE_TIMEOUT_SECONDS="${PROBE_TIMEOUT_SECONDS:-2}"

# Custom SSH command override for isolated testing
SSH_BINARY="${SSH_BINARY:-ssh}"
SKIP_KEY_CHECK="${SKIP_KEY_CHECK:-0}"

mkdir -p "$CONFIG_DIR"

# -------------------------------------------------------------
# 1. Preflight Validation
# -------------------------------------------------------------
fail_preflight() {
  local msg="$1"
  echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] [PREFLIGHT_FAIL] $msg" >&2
  # Write failure status
  cat << EOF > "$STATUS_FILE"
{
  "status": "failed",
  "supervisor_pid": $$,
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

  # Check permissions (must not be readable by group/others)
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
# 2. Concurrency-Safe Atomic Singleton Locking
# -------------------------------------------------------------
acquire_lock() {
  local max_retries=2
  local attempt=0

  while [ "$attempt" -lt "$max_retries" ]; do
    if mkdir "$LOCK_DIR" 2>/dev/null; then
      # Acquired lock atomically
      echo "$$" > "$LOCK_DIR/pid"
      date +%s > "$LOCK_DIR/start_time"
      echo "$$" > "$PID_FILE"
      chmod 600 "$PID_FILE" "$LOCK_DIR/pid" 2>/dev/null || true
      return 0
    fi

    # Lock directory exists - verify if active or stale
    local existing_pid=""
    if [ -f "$LOCK_DIR/pid" ]; then
      existing_pid=$(cat "$LOCK_DIR/pid" 2>/dev/null || true)
    fi

    if [ -n "$existing_pid" ] && kill -0 "$existing_pid" 2>/dev/null; then
      # Check command line to avoid PID reuse confusion
      local cmd_line
      cmd_line=$(ps -p "$existing_pid" -o args= 2>/dev/null || echo "")
      if echo "$cmd_line" | grep -q "run-resident-tunnel.sh"; then
        echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] Tunnel supervisor already active (PID: $existing_pid). Exiting cleanly."
        exit 0
      fi
    fi

    # Lock is stale: process dead or PID reused for non-supervisor
    echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] Detected stale lock in $LOCK_DIR. Removing and retrying..."
    rm -rf "$LOCK_DIR"
    attempt=$((attempt + 1))
    sleep 0.2
  done

  echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] Failed to acquire lock after removing stale lock. Exiting." >&2
  exit 1
}

acquire_lock

# -------------------------------------------------------------
# 3. State & Observable JSON Status
# -------------------------------------------------------------
current_backoff="$BACKOFF_INIT"
reconnect_count=0
child_ssh_pid=""
sleep_child_pid=""
is_shutting_down=0
has_held_lock=1

update_status() {
  local state="$1"
  local last_err="${2:-}"
  local tmp_status="${STATUS_FILE}.tmp.$$"
  local now_ts
  now_ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

  cat << EOF > "$tmp_status"
{
  "status": "$state",
  "supervisor_pid": $$,
  "child_ssh_pid": ${child_ssh_pid:-null},
  "remote_host": "$REMOTE_HOST",
  "remote_user": "$REMOTE_USER",
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

  # Interrupt sleeping backoff immediately
  if [ -n "$sleep_child_pid" ] && kill -0 "$sleep_child_pid" 2>/dev/null; then
    kill "$sleep_child_pid" 2>/dev/null || true
  fi

  # Terminate child SSH if running
  if [ -n "$child_ssh_pid" ] && kill -0 "$child_ssh_pid" 2>/dev/null; then
    kill -TERM "$child_ssh_pid" 2>/dev/null || true
    # Wait up to 3 seconds
    local waited=0
    while kill -0 "$child_ssh_pid" 2>/dev/null && [ "$waited" -lt 6 ]; do
      sleep 0.5
      waited=$((waited + 1))
    done
    if kill -0 "$child_ssh_pid" 2>/dev/null; then
      kill -KILL "$child_ssh_pid" 2>/dev/null || true
    fi
  fi

  update_status "stopped" "Terminated on $sig"

  # Clean up lock directory and PID file
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

# Probe Bridge state through active probe
probe_bridge_state() {
  if ! command -v curl >/dev/null 2>&1; then
    echo "forwarding_established"
    return
  fi

  local http_code
  http_code=$(curl -s -m "$PROBE_TIMEOUT_SECONDS" -o /dev/null -w "%{http_code}" "$BRIDGE_PROBE_URL" 2>/dev/null || echo "000")

  if [ "$http_code" = "200" ]; then
    echo "link_available"
  elif [ "$http_code" = "403" ]; then
    echo "bridge_locked"
  elif [ "$http_code" = "000" ]; then
    echo "forwarding_established"
  else
    echo "forwarding_established"
  fi
}

# -------------------------------------------------------------
# 5. Supervisor Loop
# -------------------------------------------------------------
echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] Starting resident reverse tunnel supervisor (PID: $$)..."
update_status "starting"

while [ "$is_shutting_down" -eq 0 ]; do
  start_time=$(date +%s)
  echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] Launching reverse SSH tunnel to $REMOTE_USER@$REMOTE_HOST:$REMOTE_PORT..."
  update_status "connecting"

  # Build arguments
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

  # Allow short moment for SSH handshake & forward failure check
  sleep 0.8

  if kill -0 "$child_ssh_pid" 2>/dev/null; then
    # SSH is running without immediate forward exit
    detected_state=$(probe_bridge_state)
    update_status "$detected_state"
  fi

  # TRUE exit code capture: set +e around wait
  set +e
  wait "$child_ssh_pid"
  exit_code=$?
  set -e
  end_time=$(date +%s)
  child_ssh_pid=""

  if [ "$is_shutting_down" -eq 1 ]; then
    break
  fi

  duration=$((end_time - start_time))
  echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] Tunnel disconnected (exit code: $exit_code, connected for: ${duration}s)."

  # If connection lasted beyond sustained threshold, reset backoff
  if [ "$duration" -ge "$SUSTAINED_THRESHOLD" ]; then
    current_backoff="$BACKOFF_INIT"
    echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] Connection was sustained for ${duration}s. Backoff reset to ${current_backoff}s."
  fi

  reconnect_count=$((reconnect_count + 1))
  update_status "reconnecting" "Exit code $exit_code after ${duration}s"

  echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] Backing off for ${current_backoff}s before reconnect attempt #$reconnect_count..."

  # Signal-aware sleep: wake up immediately if SIGTERM/SIGINT received
  sleep "$current_backoff" &
  sleep_child_pid=$!
  set +e
  wait "$sleep_child_pid" 2>/dev/null || true
  set -e
  sleep_child_pid=""

  if [ "$is_shutting_down" -eq 1 ]; then
    break
  fi

  # Exponential backoff with cap
  current_backoff=$((current_backoff * BACKOFF_FACTOR))
  if [ "$current_backoff" -gt "$BACKOFF_MAX" ]; then
    current_backoff="$BACKOFF_MAX"
  fi
done

cleanup_and_exit "NORMAL_EXIT"
