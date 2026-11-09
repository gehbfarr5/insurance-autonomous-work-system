#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# AG-05: Cross-Device Shutdown & Rollback Orchestration
# (跨设备联动停止与基线恢复编排脚本)
#
# Execution Sequence:
# 1. Close/verify MacServer business switch -> Assert 403 Safe Mode blocking.
#    (If remote is unreachable, mark as UNKNOWN_PENDING_VERIFICATION;
#     if NOT_CONFIGURED, mark as NOT_CONFIGURED and fail;
#     rely on MacServer local hard watchdog for local business shutdown)
# 2. Terminate verified task processes (Strict task attribution;
#    zero collateral damage to unrelated processes).
# 3. Restore Seoul MCP container, Compose, and config to baseline image sha256:f3e697fe...
#    (Safety Barrier: If container stop fails, SKIP rsync and docker-compose up).
# 4. Restore SSH configuration strictly based on backup manifest/list
#    (Dynamic authorized_keys path; cleanly delete if not pre-existed;
#     restore if pre-existed; reload sshd).
# 5. End-to-end baseline verification & failure aggregation:
#    (Persist recovery_result.json; if any step failed or remote status != CLOSED_VERIFIED_403,
#     output [RECOVERY_FAILED] and exit non-zero).
# ==============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GATEWAY_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PRODUCTION_ENTRY="${PRODUCTION_ENTRY:-$SCRIPT_DIR/production-entry.sh}"

BACKUP_DIR="${1:-}"
MACSERVER_SSH_TARGET="${MACSERVER_SSH_TARGET:-}" # e.g. mac-operator@100.82.240.x (if remote)
MACSERVER_TUNNEL_CTL="${MACSERVER_TUNNEL_CTL:-/opt/muse-macserver/scripts/tunnel-ctl.sh}"
SEATING_PORT="${SEATING_PORT:-18765}"
SEOUL_HEALTH_URL="${SEOUL_HEALTH_URL:-http://127.0.0.1:17734/health}"
LOCKED_BASELINE_IMAGE="${LOCKED_BASELINE_IMAGE:-sha256:f3e697fe266f58910c01985f9c906a84479705846c88fd7d2ea1ccf12c0da2f0}"

echo "========================================================================"
echo " EXECUTING UNIFIED CROSS-DEVICE RECOVERY ORCHESTRATION"
echo " Time: $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
echo " Backup Directory: ${BACKUP_DIR:-'(not provided)'}"
echo "========================================================================"

if [ -z "$BACKUP_DIR" ] || [ ! -d "$BACKUP_DIR" ]; then
  echo "CRITICAL ERROR: Valid backup directory required as argument 1!" >&2
  echo "[RECOVERY_FAILED] Orchestration aborted: missing or invalid backup dir." >&2
  exit 1
fi

if [ ! -f "$BACKUP_DIR/manifest.env" ]; then
  echo "CRITICAL ERROR: Backup manifest.env missing in $BACKUP_DIR!" >&2
  echo "[RECOVERY_FAILED] Orchestration aborted: missing manifest.env." >&2
  exit 1
fi

# Load manifest configuration
# shellcheck source=/dev/null
source "$BACKUP_DIR/manifest.env"

ROLLBACK_LOCK="${BACKUP_DIR}/.rollback.lock"
RESULT_FILE="${BACKUP_DIR}/recovery_result.json"

