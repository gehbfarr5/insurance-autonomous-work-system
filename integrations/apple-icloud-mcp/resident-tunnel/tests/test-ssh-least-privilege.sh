#!/usr/bin/env bash
# test-ssh-least-privilege.sh
# AG-05 | Automated Isolated Test Suite for SSH Least Privilege Verification
#
# Validates:
# 1. Shell access is strictly denied (ForceCommand /bin/false / command="/bin/false")
# 2. Arbitrary command execution is strictly denied
# 3. Unapproved remote port forwarding is rejected (permitlisten restriction)
# 4. Approved port forwarding succeeds without granting interactive privileges

set -euo pipefail

TEST_DIR="$(mktemp -d -t ag05_ssh_least_priv_XXXXXX)"
SSH_PORT="22244"
LISTEN_PORT="18765"
FORBIDDEN_PORT="19999"

cleanup() {
  echo "--- Cleaning up SSH test harness ---"
  if [ -f "$TEST_DIR/sshd.pid" ]; then
    local p
    p=$(cat "$TEST_DIR/sshd.pid" 2>/dev/null || true)
    if [ -n "$p" ] && kill -0 "$p" 2>/dev/null; then
      kill -9 "$p" 2>/dev/null || true
    fi
  fi
  # Kill any process listening on SSH_PORT
  lsof -ti :"$SSH_PORT" | xargs kill -9 2>/dev/null || true
  rm -rf "$TEST_DIR"
}
trap cleanup EXIT

echo "=== AG-05 SSH Least-Privilege Isolated Test Suite ==="
echo "Test working directory: $TEST_DIR"

# 1. Generate ephemeral host key and client identity key
ssh-keygen -t ed25519 -N "" -f "$TEST_DIR/host_key" >/dev/null 2>&1
ssh-keygen -t ed25519 -N "" -f "$TEST_DIR/client_key" >/dev/null 2>&1

USER_NAME=$(id -un)
PUB_KEY=$(cat "$TEST_DIR/client_key.pub")

# 2. Configure authorized_keys with hardened least-privilege options matching production template
cat << EOF > "$TEST_DIR/authorized_keys"
restrict,port-forwarding,permitlisten="127.0.0.1:$LISTEN_PORT",command="/bin/false",no-pty,no-X11-forwarding,no-agent-forwarding $PUB_KEY
EOF
chmod 600 "$TEST_DIR/authorized_keys"

# 3. Configure isolated sshd_config
cat << EOF > "$TEST_DIR/sshd_config"
Port $SSH_PORT
ListenAddress 127.0.0.1
HostKey $TEST_DIR/host_key
AuthorizedKeysFile $TEST_DIR/authorized_keys
StrictModes no
UsePAM no
AllowTcpForwarding yes
GatewayPorts clientspecified
PidFile $TEST_DIR/sshd.pid
LogLevel VERBOSE
EOF

# Verify configuration syntax
/usr/sbin/sshd -t -f "$TEST_DIR/sshd_config"

# Start isolated sshd daemon
/usr/sbin/sshd -f "$TEST_DIR/sshd_config"

# Wait for sshd to listen
waited=0
while ! nc -z 127.0.0.1 "$SSH_PORT" 2>/dev/null && [ "$waited" -lt 20 ]; do
  sleep 0.2
  waited=$((waited + 1))
done

if ! nc -z 127.0.0.1 "$SSH_PORT" 2>/dev/null; then
  echo "FAIL: Isolated sshd did not start on port $SSH_PORT"
  exit 1
fi
echo "[OK] Ephemeral sshd listening on 127.0.0.1:$SSH_PORT"

SSH_COMMON_OPTS=(
  -i "$TEST_DIR/client_key"
  -p "$SSH_PORT"
  -o StrictHostKeyChecking=no
  -o UserKnownHostsFile=/dev/null
  -o ConnectTimeout=5
  -o BatchMode=yes
  -o LogLevel=ERROR
)

# Test 1: Interactive Shell Rejection
echo "--> Test 1: Verifying interactive shell access is DENIED..."
set +e
ssh "${SSH_COMMON_OPTS[@]}" "$USER_NAME@127.0.0.1" > "$TEST_DIR/shell_out.log" 2>&1
shell_code=$?
set -e

if [ "$shell_code" -ne 0 ]; then
  echo "  [PASS] Interactive shell rejected with non-zero exit code ($shell_code)."
else
  echo "FAIL: Interactive shell succeeded unexpectedly!"
  cat "$TEST_DIR/shell_out.log"
  exit 1
fi

# Test 2: Arbitrary Command Execution Rejection
echo "--> Test 2: Verifying arbitrary command execution is DENIED..."
set +e
ssh "${SSH_COMMON_OPTS[@]}" "$USER_NAME@127.0.0.1" "id && uname -a" > "$TEST_DIR/cmd_out.log" 2>&1
cmd_code=$?
set -e

if [ "$cmd_code" -ne 0 ] && ! grep -q "uid=" "$TEST_DIR/cmd_out.log"; then
  echo "  [PASS] Arbitrary command execution rejected (code: $cmd_code, command output empty/blocked)."
else
  echo "FAIL: Arbitrary command succeeded or returned uid!"
  cat "$TEST_DIR/cmd_out.log"
  exit 1
fi

# Test 3: Unapproved Port Forwarding Rejection
echo "--> Test 3: Verifying unapproved port forwarding is REJECTED..."
set +e
ssh "${SSH_COMMON_OPTS[@]}" \
  -N -T \
  -o ExitOnForwardFailure=yes \
  -R "127.0.0.1:$FORBIDDEN_PORT:127.0.0.1:18765" \
  "$USER_NAME@127.0.0.1" > "$TEST_DIR/forbidden_fwd.log" 2>&1 &
FWD_PID=$!
sleep 1.5
set -e

if kill -0 "$FWD_PID" 2>/dev/null; then
  kill -9 "$FWD_PID" 2>/dev/null || true
  echo "FAIL: Unapproved port forward unexpectedly stayed open!"
  exit 1
fi
echo "  [PASS] Unapproved port forward on port $FORBIDDEN_PORT was rejected by permitlisten."

# Test 4: Approved Port Forwarding Succeeded in -N -T Mode
echo "--> Test 4: Verifying approved port forwarding on $LISTEN_PORT SUCCEEDS..."
ssh "${SSH_COMMON_OPTS[@]}" \
  -N -T \
  -o ExitOnForwardFailure=yes \
  -R "127.0.0.1:$LISTEN_PORT:127.0.0.1:18765" \
  "$USER_NAME@127.0.0.1" > "$TEST_DIR/approved_fwd.log" 2>&1 &
APPROVED_PID=$!
sleep 1.5

if kill -0 "$APPROVED_PID" 2>/dev/null; then
  echo "  [PASS] Approved reverse port forward active and running under PID $APPROVED_PID."
  kill -TERM "$APPROVED_PID" 2>/dev/null || true
  wait "$APPROVED_PID" 2>/dev/null || true
else
  echo "FAIL: Approved port forward exited prematurely!"
  cat "$TEST_DIR/approved_fwd.log"
  exit 1
fi

echo "=== All SSH Least-Privilege & Hardening Tests PASSED ==="
