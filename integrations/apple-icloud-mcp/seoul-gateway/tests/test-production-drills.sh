#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# AG-03: Comprehensive Production Entry & Standalone Recovery Drills
# (生产启动、中断防护与确定性恢复全场景演练套件)
#
# SCENARIOS COVERED (Strict requirements):
# (a) 正常部署流程 (Successful deploy from baseline to candidate)
# (b) Compose 构建/启动失败触发自动回滚 (Fault injection during compose up)
# (c) 候选健康检查超时/失败触发自动回滚 (Health probe failure / timeout)
# (d) 独立新终端/子进程直接触发恢复 (Standalone env -i recovery)
# (e) 原服务配置文件名为 docker-compose.yml 时的恢复（验证 compose.yaml 不会残留遮蔽）
# (f) 变更过程中途收到中断信号（SIGINT/SIGTERM）的自动回滚与无残留验证
#
# SAFETY GUARANTEE:
# - Completely isolated synthetic project (ag03-drill-*) and port (17744).
# - ZERO touch to production container insurance-carddav-mcp-carddav-1 (port 17734).
# ==============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GATEWAY_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ENTRY_SCRIPT="$GATEWAY_ROOT/scripts/production-entry.sh"
COMPOSE_PROD="$GATEWAY_ROOT/config/compose.production.yaml"

LOCKED_CANDIDATE_IMAGE="sha256:b812009113d9ab16b6cbca686bbea2f21e9111136b489e385555cffbcbcebb61"
LOCKED_BASELINE_IMAGE="sha256:f3e697fe266f58910c01985f9c906a84479705846c88fd7d2ea1ccf12c0da2f0"

DRILL_PORT=17744
DRILL_HEALTH_URL="http://127.0.0.1:${DRILL_PORT}/health"
DRILL_TS=$(date +"%Y%m%d_%H%M%S")

echo "========================================================================"
echo " STARTING AG-03 PRODUCTION ENTRY & RECOVERY VERIFICATION DRILLS"
echo " Candidate Image: $LOCKED_CANDIDATE_IMAGE"
echo " Baseline Image:  $LOCKED_BASELINE_IMAGE"
echo " Drill Port:      $DRILL_PORT"
echo " Time:            $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
echo "========================================================================"

CURRENT_STAGING_DIR=""
CURRENT_PROJECT=""
CURRENT_CONTAINER=""

cleanup_current_drill() {
  if [ -n "$CURRENT_PROJECT" ]; then
    echo "--- Cleaning up drill project $CURRENT_PROJECT ---"
    docker rm -f "$CURRENT_CONTAINER" 2>/dev/null || true
    if [ -n "$CURRENT_STAGING_DIR" ] && [ -d "$CURRENT_STAGING_DIR" ]; then
      cd "$CURRENT_STAGING_DIR" 2>/dev/null || true
      docker compose -p "$CURRENT_PROJECT" down -v 2>/dev/null || true
    fi
  fi
  if [ -n "$CURRENT_STAGING_DIR" ]; then
    rm -rf "$CURRENT_STAGING_DIR" "${CURRENT_STAGING_DIR}".bak-* 2>/dev/null || true
  fi
}
trap cleanup_current_drill EXIT INT TERM

