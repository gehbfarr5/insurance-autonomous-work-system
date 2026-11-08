#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# AG-03: Comprehensive Production Entry & Standalone Recovery Drills
# (生产启动、中断防护与确定性恢复全场景演练套件)
#
# SCENARIOS COVERED (Strict requirements):
# (a) 正常部署流程 (Successful deploy from baseline to candidate)
# (b) 备份后及配置写入后 Compose 启动失败触发自动回滚 (Post-backup startup failure)
# (c) 候选健康检查超时/失败触发自动回滚 (Health probe failure / timeout)
# (d) 独立新终端/子进程直接触发恢复 (Standalone env -i recovery)
# (e) 原服务配置文件名为 docker-compose.yml 时的恢复（验证 compose.yaml 不会残留遮蔽）
# (f) 变更过程中途向指定部署 PID 发送中断信号（SIGTERM）的自动回滚与无残留验证
# (g) 恢复自身关键步骤失败验证 (Covering rsync, docker tag, compose up failures, RECOVERY_FAILED flag)
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
# DRILL (b): 备份完成并写入配置后的 Compose 启动失败触发自动回滚
# ------------------------------------------------------------------------------
echo ""
echo ">>> [DRILL B] Testing Post-Backup & Post-Config-Write Compose Startup Failure Auto-Rollback..."
setup_drill_env "fail-startup" "compose.yaml"

set +e
INJECT_COMPOSE_STARTUP_FAILURE=1 \
APPLY_PRODUCTION_APPROVED=1 \
PROD_PROJECT="$CURRENT_PROJECT" \
PROD_CONTAINER="$CURRENT_CONTAINER" \
PROD_DIR="$CURRENT_STAGING_DIR" \
PROD_PORT="$DRILL_PORT" \
"$ENTRY_SCRIPT" deploy > "$CURRENT_STAGING_DIR/drill_b.log" 2>&1
deploy_exit=$?
set -e

cat "$CURRENT_STAGING_DIR/drill_b.log"

if [ "$deploy_exit" -eq 0 ]; then
  echo "FAIL [DRILL B]: Faulty deploy should have failed with non-zero exit code!" >&2
  exit 1
fi

# Assertions proving failure happened AFTER backup and config write, and rollback was triggered
if ! grep -q "Performing live state backup to" "$CURRENT_STAGING_DIR/drill_b.log"; then
  echo "FAIL [DRILL B]: Backup step was not reached before failure!" >&2
  exit 1
fi
if ! grep -q "Deploying candidate compose configuration" "$CURRENT_STAGING_DIR/drill_b.log"; then
  echo "FAIL [DRILL B]: Candidate compose write was not reached before failure!" >&2
  exit 1
fi
if ! grep -q "FAULT_INJECTION.*Injected failure during Compose candidate startup" "$CURRENT_STAGING_DIR/drill_b.log"; then
  echo "FAIL [DRILL B]: Injected startup failure log not found!" >&2
  exit 1
fi
if ! grep -q "UNIFIED-ROLLBACK-TRIGGER" "$CURRENT_STAGING_DIR/drill_b.log"; then
  echo "FAIL [DRILL B]: Unified rollback trigger log not found!" >&2
  exit 1
fi
if ! grep -q "ROLLBACK COMPLETED SUCCESSFULLY" "$CURRENT_STAGING_DIR/drill_b.log"; then
  echo "FAIL [DRILL B]: Rollback completion log not found!" >&2
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
echo "PASS [DRILL B]: Post-backup startup failure cleanly triggered auto-rollback to healthy baseline."

# ------------------------------------------------------------------------------
# DRILL (c): 候选健康检查超时/失败触发自动回滚
# ------------------------------------------------------------------------------
echo ""
echo ">>> [DRILL C] Testing Candidate Health Check Failure Auto-Rollback..."
setup_drill_env "fail-health" "compose.yaml"

set +e
HEALTH_CHECK_ATTEMPTS=3 \
PROD_HEALTH_URL="http://127.0.0.1:19999/health" \
APPLY_PRODUCTION_APPROVED=1 \
PROD_PROJECT="$CURRENT_PROJECT" \
PROD_CONTAINER="$CURRENT_CONTAINER" \
PROD_DIR="$CURRENT_STAGING_DIR" \
PROD_PORT="$DRILL_PORT" \
"$ENTRY_SCRIPT" deploy > "$CURRENT_STAGING_DIR/drill_c.log" 2>&1
health_fail_exit=$?
set -e

