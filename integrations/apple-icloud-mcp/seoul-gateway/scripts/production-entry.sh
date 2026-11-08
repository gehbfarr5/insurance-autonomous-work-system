#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# AG-03: Seoul MCP -> MacServer Reminders Readonly Gateway
# Unified Production Startup & Recovery Entry (生产启动与恢复唯一入口)
#
# HARDWARE & INFRASTRUCTURE LOCKED TARGETS:
# - Target Host: Seoul MCP Host (lhins-84gffkd8 / VM-0-10-ubuntu / 100.82.240.43)
# - Candidate Image ID: sha256:b812009113d9ab16b6cbca686bbea2f21e9111136b489e385555cffbcbcebb61
# - Baseline Image ID:  sha256:f3e697fe266f58910c01985f9c906a84479705846c88fd7d2ea1ccf12c0da2f0
# - Compose Project:    insurance-carddav-mcp
# - Production WorkDir: /opt/insurance-carddav-mcp
# - Production DataDir: /opt/insurance-carddav-mcp/data
# - Production Network: insurance-carddav-mcp_default (Gateway: 172.19.0.1)
# - SSH Forward Target: http://172.19.0.1:18765 (Seoul Host tunnel forwarding to MacServer 127.0.0.1:18765)
# - Secrets Source:     /opt/insurance-carddav-mcp/secrets.env (0600)
# - Gateway Env Source: /opt/insurance-carddav-mcp/gateway.env (0600)
#
# SAFETY GOVERNANCE:
# - All checks and logs report ONLY desensitized status.
# - Production deployment requires explicit approval flag: APPLY_PRODUCTION_APPROVED=1.
# - Zero real Apple data access; zero rebuilds; zero test networks in production.
# ==============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GATEWAY_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
COMPOSE_PROD_TEMPLATE="$GATEWAY_ROOT/config/compose.production.yaml"

# Pinned Image IDs (Strictly locked; no on-site rebuilding)
LOCKED_CANDIDATE_IMAGE="sha256:b812009113d9ab16b6cbca686bbea2f21e9111136b489e385555cffbcbcebb61"
LOCKED_BASELINE_IMAGE="sha256:f3e697fe266f58910c01985f9c906a84479705846c88fd7d2ea1ccf12c0da2f0"

# Production Environment Paths
PROD_PROJECT="insurance-carddav-mcp"
PROD_CONTAINER="insurance-carddav-mcp-carddav-1"
PROD_DIR="${PROD_DIR:-/opt/insurance-carddav-mcp}"
PROD_DATA_DIR="${PROD_DATA_DIR:-$PROD_DIR/data}"
PROD_SECRETS_FILE="${PROD_SECRETS_FILE:-$PROD_DIR/secrets.env}"
PROD_GATEWAY_ENV_FILE="${PROD_GATEWAY_ENV_FILE:-$PROD_DIR/gateway.env}"
PROD_COMPOSE_FILE="${PROD_COMPOSE_FILE:-$PROD_DIR/compose.yaml}"
PROD_HEALTH_URL="http://127.0.0.1:17734/health"
PROD_TUNNEL_ENDPOINT="http://172.19.0.1:18765"

