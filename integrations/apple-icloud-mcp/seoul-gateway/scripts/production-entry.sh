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
COMPOSE_PROD_TEMPLATE="${COMPOSE_PROD_TEMPLATE:-$GATEWAY_ROOT/config/compose.production.yaml}"

# Pinned Image IDs (Strictly locked; no on-site rebuilding)
LOCKED_CANDIDATE_IMAGE="${LOCKED_CANDIDATE_IMAGE:-sha256:b812009113d9ab16b6cbca686bbea2f21e9111136b489e385555cffbcbcebb61}"
LOCKED_BASELINE_IMAGE="${LOCKED_BASELINE_IMAGE:-sha256:f3e697fe266f58910c01985f9c906a84479705846c88fd7d2ea1ccf12c0da2f0}"

# Production Environment Paths & Configurations
PROD_PROJECT="${PROD_PROJECT:-insurance-carddav-mcp}"
PROD_CONTAINER="${PROD_CONTAINER:-${PROD_PROJECT}-carddav-1}"
PROD_DIR="${PROD_DIR:-/opt/insurance-carddav-mcp}"
PROD_DATA_DIR="${PROD_DATA_DIR:-$PROD_DIR/data}"
PROD_SECRETS_FILE="${PROD_SECRETS_FILE:-$PROD_DIR/secrets.env}"
PROD_GATEWAY_ENV_FILE="${PROD_GATEWAY_ENV_FILE:-$PROD_DIR/gateway.env}"
PROD_COMPOSE_FILE="${PROD_COMPOSE_FILE:-$PROD_DIR/compose.yaml}"
PROD_PORT="${PROD_PORT:-17734}"
PROD_HEALTH_URL="${PROD_HEALTH_URL:-http://127.0.0.1:${PROD_PORT}/health}"
PROD_TUNNEL_ENDPOINT="${PROD_TUNNEL_ENDPOINT:-http://172.19.0.1:18765}"

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

# Desensitization Helpers
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
    c_health=$(docker inspect "$PROD_CONTAINER" --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}')
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
    echo "Healthcheck Probe: 200 OK ($PROD_HEALTH_URL)"
  else
    echo "Healthcheck Probe: UNREACHABLE / FAILING ($PROD_HEALTH_URL)"
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
  echo " Target Project:  $PROD_PROJECT"
  echo " Target Dir:      $PROD_DIR"
  echo " Time:            $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  echo "========================================================================"

  # Step 1: Pre-flight assertions & Live Container Consistency Check
  echo "[1/6] Running pre-flight checks and live consistency inspection..."
  if ! docker image inspect "$LOCKED_CANDIDATE_IMAGE" >/dev/null 2>&1; then
    echo "CRITICAL ERROR: Candidate image $LOCKED_CANDIDATE_IMAGE not found locally! Refusing on-site build." >&2
    exit 1
  fi
  if [ ! -f "$PROD_SECRETS_FILE" ]; then
    echo "CRITICAL ERROR: Secrets file missing at $PROD_SECRETS_FILE!" >&2
    exit 1
  fi
  if [ ! -f "$PROD_GATEWAY_ENV_FILE" ]; then
    echo "CRITICAL ERROR: Gateway env missing at $PROD_GATEWAY_ENV_FILE!" >&2
    exit 1
  fi

  # Live container inspection
  if ! docker inspect "$PROD_CONTAINER" >/dev/null 2>&1; then
    echo "CRITICAL ERROR: Target container $PROD_CONTAINER is not running!" >&2
    exit 1
  fi

  local actual_image live_compose_file live_project live_mounts orig_basename
  actual_image=$(docker inspect "$PROD_CONTAINER" --format '{{.Image}}')
  live_compose_file=$(docker inspect "$PROD_CONTAINER" --format '{{index .Config.Labels "com.docker.compose.project.config_files"}}')
  live_project=$(docker inspect "$PROD_CONTAINER" --format '{{index .Config.Labels "com.docker.compose.project"}}')
  live_mounts=$(docker inspect "$PROD_CONTAINER" --format '{{json .Mounts}}')

  echo "       Live Container:        $PROD_CONTAINER"
  echo "       Live Container Image:  $actual_image"

  # Strict consistency check against approved baseline
  if [ "$actual_image" != "$LOCKED_BASELINE_IMAGE" ]; then
    echo "CRITICAL ERROR: Live container image ($actual_image) does NOT match approved baseline ($LOCKED_BASELINE_IMAGE)!" >&2
    echo "Refusing to proceed with deployment to avoid overwriting unapproved state." >&2
    exit 1
  fi

  if [ -n "$live_project" ] && [ "$live_project" != "$PROD_PROJECT" ]; then
    echo "CRITICAL ERROR: Running container Compose project ($live_project) does not match target ($PROD_PROJECT)!" >&2
    exit 1
  fi

  if [ -z "$live_compose_file" ]; then
    if [ -f "$PROD_DIR/compose.yaml" ]; then
      live_compose_file="$PROD_DIR/compose.yaml"
    elif [ -f "$PROD_DIR/docker-compose.yml" ]; then
      live_compose_file="$PROD_DIR/docker-compose.yml"
    else
      echo "CRITICAL ERROR: Could not locate original Compose configuration file in $PROD_DIR!" >&2
      exit 1
    fi
  fi
  orig_basename="$(basename "$live_compose_file")"
  echo "       Live Compose File:     $live_compose_file (basename: $orig_basename)"
  echo "       Live Mounts:           $live_mounts"

  # Verify config interpolation
  verify_config "$COMPOSE_PROD_TEMPLATE" "$PROD_SECRETS_FILE" "$PROD_GATEWAY_ENV_FILE" 0
  load_gateway_vars "$PROD_GATEWAY_ENV_FILE"

  # Step 2: Full live runtime backup
  local backup_ts backup_dir
  backup_ts=$(date +"%Y%m%d_%H%M%S")
  backup_dir="${PROD_DIR}.bak-${backup_ts}"
  echo "[2/6] Performing live state backup to $backup_dir..."
  mkdir -p "$backup_dir"
  cp -a "$PROD_DIR/." "$backup_dir/" || {
    echo "CRITICAL ERROR: Failed to create file backup from $PROD_DIR to $backup_dir!" >&2
    exit 1
  }

  # Tag image backup directly using actual container image ID (not latest tag)
  docker tag "$actual_image" "${PROD_PROJECT}-carddav:backup-pre-ag03-${backup_ts}" || {
    echo "CRITICAL ERROR: Failed to tag backup image for $actual_image!" >&2
    exit 1
  }

  # Record deterministic manifest for standalone recovery
  cat << EOF > "$backup_dir/manifest.env"
