#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# AG-03: Comprehensive Production Entry & Standalone Recovery Drills
# (生产启动、中断防护与确定性恢复全场景演练套件 - 真实命令替身验证版)
#
# SCENARIOS COVERED (Strict requirements):
# (a)  正常部署流程 (Successful deploy from baseline to candidate)
# (b1) 候选配置复制失败拦截与自动回滚 (Candidate cp failure via real command shim)
# (b2) 候选镜像标记失败拦截与自动回滚 (Candidate docker tag failure via real command shim)
# (b3) 备份后及配置写入后 Compose 启动失败拦截与自动回滚 (Candidate compose up failure via real command shim)
# (c)  候选健康检查超时/失败触发自动回滚 (Health probe failure / timeout)
# (d)  独立新终端/子进程直接触发恢复 (Standalone env -i recovery)
# (e)  原服务配置文件名为 docker-compose.yml 时的恢复（验证 compose.yaml 不会残留遮蔽）
# (f)  变更过程中途向指定部署 PID 发送中断信号（SIGTERM）的自动回滚与无残留验证
# (g1) 恢复时容器停止失败真实拦截与 RECOVERY_FAILED 验证 (Rollback stop failure via real command shim)
# (g2) 恢复时 rsync 失败真实拦截与 RECOVERY_FAILED 验证 (Rollback rsync failure via real command shim)
# (g3) 恢复时 Compose 启动失败真实拦截与 RECOVERY_FAILED 验证 (Rollback compose up failure via real command shim)
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
SHIM_DIR="/tmp/ag03-shims-${DRILL_TS}-$$"

# Setup command shims (命令替身) to intercept actual command executions without modifying production entry
REAL_CP="$(command -v cp)"
REAL_DOCKER="$(command -v docker)"
REAL_RSYNC="$(command -v rsync)"

mkdir -p "$SHIM_DIR"

cat << EOF > "$SHIM_DIR/cp"
#!/usr/bin/env bash
if [ "\${SHIM_FAIL_ACTION:-}" = "candidate_cp" ]; then
  for arg in "\$@"; do
    if [[ "\$arg" == *"compose.production.yaml" ]] || [[ "\$arg" == */compose.yaml ]]; then
      echo "[SHIM] Intercepted cp command: simulating candidate configuration copy failure!" >&2
      exit 1
    fi
  done
fi
exec "$REAL_CP" "\$@"
EOF
chmod +x "$SHIM_DIR/cp"

cat << EOF > "$SHIM_DIR/rsync"
#!/usr/bin/env bash
if [ "\${SHIM_FAIL_ACTION:-}" = "rollback_rsync" ]; then
  echo "[SHIM] Intercepted rsync command: simulating rsync restoration failure!" >&2
  exit 1
fi
exec "$REAL_RSYNC" "\$@"
EOF
chmod +x "$SHIM_DIR/rsync"

cat << EOF > "$SHIM_DIR/docker"
#!/usr/bin/env bash
case "\${SHIM_FAIL_ACTION:-}" in
  candidate_tag)
    if [ "\$1" = "tag" ] && [[ "\$*" == *":latest"* ]]; then
      echo "[SHIM] Intercepted docker tag: simulating candidate image tagging failure!" >&2
      exit 1
    fi
    ;;
  candidate_compose_up)
    if [ "\$1" = "compose" ] && [[ "\$*" == *"up"* ]]; then
      if [ "\${CARDDAV_IMAGE:-}" = "$LOCKED_CANDIDATE_IMAGE" ]; then
        echo "[SHIM] Intercepted docker compose up: simulating candidate container startup failure!" >&2
        exit 1
      fi
    fi
    ;;
  rollback_stop)
    if [ "\$1" = "compose" ] && [[ "\$*" == *"stop"* ]]; then
      echo "[SHIM] Intercepted docker compose stop: simulating stop failure!" >&2
      exit 1
    fi
    if [ "\$1" = "stop" ]; then
      echo "[SHIM] Intercepted docker stop: simulating stop failure!" >&2
      exit 1
    fi
    ;;
  rollback_compose_up)
    if [ "\$1" = "compose" ] && [[ "\$*" == *"up"* ]]; then
      echo "[SHIM] Intercepted docker compose up: simulating rollback baseline startup failure!" >&2
      exit 1
    fi
    ;;
esac

exec "$REAL_DOCKER" "\$@"
EOF
chmod +x "$SHIM_DIR/docker"

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