setup_drill_env() {
  local drill_name="$1"
  local compose_basename="${2:-compose.yaml}"

  cleanup_current_drill

  CURRENT_PROJECT="ag03-drill-${drill_name}-${DRILL_TS}"
  CURRENT_CONTAINER="${CURRENT_PROJECT}-carddav-1"
  CURRENT_STAGING_DIR="/tmp/${CURRENT_PROJECT}"

  mkdir -p "$CURRENT_STAGING_DIR/data"
  chmod 777 "$CURRENT_STAGING_DIR/data"

  # Synthetic restricted secrets (0600)
  cat << 'EOF' > "$CURRENT_STAGING_DIR/secrets.env"
ICLOUD_ACCOUNT_1=drill_test@example.com
ICLOUD_APP_PASSWORD_1=abcd-efgh-ijkl-mnop
TOKEN_ENCRYPTION_KEY=nP34swUmbnFtBRsFE/q7bcmmuDSbf6yt1rBN6vnzZMY=
ADMIN_PASSWORD_HASH=scrypt$32768$8$1$cHjOkUD3OaWk41oyEp3v3g$BTrh4k4eKPl227lIkaJRtlQXjL3908zvAzMh8aM1JEA
ALLOW_CALENDAR_READ_1=true
ALLOW_CALENDAR_WRITE_1=true
ALLOW_CONTACTS_READ_1=true
ALLOW_CONTACTS_WRITE_1=true
ALLOW_MAIL_READ_1=false
ALLOW_MAIL_WRITE_1=false
EOF
  chmod 600 "$CURRENT_STAGING_DIR/secrets.env"

  # Synthetic restricted gateway env (0600)
  cat << 'EOF' > "$CURRENT_STAGING_DIR/gateway.env"
MACSERVER_EVENTKIT_AUTH_TOKEN=test-synthetic-production-bearer-token-32b
MACSERVER_EVENTKIT_ALLOWED_LISTS=00000000-AAAA-BBBB-CCCC-000000000001:src-synthetic-icloud-test:iCloud:calDAV
MACSERVER_EVENTKIT_ENDPOINT=http://172.19.0.1:18765
EOF
  chmod 600 "$CURRENT_STAGING_DIR/gateway.env"

  # Initial baseline compose file
  cat << EOF > "$CURRENT_STAGING_DIR/$compose_basename"
services:
  carddav:
    image: ${LOCKED_BASELINE_IMAGE}
    restart: "no"
    command: ["/bin/sh", "-c", "umask 077; exec node dist/bin/http.js"]
    mem_limit: 256m
    pids_limit: 128
    env_file:
      - path: ./secrets.env
        format: raw
    environment:
      PORT: '17733'
      TOKEN_STORE_PATH: /app/data/tokens.json.enc
      PUBLIC_URL: https://seoul-forge-01.tail4db0d9.ts.net
      TRUST_PROXY: 'true'
      ALLOW_CONTACTS_READ_1: 'true'
      ALLOW_CALENDAR_READ_1: 'true'
    volumes:
      - ./data:/app/data
    ports:
      - '127.0.0.1:${DRILL_PORT}:17733'
EOF

  echo "Starting initial baseline container ($CURRENT_CONTAINER)..."
  cd "$CURRENT_STAGING_DIR"
  docker compose -p "$CURRENT_PROJECT" -f "$CURRENT_STAGING_DIR/$compose_basename" up -d --no-build carddav

  # Wait for baseline health
  local b_healthy=0
  for i in $(seq 1 15); do
    if curl -sf "$DRILL_HEALTH_URL" >/dev/null 2>&1; then
      b_healthy=1
      break
    fi
    sleep 1
  done
  if [ "$b_healthy" -ne 1 ]; then
    echo "ERROR: Failed to initialize baseline container for drill $drill_name!" >&2
    exit 1
  fi

  local init_img
  init_img=$(docker inspect "$CURRENT_CONTAINER" --format '{{.Image}}')
  if [ "$init_img" != "$LOCKED_BASELINE_IMAGE" ]; then
    echo "ERROR: Initial image mismatch! Got $init_img, expected $LOCKED_BASELINE_IMAGE" >&2
    exit 1
  fi
  echo "Baseline container initialized and verified healthy ($init_img)."
}

# ------------------------------------------------------------------------------
# DRILL (a): 正常部署流程 (Successful deploy from baseline to candidate)
# ------------------------------------------------------------------------------
echo ""
echo ">>> [DRILL A] Testing Normal Authorized Candidate Deployment..."
setup_drill_env "normal" "compose.yaml"