BACKUP_TS="$backup_ts"
BACKUP_PROD_PROJECT="$PROD_PROJECT"
BACKUP_PROD_CONTAINER="$PROD_CONTAINER"
BACKUP_PROD_DIR="$PROD_DIR"
BACKUP_PROD_DATA_DIR="$PROD_DATA_DIR"
BACKUP_PROD_SECRETS_FILE="$PROD_SECRETS_FILE"
BACKUP_PROD_GATEWAY_ENV_FILE="$PROD_GATEWAY_ENV_FILE"
BACKUP_PROD_PORT="$PROD_PORT"
BACKUP_PROD_HEALTH_URL="$PROD_HEALTH_URL"
BACKUP_ACTUAL_IMAGE_ID="$actual_image"
BACKUP_ORIG_COMPOSE_FILE="$live_compose_file"
BACKUP_ORIG_COMPOSE_BASENAME="$orig_basename"
BACKUP_CONTAINER_MOUNTS='$live_mounts'
EOF

  if [ ! -s "$backup_dir/manifest.env" ]; then
    echo "CRITICAL ERROR: Backup manifest was not created or is empty!" >&2
    exit 1
  fi
  echo "       Backup created and verified: $backup_dir"

  # Step 3: Setup deployment traps for unified failure and interruption handling
  local DEPLOY_IN_PROGRESS=1
  local ACTIVE_BACKUP_DIR="$backup_dir"

  deploy_trap_handler() {
    local exit_sig="$1"
    trap - EXIT INT TERM
    if [ "${DEPLOY_IN_PROGRESS:-0}" -eq 1 ] && [ -n "${ACTIVE_BACKUP_DIR:-}" ]; then
      echo "========================================================================" >&2
      echo " [UNIFIED-ROLLBACK-TRIGGER] Deployment failure or interruption detected (exit/signal: $exit_sig)!" >&2
      echo " Automatically executing rollback to restore production baseline..." >&2
      echo "========================================================================" >&2
      DEPLOY_IN_PROGRESS=0
      if rollback_baseline "$ACTIVE_BACKUP_DIR"; then
        echo " Unified rollback successfully restored baseline." >&2
      else
        echo " CRITICAL ALARM: Unified rollback FAILED during recovery!" >&2
      fi
    fi
    if [ "$exit_sig" -eq 0 ]; then
      exit 1
    else
      exit "$exit_sig"
    fi
  }

  trap 'deploy_trap_handler 130' INT
  trap 'deploy_trap_handler 143' TERM
  trap 'if [ "${DEPLOY_IN_PROGRESS:-0}" -eq 1 ]; then deploy_trap_handler $?; fi' EXIT

  # Step 4: Deploy compose.production.yaml
  echo "[3/6] Deploying candidate compose configuration..."
  cp "$COMPOSE_PROD_TEMPLATE" "$PROD_DIR/compose.yaml"

  # Tag candidate image as latest
  docker tag "$LOCKED_CANDIDATE_IMAGE" "${PROD_PROJECT}-carddav:latest"

  # Step 5: Restart container via Compose (--no-build)
  echo "[4/6] Restarting Seoul MCP container with candidate image..."
  cd "$PROD_DIR"
  CARDDAV_IMAGE="$LOCKED_CANDIDATE_IMAGE" \
  BIND_PORT="127.0.0.1:${PROD_PORT}" \
  SECRETS_FILE="$PROD_SECRETS_FILE" \
  GATEWAY_ENV_FILE="$PROD_GATEWAY_ENV_FILE" \
  DATA_DIR="$PROD_DATA_DIR" \
  docker compose -p "$PROD_PROJECT" -f "$PROD_DIR/compose.yaml" up -d --no-build carddav

  # Step 6: Verify health & image ID
  echo "[5/6] Verifying candidate container health and image correspondence..."
  local healthy=0
  for i in $(seq 1 30); do
    if curl -sf "$PROD_HEALTH_URL" >/dev/null 2>&1; then
      healthy=1
      echo "       Candidate container healthy at $PROD_HEALTH_URL (attempt $i)"
      break
    fi
    sleep 1
  done

  if [ "$healthy" -ne 1 ]; then
    echo "CRITICAL ERROR: Candidate container health check timed out at $PROD_HEALTH_URL!" >&2
    deploy_trap_handler 1
  fi

  local running_image
  running_image=$(docker inspect "$PROD_CONTAINER" --format '{{.Image}}')
  if [ "$running_image" != "$LOCKED_CANDIDATE_IMAGE" ]; then
    echo "CRITICAL ERROR: Running container image mismatch! Expected: $LOCKED_CANDIDATE_IMAGE, Got: $running_image" >&2
    deploy_trap_handler 1
  fi
  echo "       Candidate image ID verified: $running_image"

  # Clear traps upon verified success
  DEPLOY_IN_PROGRESS=0
  trap - EXIT INT TERM

  # Step 7: Completion summary
  echo "[6/6] Production candidate deployment completed successfully!"
  echo "       Container:       $PROD_CONTAINER"
  echo "       Image:           $LOCKED_CANDIDATE_IMAGE"
  echo "       Backup:          $backup_dir"
  echo "       Status:          Healthy (200 OK)"
  echo "========================================================================"
}

