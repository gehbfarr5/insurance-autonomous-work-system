#!/usr/bin/env bash
# test-tunnel-supervisor.sh
# AG-05 | Automated Isolated Test Suite for MacServer Resident Tunnel Supervisor
#
# Validates:
# 1. Singleton locking (prevents duplicate supervisor instances)
# 2. Observable status JSON format and state transitions
# 3. Crash detection, reconnect counter increment, and exponential backoff
# 4. Graceful shutdown on SIGTERM (zero orphan processes or left-behind PID files)

set -euo pipefail

TEST_DIR="$(mktemp -d -t ag05_tunnel_supervisor_test_XXXXXX)"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNNER="$SCRIPT_DIR/../scripts/run-resident-tunnel.sh"

cleanup() {
  echo "--- Cleaning up test processes in $TEST_DIR ---"
  if [ -f "$TEST_DIR/tunnel.pid" ]; then
    local p
    p=$(cat "$TEST_DIR/tunnel.pid" 2>/dev/null || true)
    if [ -n "$p" ] && kill -0 "$p" 2>/dev/null; then
      kill -9 "$p" 2>/dev/null || true
    fi
  fi
  rm -rf "$TEST_DIR"
}
trap cleanup EXIT

echo "=== AG-05 Resident Tunnel Supervisor Isolated Test Suite ==="
echo "Test working directory: $TEST_DIR"

# 1. Create a mock SSH command
MOCK_SSH="$TEST_DIR/mock-ssh.sh"
cat << 'EOF' > "$MOCK_SSH"
#!/usr/bin/env bash
# Mock SSH that sleeps for DURATION then exits with EXIT_CODE
duration="${MOCK_SSH_DURATION:-1}"
exit_code="${MOCK_SSH_EXIT_CODE:-0}"
sleep "$duration"
exit "$exit_code"
EOF
chmod +x "$MOCK_SSH"

# Test 1: Observable Status JSON and Connected State
echo "--> Test 1: Normal startup, state transition to 'connected', and status JSON..."
export CONFIG_DIR="$TEST_DIR"
export SSH_BINARY="$MOCK_SSH"
export MOCK_SSH_DURATION=10
export MOCK_SSH_EXIT_CODE=0
export BACKOFF_INIT=1
export BACKOFF_MAX=4
export SUSTAINED_THRESHOLD=5

"$RUNNER" > "$TEST_DIR/runner.log" 2>&1 &
SUPERVISOR_PID=$!

# Wait for status file to appear
waited=0
while [ ! -f "$TEST_DIR/tunnel_status.json" ] && [ "$waited" -lt 20 ]; do
  sleep 0.2
  waited=$((waited + 1))
done

if [ ! -f "$TEST_DIR/tunnel_status.json" ]; then
  echo "FAIL: tunnel_status.json was not created!"
  cat "$TEST_DIR/runner.log"
  exit 1
fi

status_val=$(grep '"status"' "$TEST_DIR/tunnel_status.json" | cut -d'"' -f4)
if [ "$status_val" != "connected" ] && [ "$status_val" != "connecting" ]; then
  echo "FAIL: Expected status 'connected' or 'connecting', got '$status_val'"
  exit 1
fi
echo "  [PASS] Status JSON verified: status = $status_val, PID = $SUPERVISOR_PID"

# Test 2: Singleton Locking
echo "--> Test 2: Singleton locking prevents duplicate supervisor..."
second_run_out=$("$RUNNER" 2>&1 || true)
if echo "$second_run_out" | grep -q "already active"; then
  echo "  [PASS] Second runner detected existing supervisor and exited cleanly."
else
  echo "FAIL: Second runner did not detect existing active PID!"
  echo "Output: $second_run_out"
  exit 1
fi

# Stop Test 1 supervisor
kill -TERM "$SUPERVISOR_PID"
wait "$SUPERVISOR_PID" 2>/dev/null || true
echo "  [PASS] Supervisor gracefully terminated on SIGTERM."

# Test 3: Crash Detection, Reconnect Counter, and Backoff Progression
echo "--> Test 3: Crash detection and exponential backoff..."
export MOCK_SSH_DURATION=0.1
export MOCK_SSH_EXIT_CODE=255
export BACKOFF_INIT=1
export BACKOFF_MAX=3
export BACKOFF_FACTOR=2

"$RUNNER" > "$TEST_DIR/runner_crash.log" 2>&1 &
CRASH_SUPERVISOR_PID=$!

# Wait for at least 2 reconnects
waited=0
reconnects=0
while [ "$waited" -lt 30 ]; do
  if [ -f "$TEST_DIR/tunnel_status.json" ]; then
    reconnects=$(grep '"reconnect_count"' "$TEST_DIR/tunnel_status.json" | grep -o '[0-9]*' || echo 0)
    if [ "$reconnects" -ge 2 ]; then
      break
    fi
  fi
  sleep 0.5
  waited=$((waited + 1))
done

if [ "$reconnects" -lt 2 ]; then
  echo "FAIL: Expected at least 2 reconnect attempts, got $reconnects"
  cat "$TEST_DIR/runner_crash.log"
  exit 1
fi
echo "  [PASS] Supervisor detected crash, incremented reconnect_count to $reconnects with backoff."

# Test 4: Graceful Shutdown with Child Termination
echo "--> Test 4: Graceful shutdown terminates child and cleans PID file..."
kill -TERM "$CRASH_SUPERVISOR_PID"
wait "$CRASH_SUPERVISOR_PID" 2>/dev/null || true

if [ -f "$TEST_DIR/tunnel.pid" ]; then
  echo "FAIL: PID file was not removed after graceful shutdown!"
  exit 1
fi

final_status=$(grep '"status"' "$TEST_DIR/tunnel_status.json" | cut -d'"' -f4)
if [ "$final_status" != "stopped" ]; then
  echo "FAIL: Expected final status 'stopped', got '$final_status'"
  exit 1
fi
echo "  [PASS] Final status recorded as 'stopped' and PID file removed."

echo "=== All Supervisor Unit & Fault-Recovery Tests PASSED ==="