cleanup_all() {
  cleanup_current_drill
  rm -rf "$SHIM_DIR" 2>/dev/null || true
}
trap cleanup_all EXIT INT TERM

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
# DRILL (b1): 候选配置复制失败拦截与自动回滚 (Candidate cp failure via real command shim)
# ------------------------------------------------------------------------------
echo ""
echo ">>> [DRILL B1] Testing Candidate Config Copy Failure Auto-Rollback (Shim cp)..."
setup_drill_env "fail-cp" "compose.yaml"

set +e
PATH="$SHIM_DIR:$PATH" \
SHIM_FAIL_ACTION="candidate_cp" \
APPLY_PRODUCTION_APPROVED=1 \
PROD_PROJECT="$CURRENT_PROJECT" \
PROD_CONTAINER="$CURRENT_CONTAINER" \
PROD_DIR="$CURRENT_STAGING_DIR" \
PROD_PORT="$DRILL_PORT" \
"$ENTRY_SCRIPT" deploy > /tmp/ag03_drill_b1.log 2>&1
deploy_b1_exit=$?
set -e

cat /tmp/ag03_drill_b1.log

if [ "$deploy_b1_exit" -eq 0 ]; then
  echo "FAIL [DRILL B1]: Faulty deploy should have failed with non-zero exit code!" >&2
  exit 1
fi

if ! grep -q "Intercepted cp command: simulating candidate configuration copy failure" /tmp/ag03_drill_b1.log; then
  echo "FAIL [DRILL B1]: Intercepted cp log not found!" >&2
  exit 1
fi
if ! grep -q "UNIFIED-ROLLBACK-TRIGGER" /tmp/ag03_drill_b1.log; then
  echo "FAIL [DRILL B1]: Unified rollback trigger log not found!" >&2
  exit 1
fi
if ! grep -q "ROLLBACK COMPLETED SUCCESSFULLY" /tmp/ag03_drill_b1.log; then
  echo "FAIL [DRILL B1]: Rollback completion log not found!" >&2
  exit 1
fi

b_img=$(docker inspect "$CURRENT_CONTAINER" --format '{{.Image}}')
if [ "$b_img" != "$LOCKED_BASELINE_IMAGE" ]; then
  echo "FAIL [DRILL B1]: Container was not rolled back to baseline! Got $b_img" >&2
  exit 1
fi
if ! curl -sf "$DRILL_HEALTH_URL" >/dev/null 2>&1; then
  echo "FAIL [DRILL B1]: Restored baseline container is not healthy!" >&2
  exit 1
fi
echo "PASS [DRILL B1]: Candidate cp failure cleanly triggered auto-rollback to healthy baseline."

# ------------------------------------------------------------------------------
# DRILL (b2): 候选镜像标记失败拦截与自动回滚 (Candidate docker tag failure via real command shim)
# ------------------------------------------------------------------------------
echo ""
echo ">>> [DRILL B2] Testing Candidate Docker Tag Failure Auto-Rollback (Shim docker tag)..."
setup_drill_env "fail-tag" "compose.yaml"

set +e
PATH="$SHIM_DIR:$PATH" \
SHIM_FAIL_ACTION="candidate_tag" \
APPLY_PRODUCTION_APPROVED=1 \
PROD_PROJECT="$CURRENT_PROJECT" \
PROD_CONTAINER="$CURRENT_CONTAINER" \
PROD_DIR="$CURRENT_STAGING_DIR" \
PROD_PORT="$DRILL_PORT" \
"$ENTRY_SCRIPT" deploy > /tmp/ag03_drill_b2.log 2>&1
deploy_b2_exit=$?
set -e

cat /tmp/ag03_drill_b2.log

if [ "$deploy_b2_exit" -eq 0 ]; then
  echo "FAIL [DRILL B2]: Faulty deploy should have failed with non-zero exit code!" >&2
  exit 1
fi

if ! grep -q "Intercepted docker tag: simulating candidate image tagging failure" /tmp/ag03_drill_b2.log; then
  echo "FAIL [DRILL B2]: Intercepted docker tag log not found!" >&2
  exit 1
fi
if ! grep -q "UNIFIED-ROLLBACK-TRIGGER" /tmp/ag03_drill_b2.log; then
  echo "FAIL [DRILL B2]: Unified rollback trigger log not found!" >&2
  exit 1
fi
if ! grep -q "ROLLBACK COMPLETED SUCCESSFULLY" /tmp/ag03_drill_b2.log; then
  echo "FAIL [DRILL B2]: Rollback completion log not found!" >&2
  exit 1