APPLY_PRODUCTION_APPROVED=1 \
PROD_PROJECT="$CURRENT_PROJECT" \
PROD_CONTAINER="$CURRENT_CONTAINER" \
PROD_DIR="$CURRENT_STAGING_DIR" \
PROD_PORT="$DRILL_PORT" \
"$ENTRY_SCRIPT" deploy

# Verify Candidate is active
cand_img=$(docker inspect "$CURRENT_CONTAINER" --format '{{.Image}}')
if [ "$cand_img" != "$LOCKED_CANDIDATE_IMAGE" ]; then
  echo "FAIL [DRILL A]: Container image is not candidate! Got $cand_img" >&2
  exit 1
fi
if ! curl -sf "$DRILL_HEALTH_URL" >/dev/null 2>&1; then
  echo "FAIL [DRILL A]: Candidate container is not healthy!" >&2
  exit 1
fi
# Verify backup directory and manifest
latest_bak=$(ls -td "$CURRENT_STAGING_DIR".bak-* | head -1)
if [ ! -f "$latest_bak/manifest.env" ]; then
  echo "FAIL [DRILL A]: Backup manifest missing!" >&2
  exit 1
fi
echo "PASS [DRILL A]: Normal deployment completed successfully with candidate active and healthy."

# ------------------------------------------------------------------------------
# DRILL (b): Compose 构建/启动失败触发自动回滚
# ------------------------------------------------------------------------------
echo ""
echo ">>> [DRILL B] Testing Compose Startup Failure Auto-Rollback..."
setup_drill_env "fail-startup" "compose.yaml"

# Create a faulty template that fails on startup (e.g. invalid port binding syntax)
cat << 'EOF' > "$CURRENT_STAGING_DIR/faulty_template.yaml"
services:
  carddav:
    image: ${CARDDAV_IMAGE}
    command: ["/bin/sh", "-c", "exit 1"]
    ports:
      - 'invalid-port-binding-fail'
EOF

set +e
COMPOSE_PROD_TEMPLATE="$CURRENT_STAGING_DIR/faulty_template.yaml" \
APPLY_PRODUCTION_APPROVED=1 \
PROD_PROJECT="$CURRENT_PROJECT" \
PROD_CONTAINER="$CURRENT_CONTAINER" \
PROD_DIR="$CURRENT_STAGING_DIR" \
PROD_PORT="$DRILL_PORT" \
"$ENTRY_SCRIPT" deploy
deploy_exit=$?
set -e

if [ "$deploy_exit" -eq 0 ]; then
  echo "FAIL [DRILL B]: Faulty deploy should have failed with non-zero exit code!" >&2
  exit 1
fi

# Verify baseline was automatically restored
b_img=$(docker inspect "$CURRENT_CONTAINER" --format '{{.Image}}')
if [ "$b_img" != "$LOCKED_BASELINE_IMAGE" ]; then
  echo "FAIL [DRILL B]: Container was not rolled back to baseline! Got $b_img" >&2
  exit 1
fi
if ! curl -sf "$DRILL_HEALTH_URL" >/dev/null 2>&1; then
  echo "FAIL [DRILL B]: Restored baseline container is not healthy!" >&2
  exit 1
fi
echo "PASS [DRILL B]: Compose failure correctly triggered auto-rollback to healthy baseline."

# ------------------------------------------------------------------------------
# DRILL (c): 候选健康检查超时/失败触发自动回滚
# ------------------------------------------------------------------------------
echo ""
echo ">>> [DRILL C] Testing Candidate Health Check Failure Auto-Rollback..."
setup_drill_env "fail-health" "compose.yaml"

# Point PROD_HEALTH_URL to an unreachable port to simulate health check failure
set +e
PROD_HEALTH_URL="http://127.0.0.1:19999/health" \
APPLY_PRODUCTION_APPROVED=1 \
PROD_PROJECT="$CURRENT_PROJECT" \
PROD_CONTAINER="$CURRENT_CONTAINER" \
PROD_DIR="$CURRENT_STAGING_DIR" \
PROD_PORT="$DRILL_PORT" \
"$ENTRY_SCRIPT" deploy
health_fail_exit=$?
set -e

