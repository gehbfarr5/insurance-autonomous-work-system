#!/bin/bash
set -euo pipefail

# ======================================================================
# AG-05 Final Candidate Delivery Acceptance Test Suite
# Tests items 1-4 of the final acceptance checklist using real delivery scripts,
# isolated SSH, Fake Bridge, and synthetic configurations.
# ======================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESIDENT_TUNNEL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
RUNNER_SCRIPT="$RESIDENT_TUNNEL_DIR/scripts/run-resident-tunnel.sh"
CTL_SCRIPT="$RESIDENT_TUNNEL_DIR/scripts/tunnel-ctl.sh"

TEST_BASE="$(mktemp -d /tmp/ag05-final-acceptance-XXXXXX)"
SSHD_PORT=22288
BRIDGE_PORT=18789
FORWARD_PORT=18769

cleanup_all() {
  echo ""
  echo "--- [CLEANUP] Tearing down acceptance test processes ---"
  if [ -n "${ACCEPT_SUPERVISOR_PID:-}" ] && kill -0 "$ACCEPT_SUPERVISOR_PID" 2>/dev/null; then
    kill -9 "$ACCEPT_SUPERVISOR_PID" 2>/dev/null || true
  fi
  if [ -n "${ACCEPT_BRIDGE_PID:-}" ] && kill -0 "$ACCEPT_BRIDGE_PID" 2>/dev/null; then
    kill -9 "$ACCEPT_BRIDGE_PID" 2>/dev/null || true
  fi
  if [ -n "${ACCEPT_SSHD_PID:-}" ] && kill -0 "$ACCEPT_SSHD_PID" 2>/dev/null; then
    kill -9 "$ACCEPT_SSHD_PID" 2>/dev/null || true
  fi
  rm -rf "$TEST_BASE"
  echo "--- [CLEANUP] Completed cleanly. ---"
}
trap cleanup_all EXIT

echo "========================================================================"
echo " AG-05 FINAL DELIVERY CANDIDATE ACCEPTANCE"
echo " Time: $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
echo " Staging Base: $TEST_BASE"
echo "========================================================================"

# Step 0: Set up SSH server and synthetic keys
SSH_DIR="$TEST_BASE/sshd"
mkdir -p "$SSH_DIR"
ssh-keygen -t ed25519 -f "$SSH_DIR/host_key" -N "" -q
ssh-keygen -t ed25519 -f "$SSH_DIR/client_key" -N "" -q
CLIENT_PUB=$(cat "$SSH_DIR/client_key.pub")
USER_NAME="$(id -un)"

cat << EOF > "$SSH_DIR/authorized_keys"
permitlisten="127.0.0.1:$FORWARD_PORT" $CLIENT_PUB
EOF
chmod 600 "$SSH_DIR/authorized_keys" "$SSH_DIR/host_key" "$SSH_DIR/client_key"

HOST_KEY_PUB=$(cat "$SSH_DIR/host_key.pub")
cat << EOF > "$SSH_DIR/known_hosts"
[127.0.0.1]:$SSHD_PORT $HOST_KEY_PUB
EOF
chmod 600 "$SSH_DIR/known_hosts"

cat << EOF > "$SSH_DIR/sshd_config"
Port $SSHD_PORT
ListenAddress 127.0.0.1
HostKey $SSH_DIR/host_key
AuthorizedKeysFile $SSH_DIR/authorized_keys
StrictModes no
UsePAM no
PasswordAuthentication no
PubkeyAuthentication yes
PermitTTY no
AllowTcpForwarding yes
GatewayPorts clientspecified
X11Forwarding no
PidFile $SSH_DIR/sshd.pid
EOF

$(which sshd) -f "$SSH_DIR/sshd_config" -D > "$SSH_DIR/sshd.log" 2>&1 &
ACCEPT_SSHD_PID=$!

waited=0
while ! nc -z 127.0.0.1 "$SSHD_PORT" 2>/dev/null && [ "$waited" -lt 25 ]; do
  sleep 0.2
  waited=$((waited + 1))
done
echo "[OK] Isolated OpenSSH server running on 127.0.0.1:$SSHD_PORT (PID: $ACCEPT_SSHD_PID)"

# ========================================================================
# ACCEPTANCE ITEM 1: Non-deadline isolated startup enters normal supervision loop
# ========================================================================
echo ""
echo "========================================================================"
echo " ACCEPTANCE 1: Non-deadline isolated startup enters supervision loop"
echo "========================================================================"
V1_DIR="$TEST_BASE/v1"
mkdir -p "$V1_DIR"

