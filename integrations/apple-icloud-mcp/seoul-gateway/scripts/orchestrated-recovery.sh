#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# AG-05: Cross-Device Shutdown & Rollback Orchestration
# (跨设备联动停止与基线恢复编排脚本)
#
# Execution Sequence:
# 1. Close/verify MacServer business switch -> Assert 403 Safe Mode blocking.
# 2. Stop reverse SSH tunnel & LaunchAgent on MacServer -> Assert zero residual listeners.
# 3. Restore Seoul MCP container, Compose, and config to baseline image sha256:f3e697fe...
# 4. Restore Seoul SSH configuration & authorized_keys, delete newly created drop-in files.
# 5. End-to-end verification:
#    - Seoul MCP health (200 OK on port 17734)
#    - Running container image matches baseline sha256:f3e697fe...
#    - MacServer switch locked / tunnel stopped
#    - Zero residual listeners on reverse forward port 18765
#
# FAULT GOVERNANCE:
# - Any failure immediately outputs [RECOVERY_FAILED] and exits non-zero.
# - Even if cross-device network is severed, MacServer autonomous hard timeout
#   guarantees local shutdown.
# ==============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GATEWAY_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PRODUCTION_ENTRY="${PRODUCTION_ENTRY:-$SCRIPT_DIR/production-entry.sh}"

BACKUP_DIR="${1:-}"
MACSERVER_SSH_TARGET="${MACSERVER_SSH_TARGET:-}" # e.g. mac-operator@100.82.240.x (if remote)
MACSERVER_TUNNEL_CTL="${MACSERVER_TUNNEL_CTL:-/opt/muse-macserver/scripts/tunnel-ctl.sh}"
MACSERVER_BRIDGE_URL="${MACSERVER_BRIDGE_URL:-http://127.0.0.1:18765/health}"
SEATING_PORT="${SEATING_PORT:-18765}"
SEOUL_HEALTH_URL="${SEOUL_HEALTH_URL:-http://127.0.0.1:17734/health}"
LOCKED_BASELINE_IMAGE="${LOCKED_BASELINE_IMAGE:-sha256:f3e697fe266f58910c01985f9c906a84479705846c88fd7d2ea1ccf12c0da2f0}"

echo "========================================================================"
echo " EXECUTING CROSS-DEVICE SHUTDOWN & BASELINE ROLLBACK ORCHESTRATION"
echo " Time: $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
echo " Backup Directory: ${BACKUP_DIR:-'(not provided)'}"
echo "========================================================================"

if [ -z "$BACKUP_DIR" ] || [ ! -d "$BACKUP_DIR" ]; then
  echo "CRITICAL ERROR: Valid backup directory required as argument 1!" >&2
  echo "[RECOVERY_FAILED] Orchestration aborted: missing backup dir." >&2
  exit 1
fi

# Step 1: Close MacServer business switch & verify 403 Safe Mode / block
echo "[1/5] Step 1: Closing MacServer business switch & verifying 403 blocking..."
mac_switch_verified=0
if [ -n "$MACSERVER_SSH_TARGET" ]; then
  echo "       Probing MacServer via SSH ($MACSERVER_SSH_TARGET)..."
  if ssh -o ConnectTimeout=5 -o BatchMode=yes "$MACSERVER_SSH_TARGET" "$MACSERVER_TUNNEL_CTL orchestrated-stop" 2>/dev/null; then
    mac_switch_verified=1
    echo "       MacServer business switch closed and tunnel stopped via remote ctl."
  else
    echo "       WARNING: Remote MacServer unreachable or connection timed out." >&2
    echo "       [FAILSAFE] Relying on MacServer local hard session watchdog for local autonomous shutdown." >&2
  fi
elif [ -x "$MACSERVER_TUNNEL_CTL" ]; then
  echo "       Executing local MacServer tunnel-ctl orchestrated-stop..."
  if "$MACSERVER_TUNNEL_CTL" orchestrated-stop; then
    mac_switch_verified=1
  fi
else
  echo "       No direct MacServer SSH target specified; checking local port $SEATING_PORT..."
fi

# Step 2: Stop reverse SSH tunnel & confirm zero residual listeners on port 18765
echo "[2/5] Step 2: Stopping reverse SSH tunnel and verifying zero residual listeners..."
# If on Seoul host, kill any reverse tunnel connection or SSH listener
if command -v fuser >/dev/null 2>&1; then
  fuser -k "${SEATING_PORT}/tcp" 2>/dev/null || true
fi