# Load gateway variables from local restricted file without shell account leakage
load_gateway_vars() {
  local gw_file="$1"
  # Unset any preexisting gateway variables first
  unset MACSERVER_EVENTKIT_AUTH_TOKEN MACSERVER_EVENTKIT_ALLOWED_LISTS MACSERVER_EVENTKIT_ENDPOINT MACSERVER_EVENTKIT_TIMEOUT_MS || true
  if [ -f "$gw_file" ]; then
    while IFS='=' read -r key val || [ -n "$key" ]; do
      key=$(echo "$key" | xargs 2>/dev/null || echo "$key")
      [[ "$key" =~ ^#.* ]] && continue
      [ -z "$key" ] && continue
      if [[ "$key" =~ ^MACSERVER_EVENTKIT_ ]]; then
        export "$key"="$val"
      fi
    done < "$gw_file"
  fi
}

# Desensitization Helper
mask_token() {
  local val="$1"
  if [ -z "$val" ]; then
    echo "(empty)"
  else
    echo "[REDACTED_${#val}_CHARS]"
  fi
}

mask_binding() {
  local val="$1"
  if [ -z "$val" ]; then
    echo "(empty)"
    return
  fi
  IFS=':' read -r list_id source_id source_name source_type <<< "$val"
  if [ -n "$list_id" ] && [ ${#list_id} -ge 8 ]; then
    local prefix="${list_id:0:4}"
    local suffix="${list_id: -4}"
    echo "${prefix}****${suffix}:${source_name:-iCloud}:${source_type:-calDAV}"
  else
    echo "[REDACTED_BINDING]"
  fi
}

show_status() {
  echo "========================================================================"
  echo " SEOUL MCP PRODUCTION SERVICE STATUS AUDIT (DESENSITIZED)"
  echo " Time: $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  echo "========================================================================"

  # 1. Container status
  if docker inspect "$PROD_CONTAINER" >/dev/null 2>&1; then
    local c_status c_health c_started c_image
    c_status=$(docker inspect "$PROD_CONTAINER" --format '{{.State.Status}}')
    c_health=$(docker inspect "$PROD_CONTAINER" --format '{{.State.Health.Status}}')
    c_started=$(docker inspect "$PROD_CONTAINER" --format '{{.State.StartedAt}}')
    c_image=$(docker inspect "$PROD_CONTAINER" --format '{{.Image}}')
    echo "Container Name:    $PROD_CONTAINER"
    echo "Runtime Status:    $c_status ($c_health)"
    echo "Uptime Started:    $c_started"
    echo "Active Image ID:   $c_image"
    if [ "$c_image" = "$LOCKED_BASELINE_IMAGE" ]; then
      echo "Image Classification: [BASELINE_PRODUCTION_IMAGE]"
    elif [ "$c_image" = "$LOCKED_CANDIDATE_IMAGE" ]; then
      echo "Image Classification: [ACCEPTED_CANDIDATE_IMAGE]"
    else
      echo "Image Classification: [UNKNOWN_IMAGE]"
    fi
  else
    echo "Container $PROD_CONTAINER: NOT_RUNNING"
  fi

  # 2. Local restricted configs
  echo "--- Local Restricted Configuration Checks ---"
  echo "Secrets Path:      $PROD_SECRETS_FILE (exists: $([ -f "$PROD_SECRETS_FILE" ] && echo "YES" || echo "NO"))"
  echo "Gateway Env Path:  $PROD_GATEWAY_ENV_FILE (exists: $([ -f "$PROD_GATEWAY_ENV_FILE" ] && echo "YES" || echo "NO"))"

  if [ -f "$PROD_GATEWAY_ENV_FILE" ]; then
    local gw_token gw_lists gw_endpoint
    gw_token=$(grep -E "^MACSERVER_EVENTKIT_AUTH_TOKEN=" "$PROD_GATEWAY_ENV_FILE" | cut -d'=' -f2- || true)
    gw_lists=$(grep -E "^MACSERVER_EVENTKIT_ALLOWED_LISTS=" "$PROD_GATEWAY_ENV_FILE" | cut -d'=' -f2- || true)
    gw_endpoint=$(grep -E "^MACSERVER_EVENTKIT_ENDPOINT=" "$PROD_GATEWAY_ENV_FILE" | cut -d'=' -f2- || true)
    echo "Gateway Endpoint:  ${gw_endpoint:-$PROD_TUNNEL_ENDPOINT}"
    echo "Gateway Token:     $(mask_token "$gw_token")"
    echo "Gateway Bindings:  $(mask_binding "$gw_lists")"
  fi

  # 3. Health Endpoint
  if curl -sf "$PROD_HEALTH_URL" >/dev/null 2>&1; then
    echo "Healthcheck Probe: 200 OK (http://127.0.0.1:17734/health)"
  else
    echo "Healthcheck Probe: UNREACHABLE / FAILING"
  fi
  echo "========================================================================"
}

verify_config() {
  local target_compose="${1:-$COMPOSE_PROD_TEMPLATE}"
  local target_secrets="${2:-$PROD_SECRETS_FILE}"
  local target_gateway="${3:-$PROD_GATEWAY_ENV_FILE}"
  local dry_run_mode="${4:-0}"

  echo "--- [VERIFY-CONFIG] Validating Production Compose Interpolation & Fail-Fast ---"
  echo "Target Compose Template: $target_compose"
  echo "Target Secrets File:     $target_secrets"
  echo "Target Gateway Env File: $target_gateway"

  if [ ! -f "$target_compose" ]; then
    echo "ERROR: Compose template not found: $target_compose" >&2
    return 1
  fi
  if [ ! -f "$target_secrets" ]; then
    echo "ERROR: Secrets file not found: $target_secrets" >&2
    return 1
  fi
  if [ ! -f "$target_gateway" ]; then
    echo "ERROR: Gateway env file not found: $target_gateway" >&2
    return 1
  fi

  # Check permissions on sensitive files if in production mode
  if [ "$dry_run_mode" -eq 0 ]; then
    local s_perm g_perm
    s_perm=$(stat -c "%a" "$target_secrets" 2>/dev/null || stat -f "%Lp" "$target_secrets" 2>/dev/null || echo "unknown")
    g_perm=$(stat -c "%a" "$target_gateway" 2>/dev/null || stat -f "%Lp" "$target_gateway" 2>/dev/null || echo "unknown")
    if [ "$s_perm" != "600" ] && [ "$s_perm" != "400" ]; then
      echo "WARNING: Secrets file permission is $s_perm (recommended: 0600)" >&2
    fi
    if [ "$g_perm" != "600" ] && [ "$g_perm" != "400" ]; then
      echo "WARNING: Gateway env file permission is $g_perm (recommended: 0600)" >&2
    fi
  fi

  # 1. Test fail-fast when required gateway variable is missing
  echo "Testing Fail-Fast syntax when MACSERVER_EVENTKIT_AUTH_TOKEN is missing..."
  if (
    unset MACSERVER_EVENTKIT_AUTH_TOKEN MACSERVER_EVENTKIT_ALLOWED_LISTS
    CARDDAV_IMAGE="$LOCKED_CANDIDATE_IMAGE" \
    SECRETS_FILE="$target_secrets" \
    GATEWAY_ENV_FILE="$target_gateway" \
    docker compose -f "$target_compose" config >/dev/null 2>&1
  ); then
    echo "ERROR: Compose config failed to refuse startup when gateway variables were missing!" >&2
    return 1
  fi
  echo "       PASS: Compose refused startup on missing required gateway variables."

  # 2. Test successful rendering after loading variables from gateway.env
  echo "Testing successful Compose interpolation with locked candidate image..."
  load_gateway_vars "$target_gateway"

  local rendered_config
  rendered_config=$(
    CARDDAV_IMAGE="$LOCKED_CANDIDATE_IMAGE" \
    SECRETS_FILE="$target_secrets" \
    GATEWAY_ENV_FILE="$target_gateway" \
    docker compose -f "$target_compose" config
  )

  # Assertions on rendered configuration
  if ! echo "$rendered_config" | grep -q "$LOCKED_CANDIDATE_IMAGE"; then
    echo "ERROR: Rendered compose config does not contain locked candidate image ID!" >&2
    return 1
  fi
  if ! echo "$rendered_config" | grep -q 'ALLOW_REMINDERS_READ_1: "true"'; then
    echo "ERROR: ALLOW_REMINDERS_READ_1 was not set to true in rendered config!" >&2
    return 1
  fi
  if ! echo "$rendered_config" | grep -q 'ALLOW_REMINDERS_WRITE_1: "false"'; then
    echo "ERROR: ALLOW_REMINDERS_WRITE_1 was not set to false in rendered config!" >&2
    return 1
  fi

  echo "       PASS: Rendered compose configuration verified successfully."
  echo "       - Image ID:           $LOCKED_CANDIDATE_IMAGE (locked)"
  echo "       - Reminders Read:     true (gateway override)"
  echo "       - Reminders Write:    false (strictly blocked)"
  echo "       - Compose Project:    $PROD_PROJECT"
  echo "       - Production Network: ${PROD_PROJECT}_default (retained)"
  echo "--- [VERIFY-CONFIG] Configuration check completed with 0 errors ---"
  return 0
}

deploy_candidate() {
  if [ "${APPLY_PRODUCTION_APPROVED:-0}" != "1" ]; then
    echo "========================================================================"
    echo " CRITICAL SECURITY SAFEGUARD: PRODUCTION DEPLOYMENT BLOCKED"
    echo " User approval is strictly required before modifying production."
    echo " To execute an authorized deployment, invoke with:"
    echo "   APPLY_PRODUCTION_APPROVED=1 $0 deploy"
    echo "========================================================================"
    exit 1
  fi

  echo "========================================================================"
  echo " EXECUTING AUTHORIZED PRODUCTION DEPLOYMENT"
  echo " Candidate Image: $LOCKED_CANDIDATE_IMAGE"
  echo " Target Host:     Seoul MCP (100.82.240.43)"
  echo " Time:            $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  echo "========================================================================"

  # Step 1: Pre-flight assertions
  echo "[1/6] Running pre-flight checks..."
  if ! docker image inspect "$LOCKED_CANDIDATE_IMAGE" >/dev/null 2>&1; then
    echo "ERROR: Candidate image $LOCKED_CANDIDATE_IMAGE not found locally! Refusing on-site build." >&2
    exit 1
  fi
  if [ ! -f "$PROD_SECRETS_FILE" ]; then
    echo "ERROR: Production secrets file missing at $PROD_SECRETS_FILE!" >&2
    exit 1
  fi
  if [ ! -f "$PROD_GATEWAY_ENV_FILE" ]; then
    echo "ERROR: Production gateway env missing at $PROD_GATEWAY_ENV_FILE!" >&2
    exit 1
  fi

  # Verify config interpolation
  verify_config "$COMPOSE_PROD_TEMPLATE" "$PROD_SECRETS_FILE" "$PROD_GATEWAY_ENV_FILE" 0
  load_gateway_vars "$PROD_GATEWAY_ENV_FILE"

  # Step 2: Full live runtime backup
  local backup_ts
  backup_ts=$(date +"%Y%m%d_%H%M%S")
  local backup_dir="${PROD_DIR}.bak-${backup_ts}"
  echo "[2/6] Performing live state backup to $backup_dir..."
  cp -a "$PROD_DIR" "$backup_dir"
  docker tag insurance-carddav-mcp-carddav:latest "insurance-carddav-mcp-carddav:backup-pre-ag03-${backup_ts}" 2>/dev/null || true
  echo "       Backup created: $backup_dir"

  # Step 3: Deploy compose.production.yaml
  echo "[3/6] Deploying candidate compose configuration..."
  cp "$COMPOSE_PROD_TEMPLATE" "$PROD_COMPOSE_FILE"

  # Tag candidate image as latest
  docker tag "$LOCKED_CANDIDATE_IMAGE" insurance-carddav-mcp-carddav:latest

  # Step 4: Restart container via Compose (--no-build)
  echo "[4/6] Restarting Seoul MCP container with candidate image..."
  cd "$PROD_DIR"
  CARDDAV_IMAGE="$LOCKED_CANDIDATE_IMAGE" \
  docker compose -p "$PROD_PROJECT" -f "$PROD_COMPOSE_FILE" up -d --no-build carddav

  # Step 5: Verify health & image ID
  echo "[5/6] Verifying container health and image correspondence..."
  local healthy=0
  for i in $(seq 1 30); do
    if curl -sf "$PROD_HEALTH_URL" >/dev/null 2>&1; then
      healthy=1
      echo "       Container healthy at $PROD_HEALTH_URL (attempt $i)"
      break
    fi
    sleep 1
  done

  if [ "$healthy" -ne 1 ]; then
    echo "ERROR: Candidate container health check timed out! Initiating emergency rollback..." >&2
    rollback_baseline "$backup_dir"
    exit 1
  fi

  local running_image
  running_image=$(docker inspect "$PROD_CONTAINER" --format '{{.Image}}')
  if [ "$running_image" != "$LOCKED_CANDIDATE_IMAGE" ]; then
    echo "ERROR: Running container image mismatch! Expected: $LOCKED_CANDIDATE_IMAGE, Got: $running_image" >&2
    rollback_baseline "$backup_dir"
    exit 1
  fi
  echo "       Candidate image ID verified: $running_image"

  # Step 6: Completion summary
  echo "[6/6] Production candidate deployment completed successfully!"
  echo "       Container:       $PROD_CONTAINER"
  echo "       Image:           $LOCKED_CANDIDATE_IMAGE"
  echo "       Backup:          $backup_dir"
  echo "       Status:          Healthy (200 OK)"
  echo "========================================================================"
}

rollback_baseline() {
  local backup_dir="${1:-}"
  echo "========================================================================"
  echo " EXECUTING DETERMINISTIC ROLLBACK TO PRODUCTION BASELINE"
  echo " Baseline Image: $LOCKED_BASELINE_IMAGE"
  echo " Target Host:    Seoul MCP (100.82.240.43)"
  echo " Time:           $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  echo "========================================================================"

  # 1. Stop candidate container
  echo "[1/4] Stopping candidate container..."
  cd "$PROD_DIR"
  docker compose -p "$PROD_PROJECT" stop carddav || docker stop "$PROD_CONTAINER" || true

  # 2. Restore configuration from backup if provided, preserving runtime token store
  if [ -n "$backup_dir" ] && [ -d "$backup_dir" ]; then
    echo "[2/4] Restoring configuration from backup ($backup_dir), preserving runtime data..."
    rsync -a --exclude 'data/tokens.json.enc*' "$backup_dir/" "$PROD_DIR/"
  fi

  # 3. Retag latest to baseline image
  echo "[3/4] Locking image tag to baseline image ID ($LOCKED_BASELINE_IMAGE)..."
  docker tag "$LOCKED_BASELINE_IMAGE" insurance-carddav-mcp-carddav:latest

  # 4. Restart baseline container
  echo "[4/4] Restarting baseline container..."
  cd "$PROD_DIR"
  CARDDAV_IMAGE="$LOCKED_BASELINE_IMAGE" \
  docker compose -p "$PROD_PROJECT" up -d --no-build carddav

  # Verify baseline health
  local healthy=0
  for i in $(seq 1 30); do
    if curl -sf "$PROD_HEALTH_URL" >/dev/null 2>&1; then
      healthy=1
      echo "       Baseline container healthy at $PROD_HEALTH_URL (attempt $i)"
      break
    fi
    sleep 1
  done

  if [ "$healthy" -ne 1 ]; then
    echo "CRITICAL ERROR: Rollback baseline container failed to become healthy!" >&2
    exit 1
  fi

  local active_image
  active_image=$(docker inspect "$PROD_CONTAINER" --format '{{.Image}}')
  if [ "$active_image" != "$LOCKED_BASELINE_IMAGE" ]; then
    echo "CRITICAL ERROR: Active container image after rollback is $active_image (expected $LOCKED_BASELINE_IMAGE)!" >&2
    exit 1
  fi

  echo "========================================================================"
  echo " ROLLBACK COMPLETED SUCCESSFULLY"
  echo " Active Image: $active_image (Verified Baseline)"
  echo " Health:       200 OK"
  echo " Contacts/Cal: Restored to pristine baseline"
  echo "========================================================================"
}

case "${1:-status}" in
  status)
    show_status
    ;;
  verify-config)
    verify_config "${2:-$COMPOSE_PROD_TEMPLATE}" "${3:-$PROD_SECRETS_FILE}" "${4:-$PROD_GATEWAY_ENV_FILE}" "${5:-0}"
    ;;
  deploy)
    deploy_candidate
    ;;
  rollback)
    rollback_baseline "${2:-}"
    ;;
  *)
    echo "Usage: $0 {status|verify-config|deploy|rollback}"
    exit 1
    ;;
esac
