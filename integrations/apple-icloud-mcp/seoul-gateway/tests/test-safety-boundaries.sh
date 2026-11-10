#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# AG-05 Targeted Safety Boundaries Verification Suite
# (针对性安全边界验收测试套件)
#
# Core principles verified:
# 1. SSH backup must fail-fast and block deploy before changes.
# 2. Indeterminate authorization path refuses deploy without guessing ~/.ssh.
# 3. Docker inspect fail/empty/unknown strictly blocks config overwrite & baseline up.
# 4. PID file pointing to same-name unrelated process: zero collateral damage.
# 5. watchdog.pid pointing to unrelated process or different deadline: refuses reuse.
# ==============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GATEWAY_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
MCP_ROOT="$(cd "$GATEWAY_ROOT/.." && pwd)"

PRODUCTION_ENTRY="$GATEWAY_ROOT/scripts/production-entry.sh"
ORCHESTRATED_RECOVERY="$GATEWAY_ROOT/scripts/orchestrated-recovery.sh"
TUNNEL_CTL="$MCP_ROOT/resident-tunnel/scripts/tunnel-ctl.sh"
TUNNEL_RUNNER="$MCP_ROOT/resident-tunnel/scripts/run-resident-tunnel.sh"

TEST_TS=$(date +"%Y%m%d_%H%M%S")
TEST_BASE_DIR="/tmp/ag05-safety-boundaries-${TEST_TS}-$$"
mkdir -p "$TEST_BASE_DIR"

cleanup_test_env() {
  echo "--- [CLEANUP] Cleaning safety boundary test processes ---"
  if [ -f "$TEST_BASE_DIR/unrelated_bpid.pid" ]; then
    ubpid=$(cat "$TEST_BASE_DIR/unrelated_bpid.pid" 2>/dev/null || true)
    if [ -n "$ubpid" ] && kill -0 "$ubpid" 2>/dev/null; then
      kill -9 "$ubpid" 2>/dev/null || true
    fi
  fi
  if [ -f "$TEST_BASE_DIR/unrelated_tpid.pid" ]; then
    utpid=$(cat "$TEST_BASE_DIR/unrelated_tpid.pid" 2>/dev/null || true)
    if [ -n "$utpid" ] && kill -0 "$utpid" 2>/dev/null; then
      kill -9 "$utpid" 2>/dev/null || true
    fi
  fi
  if [ -f "$TEST_BASE_DIR/dummy_watchdog.pid" ]; then
    dwpid=$(cat "$TEST_BASE_DIR/dummy_watchdog.pid" 2>/dev/null || true)
    if [ -n "$dwpid" ] && kill -0 "$dwpid" 2>/dev/null; then
      kill -9 "$dwpid" 2>/dev/null || true
    fi
  fi
  pkill -f "$TEST_BASE_DIR" 2>/dev/null || true
  rm -rf "$TEST_BASE_DIR" 2>/dev/null || true
}
trap cleanup_test_env EXIT INT TERM

echo "========================================================================"
echo " AG-05 TARGETED SAFETY BOUNDARIES NEGATIVE VERIFICATION"
echo " Time: $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
echo " Base Staging: $TEST_BASE_DIR"
echo " Note: [SHIM_TEST] Isolated staging execution; production untouched"
echo "========================================================================"

# Common Mock Docker
MOCK_BIN="$TEST_BASE_DIR/bin"
mkdir -p "$MOCK_BIN"
cat << 'MOCKDOCKER' > "$MOCK_BIN/docker"
#!/usr/bin/env bash
cmd="$1"
shift || true
case "$cmd" in
  image) exit 0 ;;
  compose)
    is_config=0
    for a in "$@"; do
      if [ "$a" = "config" ]; then
        is_config=1
      fi
    done
    if [ "$is_config" -eq 1 ]; then
      if [ -z "${MACSERVER_EVENTKIT_AUTH_TOKEN:-}" ]; then
        echo "variable MACSERVER_EVENTKIT_AUTH_TOKEN not set" >&2
        exit 1
      fi
      cat << 'COMPOSE_OUT'