# Concurrency protection & idempotent execution
if ! mkdir "$ROLLBACK_LOCK" 2>/dev/null; then
  echo "[ROLLBACK_LOCK] Active rollback already in progress for $BACKUP_DIR. Waiting for concurrent completion..."
  wait_count=0
  while [ -d "$ROLLBACK_LOCK" ] && [ "$wait_count" -lt 60 ]; do
    sleep 0.5
    wait_count=$((wait_count + 1))
  done
  if [ -d "$ROLLBACK_LOCK" ]; then
    echo "CRITICAL ERROR: Rollback lock timed out waiting for concurrent recovery!" >&2
    echo "[RECOVERY_FAILED] Rollback failed (lock acquisition timeout)." >&2
    exit 1
  fi

  echo "[ROLLBACK_WAIT] Prior rollback completed. Inspecting recovery results ($RESULT_FILE)..."
  if [ ! -f "$RESULT_FILE" ]; then
    echo "CRITICAL ERROR: Result file $RESULT_FILE missing after concurrent rollback!" >&2
    echo "[RECOVERY_FAILED] Incomplete concurrent recovery." >&2
    exit 1
  fi

  rec_status=$(grep '"recovery_status"' "$RESULT_FILE" 2>/dev/null | head -n1 | cut -d'"' -f4 || echo "UNKNOWN")
  remote_mac_status=$(grep '"mac_switch_status"' "$RESULT_FILE" 2>/dev/null | head -n1 | cut -d'"' -f4 || echo "UNKNOWN")

  if [ "$rec_status" != "SUCCESS" ] || [ "$remote_mac_status" != "CLOSED_VERIFIED_403" ]; then
    echo "CRITICAL ERROR: Concurrent recovery run reported failure (recovery_status: '$rec_status', MacServer status: '$remote_mac_status')!" >&2
    echo "[RECOVERY_FAILED] Concurrent recovery did not achieve complete success." >&2
    exit 1
  fi

  # Verify actual baseline state independently (never infer success without checking actual resources!)
  echo "[ROLLBACK_IDEMPOTENT] Verifying actual baseline state..."

  # 1. Container health probe
  check_health_url="${BACKUP_PROD_HEALTH_URL:-$SEOUL_HEALTH_URL}"
  check_ok=0
  for i in 1 2 3 4 5; do
    if curl -sf "$check_health_url" >/dev/null 2>&1; then
      check_ok=1
      break
    fi
    sleep 0.5
  done
  if [ "$check_ok" -ne 1 ]; then
    echo "CRITICAL ERROR: Health probe failed at $check_health_url after concurrent rollback!" >&2
    echo "[RECOVERY_FAILED] Idempotent health check failed." >&2
    exit 1
  fi

  # 2. Container image check
  target_container="${BACKUP_PROD_CONTAINER:-insurance-carddav-mcp-carddav-1}"
  target_baseline_image="${BACKUP_ACTUAL_IMAGE_ID:-$LOCKED_BASELINE_IMAGE}"
  if command -v docker >/dev/null 2>&1; then
    cur_img=$(docker inspect "$target_container" --format '{{.Image}}' 2>/dev/null || echo "")
    if [ "$cur_img" != "$target_baseline_image" ]; then
      echo "CRITICAL ERROR: Container active image ($cur_img) != baseline ($target_baseline_image)!" >&2
      echo "[RECOVERY_FAILED] Idempotent image check failed." >&2
      exit 1
    fi
  fi

  # 3. Port listener check
  if command -v lsof >/dev/null 2>&1; then
    if lsof -i ":${SEATING_PORT}" >/dev/null 2>&1; then
      echo "CRITICAL ERROR: Port $SEATING_PORT still has active listener!" >&2
      echo "[RECOVERY_FAILED] Idempotent port check failed." >&2
      exit 1
    fi
  elif command -v ss >/dev/null 2>&1; then
    if ss -tulpn | grep -q ":${SEATING_PORT} "; then
      echo "CRITICAL ERROR: Port $SEATING_PORT still has active listener!" >&2
      echo "[RECOVERY_FAILED] Idempotent port check failed." >&2
      exit 1
    fi
  fi

  echo "[ROLLBACK_IDEMPOTENT] All required baseline states verified. Rollback succeeded idempotently."
  exit 0
fi

declare -a recovery_errors=()
mac_switch_status="UNKNOWN"

step1_macserver="PENDING"
step2_process_cleanup="PENDING"
step3_container_restore="PENDING"
step4_ssh_restore="PENDING"
step5_verification="PENDING"

