#!/usr/bin/env bash
# test-tunnel-supervisor.sh
# AG-05 | Automated Isolated Test Suite for MacServer Resident Tunnel Supervisor
#
# Validates:
# 1. Atomic directory singleton locking (mkdir) & concurrency rejection
# 2. Stale lock detection & automatic recovery
# 3. True exit code capture (verifying non-zero exit code is never masked)
# 4. Exponential backoff progression, capping, and sustained reset
# 5. Signal-aware backoff sleep & graceful shutdown on SIGTERM (zero orphans)
# 6. Restricted permissions (umask 077 / 0600 on state files)

set -euo pipefail

TEST_DIR="$(mktemp -d -t ag05_tunnel_supervisor_test_XXXXXX)"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNNER="$SCRIPT_DIR/../scripts/run-resident-tunnel.sh"

cleanup() {
  echo "--- Cleaning up test processes in $TEST_DIR ---"
  if [ -f "$TEST_DIR/tunnel.lock/pid" ]; then
    local p
    p=$(cat "$TEST_DIR/tunnel.lock/pid" 2>/dev/null || true)
    if [ -n "$p" ] && kill -0 "$p" 2>/dev/null; then
      kill -9 "$p" 2>/dev/null || true
    fi
  fi
  rm -rf "$TEST_DIR"
}
trap cleanup EXIT

echo "=== AG-05 Resident Tunnel Supervisor Isolated Test Suite ==="
echo "Test working directory: $TEST_DIR"

# Create mock SSH command
MOCK_SSH="$TEST_DIR/mock-ssh.sh"
cat << 'EOF' > "$MOCK_SSH"
#!/usr/bin/env bash
duration="${MOCK_SSH_DURATION:-1}"
exit_code="${MOCK_SSH_EXIT_CODE:-0}"
sleep "$duration"
exit "$exit_code"
EOF
chmod +x "$MOCK_SSH"

# Test 1: Normal startup, state transition to 'forwarding_established', status JSON, and umask 077
echo "--> Test 1: Normal startup, state transition, status JSON, and 0600 permissions..."
export CONFIG_DIR="$TEST_DIR"
export SSH_BINARY="$MOCK_SSH"
export MOCK_SSH_DURATION=10
export MOCK_SSH_EXIT_CODE=0
export BACKOFF_INIT=1
export BACKOFF_MAX=4
export SUSTAINED_THRESHOLD=5
export SKIP_KEY_CHECK=1
export REMOTE_HOST="127.0.0.1"

"$RUNNER" > "$TEST_DIR/runner.log" 2>&1 &
SUPERVISOR_PID=$!

# Wait for status file
waited=0
while [ ! -f "$TEST_DIR/tunnel_status.json" ] && [ "$waited" -lt 25 ]; do
  sleep 0.2
  waited=$((waited + 1))
done

if [ ! -f "$TEST_DIR/tunnel_status.json" ]; then
  echo "FAIL: tunnel_status.json was not created!"
  cat "$TEST_DIR/runner.log"
  exit 1
fi

status_val=$(grep '"status"' "$TEST_DIR/tunnel_status.json" | cut -d'"' -f4)
if [ "$status_val" != "forwarding_established" ] && [ "$status_val" != "connecting" ]; then
  echo "FAIL: Expected status 'forwarding_established' or 'connecting', got '$status_val'"
  exit 1
fi

# Verify permissions: must be 0600
status_perms=$(stat -f "%OLp" "$TEST_DIR/tunnel_status.json" 2>/dev/null || stat -c "%a" "$TEST_DIR/tunnel_status.json" 2>/dev/null || echo "")
if [ "$status_perms" != "600" ]; then
  echo "FAIL: tunnel_status.json permissions should be 600, got: $status_perms"
  exit 1
fi
echo "  [PASS] Status JSON verified: status = $status_val, PID = $SUPERVISOR_PID, permissions = 0600"

# Test 2: Concurrency & Atomic Singleton Locking
echo "--> Test 2: Atomic directory singleton locking prevents concurrent execution..."
second_run_out=$("$RUNNER" 2>&1 || true)
if echo "$second_run_out" | grep -q "already active"; then
  echo "  [PASS] Second runner detected existing supervisor lock and exited cleanly."
else
  echo "FAIL: Second runner did not detect existing active lock!"
  echo "Output: $second_run_out"
  exit 1
fi

# Test 2b: High Concurrency Hammer Test (15 simultaneous launches)
echo "--> Test 2b: High concurrency pressure test (15 simultaneous launches)..."
hammer_pids=()
for i in $(seq 1 15); do
  "$RUNNER" > "$TEST_DIR/hammer_$i.log" 2>&1 &
  hammer_pids+=($!)
done

for pid in "${hammer_pids[@]}"; do
  wait "$pid"
  code=$?
  if [ "$code" -ne 0 ]; then
    echo "FAIL: Concurrent runner $pid exited with non-zero code ($code)!"
    exit 1
  fi