services:
  carddav:
    image: sha256:faa6e380ee4b9f9d96dd424ced56bf27a0778722a02323efedd542b29f362929
    environment:
      ALLOW_REMINDERS_READ_1: "true"
      ALLOW_REMINDERS_WRITE_1: "false"
COMPOSE_OUT
      exit 0
    fi
    exit 0
    ;;
  tag) exit 0 ;;
  stop) exit 0 ;;
  inspect)
    while [ $# -gt 0 ]; do
      case "$1" in
        --format)
          fmt="$2"
          shift 2 || true
          case "$fmt" in
            *'{{.State.Status}}'*) echo "running"; exit 0 ;;
            *'{{.Image}}'*) echo "sha256:f3e697fe266f58910c01985f9c906a84479705846c88fd7d2ea1ccf12c0da2f0"; exit 0 ;;
            *'Config.Env'*) echo "ALLOW_CONTACTS_READ_1=true ALLOW_CONTACTS_WRITE_1=false ALLOW_CALENDAR_READ_1=true ALLOW_CALENDAR_WRITE_1=false"; exit 0 ;;
            *'project.config_files'*) echo "/opt/insurance-carddav-mcp/compose.yaml"; exit 0 ;;
            *'project'*) echo "insurance-carddav-mcp"; exit 0 ;;
            *) echo "ok"; exit 0 ;;
          esac
          ;;
        *) shift || true ;;
      esac
    done
    echo "{}"
    exit 0
    ;;
  *) exit 0 ;;
esac
MOCKDOCKER
chmod +x "$MOCK_BIN/docker"

cat << 'MOCKCTL' > "$MOCK_BIN/tunnel-ctl.sh"
#!/usr/bin/env bash
exit 0
MOCKCTL
chmod +x "$MOCK_BIN/tunnel-ctl.sh"

export PATH="$MOCK_BIN:$PATH"

# ------------------------------------------------------------------------------
# TEST 1: authorized_keys 备份失败：部署在变更前被阻断
# ------------------------------------------------------------------------------
echo ""
echo "========================================================================"
echo " TEST 1: authorized_keys backup failure blocks deployment before changes"
echo "========================================================================"

T1_DIR="$TEST_BASE_DIR/t1"
mkdir -p "$T1_DIR/prod" "$T1_DIR/keys"
touch "$T1_DIR/prod/secrets.env" "$T1_DIR/prod/gateway.env" "$T1_DIR/prod/compose.yaml"
cat << 'EOF' > "$T1_DIR/prod/secrets.env"
APPLE_ID=test@example.com
PASSWORD_CLEAR=dummy
EOF
cat << 'EOF' > "$T1_DIR/prod/gateway.env"
MACSERVER_EVENTKIT_AUTH_TOKEN=0123456789abcdef0123456789abcdef
MACSERVER_EVENTKIT_ALLOWED_LISTS=00000000-0000-0000-0000-000000000001:src:iCloud:calDAV
MACSERVER_EVENTKIT_ENDPOINT=http://172.19.0.1:18765
EOF
chmod 600 "$T1_DIR/prod/secrets.env" "$T1_DIR/prod/gateway.env"

# Pre-existing authorized_keys exists
echo "ssh-ed25519 CRITICAL_EXISTING_SSH_KEY" > "$T1_DIR/keys/authorized_keys"

# Create a mock cp wrapper in a private bin that fails ONLY when copying authorized_keys
mkdir -p "$T1_DIR/bin"
cat << 'MOCKCP' > "$T1_DIR/bin/cp"
#!/usr/bin/env bash
for arg in "$@"; do
  if [[ "$arg" =~ authorized_keys$ ]]; then
    echo "cp: simulated disk error / permission denied on authorized_keys" >&2
    exit 1
  fi
done
exec /bin/cp "$@"
MOCKCP
chmod +x "$T1_DIR/bin/cp"