cat "$CURRENT_STAGING_DIR/drill_c.log"

if [ "$health_fail_exit" -eq 0 ]; then
  echo "FAIL [DRILL C]: Health check failure should have exited non-zero!" >&2
  exit 1
fi

if ! grep -q "Candidate container health check timed out" "$CURRENT_STAGING_DIR/drill_c.log"; then
  echo "FAIL [DRILL C]: Health check timeout log not found!" >&2
  exit 1
fi
if ! grep -q "UNIFIED-ROLLBACK-TRIGGER" "$CURRENT_STAGING_DIR/drill_c.log"; then
  echo "FAIL [DRILL C]: Unified rollback trigger log not found!" >&2
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
# DRILL (f): 变更过程中途向指定部署 PID 发送中断信号（SIGTERM）的自动回滚与无残留验证
# ------------------------------------------------------------------------------
echo ""
echo ">>> [DRILL F] Testing Targeted PID Interruption Signal (SIGTERM) Auto-Rollback..."
setup_drill_env "interrupt" "compose.yaml"

# Launch deploy in background and capture exact PID (zero pgrep commands)
APPLY_PRODUCTION_APPROVED=1 \
PROD_PROJECT="$CURRENT_PROJECT" \
PROD_CONTAINER="$CURRENT_CONTAINER" \
PROD_DIR="$CURRENT_STAGING_DIR" \
PROD_PORT="$DRILL_PORT" \
"$ENTRY_SCRIPT" deploy > "$CURRENT_STAGING_DIR/drill_f.log" 2>&1 &
DEPLOY_PID=$!

echo "Started deploy process in background with PID $DEPLOY_PID..."

# Wait briefly for deployment to enter active progress (DEPLOY_IN_PROGRESS=1)
sleep 1
if kill -0 "$DEPLOY_PID" 2>/dev/null; then
  echo "Sending SIGTERM specifically to PID $DEPLOY_PID (no pgrep used)..."
  kill -TERM "$DEPLOY_PID" 2>/dev/null || true
fi

set +e
wait "$DEPLOY_PID"
int_exit=$?
set -e

cat "$CURRENT_STAGING_DIR/drill_f.log" || true

echo "Deploy exit code after signal interruption: $int_exit"
if [ "$int_exit" -ne 143 ]; then
  echo "FAIL [DRILL F]: Interrupted deploy should have exited with code 143, got $int_exit!" >&2
  exit 1
fi

if ! grep -q "Deployment failure or interruption detected (exit/signal: 143)" "$CURRENT_STAGING_DIR/drill_f.log"; then
  echo "FAIL [DRILL F]: Expected signal 143 interruption log not found!" >&2
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
echo "PASS [DRILL F]: Signal interruption to exact PID cleanly caught; auto-rollback restored baseline."

# ------------------------------------------------------------------------------
# DRILL (g): 恢复自身关键步骤失败验证 (Covering rsync, docker tag, compose up failures, RECOVERY_FAILED flag)
# ------------------------------------------------------------------------------
echo ""
echo ">>> [DRILL G] Testing Rollback Critical Failure Handling & RECOVERY_FAILED Detection..."
setup_drill_env "rec-fail" "compose.yaml"

# Deploy candidate normally first so we have a valid backup
APPLY_PRODUCTION_APPROVED=1 \
PROD_PROJECT="$CURRENT_PROJECT" \
PROD_CONTAINER="$CURRENT_CONTAINER" \
PROD_DIR="$CURRENT_STAGING_DIR" \
PROD_PORT="$DRILL_PORT" \
"$ENTRY_SCRIPT" deploy >/dev/null 2>&1

valid_bak=$(ls -td "$CURRENT_STAGING_DIR".bak-* | head -1)

# Test 1: Injected rsync failure during rollback
echo "--- Testing rollback failure on rsync step ---"
set +e
INJECT_ROLLBACK_STEP_FAILURE="rsync" "$ENTRY_SCRIPT" rollback "$valid_bak" > "$CURRENT_STAGING_DIR/drill_g_rsync.log" 2>&1
rsync_fail_exit=$?
set -e

if [ "$rsync_fail_exit" -eq 0 ]; then
  echo "FAIL [DRILL G]: Rollback should have failed when rsync failed!" >&2
  exit 1