fi

b_img=$(docker inspect "$CURRENT_CONTAINER" --format '{{.Image}}')
if [ "$b_img" != "$LOCKED_BASELINE_IMAGE" ]; then
  echo "FAIL [DRILL B2]: Container was not rolled back to baseline! Got $b_img" >&2
  exit 1
fi
if ! curl -sf "$DRILL_HEALTH_URL" >/dev/null 2>&1; then
  echo "FAIL [DRILL B2]: Restored baseline container is not healthy!" >&2
  exit 1
fi
echo "PASS [DRILL B2]: Candidate docker tag failure cleanly triggered auto-rollback to healthy baseline."

# ------------------------------------------------------------------------------
# DRILL (b3): 备份完成并写入配置后的 Compose 启动失败拦截与自动回滚 (Shim docker compose up)
# ------------------------------------------------------------------------------
echo ""
echo ">>> [DRILL B3] Testing Post-Backup Candidate Compose Up Failure Auto-Rollback (Shim compose up)..."
setup_drill_env "fail-compose-up" "compose.yaml"

set +e
PATH="$SHIM_DIR:$PATH" \
SHIM_FAIL_ACTION="candidate_compose_up" \
APPLY_PRODUCTION_APPROVED=1 \
PROD_PROJECT="$CURRENT_PROJECT" \
PROD_CONTAINER="$CURRENT_CONTAINER" \
PROD_DIR="$CURRENT_STAGING_DIR" \
PROD_PORT="$DRILL_PORT" \
"$ENTRY_SCRIPT" deploy > /tmp/ag03_drill_b3.log 2>&1
deploy_b3_exit=$?
set -e

cat /tmp/ag03_drill_b3.log

if [ "$deploy_b3_exit" -eq 0 ]; then
  echo "FAIL [DRILL B3]: Faulty deploy should have failed with non-zero exit code!" >&2
  exit 1
fi

# Assertions proving failure happened AFTER backup and config write, and rollback was triggered
if ! grep -q "Performing live state backup to" /tmp/ag03_drill_b3.log; then
  echo "FAIL [DRILL B3]: Backup step was not reached before failure!" >&2
  exit 1
fi
if ! grep -q "Deploying candidate compose configuration" /tmp/ag03_drill_b3.log; then
  echo "FAIL [DRILL B3]: Candidate compose write was not reached before failure!" >&2
  exit 1
fi
if ! grep -q "Intercepted docker compose up: simulating candidate container startup failure" /tmp/ag03_drill_b3.log; then
  echo "FAIL [DRILL B3]: Intercepted compose up failure log not found!" >&2
  exit 1
fi
if ! grep -q "UNIFIED-ROLLBACK-TRIGGER" /tmp/ag03_drill_b3.log; then
  echo "FAIL [DRILL B3]: Unified rollback trigger log not found!" >&2
  exit 1
fi
if ! grep -q "ROLLBACK COMPLETED SUCCESSFULLY" /tmp/ag03_drill_b3.log; then
  echo "FAIL [DRILL B3]: Rollback completion log not found!" >&2
  exit 1
fi

# Verify baseline was automatically restored
b_img=$(docker inspect "$CURRENT_CONTAINER" --format '{{.Image}}')
if [ "$b_img" != "$LOCKED_BASELINE_IMAGE" ]; then
  echo "FAIL [DRILL B3]: Container was not rolled back to baseline! Got $b_img" >&2
  exit 1
fi
if ! curl -sf "$DRILL_HEALTH_URL" >/dev/null 2>&1; then
  echo "FAIL [DRILL B3]: Restored baseline container is not healthy!" >&2
  exit 1
fi
echo "PASS [DRILL B3]: Post-backup candidate compose up failure cleanly triggered auto-rollback to healthy baseline."

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
"$ENTRY_SCRIPT" deploy > /tmp/ag03_drill_c.log 2>&1
health_fail_exit=$?
set -e

cat /tmp/ag03_drill_c.log

if [ "$health_fail_exit" -eq 0 ]; then
  echo "FAIL [DRILL C]: Health check failure should have exited non-zero!" >&2
  exit 1
fi

if ! grep -q "Candidate container health check timed out" /tmp/ag03_drill_c.log; then
  echo "FAIL [DRILL C]: Health check timeout log not found!" >&2
  exit 1