set +e
PATH="$T1_DIR/bin:$MOCK_BIN:$PATH" \
PROD_DIR="$T1_DIR/prod" \
PROD_SECRETS_FILE="$T1_DIR/prod/secrets.env" \
PROD_GATEWAY_ENV_FILE="$T1_DIR/prod/gateway.env" \
PROD_COMPOSE_FILE="$T1_DIR/prod/compose.yaml" \
MACSERVER_SSH_TARGET="mac-operator@127.0.0.1" \
MACSERVER_TUNNEL_CTL="$MOCK_BIN/tunnel-ctl.sh" \
SSH_AUTHORIZED_KEYS_PATH="$T1_DIR/keys/authorized_keys" \
APPLY_PRODUCTION_APPROVED=1 \
"$PRODUCTION_ENTRY" deploy > "$T1_DIR/deploy.log" 2>&1
t1_code=$?
set -e

echo "  [T1-VERIFY] Deploy exit code on authorized_keys backup failure: $t1_code (Expected: 1)"
if [ "$t1_code" -ne 1 ]; then
  echo "  [FAIL] Deploy was NOT blocked when authorized_keys backup failed!" >&2
  cat "$T1_DIR/deploy.log" >&2
  exit 1
fi

if ! grep -q "CRITICAL ERROR: Failed to backup authorized_keys" "$T1_DIR/deploy.log"; then
  echo "  [FAIL] Expected failure message missing in log!" >&2
  cat "$T1_DIR/deploy.log" >&2
  exit 1
fi
echo "  [PASS] Backup failure caught and explicitly reported"

# Verify ZERO production changes occurred
if [ -f "$T1_DIR/prod/compose.yaml.deployed" ]; then
  echo "  [FAIL] compose.yaml was modified or candidate applied!" >&2
  exit 1
fi
# Watchdog must not have been created
if [ -d "$T1_DIR/prod.bak-"* ] && [ -f "$T1_DIR/prod.bak-"*/watchdog.pid ]; then
  echo "  [FAIL] Watchdog was launched despite backup failure!" >&2
  exit 1
fi
echo "  [PASS] Zero subsequent changes occurred; deployment cleanly aborted"

# ------------------------------------------------------------------------------
# TEST 2: 授权路径无法确定：拒绝部署，不以用户家目录存在作为授权路径证明
# ------------------------------------------------------------------------------
echo ""
echo "========================================================================"
echo " TEST 2: Target user home/.ssh exists but sshd config unresolvable"
echo "========================================================================"

T2_DIR="$TEST_BASE_DIR/t2"
mkdir -p "$T2_DIR/prod"
touch "$T2_DIR/prod/secrets.env" "$T2_DIR/prod/gateway.env" "$T2_DIR/prod/compose.yaml"
cp "$T1_DIR/prod/secrets.env" "$T2_DIR/prod/secrets.env"
cp "$T1_DIR/prod/gateway.env" "$T2_DIR/prod/gateway.env"
chmod 600 "$T2_DIR/prod/secrets.env" "$T2_DIR/prod/gateway.env"

# Target user's home/.ssh indeed exists!
MOCK_USER_HOME="$T2_DIR/mock_mac_operator_home"
mkdir -p "$MOCK_USER_HOME/.ssh"
echo "ssh-ed25519 CRITICAL_PREEXISTING_KEY_IN_USER_HOME" > "$MOCK_USER_HOME/.ssh/authorized_keys"
chmod 600 "$MOCK_USER_HOME/.ssh/authorized_keys"

mkdir -p "$T2_DIR/bin"
# Mock getent returning this user home
cat << MOCKGETENT > "$T2_DIR/bin/getent"
#!/usr/bin/env bash
if [ "\$1" = "passwd" ] && [ "\$2" = "mac-operator" ]; then
  echo "mac-operator:x:1001:1001::$MOCK_USER_HOME:/bin/bash"
  exit 0
fi
exit 1
MOCKGETENT
chmod +x "$T2_DIR/bin/getent"

# Mock sshd that fails / returns no authorizedkeysfile
cat << 'MOCKSSHD' > "$T2_DIR/bin/sshd"
#!/usr/bin/env bash
exit 1
MOCKSSHD
chmod +x "$T2_DIR/bin/sshd"