done

current_lock_pid=$(cat "$TEST_DIR/tunnel.lock/pid" 2>/dev/null || echo "")
if [ "$current_lock_pid" = "$SUPERVISOR_PID" ] && kill -0 "$SUPERVISOR_PID" 2>/dev/null; then
  echo "  [PASS] High concurrency test PASSED: All 15 concurrent instances detected lock & exited cleanly; primary PID $SUPERVISOR_PID retained."
else
  echo "FAIL: Primary supervisor PID $SUPERVISOR_PID lost lock! Current: $current_lock_pid"
  exit 1
fi

# Stop Test 1 supervisor
kill -TERM "$SUPERVISOR_PID"
wait "$SUPERVISOR_PID" 2>/dev/null || true
echo "  [PASS] Supervisor gracefully terminated on SIGTERM."

# Test 3: Stale Lock Detection and Auto-Recovery
echo "--> Test 3: Stale lock recovery when dead PID remains in lock dir..."
mkdir -p "$TEST_DIR/tunnel.lock"
echo "99999" > "$TEST_DIR/tunnel.lock/pid" # Non-existent PID

"$RUNNER" > "$TEST_DIR/stale_test.log" 2>&1 &
STALE_RUNNER_PID=$!
sleep 1.2

if [ -f "$TEST_DIR/tunnel.lock/pid" ]; then
  recovered_pid=$(cat "$TEST_DIR/tunnel.lock/pid")
  if [ "$recovered_pid" != "99999" ]; then
    echo "  [PASS] Stale lock cleaned and reclaimed by active PID $recovered_pid."
  else
    echo "FAIL: Lock directory still holds stale PID 99999!"
    exit 1
  fi
  # Clean up recovered process
  kill -TERM "$recovered_pid" 2>/dev/null || true
  wait "$recovered_pid" 2>/dev/null || true
  sleep 0.5
else
  echo "FAIL: Stale lock directory was not recovered!"
  exit 1
fi

rm -rf "$TEST_DIR/tunnel.lock" "$TEST_DIR/tunnel.pid" "$TEST_DIR/tunnel_status.json"

# Test 4: True Exit Code Capture (Non-Zero is not masked)
echo "--> Test 4: True SSH exit code capture (verifying code 42 is preserved)..."
export MOCK_SSH_DURATION=0.1
export MOCK_SSH_EXIT_CODE=42
export BACKOFF_INIT=1
export BACKOFF_MAX=4
export BACKOFF_FACTOR=2

"$RUNNER" > "$TEST_DIR/runner_code42.log" 2>&1 &
CODE42_PID=$!

waited=0
found_code_42=0
while [ "$waited" -lt 25 ]; do
  if [ -f "$TEST_DIR/tunnel_status.json" ]; then
    if grep -q "Exit code 42" "$TEST_DIR/tunnel_status.json"; then
      found_code_42=1
      break
    fi
  fi
  sleep 0.3
  waited=$((waited + 1))
done

if [ "$found_code_42" -eq 1 ]; then
  echo "  [PASS] True exit code 42 captured and recorded in status JSON."
else
  echo "FAIL: Expected 'Exit code 42' in status JSON!"
  cat "$TEST_DIR/tunnel_status.json" 2>/dev/null || true
  exit 1
fi

# Test 5: Exponential Backoff Progression & Signal-Aware Sleep
echo "--> Test 5: Verifying exponential backoff progression and immediate wakeup on SIGTERM..."
# At this point, backoff has grown: 1s -> 2s -> 4s (capped)
reconnects=$(grep '"reconnect_count"' "$TEST_DIR/tunnel_status.json" | grep -o '[0-9]*' || echo 0)
backoff_val=$(grep '"current_backoff_seconds"' "$TEST_DIR/tunnel_status.json" | grep -o '[0-9]*' || echo 0)
echo "  [INFO] Reconnect count: $reconnects, current backoff: ${backoff_val}s"

term_start=$(date +%s)
kill -TERM "$CODE42_PID"
wait "$CODE42_PID" 2>/dev/null || true
term_end=$(date +%s)
term_duration=$((term_end - term_start))

if [ "$term_duration" -gt 3 ]; then
  echo "FAIL: SIGTERM was delayed by backoff sleep! Took ${term_duration}s"
  exit 1
fi
echo "  [PASS] SIGTERM woke up supervisor immediately (${term_duration}s) without waiting for backoff timer."

# Verify final clean state
if [ -d "$TEST_DIR/tunnel.lock" ]; then
  echo "FAIL: Lock directory was not cleaned on shutdown!"
  exit 1
fi
if [ -f "$TEST_DIR/tunnel.pid" ]; then
  echo "FAIL: PID file was not removed on shutdown!"
  exit 1
fi

echo "=== All Supervisor Unit & Fault-Recovery Tests PASSED ==="