write_recovery_result() {
  local final_status="$1"
  local tmp_res="${RESULT_FILE}.tmp.$$"
  local errors_json="[]"
  if [ ${#recovery_errors[@]} -gt 0 ]; then
    if command -v jq >/dev/null 2>&1; then
      errors_json=$(printf '%s\n' "${recovery_errors[@]}" | jq -R . | jq -s . 2>/dev/null || echo "[]")
    else
      local joined=""
      for e in "${recovery_errors[@]}"; do
        clean_e=$(echo "$e" | tr '"' "'")
        if [ -z "$joined" ]; then
          joined="\"$clean_e\""
        else
          joined="$joined, \"$clean_e\""
        fi
      done
      errors_json="[$joined]"
    fi
  fi

  cat << EOF > "$tmp_res"
{
  "recovery_status": "$final_status",
  "timestamp": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
  "backup_dir": "$BACKUP_DIR",
  "mac_switch_status": "$mac_switch_status",
  "step_results": {
    "step1_macserver": "$step1_macserver",
    "step2_process_cleanup": "$step2_process_cleanup",
    "step3_container_restore": "$step3_container_restore",
    "step4_ssh_restore": "$step4_ssh_restore",
    "step5_verification": "$step5_verification"
  },
  "errors": $errors_json
}
EOF
  chmod 600 "$tmp_res" 2>/dev/null || true
  mv -f "$tmp_res" "$RESULT_FILE"
}

cleanup_lock() {
  if [ ! -f "$RESULT_FILE" ]; then
    write_recovery_result "FAILED"
  fi
  rm -rf "$ROLLBACK_LOCK" 2>/dev/null || true
}
trap cleanup_lock EXIT INT TERM

# Stop active Seoul watchdog timer if running (do not kill self if watchdog triggered rollback)
if [ -f "$BACKUP_DIR/watchdog.pid" ]; then
  wpid=$(cat "$BACKUP_DIR/watchdog.pid" 2>/dev/null || true)
  wmeta="$BACKUP_DIR/watchdog_metadata.env"
  if [ -n "$wpid" ] && [ "$wpid" != "$$" ] && kill -0 "$wpid" 2>/dev/null; then
    w_verified=0
    if [ -f "$wmeta" ]; then
      meta_wpid=$(grep '^WATCHDOG_PID=' "$wmeta" | cut -d'=' -f2- || true)
      meta_bdir=$(grep '^WATCHDOG_BACKUP_DIR=' "$wmeta" | cut -d'=' -f2- || true)
      meta_uid=$(grep '^WATCHDOG_UID=' "$wmeta" | cut -d'=' -f2- || true)
      meta_lstart=$(grep '^WATCHDOG_LSTART=' "$wmeta" | cut -d'=' -f2- || true)
      proc_uid=$(ps -p "$wpid" -o uid= 2>/dev/null | tr -d ' ' || echo "")
      proc_lstart=$(ps -p "$wpid" -o lstart= 2>/dev/null | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' || echo "")
      if [ "$meta_wpid" = "$wpid" ] && \
         [ "$meta_bdir" = "$BACKUP_DIR" ] && \
         [ "$meta_uid" = "$UID" ] && \
         [ "$proc_uid" = "$UID" ] && \
         [ -n "$meta_lstart" ] && \
         [ "$meta_lstart" = "$proc_lstart" ]; then
        w_verified=1
      fi
    fi
    if [ "$w_verified" -eq 1 ]; then
      echo "       Stopping verified active watchdog timer (PID: $wpid)..."
      kill -TERM "$wpid" 2>/dev/null || true
    else
      echo "       WARNING: Watchdog PID $wpid attribution unverified (metadata mismatch or not owned by task); refusing to signal unverified process!" >&2
    fi
  fi
  rm -f "$BACKUP_DIR/watchdog.pid" "$BACKUP_DIR/watchdog_metadata.env" 2>/dev/null || true
fi

# ------------------------------------------------------------------------------
# Step 1: MacServer Business Close & Tunnel Stop
# ------------------------------------------------------------------------------
echo "[1/5] Step 1: Requesting MacServer business close and tunnel stop..."

if [ -n "$MACSERVER_SSH_TARGET" ]; then
  echo "       Attempting remote execution via SSH ($MACSERVER_SSH_TARGET)..."
  if ssh -o ConnectTimeout=4 -o BatchMode=yes "$MACSERVER_SSH_TARGET" "$MACSERVER_TUNNEL_CTL orchestrated-stop" 2>/dev/null; then
    mac_switch_status="CLOSED_VERIFIED_403"
    step1_macserver="SUCCESS"
    echo "       [OK] MacServer business permissions closed (403 verified) and tunnel stopped via SSH."
  else
    mac_switch_status="UNKNOWN_PENDING_VERIFICATION"
    step1_macserver="UNKNOWN_PENDING_VERIFICATION"
    echo "       WARNING: Remote MacServer unreachable or connection timed out over SSH." >&2
    echo "       [FAILSAFE] Relying on MacServer local autonomous hard watchdog for local business shutdown." >&2
    recovery_errors+=("Remote MacServer unreachable over SSH ($MACSERVER_SSH_TARGET); remote business shutdown unverified (status: UNKNOWN_PENDING_VERIFICATION)")
  fi
elif [ -x "$MACSERVER_TUNNEL_CTL" ]; then
  echo "       Executing local MacServer tunnel-ctl orchestrated-stop..."
  if "$MACSERVER_TUNNEL_CTL" orchestrated-stop; then
    mac_switch_status="CLOSED_VERIFIED_403"
    step1_macserver="SUCCESS"
    echo "       [OK] Local MacServer business permissions closed (403 verified) and tunnel stopped."
  else
    mac_switch_status="FAILED"
    step1_macserver="FAILED"
    echo "       ERROR: Local MacServer tunnel-ctl orchestrated-stop failed!" >&2
    recovery_errors+=("Local MacServer tunnel-ctl orchestrated-stop failed")
  fi
else
  echo "       No MacServer SSH target or local control script configured. Marking status as NOT_CONFIGURED."
  mac_switch_status="NOT_CONFIGURED"
  step1_macserver="NOT_CONFIGURED"
  recovery_errors+=("MacServer is NOT_CONFIGURED; cannot verify remote business shutdown")
fi

# ------------------------------------------------------------------------------
# Step 2: Terminate Task-Specific Processes on Seoul Host
# (NO indiscriminate fuser -k or port killing; strictly terminate verified task PIDs)
# ------------------------------------------------------------------------------
echo "[2/5] Step 2: Terminating verified task processes on host (zero collateral damage)..."

# Pre-flight check: inspection tools
if ! command -v lsof >/dev/null 2>&1 && ! command -v ss >/dev/null 2>&1; then
  echo "       CRITICAL ERROR: Neither lsof nor ss is available to inspect port listeners!" >&2
  recovery_errors+=("Missing listener inspection tools (neither lsof nor ss available)")
fi

terminate_verified_pid() {
  local target_pid="$1"
  local pattern="$2"
  if [ -n "$target_pid" ] && kill -0 "$target_pid" 2>/dev/null; then
    # Verify launch identity (UID must match current UID)
    local proc_uid
    proc_uid=$(ps -p "$target_pid" -o uid= 2>/dev/null | tr -d ' ' || echo "")
    if [ -n "$proc_uid" ] && [ "$proc_uid" != "$UID" ]; then
      echo "       WARNING: PID $target_pid UID ($proc_uid) != current UID ($UID); refusing to signal unowned process!" >&2
      return 1
    fi

    local proc_args
    proc_args=$(ps -p "$target_pid" -o args= 2>/dev/null || echo "")
    if echo "$proc_args" | grep -E -q "$pattern"; then
      echo "       Terminating verified task process (PID: $target_pid, Pattern: $pattern)..."
      kill -TERM "$target_pid" 2>/dev/null || true
      local waited=0
      while kill -0 "$target_pid" 2>/dev/null && [ "$waited" -lt 10 ]; do
        sleep 0.2
        waited=$((waited + 1))
      done
      if kill -0 "$target_pid" 2>/dev/null; then
        kill -KILL "$target_pid" 2>/dev/null || true
      fi
    else
      echo "       WARNING: PID $target_pid does not match pattern '$pattern' (skipping to avoid collateral damage)."
    fi
  fi
}

# 1. Terminate task-specific tunnel runner if recorded and verified
if [ -f "$BACKUP_DIR/task_tunnel.pid" ]; then
  t_pid=$(cat "$BACKUP_DIR/task_tunnel.pid" 2>/dev/null || true)
  t_meta="$BACKUP_DIR/task_tunnel_metadata.env"
  t_verified=1
  if [ -f "$t_meta" ]; then
    meta_tpid=$(grep '^TASK_PID=' "$t_meta" | cut -d'=' -f2- || true)
    meta_tuid=$(grep '^TASK_UID=' "$t_meta" | cut -d'=' -f2- || true)
    meta_tlstart=$(grep '^TASK_LSTART=' "$t_meta" | cut -d'=' -f2- || true)
    proc_tlstart=$(ps -p "$t_pid" -o lstart= 2>/dev/null | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' || echo "")
    if [ "$meta_tpid" != "$t_pid" ] || [ "$meta_tuid" != "$UID" ] || ([ -n "$meta_tlstart" ] && [ "$meta_tlstart" != "$proc_tlstart" ]); then
      echo "       WARNING: Task tunnel PID $t_pid attribution mismatch ($meta_tpid, UID $meta_tuid, lstart: '$meta_tlstart'); skipping!" >&2
      t_verified=0
    fi
  fi
  if [ "$t_verified" -eq 1 ]; then
    terminate_verified_pid "$t_pid" "run-resident-tunnel|ssh"
  fi
fi

# 2. Check listeners on seating port 18765
# Attribution rule: Only terminate if process PID is verified to belong to task (e.g. recorded task_tunnel.pid).
# If an unrelated process is listening on SEATING_PORT, DO NOT KILL IT (Zero collateral damage policy)!
if command -v lsof >/dev/null 2>&1; then
  port_pids=$(lsof -ti ":${SEATING_PORT}" 2>/dev/null || echo "")
  for p in $port_pids; do
    if [ -f "$BACKUP_DIR/task_tunnel.pid" ] && [ "$p" = "$(cat "$BACKUP_DIR/task_tunnel.pid" 2>/dev/null || echo "")" ]; then
      terminate_verified_pid "$p" "run-resident-tunnel|ssh"
    else
      echo "       WARNING: Process PID $p is listening on port $SEATING_PORT but does NOT match task attribution. Refusing indiscriminate kill to prevent collateral damage!" >&2
    fi
  done
fi

# Re-verify port 18765 status
port_listener_present=0
if command -v lsof >/dev/null 2>&1; then
  if lsof -i ":${SEATING_PORT}" >/dev/null 2>&1; then
    port_listener_present=1
  fi
elif command -v ss >/dev/null 2>&1; then
  if ss -tulpn | grep -q ":${SEATING_PORT} "; then
    port_listener_present=1
  fi
fi

if [ "$port_listener_present" -ne 0 ]; then
  echo "       ERROR: Port $SEATING_PORT still has an active listener!" >&2
  recovery_errors+=("Port $SEATING_PORT still has active listener after task termination")
  step2_process_cleanup="FAILED"
else
  echo "       [OK] Port $SEATING_PORT confirmed free (zero residual listeners)."
  step2_process_cleanup="SUCCESS"
fi

# ------------------------------------------------------------------------------
# Step 3: Restore Seoul MCP Container, Compose, and Configuration
# (Safety Boundary: If container stop fails, SKIP rsync and docker compose up)
# ------------------------------------------------------------------------------
echo "[3/5] Step 3: Restoring Seoul MCP container and baseline configuration..."

target_project="${BACKUP_PROD_PROJECT:-insurance-carddav-mcp}"
target_container="${BACKUP_PROD_CONTAINER:-insurance-carddav-mcp-carddav-1}"
target_dir="${BACKUP_PROD_DIR:-$GATEWAY_ROOT}"
target_health_url="${BACKUP_PROD_HEALTH_URL:-$SEOUL_HEALTH_URL}"
target_baseline_image="${BACKUP_ACTUAL_IMAGE_ID:-$LOCKED_BASELINE_IMAGE}"
target_port="${BACKUP_PROD_PORT:-17734}"
orig_basename="${BACKUP_ORIG_COMPOSE_BASENAME:-compose.yaml}"
target_compose_file="$target_dir/$orig_basename"

# Stop candidate container
echo "       Stopping candidate container ($target_container)..."
stop_ok=0
if (cd "$target_dir" && docker compose -p "$target_project" stop carddav >/dev/null 2>&1); then
  stop_ok=1
elif docker stop "$target_container" >/dev/null 2>&1; then
  stop_ok=1
fi

container_stopped=0 # Explicit allow condition: default to 0
inspect_err_file=$(mktemp)
set +e
c_status=$(docker inspect "$target_container" --format '{{.State.Status}}' 2>"$inspect_err_file")
inspect_ec=$?
set -e
inspect_err=$(cat "$inspect_err_file" 2>/dev/null || echo "")
rm -f "$inspect_err_file"

if [ "$inspect_ec" -eq 0 ]; then
  # Inspect succeeded: inspect status string must match explicit stopped states
  if [ -z "$c_status" ] || [ "$c_status" = "unknown" ]; then
    echo "       CRITICAL ERROR: Container $target_container returned indeterminate status ('$c_status')! Refusing to assume stopped." >&2
    recovery_errors+=("Container $target_container returned indeterminate status ('$c_status')")
  elif [ "$c_status" = "exited" ] || [ "$c_status" = "stopped" ] || [ "$c_status" = "dead" ] || [ "$c_status" = "created" ]; then
    echo "       [OK] Candidate container confirmed in stopped state: $c_status"
    container_stopped=1
  else
    echo "       CRITICAL ERROR: Container $target_container is in unstopped status: $c_status!" >&2
    recovery_errors+=("Candidate container not stopped (status: $c_status)")
  fi
else
  # Inspect failed: check if it explicitly failed because target container does NOT exist
  if echo "$inspect_err" | grep -E -iq "no such (container|object)|not found"; then
    echo "       [OK] Candidate container does not exist on host (confirmed absent)."
    container_stopped=1
  else
    echo "       CRITICAL ERROR: docker inspect failed unexpectedly (code $inspect_ec: $inspect_err)! Refusing to assume container stopped." >&2
    recovery_errors+=("docker inspect failed unexpectedly for $target_container (code $inspect_ec)")
  fi
fi

if [ "$container_stopped" -ne 1 ]; then
  echo "       [SAFETY_BARRIER] Candidate container not confirmed stopped. FORBIDDEN to overwrite configs (rsync) or restart baseline (docker compose up) to protect runtime state!" >&2
  step3_container_restore="FAILED_STOP_REFUSED"
else
  # Restore files from backup
  echo "       Restoring configuration files from $BACKUP_DIR..."
  if ! rsync -a --exclude 'data/tokens.json.enc*' "$BACKUP_DIR/" "$target_dir/"; then
    echo "       CRITICAL ERROR: rsync restore from $BACKUP_DIR to $target_dir failed!" >&2
    recovery_errors+=("rsync configuration restore failed")
  fi

  # Clean up deployed compose.yaml if original was different to prevent masking
  if [ "$orig_basename" != "compose.yaml" ] && [ -f "$target_dir/compose.yaml" ]; then
    echo "       Removing deployed compose.yaml to unmask $orig_basename..."
    rm -f "$target_dir/compose.yaml" || true
  fi

  # Retag baseline image
  echo "       Retagging baseline image ($target_baseline_image)..."
  if ! docker tag "$target_baseline_image" "${target_project}-carddav:latest" 2>/dev/null; then
    echo "       CRITICAL ERROR: Failed to tag baseline image $target_baseline_image!" >&2
    recovery_errors+=("docker tag baseline image failed")
  fi

  # Restart baseline container
  echo "       Starting baseline container via Compose ($orig_basename)..."
  if ! (cd "$target_dir" && CARDDAV_IMAGE="$target_baseline_image" BIND_PORT="127.0.0.1:${target_port}" docker compose -p "$target_project" -f "$target_compose_file" up -d --no-build carddav >/dev/null 2>&1); then
    echo "       CRITICAL ERROR: Docker compose up failed for baseline container!" >&2
    recovery_errors+=("docker compose up failed for baseline container")
  fi

  step3_container_restore="SUCCESS"
fi

# ------------------------------------------------------------------------------
# Step 4: Restore SSH Configuration Based Strictly on Manifest
# ------------------------------------------------------------------------------
echo "[4/5] Step 4: Restoring SSH configurations strictly based on manifest..."

ssh_step_ok=1
ssh_dropin_path="/etc/ssh/sshd_config.d/60-macserver-gateway.conf"
ssh_preexisted="${BACKUP_SSH_DROPIN_PREEXISTED:-0}"
ssh_created="${BACKUP_SSH_DROPIN_CREATED:-0}"

if [ "$ssh_created" = "1" ] && [ "$ssh_preexisted" != "1" ]; then
  if [ -f "$ssh_dropin_path" ]; then
    echo "       Removing newly created task drop-in $ssh_dropin_path..."
    rm -f "$ssh_dropin_path" || true
  fi
elif [ "$ssh_preexisted" = "1" ]; then
  if [ -f "$BACKUP_DIR/sshd_config.d/60-macserver-gateway.conf" ]; then
    echo "       Restoring pre-existing $ssh_dropin_path from backup..."
    mkdir -p "/etc/ssh/sshd_config.d"
    cp -f "$BACKUP_DIR/sshd_config.d/60-macserver-gateway.conf" "$ssh_dropin_path"
    chmod 644 "$ssh_dropin_path"
  else
    echo "       CRITICAL ERROR: Pre-existing drop-in backup missing in $BACKUP_DIR!" >&2
    recovery_errors+=("Pre-existing drop-in backup missing in $BACKUP_DIR")
    ssh_step_ok=0
  fi
fi

# Authorized keys restoration (dynamic path from manifest; accurate 3-state handling)
ssh_auth_keys_path="${BACKUP_SSH_AUTH_KEYS_PATH:-/home/mac-operator/.ssh/authorized_keys}"
ssh_auth_keys_preexisted="${BACKUP_SSH_AUTH_KEYS_PREEXISTED:-0}"

if [ "$ssh_auth_keys_preexisted" = "0" ]; then
  if [ -f "$ssh_auth_keys_path" ]; then
    echo "       Removing newly created authorized_keys file $ssh_auth_keys_path (preexisted=0)..."
    rm -f "$ssh_auth_keys_path" || true
  fi
elif [ "$ssh_auth_keys_preexisted" = "1" ]; then
  if [ -f "$BACKUP_DIR/authorized_keys" ]; then
    echo "       Restoring pre-existing authorized_keys from backup to $ssh_auth_keys_path..."
    mkdir -p "$(dirname "$ssh_auth_keys_path")"
    cp -f "$BACKUP_DIR/authorized_keys" "$ssh_auth_keys_path"
    chmod 600 "$ssh_auth_keys_path"
  else
    echo "       CRITICAL ERROR: Pre-existing authorized_keys backup missing in $BACKUP_DIR!" >&2
    recovery_errors+=("Missing backup authorized_keys file to restore $ssh_auth_keys_path")
    ssh_step_ok=0
  fi
fi

# Reload SSH service
ssh_reloaded=0
if [ -n "${SSH_RELOAD_CMD:-}" ]; then
  if eval "$SSH_RELOAD_CMD"; then
    ssh_reloaded=1
    echo "       [OK] sshd reloaded via SSH_RELOAD_CMD."
  else
    echo "       WARNING: SSH_RELOAD_CMD failed!" >&2
    recovery_errors+=("SSH_RELOAD_CMD failed")
    ssh_step_ok=0
  fi
elif command -v systemctl >/dev/null 2>&1; then
  if systemctl reload sshd 2>/dev/null || systemctl reload ssh 2>/dev/null; then
    ssh_reloaded=1
    echo "       [OK] sshd reloaded successfully via systemctl."
  else
    echo "       WARNING: systemctl reload sshd failed!" >&2
    recovery_errors+=("systemctl reload sshd failed")
    ssh_step_ok=0
  fi
elif command -v service >/dev/null 2>&1; then
  if service ssh reload 2>/dev/null; then
    ssh_reloaded=1
    echo "       [OK] ssh reloaded successfully via service."
  else
    echo "       WARNING: service ssh reload failed!" >&2
    recovery_errors+=("service ssh reload failed")
    ssh_step_ok=0
  fi
else
  echo "       WARNING: Neither systemctl nor service found to reload sshd." >&2
  recovery_errors+=("No service management tool found to reload sshd")
  ssh_step_ok=0
fi

if [ "$ssh_step_ok" -eq 1 ]; then
  step4_ssh_restore="SUCCESS"
else
  step4_ssh_restore="FAILED"
fi

# ------------------------------------------------------------------------------
# Step 5: Verification & Failure Aggregation
# ------------------------------------------------------------------------------
echo "[5/5] Step 5: Verifying overall system health and aggregating status..."

# Healthcheck probe
echo "       Probing Seoul baseline health ($target_health_url)..."
health_ok=0
health_attempts="${HEALTH_CHECK_ATTEMPTS:-15}"
for i in $(seq 1 "$health_attempts"); do
  if curl -sf "$target_health_url" >/dev/null 2>&1; then
    health_ok=1
    echo "       [OK] Seoul container healthy at $target_health_url (probe attempt $i)."
    break
  fi
  sleep 0.5
done

if [ "$health_ok" -ne 1 ]; then
  echo "       CRITICAL ERROR: Seoul container health probe timed out!" >&2
  recovery_errors+=("Seoul baseline container health probe timed out at $target_health_url")
fi

# Running image check
cur_active_image=""
if command -v docker >/dev/null 2>&1; then
  cur_active_image=$(docker inspect "$target_container" --format '{{.Image}}' 2>/dev/null || echo "")
  if [ -z "$cur_active_image" ]; then
    echo "       CRITICAL ERROR: Unable to inspect active container image!" >&2
    recovery_errors+=("Failed to inspect running container image for $target_container")
  elif [ "$cur_active_image" != "$target_baseline_image" ]; then
    echo "       CRITICAL ERROR: Container active image ($cur_active_image) != baseline ($target_baseline_image)!" >&2
    recovery_errors+=("Container image mismatch: active ($cur_active_image) != baseline ($target_baseline_image)")
  else
    echo "       [OK] Active container image verified: $cur_active_image"
  fi
else
  echo "       CRITICAL ERROR: docker command not available to verify container image!" >&2
  recovery_errors+=("docker command unavailable for image verification")
fi

# Permissions comparison
if command -v docker >/dev/null 2>&1; then
  c_env=$(docker inspect "$target_container" --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null || echo "")
  cur_contacts_read=$(echo "$c_env" | grep -E '^ALLOW_CONTACTS_READ_1=' | cut -d'=' -f2- || true)
  cur_contacts_write=$(echo "$c_env" | grep -E '^ALLOW_CONTACTS_WRITE_1=' | cut -d'=' -f2- || true)
  cur_calendar_read=$(echo "$c_env" | grep -E '^ALLOW_CALENDAR_READ_1=' | cut -d'=' -f2- || true)
  cur_calendar_write=$(echo "$c_env" | grep -E '^ALLOW_CALENDAR_WRITE_1=' | cut -d'=' -f2- || true)

  if [ -n "${BACKUP_ALLOW_CONTACTS_READ_1:-}" ] && [ "$cur_contacts_read" != "$BACKUP_ALLOW_CONTACTS_READ_1" ]; then
    recovery_errors+=("ALLOW_CONTACTS_READ_1 mismatch: expected '$BACKUP_ALLOW_CONTACTS_READ_1', got '$cur_contacts_read'")
  fi
  if [ -n "${BACKUP_ALLOW_CONTACTS_WRITE_1:-}" ] && [ "$cur_contacts_write" != "$BACKUP_ALLOW_CONTACTS_WRITE_1" ]; then
    recovery_errors+=("ALLOW_CONTACTS_WRITE_1 mismatch: expected '$BACKUP_ALLOW_CONTACTS_WRITE_1', got '$cur_contacts_write'")
  fi
  if [ -n "${BACKUP_ALLOW_CALENDAR_READ_1:-}" ] && [ "$cur_calendar_read" != "$BACKUP_ALLOW_CALENDAR_READ_1" ]; then
    recovery_errors+=("ALLOW_CALENDAR_READ_1 mismatch: expected '$BACKUP_ALLOW_CALENDAR_READ_1', got '$cur_calendar_read'")
  fi
  if [ -n "${BACKUP_ALLOW_CALENDAR_WRITE_1:-}" ] && [ "$cur_calendar_write" != "$BACKUP_ALLOW_CALENDAR_WRITE_1" ]; then
    recovery_errors+=("ALLOW_CALENDAR_WRITE_1 mismatch: expected '$BACKUP_ALLOW_CALENDAR_WRITE_1', got '$cur_calendar_write'")
  fi
fi

if [ "$health_ok" -eq 1 ] && [ "$cur_active_image" = "$target_baseline_image" ]; then
  step5_verification="SUCCESS"
else
  step5_verification="FAILED"
fi

# ------------------------------------------------------------------------------
# Final Status Evaluation & Persistence
# ------------------------------------------------------------------------------
echo "========================================================================"
if [ ${#recovery_errors[@]} -gt 0 ] || [ "$mac_switch_status" != "CLOSED_VERIFIED_403" ]; then
  write_recovery_result "FAILED"
  echo " [RECOVERY_FAILED] Recovery completed with failures or incomplete remote status:" >&2
  echo "   MacServer Remote Status: $mac_switch_status" >&2
  echo "   Recorded Errors (${#recovery_errors[@]}):" >&2
  for err in "${recovery_errors[@]}"; do
    echo "     - $err" >&2
  done
  echo "========================================================================" >&2
  exit 1
else
  write_recovery_result "SUCCESS"
  echo " [RECOVERY-SUCCESS] Unified cross-device recovery completed successfully."
  echo "   MacServer Remote Status: $mac_switch_status"
  echo "   Seoul Container:         Restored to baseline ($target_baseline_image)"
  echo "   Seoul Health:            200 OK ($target_health_url)"
  echo "   Seoul SSH:               Restored from manifest and reloaded"
  echo "   Port $SEATING_PORT:               Zero residual listeners verified"
  echo "========================================================================"
  exit 0
fi