set +e
PATH="$T2_DIR/bin:$MOCK_BIN:$PATH" \
PROD_DIR="$T2_DIR/prod" \
PROD_SECRETS_FILE="$T2_DIR/prod/secrets.env" \
PROD_GATEWAY_ENV_FILE="$T2_DIR/prod/gateway.env" \
PROD_COMPOSE_FILE="$T2_DIR/prod/compose.yaml" \
MACSERVER_SSH_TARGET="mac-operator@127.0.0.1" \
MACSERVER_TUNNEL_CTL="$MOCK_BIN/tunnel-ctl.sh" \
REMOTE_USER="mac-operator" \
SSH_AUTHORIZED_KEYS_PATH="" \
APPLY_PRODUCTION_APPROVED=1 \
"$PRODUCTION_ENTRY" deploy > "$T2_DIR/deploy.log" 2>&1
t2_code=$?
set -e

echo "  [T2-VERIFY] Deploy exit code on unresolvable sshd config: $t2_code (Expected: 1)"
if [ "$t2_code" -ne 1 ]; then
  echo "  [FAIL] Deploy did not fail when auth path was unresolvable!" >&2
  cat "$T2_DIR/deploy.log" >&2
  exit 1
fi

if ! grep -q "Refusing deployment to protect SSH access without guessing" "$T2_DIR/deploy.log"; then
  echo "  [FAIL] Log did not contain expected refusal message!" >&2
  cat "$T2_DIR/deploy.log" >&2
  exit 1
fi

# Verify the guessed user home authorized_keys was NOT accessed or copied
if ls -d "$T2_DIR/prod.bak-"* 2>/dev/null | grep -q "prod.bak"; then
  for bdir in "$T2_DIR/prod.bak-"*; do
    if [ -f "$bdir/authorized_keys" ]; then
      echo "  [FAIL] Guessed authorized_keys was accessed and copied to backup $bdir!" >&2
      exit 1
    fi
  done
fi

# Verify content in mock user home is completely untouched
if [ "$(cat "$MOCK_USER_HOME/.ssh/authorized_keys")" != "ssh-ed25519 CRITICAL_PREEXISTING_KEY_IN_USER_HOME" ]; then
  echo "  [FAIL] Mock user home authorized_keys was modified!" >&2
  exit 1
fi
echo "  [PASS] Target user home/.ssh exists but sshd config unresolvable: refused deploy without accessing guessed path"

# ------------------------------------------------------------------------------
# TEST 3: Docker inspect 失败／空状态／unknown：不执行配置覆盖及基线启动
# ------------------------------------------------------------------------------
echo ""
echo "========================================================================"
echo " TEST 3: Docker inspect fail / empty / unknown strictly blocks restore"
echo "========================================================================"

T3_DIR="$TEST_BASE_DIR/t3"
mkdir -p "$T3_DIR/backup" "$T3_DIR/prod" "$T3_DIR/bin"
cp "$MOCK_BIN/tunnel-ctl.sh" "$T3_DIR/bin/tunnel-ctl.sh"

cat << EOF > "$T3_DIR/backup/manifest.env"
BACKUP_TS="20261109_120000"
BACKUP_PROD_PROJECT="insurance-carddav-mcp"
BACKUP_PROD_CONTAINER="insurance-carddav-mcp-carddav-1"
BACKUP_PROD_DIR="$T3_DIR/prod"
BACKUP_PROD_DATA_DIR="$T3_DIR/prod/data"
BACKUP_PROD_SECRETS_FILE="$T3_DIR/prod/secrets.env"
BACKUP_PROD_GATEWAY_ENV_FILE="$T3_DIR/prod/gateway.env"
BACKUP_PROD_PORT="17734"
BACKUP_PROD_HEALTH_URL="http://127.0.0.1:17734/health"
BACKUP_ACTUAL_IMAGE_ID="sha256:f3e697fe266f58910c01985f9c906a84479705846c88fd7d2ea1ccf12c0da2f0"
BACKUP_ORIG_COMPOSE_BASENAME="compose.yaml"
BACKUP_SSH_DROPIN_PREEXISTED="0"
BACKUP_SSH_DROPIN_CREATED="0"
EOF
echo "services: {}" > "$T3_DIR/backup/compose.yaml"