# Launch Fake Bridge for V1
node -e "
import http from 'node:http';
const server = http.createServer((req, res) => {
  if (req.url === '/health') {
    res.writeHead(200, { 'Content-Type': 'application/json' });
    return res.end(JSON.stringify({ status: 'ok' }));
  }
  res.writeHead(404);
  res.end();
});
server.listen($BRIDGE_PORT, '127.0.0.1', () => console.log('Bridge ready'));
" > "$V1_DIR/fake_bridge.log" 2>&1 &
ACCEPT_BRIDGE_PID=$!

waited=0
while ! nc -z 127.0.0.1 "$BRIDGE_PORT" 2>/dev/null && [ "$waited" -lt 25 ]; do
  sleep 0.2
  waited=$((waited + 1))
done

cat << EOF > "$V1_DIR/tunnel.conf"
REMOTE_HOST="127.0.0.1"
REMOTE_PORT="$SSHD_PORT"
REMOTE_USER="$USER_NAME"
IDENTITY_FILE="$SSH_DIR/client_key"
KNOWN_HOSTS_FILE="$SSH_DIR/known_hosts"
REMOTE_BINDS="-R 127.0.0.1:$FORWARD_PORT:127.0.0.1:$BRIDGE_PORT"
STATUS_FILE="$V1_DIR/tunnel_status.json"
PID_FILE="$V1_DIR/tunnel.pid"
LOG_FILE="$V1_DIR/tunnel.log"
LOCK_DIR="$V1_DIR/tunnel.lock"
BACKOFF_INIT=1
BACKOFF_MAX=4
BACKOFF_FACTOR=2
SUSTAINED_THRESHOLD=3
BRIDGE_PROBE_URL="http://127.0.0.1:$BRIDGE_PORT/health"
SESSION_TIMEOUT_SECONDS=0
SKIP_KEY_CHECK=0
EOF

CONFIG_DIR="$V1_DIR" "$RUNNER_SCRIPT" > "$V1_DIR/runner.log" 2>&1 &
ACCEPT_SUPERVISOR_PID=$!

waited=0
while ! nc -z 127.0.0.1 "$FORWARD_PORT" 2>/dev/null && [ "$waited" -lt 30 ]; do
  sleep 0.2
  waited=$((waited + 1))
done

if ! nc -z 127.0.0.1 "$FORWARD_PORT" 2>/dev/null; then
  echo "FAIL [V1]: Reverse forward port $FORWARD_PORT did not open!"
  echo "--- runner.log ---"
  cat "$V1_DIR/runner.log" || true
  echo "--- tunnel.log ---"
  cat "$V1_DIR/tunnel.log" || true
  exit 1
fi

# Verify status & health
v1_status=$(CONFIG_DIR="$V1_DIR" "$CTL_SCRIPT" status)
echo "$v1_status"
if ! echo "$v1_status" | grep -q "Supervisor is RUNNING"; then
  echo "FAIL [V1]: Supervisor not reported running by tunnel-ctl.sh!"
  exit 1
fi

v1_health=$(CONFIG_DIR="$V1_DIR" "$CTL_SCRIPT" health)
echo "$v1_health"
if ! echo "$v1_health" | grep -q "HEALTH: OK"; then
  echo "FAIL [V1]: Health check did not return HEALTH: OK!"
  exit 1
fi

# Confirm no watchdog spawned when timeout=0
if [ -f "$V1_DIR/watchdog.pid" ]; then
  echo "FAIL [V1]: watchdog.pid should not exist when SESSION_TIMEOUT_SECONDS=0!"
  exit 1
fi
echo "  [PASS] Acceptance 1: Non-deadline isolated startup entered normal supervision loop."

# Clean up V1 supervisor and bridge
CONFIG_DIR="$V1_DIR" "$CTL_SCRIPT" stop
wait "$ACCEPT_SUPERVISOR_PID" 2>/dev/null || true
ACCEPT_SUPERVISOR_PID=""
kill "$ACCEPT_BRIDGE_PID" 2>/dev/null || true
wait "$ACCEPT_BRIDGE_PID" 2>/dev/null || true
ACCEPT_BRIDGE_PID=""
sleep 0.5