fi
if ! grep -q "UNIFIED-ROLLBACK-TRIGGER" /tmp/ag03_drill_c.log; then
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
"$ENTRY_SCRIPT" deploy > /tmp/ag03_drill_f.log 2>&1 &
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

cat /tmp/ag03_drill_f.log || true

echo "Deploy exit code after signal interruption: $int_exit"
if [ "$int_exit" -ne 143 ]; then
  echo "FAIL [DRILL F]: Interrupted deploy should have exited with code 143, got $int_exit!" >&2
  exit 1
fi

if ! grep -q "Deployment failure or interruption detected (exit/signal: 143)" /tmp/ag03_drill_f.log; then
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
# DRILL (g1): 恢复时容器停止失败真实拦截与 RECOVERY_FAILED 验证 (Shim docker stop)
# ------------------------------------------------------------------------------
echo ""
echo ">>> [DRILL G1] Testing Rollback Stop Container Failure Handling & RECOVERY_FAILED Detection..."
setup_drill_env "rec-fail-stop" "compose.yaml"

# Deploy candidate normally first so we have a valid backup
APPLY_PRODUCTION_APPROVED=1 \
PROD_PROJECT="$CURRENT_PROJECT" \
PROD_CONTAINER="$CURRENT_CONTAINER" \
PROD_DIR="$CURRENT_STAGING_DIR" \
PROD_PORT="$DRILL_PORT" \
"$ENTRY_SCRIPT" deploy >/dev/null 2>&1

valid_bak=$(ls -td "$CURRENT_STAGING_DIR".bak-* | head -1)

echo "--- Testing rollback failure on container stop step ---"
set +e
PATH="$SHIM_DIR:$PATH" \
SHIM_FAIL_ACTION="rollback_stop" \
"$ENTRY_SCRIPT" rollback "$valid_bak" > /tmp/ag03_drill_g1.log 2>&1
stop_fail_exit=$?
set -e

cat /tmp/ag03_drill_g1.log

if [ "$stop_fail_exit" -eq 0 ]; then
  echo "FAIL [DRILL G1]: Rollback should have failed when container stop failed!" >&2
  exit 1
fi
if ! grep -q "RECOVERY_FAILED" /tmp/ag03_drill_g1.log; then
  echo "FAIL [DRILL G1]: RECOVERY_FAILED tag not output on container stop failure!" >&2
  exit 1
fi
if grep -q "ROLLBACK COMPLETED SUCCESSFULLY" /tmp/ag03_drill_g1.log; then
  echo "FAIL [DRILL G1]: ROLLBACK COMPLETED SUCCESSFULLY should not be printed on failure!" >&2
  exit 1
fi
if [ ! -d "$valid_bak" ]; then
  echo "FAIL [DRILL G1]: Backup directory was deleted upon rollback failure!" >&2
  exit 1
fi
echo "       PASS: Container stop failure correctly flagged RECOVERY_FAILED, exited non-zero, preserved backup."
echo "PASS [DRILL G1]: Rollback stop failure strictly intercepted and verified."

# ------------------------------------------------------------------------------
# DRILL (g2): 恢复时 rsync 失败真实拦截与 RECOVERY_FAILED 验证 (Shim rsync)
# ------------------------------------------------------------------------------
echo ""
echo ">>> [DRILL G2] Testing Rollback Rsync Failure Handling & RECOVERY_FAILED Detection..."
setup_drill_env "rec-fail-rsync" "compose.yaml"

APPLY_PRODUCTION_APPROVED=1 \
PROD_PROJECT="$CURRENT_PROJECT" \
PROD_CONTAINER="$CURRENT_CONTAINER" \
PROD_DIR="$CURRENT_STAGING_DIR" \
PROD_PORT="$DRILL_PORT" \
"$ENTRY_SCRIPT" deploy >/dev/null 2>&1

valid_bak=$(ls -td "$CURRENT_STAGING_DIR".bak-* | head -1)

echo "--- Testing rollback failure on rsync step ---"
set +e
PATH="$SHIM_DIR:$PATH" \
SHIM_FAIL_ACTION="rollback_rsync" \
"$ENTRY_SCRIPT" rollback "$valid_bak" > /tmp/ag03_drill_g2.log 2>&1
rsync_fail_exit=$?
set -e

cat /tmp/ag03_drill_g2.log

if [ "$rsync_fail_exit" -eq 0 ]; then
  echo "FAIL [DRILL G2]: Rollback should have failed when rsync failed!" >&2
  exit 1
