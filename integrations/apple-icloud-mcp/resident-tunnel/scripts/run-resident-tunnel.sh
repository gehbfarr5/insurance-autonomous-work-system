#!/usr/bin/env bash
# run-resident-tunnel.sh
# AG-05 | feat/ag05-resident-readonly-candidate
#
# Production launchd supervisor runner for MacServer -> Seoul reverse SSH tunnel.
# Features:
# - Strict singleton locking (prevents duplicate instances)
# - Capped exponential backoff with sustained connection reset
# - Observable JSON status file (~/.config/muse-macserver/tunnel_status.json)
# - Keepalive and connection monitoring
# - Graceful signal termination (SIGTERM, SIGINT)

set -euo pipefail

# Configuration defaults (overridable via environment or config file)
CONFIG_DIR="${CONFIG_DIR:-$HOME/.config/muse-macserver}"
CONFIG_FILE="${CONFIG_FILE:-$CONFIG_DIR/tunnel.conf}"

if [ -f "$CONFIG_FILE" ]; then
  # shellcheck source=/dev/null
  source "$CONFIG_FILE"
fi

REMOTE_HOST="${REMOTE_HOST:-100.82.240.43}"
REMOTE_USER="${REMOTE_USER:-mac-operator}"
REMOTE_PORT="${REMOTE_PORT:-22}"
IDENTITY_FILE="${IDENTITY_FILE:-$HOME/.ssh/id_ed25519_macserver_resident_tunnel}"

REMOTE_BINDS="${REMOTE_BINDS:--R 172.19.0.1:18765:127.0.0.1:18765 -R 127.0.0.1:18765:127.0.0.1:18765}"
STATUS_FILE="${STATUS_FILE:-$CONFIG_DIR/tunnel_status.json}"
LOG_FILE="${LOG_FILE:-$CONFIG_DIR/tunnel.log}"
PID_FILE="${PID_FILE:-$CONFIG_DIR/tunnel.pid}"

BACKOFF_INIT="${BACKOFF_INIT:-2}"
BACKOFF_MAX="${BACKOFF_MAX:-30}"
BACKOFF_FACTOR="${BACKOFF_FACTOR:-2}"
SUSTAINED_THRESHOLD="${SUSTAINED_THRESHOLD:-60}"

# Custom SSH command override for isolated testing
SSH_BINARY="${SSH_BINARY:-ssh}"

mkdir -p "$CONFIG_DIR"

# 1. Singleton Locking
if [ -f "$PID_FILE" ]; then
  existing_pid=$(cat "$PID_FILE" 2>/dev/null || true)
  if [ -n "$existing_pid" ] && kill -0 "$existing_pid" 2>/dev/null; then
    echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] Tunnel supervisor already active with PID $existing_pid. Exiting cleanly."
    exit 0
  fi
  rm -f "$PID_FILE"
fi

echo "$$" > "$PID_FILE"

# 2. State tracking
current_backoff="$BACKOFF_INIT"
reconnect_count=0
child_ssh_pid=""
is_shutting_down=0

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
  "child_ssh_pid": "${child_ssh_pid:-null}",
  "remote_host": "$REMOTE_HOST",
  "remote_user": "$REMOTE_USER",
  "reconnect_count": $reconnect_count,
  "current_backoff_seconds": $current_backoff,
  "last_updated": "$now_ts",
  "last_error": "$last_err"
}
EOF
  mv -f "$tmp_status" "$STATUS_FILE"
}

# 3. Signal Handlers
cleanup_and_exit() {
  local sig="$1"
  is_shutting_down=1
  echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] Caught signal $sig. Shutting down tunnel supervisor gracefully..."
  if [ -n "$child_ssh_pid" ] && kill -0 "$child_ssh_pid" 2>/dev/null; then
    kill "$child_ssh_pid" 2>/dev/null || true
    wait "$child_ssh_pid" 2>/dev/null || true
  fi
  update_status "stopped" "Received $sig"
  rm -f "$PID_FILE"
  echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] Tunnel supervisor stopped cleanly."
  exit 0
}

trap 'cleanup_and_exit SIGTERM' SIGTERM
trap 'cleanup_and_exit SIGINT' SIGINT
trap 'cleanup_and_exit SIGHUP' SIGHUP

# 4. Supervisor Loop
echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] Starting resident reverse tunnel supervisor (PID: $$)..."
update_status "starting"

while [ "$is_shutting_down" -eq 0 ]; do
  start_time=$(date +%s)
  echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] Launching tunnel connection to $REMOTE_USER@$REMOTE_HOST:$REMOTE_PORT..."
  update_status "connecting"

  # Split remote binds into array
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
    -o ConnectTimeout=10 \
    -i "$IDENTITY_FILE" \
    "$@" \
    "$REMOTE_USER@$REMOTE_HOST" >> "$LOG_FILE" 2>&1 &

  child_ssh_pid=$!
  update_status "connected"

  # Wait for SSH process to exit
  wait "$child_ssh_pid" || true
  exit_code=$?
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
  sleep "$current_backoff"

  # Exponential backoff with cap
  current_backoff=$((current_backoff * BACKOFF_FACTOR))
  if [ "$current_backoff" -gt "$BACKOFF_MAX" ]; then
    current_backoff="$BACKOFF_MAX"
  fi
done

rm -f "$PID_FILE"