# ========================================================================
# ACCEPTANCE ITEM 2 & 3: Restricted startup with absolute deadline,
# establishing watchdog, running, and autonomous business shutdown on timeout.
# ========================================================================
echo ""
echo "========================================================================"
echo " ACCEPTANCE 2 & 3: Restricted startup with deadline -> watchdog -> timeout 403"
echo "========================================================================"
V2_DIR="$TEST_BASE/v2"
mkdir -p "$V2_DIR"

# Stateful Fake Bridge supporting reload and business endpoint
cat << 'EOF' > "$V2_DIR/fake_bridge.mjs"
import http from 'node:http';
import fs from 'node:fs';

const configPath = process.env.BRIDGE_CONFIG_FILE;
function isAuthorized() {
  if (!fs.existsSync(configPath)) return false;
  const content = fs.readFileSync(configPath, 'utf8');
  return content.includes('EVENTKIT_BRIDGE_PRODUCTION_AUTHORIZED=true');
}

const server = http.createServer((req, res) => {
  if (req.url === '/health') {
    res.writeHead(200, { 'Content-Type': 'application/json' });
    return res.end(JSON.stringify({ status: 'ok' }));
  }
  if (req.url === '/reminders/lists') {
    if (!isAuthorized()) {
      res.writeHead(403, { 'Content-Type': 'application/json' });
      return res.end(JSON.stringify({ error: { code: 'PERMISSION_DENIED', message: 'Read-only trial expired' } }));
    }
    res.writeHead(200, { 'Content-Type': 'application/json' });
    return res.end(JSON.stringify([{ listID: '00000000-0000-0000-0000-000000000001', title: 'Acceptance List' }]));
  }
  res.writeHead(404);
  res.end();
});

const port = parseInt(process.env.BRIDGE_PORT || '18789', 10);
server.listen(port, '127.0.0.1', () => console.log('Stateful bridge listening'));
EOF

cat << EOF > "$V2_DIR/bridge.env"
EVENTKIT_BRIDGE_PRODUCTION_AUTHORIZED=true
EVENTKIT_BRIDGE_BEARER_TOKEN="acceptance-token-12345"
EOF
chmod 600 "$V2_DIR/bridge.env"

BRIDGE_CONFIG_FILE="$V2_DIR/bridge.env" BRIDGE_PORT="$BRIDGE_PORT" node "$V2_DIR/fake_bridge.mjs" > "$V2_DIR/bridge.log" 2>&1 &
ACCEPT_BRIDGE_PID=$!