fi
if ! grep -q "RECOVERY_FAILED" /tmp/ag03_drill_g2.log; then
  echo "FAIL [DRILL G2]: RECOVERY_FAILED tag not output on rsync failure!" >&2
  exit 1
fi
if grep -q "ROLLBACK COMPLETED SUCCESSFULLY" /tmp/ag03_drill_g2.log; then
  echo "FAIL [DRILL G2]: ROLLBACK COMPLETED SUCCESSFULLY should not be printed on failure!" >&2
  exit 1
fi
if [ ! -d "$valid_bak" ]; then
  echo "FAIL [DRILL G2]: Backup directory was deleted upon rollback failure!" >&2
  exit 1
fi
echo "       PASS: rsync failure correctly flagged RECOVERY_FAILED, exited non-zero, preserved backup."
echo "PASS [DRILL G2]: Rollback rsync failure strictly intercepted and verified."

# ------------------------------------------------------------------------------
# DRILL (g3): 恢复时 Compose 启动失败真实拦截与 RECOVERY_FAILED 验证 (Shim docker compose up)
# ------------------------------------------------------------------------------
echo ""
echo ">>> [DRILL G3] Testing Rollback Compose Up Failure Handling & RECOVERY_FAILED Detection..."
setup_drill_env "rec-fail-compose" "compose.yaml"

APPLY_PRODUCTION_APPROVED=1 \
PROD_PROJECT="$CURRENT_PROJECT" \
PROD_CONTAINER="$CURRENT_CONTAINER" \
PROD_DIR="$CURRENT_STAGING_DIR" \
PROD_PORT="$DRILL_PORT" \
"$ENTRY_SCRIPT" deploy >/dev/null 2>&1

valid_bak=$(ls -td "$CURRENT_STAGING_DIR".bak-* | head -1)

echo "--- Testing rollback failure on compose up step ---"
set +e
PATH="$SHIM_DIR:$PATH" \
SHIM_FAIL_ACTION="rollback_compose_up" \
"$ENTRY_SCRIPT" rollback "$valid_bak" > /tmp/ag03_drill_g3.log 2>&1
compose_fail_exit=$?
set -e

cat /tmp/ag03_drill_g3.log

if [ "$compose_fail_exit" -eq 0 ]; then
  echo "FAIL [DRILL G3]: Rollback should have failed when compose up failed!" >&2
  exit 1
fi
if ! grep -q "RECOVERY_FAILED" /tmp/ag03_drill_g3.log; then
  echo "FAIL [DRILL G3]: RECOVERY_FAILED tag not output on compose up failure!" >&2
  exit 1
fi
if grep -q "ROLLBACK COMPLETED SUCCESSFULLY" /tmp/ag03_drill_g3.log; then
  echo "FAIL [DRILL G3]: ROLLBACK COMPLETED SUCCESSFULLY should not be printed on failure!" >&2
  exit 1
fi
if [ ! -d "$valid_bak" ]; then
  echo "FAIL [DRILL G3]: Backup directory was deleted upon rollback failure!" >&2
  exit 1
fi
echo "       PASS: compose up failure correctly flagged RECOVERY_FAILED, exited non-zero, preserved backup."
echo "PASS [DRILL G3]: Rollback compose up failure strictly intercepted and verified."

# Final Cleanup
cleanup_all
trap - EXIT INT TERM

echo ""
echo "========================================================================"
echo " ALL 11 PRODUCTION ENTRY & RECOVERY DRILLS PASSED CLEANLY (11/11)"
echo " (a)  Normal deployment:                                      PASSED"
echo " (b1) Candidate cp failure auto-rollback (Shim cp):           PASSED"
echo " (b2) Candidate docker tag failure auto-rollback (Shim tag):  PASSED"
echo " (b3) Candidate compose up failure auto-rollback (Shim up):   PASSED"
echo " (c)  Health check failure auto-rollback:                     PASSED"
echo " (d)  Standalone clean-env recovery:                          PASSED"
echo " (e)  Priority masking prevention:                            PASSED"
echo " (f)  Targeted PID interruption signal auto-rollback:         PASSED"
echo " (g1) Rollback stop container failure (Shim stop):            PASSED"
echo " (g2) Rollback rsync failure (Shim rsync):                    PASSED"
echo " (g3) Rollback compose up failure (Shim compose up):          PASSED"
echo " Zero production impact verified; 100% real command failures tested."
echo "========================================================================"