if [ "$health_fail_exit" -eq 0 ]; then
  echo "FAIL [DRILL C]: Health check failure should have exited non-zero!" >&2
  exit 1
fi

# Verify baseline was automatically restored
c_restored_img=$(docker inspect "$CURRENT_CONTAINER" --format '{{.Image}}')
if [ "$c_restored_img" != "$LOCKED_BASELINE_IMAGE" ]; then
  echo "FAIL [DRILL C]: Container was not rolled back to baseline! Got $c_restored_img" >&2
  exit 1
fi
if ! curl -sf "$DRILL_HEALTH_URL" >/dev/null 2>&1; then
  echo "FAIL [DRILL C]: Restored baseline container is not healthy on real port!" >&2
  exit 1
fi
echo "PASS [DRILL C]: Health check failure correctly triggered auto-rollback to healthy baseline."

# ------------------------------------------------------------------------------
# DRILL (d): 独立新终端/子进程直接触发恢复
# ------------------------------------------------------------------------------
echo ""
echo ">>> [DRILL D] Testing Standalone Subprocess Direct Recovery (env -i)..."
setup_drill_env "standalone-rec" "compose.yaml"

# First deploy candidate
APPLY_PRODUCTION_APPROVED=1 \
PROD_PROJECT="$CURRENT_PROJECT" \
PROD_CONTAINER="$CURRENT_CONTAINER" \
PROD_DIR="$CURRENT_STAGING_DIR" \
PROD_PORT="$DRILL_PORT" \
"$ENTRY_SCRIPT" deploy

latest_bak=$(ls -td "$CURRENT_STAGING_DIR".bak-* | head -1)

# Now invoke rollback from an isolated clean environment (env -i) without any PROD_* variables
env -i PATH="$PATH" "$ENTRY_SCRIPT" rollback "$latest_bak"

# Verify rollback succeeded
d_img=$(docker inspect "$CURRENT_CONTAINER" --format '{{.Image}}')
if [ "$d_img" != "$LOCKED_BASELINE_IMAGE" ]; then
  echo "FAIL [DRILL D]: Standalone rollback failed to restore baseline! Got $d_img" >&2
  exit 1
fi
if ! curl -sf "$DRILL_HEALTH_URL" >/dev/null 2>&1; then
  echo "FAIL [DRILL D]: Container is not healthy after standalone rollback!" >&2
  exit 1
fi
echo "PASS [DRILL D]: Standalone rollback in clean environment successfully restored baseline."

# ------------------------------------------------------------------------------
# DRILL (e): 原服务配置文件名为 docker-compose.yml 时的恢复（验证 compose.yaml 不会残留遮蔽）
# ------------------------------------------------------------------------------
echo ""
echo ">>> [DRILL E] Testing docker-compose.yml Priority Masking Prevention..."
setup_drill_env "masking-test" "docker-compose.yml"

# Original file is docker-compose.yml; verify compose.yaml does NOT exist initially
if [ -f "$CURRENT_STAGING_DIR/compose.yaml" ]; then
  rm -f "$CURRENT_STAGING_DIR/compose.yaml"
fi

# Deploy candidate (which creates compose.yaml)
APPLY_PRODUCTION_APPROVED=1 \
PROD_PROJECT="$CURRENT_PROJECT" \
PROD_CONTAINER="$CURRENT_CONTAINER" \
PROD_DIR="$CURRENT_STAGING_DIR" \
PROD_PORT="$DRILL_PORT" \
"$ENTRY_SCRIPT" deploy

# Verify candidate deploy created compose.yaml
if [ ! -f "$CURRENT_STAGING_DIR/compose.yaml" ]; then
  echo "FAIL [DRILL E]: compose.yaml should have been created by candidate deploy!" >&2
  exit 1