test_inspect_barrier() {
  local subtest_name="$1"
  local mock_inspect_mode="$2"

  echo "  [T3-ACT] Testing inspect mode: $mock_inspect_mode ($subtest_name)..."
  # Setup live state with sensitive candidate data
  echo "CANDIDATE_DATA_PRESERVE_ME" > "$T3_DIR/prod/data.txt"
  echo "BASELINE_DATA_RESTORE" > "$T3_DIR/backup/data.txt"

  cat << MOCKINSPECTDOCKER > "$T3_DIR/bin/docker"
#!/usr/bin/env bash
cmd="\$1"
shift || true
case "\$cmd" in
  compose)
    echo "compose called: \$*" >> /tmp/t3_compose.log
    exit 0
    ;;
  stop) exit 0 ;;
  inspect)
    case "$mock_inspect_mode" in
      fail_daemon)
        echo "Error response from daemon: connection refused" >&2
        exit 1
        ;;
      empty_status)
        echo ""
        exit 0
        ;;
      unknown_status)
        echo "unknown"
        exit 0
        ;;
    esac
    ;;
  *) exit 0 ;;
esac
MOCKINSPECTDOCKER
  chmod +x "$T3_DIR/bin/docker"
  rm -f /tmp/t3_compose.log

  set +e
  PATH="$T3_DIR/bin:$MOCK_BIN:$PATH" \
  MACSERVER_TUNNEL_CTL="$T3_DIR/bin/tunnel-ctl.sh" \
  SSH_RELOAD_CMD="true" \
  SEOUL_HEALTH_URL="http://127.0.0.1:17734/health" \
  SEATING_PORT="19765" \
  "$ORCHESTRATED_RECOVERY" "$T3_DIR/backup" > "$T3_DIR/rec_${mock_inspect_mode}.log" 2>&1
  local t3_code=$?
  set -e

  if [ "$t3_code" -ne 1 ]; then
    echo "  [FAIL] Recovery returned 0 on $mock_inspect_mode instead of 1!" >&2
    cat "$T3_DIR/rec_${mock_inspect_mode}.log" >&2
    exit 1
  fi

  if ! grep -q "SAFETY_BARRIER" "$T3_DIR/rec_${mock_inspect_mode}.log"; then
    echo "  [FAIL] SAFETY_BARRIER was NOT engaged on $mock_inspect_mode!" >&2
    cat "$T3_DIR/rec_${mock_inspect_mode}.log" >&2
    exit 1
  fi

  # Assert data.txt was NOT overwritten (rsync skipped)
  local cur_data
  cur_data=$(cat "$T3_DIR/prod/data.txt")
  if [ "$cur_data" != "CANDIDATE_DATA_PRESERVE_ME" ]; then
    echo "  [FAIL] Config overwrite executed on $mock_inspect_mode! Data overwritten: $cur_data" >&2
    exit 1
  fi

  # Assert compose up was NOT executed
  if [ -f /tmp/t3_compose.log ] && grep -q "up" /tmp/t3_compose.log; then
    echo "  [FAIL] compose up was executed on $mock_inspect_mode!" >&2
    exit 1
  fi

  echo "  [PASS] $subtest_name: inspect indeterminate status successfully triggered safety barrier"
}

test_inspect_barrier "Subcase 3a" "fail_daemon"
test_inspect_barrier "Subcase 3b" "empty_status"
test_inspect_barrier "Subcase 3c" "unknown_status"

# ------------------------------------------------------------------------------
# TEST 4: PID 指向同 UID 同名进程，缺失必需身份记录：拒绝发信号
# ------------------------------------------------------------------------------
echo ""
echo "========================================================================"
echo " TEST 4: Same UID, same name process with missing identity record"
echo "========================================================================"

T4_DIR="$TEST_BASE_DIR/t4"
mkdir -p "$T4_DIR"