echo "$ACCEPT_BRIDGE_PID" > "$V2_DIR/bridge.pid"
b_lstart=$(ps -p "$ACCEPT_BRIDGE_PID" -o lstart= 2>/dev/null | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' || echo "")
cat << EOF > "$V2_DIR/bridge_identity.env"
BRIDGE_PID=$ACCEPT_BRIDGE_PID
BRIDGE_UID=$UID
BRIDGE_USER="$(id -un)"
BRIDGE_CONFIG_FILE="$V2_DIR/bridge.env"
BRIDGE_LSTART="$b_lstart"
EOF
chmod 600 "$V2_DIR/bridge.pid" "$V2_DIR/bridge_identity.env"

waited=0
while ! nc -z 127.0.0.1 "$BRIDGE_PORT" 2>/dev/null && [ "$waited" -lt 25 ]; do
  sleep 0.2
  waited=$((waited + 1))
done

# Pre-test query: business endpoint must return 200 initially
pre_code=$(curl -s -m 2 -o /dev/null -w "%{http_code}" -H "Authorization: Bearer acceptance-token-12345" "http://127.0.0.1:$BRIDGE_PORT/reminders/lists" || echo "000")
if [ "$pre_code" != "200" ]; then
  echo "FAIL [V2]: Initial business endpoint query returned $pre_code (expected 200)!"
  exit 1
fi
echo "  [OK] Pre-timeout business endpoint verified HTTP 200."

# Configure restricted runner with 4-second timeout
cat << EOF > "$V2_DIR/tunnel.conf"
REMOTE_HOST="127.0.0.1"
REMOTE_PORT="$SSHD_PORT"
REMOTE_USER="$USER_NAME"
IDENTITY_FILE="$SSH_DIR/client_key"
KNOWN_HOSTS_FILE="$SSH_DIR/known_hosts"
REMOTE_BINDS="-R 127.0.0.1:$FORWARD_PORT:127.0.0.1:$BRIDGE_PORT"
STATUS_FILE="$V2_DIR/tunnel_status.json"
PID_FILE="$V2_DIR/tunnel.pid"
LOG_FILE="$V2_DIR/tunnel.log"
LOCK_DIR="$V2_DIR/tunnel.lock"
BACKOFF_INIT=1
BACKOFF_MAX=4
BACKOFF_FACTOR=2
SUSTAINED_THRESHOLD=3
BRIDGE_PROBE_URL="http://127.0.0.1:$BRIDGE_PORT/health"
SESSION_TIMEOUT_SECONDS=4
SKIP_KEY_CHECK=0
BRIDGE_CONFIG_FILE="$V2_DIR/bridge.env"
BRIDGE_PID_FILE="$V2_DIR/bridge.pid"
BRIDGE_BUSINESS_URL="http://127.0.0.1:$BRIDGE_PORT/reminders/lists"
BRIDGE_TOKEN="acceptance-token-12345"
EOF

CONFIG_DIR="$V2_DIR" "$RUNNER_SCRIPT" > "$V2_DIR/runner.log" 2>&1 &
ACCEPT_SUPERVISOR_PID=$!

# Wait for forward port to establish
waited=0
while ! nc -z 127.0.0.1 "$FORWARD_PORT" 2>/dev/null && [ "$waited" -lt 25 ]; do
  sleep 0.2
  waited=$((waited + 1))
done

# Assert Acceptance 2: Watchdog established, connection complete, running
if [ ! -f "$V2_DIR/watchdog.pid" ]; then
  echo "FAIL [V2]: Watchdog PID file missing!"
  exit 1
fi
W_PID=$(cat "$V2_DIR/watchdog.pid")
if ! kill -0 "$W_PID" 2>/dev/null; then
  echo "FAIL [V2]: Watchdog process $W_PID is not running!"
  exit 1
fi
echo "  [PASS] Acceptance 2: Restricted startup established watchdog (PID: $W_PID), connected SSH, and is running."

# Wait for 4-second timeout to trigger autonomous shutdown
echo "  [INFO] Waiting for 4-second session deadline to expire..."
wait "$ACCEPT_SUPERVISOR_PID" 2>/dev/null || true
ACCEPT_SUPERVISOR_PID=""

# Assert Acceptance 3:
# a) bridge.env switch is false
if ! grep -q "EVENTKIT_BRIDGE_PRODUCTION_AUTHORIZED=false" "$V2_DIR/bridge.env"; then
  echo "FAIL [V3]: bridge.env did NOT persist EVENTKIT_BRIDGE_PRODUCTION_AUTHORIZED=false!"
  cat "$V2_DIR/bridge.env"
  exit 1
fi
echo "  [PASS] Acceptance 3a: bridge.env switch persisted to false."

# b) business endpoint returns HTTP 403
post_code=$(curl -s -m 2 -o /dev/null -w "%{http_code}" -H "Authorization: Bearer acceptance-token-12345" "http://127.0.0.1:$BRIDGE_PORT/reminders/lists" || echo "000")
if [ "$post_code" != "403" ]; then
  echo "FAIL [V3]: Business endpoint query returned HTTP $post_code (expected 403)!"
  exit 1
fi
echo "  [PASS] Acceptance 3b: Business endpoint returned HTTP 403 (Safe Mode Active)."

# c) supervisor is terminated
if [ -f "$V2_DIR/tunnel.pid" ]; then
  s_pid=$(cat "$V2_DIR/tunnel.pid" 2>/dev/null || true)
  if [ -n "$s_pid" ] && kill -0 "$s_pid" 2>/dev/null; then
    echo "FAIL [V3]: Supervisor $s_pid is still running after timeout!"
    exit 1
  fi
fi
echo "  [PASS] Acceptance 3c: Supervisor cleanly exited on deadline expiry."

# Clean up V2 bridge
kill "$ACCEPT_BRIDGE_PID" 2>/dev/null || true
wait "$ACCEPT_BRIDGE_PID" 2>/dev/null || true
ACCEPT_BRIDGE_PID=""
sleep 0.5

# ========================================================================
# ACCEPTANCE ITEM 4: Manual stop via tunnel-ctl.sh stop leaves no residual
# processes or lock files
# ========================================================================
echo ""
echo "========================================================================"
echo " ACCEPTANCE 4: Manual stop -> zero residual processes & lock files"
echo "========================================================================"
V4_DIR="$TEST_BASE/v4"
mkdir -p "$V4_DIR"

# Launch Fake Bridge for V4
node -e "
import http from 'node:http';
const server = http.createServer((req, res) => {
  if (req.url === '/health') {
    res.writeHead(200, { 'Content-Type': 'application/json' });
    return res.end(JSON.stringify({ status: 'ok' }));
  }
  res.writeHead(404);
  res.end();
});
server.listen($BRIDGE_PORT, '127.0.0.1', () => console.log('Bridge ready'));
" > "$V4_DIR/fake_bridge.log" 2>&1 &
ACCEPT_BRIDGE_PID=$!

waited=0
while ! nc -z 127.0.0.1 "$BRIDGE_PORT" 2>/dev/null && [ "$waited" -lt 25 ]; do
  sleep 0.2
  waited=$((waited + 1))
done

cat << EOF > "$V4_DIR/tunnel.conf"
REMOTE_HOST="127.0.0.1"
REMOTE_PORT="$SSHD_PORT"
REMOTE_USER="$USER_NAME"
IDENTITY_FILE="$SSH_DIR/client_key"
KNOWN_HOSTS_FILE="$SSH_DIR/known_hosts"
REMOTE_BINDS="-R 127.0.0.1:$FORWARD_PORT:127.0.0.1:$BRIDGE_PORT"
STATUS_FILE="$V4_DIR/tunnel_status.json"
PID_FILE="$V4_DIR/tunnel.pid"
LOG_FILE="$V4_DIR/tunnel.log"
LOCK_DIR="$V4_DIR/tunnel.lock"
BACKOFF_INIT=1
BACKOFF_MAX=4
BACKOFF_FACTOR=2
SUSTAINED_THRESHOLD=3
BRIDGE_PROBE_URL="http://127.0.0.1:$BRIDGE_PORT/health"
SESSION_TIMEOUT_SECONDS=60
SKIP_KEY_CHECK=0
EOF

CONFIG_DIR="$V4_DIR" "$RUNNER_SCRIPT" > "$V4_DIR/runner.log" 2>&1 &
ACCEPT_SUPERVISOR_PID=$!

waited=0
while ! nc -z 127.0.0.1 "$FORWARD_PORT" 2>/dev/null && [ "$waited" -lt 25 ]; do
  sleep 0.2
  waited=$((waited + 1))
done

# Grab child SSH and Watchdog PIDs before stop
v4_child_ssh=$(grep '"child_ssh_pid"' "$V4_DIR/tunnel_status.json" | grep -o '[0-9]*' || echo "")
v4_watchdog=$(cat "$V4_DIR/watchdog.pid" 2>/dev/null || echo "")

echo "  [INFO] Active PIDs: Supervisor=$ACCEPT_SUPERVISOR_PID, SSH=$v4_child_ssh, Watchdog=$v4_watchdog"

# Execute manual stop via tunnel-ctl.sh stop
CONFIG_DIR="$V4_DIR" "$CTL_SCRIPT" stop
wait "$ACCEPT_SUPERVISOR_PID" 2>/dev/null || true
ACCEPT_SUPERVISOR_PID=""

# Assert all processes are dead
if [ -n "$v4_child_ssh" ] && kill -0 "$v4_child_ssh" 2>/dev/null; then
  echo "FAIL [V4]: Child SSH $v4_child_ssh is still running after tunnel-ctl.sh stop!"
  exit 1
fi
if [ -n "$v4_watchdog" ] && kill -0 "$v4_watchdog" 2>/dev/null; then
  echo "FAIL [V4]: Watchdog $v4_watchdog is still running after tunnel-ctl.sh stop!"
  exit 1
fi

# Assert lock directory and PID files are removed
if [ -d "$V4_DIR/tunnel.lock" ]; then
  echo "FAIL [V4]: Lock directory $V4_DIR/tunnel.lock still exists!"
  exit 1
fi
if [ -f "$V4_DIR/tunnel.pid" ]; then
  echo "FAIL [V4]: PID file $V4_DIR/tunnel.pid still exists!"
  exit 1
fi

echo "  [PASS] Acceptance 4: Manual stop cleanly terminated supervisor, SSH, and watchdog; zero residual lock files."

# Clean up V4 bridge
kill "$ACCEPT_BRIDGE_PID" 2>/dev/null || true
wait "$ACCEPT_BRIDGE_PID" 2>/dev/null || true
ACCEPT_BRIDGE_PID=""

echo ""
echo "========================================================================"
echo " [ALL 4 ACCEPTANCE TESTS PASSED 100%]"
echo "========================================================================"