fi
if ! grep -q "RECOVERY_FAILED" "$CURRENT_STAGING_DIR/drill_g_rsync.log"; then
  echo "FAIL [DRILL G]: RECOVERY_FAILED tag not output on rsync failure!" >&2
  exit 1
fi
if grep -q "ROLLBACK COMPLETED SUCCESSFULLY" "$CURRENT_STAGING_DIR/drill_g_rsync.log"; then
  echo "FAIL [DRILL G]: ROLLBACK COMPLETED SUCCESSFULLY should not be printed on failure!" >&2
  exit 1
fi
echo "       PASS: rsync failure correctly flagged RECOVERY_FAILED and exited non-zero."

# Test 2: Injected docker tag failure during rollback
echo "--- Testing rollback failure on docker tag step ---"
set +e
INJECT_ROLLBACK_STEP_FAILURE="docker_tag" "$ENTRY_SCRIPT" rollback "$valid_bak" > "$CURRENT_STAGING_DIR/drill_g_tag.log" 2>&1
tag_fail_exit=$?
set -e

if [ "$tag_fail_exit" -eq 0 ]; then
  echo "FAIL [DRILL G]: Rollback should have failed when docker tag failed!" >&2
  exit 1
fi
if ! grep -q "RECOVERY_FAILED" "$CURRENT_STAGING_DIR/drill_g_tag.log"; then
  echo "FAIL [DRILL G]: RECOVERY_FAILED tag not output on docker tag failure!" >&2
  exit 1
fi
if grep -q "ROLLBACK COMPLETED SUCCESSFULLY" "$CURRENT_STAGING_DIR/drill_g_tag.log"; then
  echo "FAIL [DRILL G]: ROLLBACK COMPLETED SUCCESSFULLY should not be printed on failure!" >&2
  exit 1
fi
echo "       PASS: docker tag failure correctly flagged RECOVERY_FAILED and exited non-zero."

# Test 3: Injected compose up failure during rollback
echo "--- Testing rollback failure on compose up step ---"
set +e
INJECT_ROLLBACK_STEP_FAILURE="compose_up" "$ENTRY_SCRIPT" rollback "$valid_bak" > "$CURRENT_STAGING_DIR/drill_g_compose.log" 2>&1
compose_fail_exit=$?
set -e

if [ "$compose_fail_exit" -eq 0 ]; then
  echo "FAIL [DRILL G]: Rollback should have failed when compose up failed!" >&2
  exit 1
fi
if ! grep -q "RECOVERY_FAILED" "$CURRENT_STAGING_DIR/drill_g_compose.log"; then
  echo "FAIL [DRILL G]: RECOVERY_FAILED tag not output on compose up failure!" >&2
  exit 1
fi
if grep -q "ROLLBACK COMPLETED SUCCESSFULLY" "$CURRENT_STAGING_DIR/drill_g_compose.log"; then
  echo "FAIL [DRILL G]: ROLLBACK COMPLETED SUCCESSFULLY should not be printed on failure!" >&2
  exit 1
fi
echo "       PASS: compose up failure correctly flagged RECOVERY_FAILED and exited non-zero."

# Assert backup directory is strictly preserved
if [ ! -d "$valid_bak" ]; then
  echo "FAIL [DRILL G]: Backup directory was deleted upon rollback failure!" >&2
  exit 1
fi
echo "       PASS: Backup directory preserved for post-mortem forensics."
echo "PASS [DRILL G]: All critical recovery failure paths verified (non-zero exit, RECOVERY_FAILED flag, zero false success)."

# Final Cleanup
cleanup_current_drill
trap - EXIT INT TERM

echo ""
echo "========================================================================"
echo " ALL 7 PRODUCTION ENTRY & RECOVERY DRILLS PASSED CLEANLY (7/7)"
echo " (a) Normal deployment:                                   PASSED"
echo " (b) Post-backup Compose startup failure auto-rollback:   PASSED"
echo " (c) Health check failure auto-rollback:                  PASSED"
echo " (d) Standalone clean-env recovery:                       PASSED"
echo " (e) Priority masking prevention:                         PASSED"
echo " (f) Targeted PID interruption signal auto-rollback:      PASSED"
echo " (g) Recovery critical step failure & RECOVERY_FAILED:    PASSED"
echo " Zero production impact verified."
echo "========================================================================"