# 1. Spawn unrelated process with matching name under current UID ($UID)
(
  exec -a "EventKitBridgeServer --unrelated-test" sleep 100
) >/dev/null 2>&1 &
unrelated_pid4=$!
echo "$unrelated_pid4" > "$TEST_BASE_DIR/unrelated_bpid.pid"
echo "  [T4-PRE] Spawned same-UID, same-name EventKitBridgeServer process PID: $unrelated_pid4 (UID: $UID)"

# Subcase 4A: Missing required identity record entirely
echo "$unrelated_pid4" > "$T4_DIR/bridge.pid"
rm -f "$T4_DIR/bridge_identity.env"

set +e
CONFIG_DIR="$T4_DIR" \
BRIDGE_CONFIG_FILE="$T4_DIR/bridge.env" \
BRIDGE_PID_FILE="$T4_DIR/bridge.pid" \
"$TUNNEL_CTL" close-business > "$T4_DIR/ctl_4a.log" 2>&1
t4a_code=$?
set -e

echo "  [T4A-VERIFY] tunnel-ctl close-business exit code with missing identity record: $t4a_code (Expected: 1)"
if [ "$t4a_code" -ne 1 ]; then
  echo "  [FAIL] tunnel-ctl should have refused signaling when identity record is missing!" >&2
  cat "$T4_DIR/ctl_4a.log" >&2
  exit 1
fi

if ! grep -q "Bridge PID fallback requires identity record" "$T4_DIR/ctl_4a.log"; then
  echo "  [FAIL] Missing required record error missing in log!" >&2
  cat "$T4_DIR/ctl_4a.log" >&2
  exit 1
fi

if ! kill -0 "$unrelated_pid4" 2>/dev/null; then
  echo "  [FAIL] Unrelated process $unrelated_pid4 was killed! Collateral damage occurred!" >&2
  exit 1
fi
echo "  [PASS] Subcase 4A: Missing identity record refused signaling; process $unrelated_pid4 unharmed"

# Subcase 4B: Metadata present but launch identity / config mismatched
cat << EOF > "$T4_DIR/bridge_identity.env"
BRIDGE_PID=$unrelated_pid4
BRIDGE_UID=$UID
BRIDGE_CONFIG_FILE=/other/path/different_config.env
BRIDGE_LSTART="Sun Jan 1 00:00:00 2000"
EOF

set +e
CONFIG_DIR="$T4_DIR" \
BRIDGE_CONFIG_FILE="$T4_DIR/bridge.env" \
BRIDGE_PID_FILE="$T4_DIR/bridge.pid" \
"$TUNNEL_CTL" close-business > "$T4_DIR/ctl_4b.log" 2>&1
t4b_code=$?
set -e

echo "  [T4B-VERIFY] tunnel-ctl close-business exit code with launch identity mismatch: $t4b_code (Expected: 1)"
if [ "$t4b_code" -ne 1 ]; then
  echo "  [FAIL] tunnel-ctl should have refused signaling on launch identity mismatch!" >&2
  cat "$T4_DIR/ctl_4b.log" >&2
  exit 1
fi

if ! kill -0 "$unrelated_pid4" 2>/dev/null; then
  echo "  [FAIL] Unrelated process $unrelated_pid4 was killed! Collateral damage occurred!" >&2
  exit 1
fi
echo "  [PASS] Subcase 4B: Launch identity mismatch refused signaling; process $unrelated_pid4 unharmed"

kill -9 "$unrelated_pid4" 2>/dev/null || true
rm -f "$TEST_BASE_DIR/unrelated_bpid.pid"

# ------------------------------------------------------------------------------
# TEST 5: PID/UID/配置目录/期限均匹配旧元数据，但进程启动身份不匹配：拒绝复用
# ------------------------------------------------------------------------------
echo ""
echo "========================================================================"
echo " TEST 5: PID/UID/config/deadline match but launch identity mismatches"
echo "========================================================================"

T5_DIR="$TEST_BASE_DIR/t5"
mkdir -p "$T5_DIR"