rollback_baseline() {
  local backup_dir="${1:-}"
  if [ -z "$backup_dir" ]; then
    echo "ERROR: Rollback requires explicit backup directory path!" >&2
    return 1
  fi
  if [ ! -d "$backup_dir" ]; then
    echo "ERROR: Backup directory not found: $backup_dir" >&2
    return 1
  fi
  if [ ! -f "$backup_dir/manifest.env" ]; then
    echo "ERROR: Backup manifest.env missing in $backup_dir!" >&2
    return 1
  fi

  # Load manifest so execution in a clean independent shell works without leftover env vars
  # shellcheck source=/dev/null
  source "$backup_dir/manifest.env"

  local target_project="${BACKUP_PROD_PROJECT:-$PROD_PROJECT}"
  local target_container="${BACKUP_PROD_CONTAINER:-$PROD_CONTAINER}"
  local target_dir="${BACKUP_PROD_DIR:-$PROD_DIR}"
  local target_health_url="${BACKUP_PROD_HEALTH_URL:-$PROD_HEALTH_URL}"
  local target_baseline_image="${BACKUP_ACTUAL_IMAGE_ID:-$LOCKED_BASELINE_IMAGE}"
  local target_port="${BACKUP_PROD_PORT:-17734}"
  local orig_basename="${BACKUP_ORIG_COMPOSE_BASENAME:-compose.yaml}"
  local target_compose_file="$target_dir/$orig_basename"

  echo "========================================================================"
  echo " EXECUTING DETERMINISTIC ROLLBACK TO PRODUCTION BASELINE"
  echo " Backup Dir:       $backup_dir"
  echo " Target Project:   $target_project"
  echo " Target Container: $target_container"
  echo " Target Dir:       $target_dir"
  echo " Compose File:     $orig_basename"
  echo " Baseline Image:   $target_baseline_image"
  echo " Target Health:    $target_health_url"
  echo " Time:             $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  echo "========================================================================"

  # 1. Stop candidate container
  echo "[1/5] Stopping current container..."
  cd "$target_dir"
  docker compose -p "$target_project" stop carddav 2>/dev/null || docker stop "$target_container" 2>/dev/null || true

  # 2. Restore configuration from backup, preserving runtime OAuth tokens
  echo "[2/5] Restoring configuration files from backup ($backup_dir)..."
  # Note: Exclude data/tokens.json.enc* to preserve tokens issued or refreshed during runtime
  rsync -a --exclude 'data/tokens.json.enc*' "$backup_dir/" "$target_dir/"

  # Handle Compose file priority masking:
  # Docker Compose gives priority to compose.yaml over docker-compose.yml.
  # If the original file was NOT compose.yaml, we must delete compose.yaml so original compose file is not masked!
  if [ "$orig_basename" != "compose.yaml" ] && [ -f "$target_dir/compose.yaml" ]; then
    echo "       Removing deployed compose.yaml to prevent priority masking of original $orig_basename..."
    rm -f "$target_dir/compose.yaml"
  fi

  # 3. Retag baseline image
  echo "[3/5] Restoring baseline image tag ($target_baseline_image)..."
  docker tag "$target_baseline_image" "${target_project}-carddav:latest"

  # 4. Restart baseline container using original Compose configuration
  echo "[4/5] Restarting baseline container via Compose with original configuration ($orig_basename)..."
  cd "$target_dir"
  CARDDAV_IMAGE="$target_baseline_image" \
  BIND_PORT="127.0.0.1:${target_port}" \
  docker compose -p "$target_project" -f "$target_compose_file" up -d --no-build carddav

  # 5. Strict verification: Healthcheck, Image ID, and Contacts/Calendar configuration correspondence
  echo "[5/5] Performing post-rollback verification (Health, Image ID, Permissions)..."
  local healthy=0
  for i in $(seq 1 30); do
    if curl -sf "$target_health_url" >/dev/null 2>&1; then
      healthy=1
      echo "       Baseline container healthy at $target_health_url (attempt $i)"
      break
    fi
    sleep 1
  done

  if [ "$healthy" -ne 1 ]; then
    echo "CRITICAL ERROR: Restored baseline container failed health probe at $target_health_url!" >&2
    return 1
  fi

  local active_image
  active_image=$(docker inspect "$target_container" --format '{{.Image}}')
  if [ "$active_image" != "$target_baseline_image" ]; then
    echo "CRITICAL ERROR: Active image ($active_image) does not match baseline image ($target_baseline_image)!" >&2
    return 1
  fi
  echo "       Image ID verified: $active_image"

  # Check Contacts and Calendar configuration in container
  local c_env
  c_env=$(docker inspect "$target_container" --format '{{range .Config.Env}}{{println .}}{{end}}')
  if ! echo "$c_env" | grep -q 'ALLOW_CONTACTS_READ_1=true'; then
    echo "CRITICAL ERROR: ALLOW_CONTACTS_READ_1 not found or not true in restored container!" >&2
    return 1
  fi
  if ! echo "$c_env" | grep -q 'ALLOW_CALENDAR_READ_1=true'; then
    echo "CRITICAL ERROR: ALLOW_CALENDAR_READ_1 not found or not true in restored container!" >&2
    return 1
  fi
  echo "       Configuration correspondence verified: Contacts and Calendar permissions intact."

  echo "========================================================================"
  echo " ROLLBACK COMPLETED SUCCESSFULLY"
  echo " Active Image:    $active_image (Verified Baseline)"
  echo " Health Probe:    200 OK ($target_health_url)"
  echo " Contacts/Cal:    Intact & Verified"
  echo " OAuth Tokens:    Preserved (Backward-Compatible Encryption Store)"
  echo " Masking Check:   No compose.yaml shadow over $orig_basename"
  echo "========================================================================"
  return 0
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
    rollback_baseline "${2:-}" || exit 1
    ;;
  *)
    echo "Usage: $0 {status|verify-config|deploy|rollback}"
    exit 1
    ;;
esac