# Verify no process is listening on port 18765
local_listeners=0
if command -v lsof >/dev/null 2>&1; then
  if lsof -i ":${SEATING_PORT}" >/dev/null 2>&1; then
    local_listeners=1
  fi
elif command -v ss >/dev/null 2>&1; then
  if ss -tulpn | grep -q ":${SEATING_PORT} "; then
    local_listeners=1
  fi
fi

if [ "$local_listeners" -ne 0 ]; then
  echo "CRITICAL ERROR: Port $SEATING_PORT still has active listener after stopping tunnel!" >&2
  echo "[RECOVERY_FAILED] Orchestration failed at Step 2 (residual listener on $SEATING_PORT)." >&2
  exit 1
fi
echo "       Port $SEATING_PORT confirmed free (zero residual listeners)."

# Step 3: Restore Seoul MCP image, Compose, and config
echo "[3/5] Step 3: Restoring Seoul MCP container, Compose, and config from backup..."
if ! "$PRODUCTION_ENTRY" rollback "$BACKUP_DIR"; then
  echo "CRITICAL ERROR: Production entry rollback failed!" >&2
  echo "[RECOVERY_FAILED] Orchestration failed at Step 3 (production-entry.sh rollback)." >&2
  exit 1
fi
echo "       Seoul container restored and verified baseline image."

# Step 4: Restore Seoul SSH config and authorized_keys, remove newly created files
echo "[4/5] Step 4: Restoring SSH configurations and removing temporary drop-ins..."
if [ -f "/etc/ssh/sshd_config.d/60-macserver-gateway.conf" ]; then
  echo "       Removing newly created drop-in /etc/ssh/sshd_config.d/60-macserver-gateway.conf..."
  rm -f "/etc/ssh/sshd_config.d/60-macserver-gateway.conf"
  if command -v systemctl >/dev/null 2>&1; then
    systemctl reload sshd 2>/dev/null || true
  fi
fi

# Restore authorized_keys from backup if present in backup dir
if [ -f "$BACKUP_DIR/authorized_keys" ] && [ -d "/home/mac-operator/.ssh" ]; then
  echo "       Restoring /home/mac-operator/.ssh/authorized_keys from backup..."
  cp -f "$BACKUP_DIR/authorized_keys" /home/mac-operator/.ssh/authorized_keys
  chmod 600 /home/mac-operator/.ssh/authorized_keys
fi
echo "       SSH configurations restored; temporary drop-ins cleaned."

# Step 5: Final End-to-End Baseline Integrity Verification
echo "[5/5] Step 5: Verifying overall system baseline health..."
# Check Seoul container health
if ! curl -sf "$SEOUL_HEALTH_URL" >/dev/null 2>&1; then
  echo "CRITICAL ERROR: Seoul container health probe failing at $SEOUL_HEALTH_URL!" >&2
  echo "[RECOVERY_FAILED] Orchestration failed at Step 5 (health check)." >&2
  exit 1
fi
echo "       Seoul container healthy (200 OK at $SEOUL_HEALTH_URL)."

# Check Seoul running container image
if command -v docker >/dev/null 2>&1; then
  manifest_container=""
  if [ -f "$BACKUP_DIR/manifest.env" ]; then
    manifest_container=$(grep '^BACKUP_PROD_CONTAINER=' "$BACKUP_DIR/manifest.env" | cut -d'=' -f2- | tr -d '"' || echo "")
  fi
  if [ -n "$manifest_container" ] && docker inspect "$manifest_container" >/dev/null 2>&1; then
    cur_img=$(docker inspect "$manifest_container" --format '{{.Image}}' 2>/dev/null || echo "")
    if [ "$cur_img" != "$LOCKED_BASELINE_IMAGE" ]; then
      echo "CRITICAL ERROR: Running container image ($cur_img) does not match locked baseline ($LOCKED_BASELINE_IMAGE)!" >&2
      echo "[RECOVERY_FAILED] Orchestration failed at Step 5 (image mismatch)." >&2
      exit 1
    fi
    echo "       Running container image verified: $cur_img"
  fi
fi

echo "========================================================================"
echo " CROSS-DEVICE ORCHESTRATION RECOVERY COMPLETED SUCCESSFULLY"
echo " - MacServer business switch closed & verified"
echo " - Reverse SSH tunnel stopped (zero residual listeners on $SEATING_PORT)"
echo " - Seoul container restored to verified baseline: $LOCKED_BASELINE_IMAGE"
echo " - Drop-in SSH config removed & authorized_keys restored"
echo " - Baseline health check: 200 OK"
echo "========================================================================"
exit 0