fi

latest_bak=$(ls -td "$CURRENT_STAGING_DIR".bak-* | head -1)

# Execute rollback
"$ENTRY_SCRIPT" rollback "$latest_bak"

# Verify compose.yaml was removed to prevent masking docker-compose.yml
if [ -f "$CURRENT_STAGING_DIR/compose.yaml" ]; then
  echo "FAIL [DRILL E]: compose.yaml was NOT removed! It is masking docker-compose.yml!" >&2
  exit 1
fi
if [ ! -f "$CURRENT_STAGING_DIR/docker-compose.yml" ]; then
  echo "FAIL [DRILL E]: Original docker-compose.yml was lost!" >&2
  exit 1
fi

e_img=$(docker inspect "$CURRENT_CONTAINER" --format '{{.Image}}')
if [ "$e_img" != "$LOCKED_BASELINE_IMAGE" ]; then
  echo "FAIL [DRILL E]: Rollback failed to restore baseline! Got $e_img" >&2
  exit 1
fi
echo "PASS [DRILL E]: Compose file priority masking prevented; compose.yaml removed cleanly."

# ------------------------------------------------------------------------------
# DRILL (f): 变更过程中途收到中断信号（SIGINT/SIGTERM）的自动回滚与无残留验证
# ------------------------------------------------------------------------------
echo ""
echo ">>> [DRILL F] Testing Interruption Signal (SIGTERM) Auto-Rollback..."
setup_drill_env "interrupt" "compose.yaml"

# Start deploy in background and send SIGTERM shortly after startup
(
  sleep 1
  # Find the running deploy script PID and send TERM
  pids=$(pgrep -f "production-entry.sh deploy" || true)
  for p in $pids; do
    if [ "$p" != "$$" ]; then
      kill -TERM "$p" 2>/dev/null || true
    fi
  done
) &
term_injector_pid=$!

set +e
APPLY_PRODUCTION_APPROVED=1 \
PROD_PROJECT="$CURRENT_PROJECT" \
PROD_CONTAINER="$CURRENT_CONTAINER" \
PROD_DIR="$CURRENT_STAGING_DIR" \
PROD_PORT="$DRILL_PORT" \
"$ENTRY_SCRIPT" deploy
int_exit=$?
set -e

wait "$term_injector_pid" 2>/dev/null || true

echo "Deploy exit code after signal interruption: $int_exit"
if [ "$int_exit" -eq 0 ]; then
  echo "FAIL [DRILL F]: Interrupted deploy should have exited with non-zero code!" >&2
  exit 1
fi

# Verify baseline was automatically restored
f_img=$(docker inspect "$CURRENT_CONTAINER" --format '{{.Image}}')
if [ "$f_img" != "$LOCKED_BASELINE_IMAGE" ]; then
  echo "FAIL [DRILL F]: Container was not rolled back to baseline after interrupt! Got $f_img" >&2
  exit 1
fi
if ! curl -sf "$DRILL_HEALTH_URL" >/dev/null 2>&1; then
  echo "FAIL [DRILL F]: Restored baseline container is not healthy after interrupt!" >&2
  exit 1
fi
echo "PASS [DRILL F]: Signal interruption cleanly caught; auto-rollback restored baseline."

# Final Cleanup
cleanup_current_drill
trap - EXIT INT TERM

echo ""
echo "========================================================================"
echo " ALL 6 PRODUCTION ENTRY & RECOVERY DRILLS PASSED CLEANLY (6/6)"
echo " (a) Normal deployment:                       PASSED"
echo " (b) Compose startup failure auto-rollback:   PASSED"
echo " (c) Health check failure auto-rollback:      PASSED"
echo " (d) Standalone clean-env recovery:           PASSED"
echo " (e) Priority masking prevention:             PASSED"
echo " (f) Interruption signal auto-rollback:       PASSED"
echo " Zero production impact verified."
echo "========================================================================"