(
  exec -a "unrelated-background-daemon" sleep 100
) >/dev/null 2>&1 &
dummy_wpid=$!
echo "$dummy_wpid" > "$TEST_BASE_DIR/dummy_watchdog.pid"
echo "$dummy_wpid" > "$T5_DIR/watchdog.pid"

current_test_epoch=$(( $(date +%s) + 5 ))
cat << EOF > "$T5_DIR/session_deadline.env"
DEADLINE_EPOCH=$current_test_epoch
SESSION_TIMEOUT_SECONDS=5
EOF

# PID, UID, CONFIG_DIR, and DEADLINE_EPOCH all match current task!
# BUT WATCHDOG_LSTART is intentionally set to a fake mismatched start time!
cat << EOF > "$T5_DIR/watchdog_metadata.env"
WATCHDOG_PID=$dummy_wpid
WATCHDOG_UID=$UID
WATCHDOG_USER="${USER:-$(id -un)}"
WATCHDOG_DEADLINE_EPOCH=$current_test_epoch
WATCHDOG_CONFIG_DIR="$T5_DIR"
WATCHDOG_SUPERVISOR_PID=99999
WATCHDOG_LSTART="Sun Jan 1 00:00:00 2000"
EOF

echo "  [T5-ACT] Launching runner with matched PID/UID/config/deadline but mismatched start identity..."
CONFIG_DIR="$T5_DIR" \
SKIP_KEY_CHECK=1 \
REMOTE_HOST="127.0.0.1" \
SSH_BINARY="sleep" \
"$TUNNEL_RUNNER" > "$T5_DIR/runner5.log" 2>&1 &
rpid5=$!

sleep 1.2
kill -9 "$rpid5" 2>/dev/null || true

# Check runner log: must NOT reuse dummy_wpid!
if grep -q "Verified surviving watchdog PID $dummy_wpid" "$T5_DIR/runner5.log"; then
  echo "  [FAIL] Runner falsely reused dummy watchdog despite launch identity mismatch!" >&2
  cat "$T5_DIR/runner5.log" >&2
  exit 1
fi

if grep -q "attribution mismatch" "$T5_DIR/runner5.log"; then
  echo "  [PASS] Runner detected launch identity mismatch and refused to reuse unverified watchdog"
else
  echo "  [FAIL] Runner did not log attribution mismatch warning!" >&2
  cat "$T5_DIR/runner5.log" >&2
  exit 1
fi

# The dummy process must NOT have been killed by supervisor
if ! kill -0 "$dummy_wpid" 2>/dev/null; then
  echo "  [FAIL] Dummy unrelated process was killed by supervisor!" >&2
  exit 1
fi
echo "  [PASS] Dummy unrelated process is STILL ALIVE (unverified watchdog not signaled)"

# Verify a fresh watchdog was spawned with genuine identity
new_wpid=$(cat "$T5_DIR/watchdog.pid" 2>/dev/null || echo "")
if [ "$new_wpid" = "$dummy_wpid" ]; then
  echo "  [FAIL] watchdog.pid still points to dummy PID!" >&2
  exit 1
fi
echo "  [PASS] Fresh watchdog spawned (PID: $new_wpid != dummy $dummy_wpid)"

kill -9 "$dummy_wpid" 2>/dev/null || true
rm -f "$TEST_BASE_DIR/dummy_watchdog.pid"

# ==============================================================================
# ALL 5 TARGETED SAFETY BOUNDARY TESTS PASSED
# ==============================================================================
echo ""
echo "========================================================================"
echo " [ALL SAFETY BOUNDARY TESTS PASSED] 5/5 Negative Tests Passed 100%"
echo " - Test 1: authorized_keys backup failure blocks deployment before changes"
echo " - Test 2: Target user home/.ssh exists but sshd config unresolvable: refused deploy"
echo " - Test 3: Docker inspect fail/empty/unknown strictly blocks restore"
echo " - Test 4: Same UID/name with missing or mismatched identity record: refuses signal"
echo " - Test 5: PID/UID/config/deadline matched but launch identity mismatched: refuses reuse"
echo "========================================================================"
exit 0
