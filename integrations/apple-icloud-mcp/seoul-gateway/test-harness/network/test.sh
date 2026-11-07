#!/bin/bash
set -e

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SEMAPHORE_DIR="$(cd "$DIR/../.." && pwd)"
cd "$DIR"

echo "=== [AG-03 Network Integration] Running multi-hop test suite in Docker ==="

NETWORK_NAME="ag03_test_network"
GATEWAY_IP="172.30.55.1"
TOKEN="ag03-test-token-at-least-32-chars-long!"
RECEIPT_FILE="$DIR/RECEIPT_NETWORK_INTEGRATION.json"

TEST_RESULTS=()

# Helper to run client in container
run_client_container() {
  local mode="$1"
  local target_endpoint="$2"
  docker run --rm \
    --network "$NETWORK_NAME" \
    -v "$SEMAPHORE_DIR:/workspace:ro" \
    -w /workspace/test-harness/network \
    -e GATEWAY_ENDPOINT="$target_endpoint" \
    -e AUTH_TOKEN="$TOKEN" \
    node:22-alpine \
    node --experimental-strip-types test_client.mjs "$mode"
}

# --- TEST 1: Normal Read Path via Gateway & SSH Tunnel ---
echo ""
echo "--- TEST 1: Normal Read Path (Container -> Gateway -> SSH Tunnel -> Fake Bridge) ---"
if run_client_container "normal" "http://$GATEWAY_IP:18765"; then
  echo "TEST 1 PASS: Normal multi-hop reading verified."
  T1_STATUS="PASS"
else
  echo "TEST 1 FAIL"
  T1_STATUS="FAIL"
fi

# --- TEST 2: Wrong Host Key (SSH verification failure) ---
echo ""
echo "--- TEST 2: Wrong Host Key Explicit Failure ---"
# Create bad known_hosts
echo "172.30.55.10 ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFAKEBADHOSTKEYDOESNOTMATCH0000000000000" > known_hosts_bad
# Attempt SSH connection with bad host key - must fail
if ssh -i test_id_ed25519 \
  -o StrictHostKeyChecking=yes \
  -o UserKnownHostsFile=known_hosts_bad \
  -p 2222 \
  -N \
  -L "172.30.55.1:18766:127.0.0.1:18765" \
  root@172.30.55.10 2> bad_hostkey.log; then
  echo "TEST 2 FAIL: SSH should have rejected mismatched host key!"
  T2_STATUS="FAIL"
else
  echo "SSH properly rejected mismatched host key with error:"
  cat bad_hostkey.log
  # Now verify client container connecting to port 18766 fails explicitly
  if run_client_container "bad_hostkey" "http://$GATEWAY_IP:18766"; then
    echo "TEST 2 PASS: Mismatched host key explicitly blocked tunnel establishment."
    T2_STATUS="PASS"
  else
    echo "TEST 2 FAIL: Client did not catch upstream error."
    T2_STATUS="FAIL"
  fi
fi

# --- TEST 3: Broken Tunnel Failure ---
echo ""
echo "--- TEST 3: Broken Tunnel Explicit Failure ---"
# Kill current tunnel process
if [ -f tunnel.pid ]; then
  kill $(cat tunnel.pid) 2>/dev/null || true
  rm -f tunnel.pid
fi
sleep 1

# Container attempting to read through broken tunnel must fail with UPSTREAM_ERROR
if run_client_container "broken_tunnel" "http://$GATEWAY_IP:18765"; then
  echo "TEST 3 PASS: Broken tunnel explicitly rejected; zero fake success."
  T3_STATUS="PASS"
else
  echo "TEST 3 FAIL"
  T3_STATUS="FAIL"
fi

# Restart SSH tunnel for Test 4
ssh -i test_id_ed25519 \
  -o StrictHostKeyChecking=yes \
  -o UserKnownHostsFile=known_hosts \
  -o GatewayPorts=yes \
  -p 2222 \
  -N \
  -L "$GATEWAY_IP:18765:127.0.0.1:18765" \
  root@172.30.55.10 >/dev/null 2>&1 &
echo $! > tunnel.pid
sleep 1

# --- TEST 4: Permission Denied (403 from Bridge) ---
echo ""
echo "--- TEST 4: Permission Denied (403 from Fake Bridge) ---"
# Reconfigure Fake MacServer with EVENTKIT_BRIDGE_PRODUCTION_AUTHORIZED=false
docker stop ag03-fake-macserver >/dev/null 2>&1 || true
docker rm ag03-fake-macserver >/dev/null 2>&1 || true
docker run -d \
  --name ag03-fake-macserver \
  --network "$NETWORK_NAME" \
  --ip 172.30.55.10 \
  -v "$DIR/test_authorized_keys:/root/.ssh/authorized_keys:ro" \
  -e EVENTKIT_BRIDGE_PRODUCTION_AUTHORIZED=false \
  -e EVENTKIT_BRIDGE_AUTH_TOKEN="$TOKEN" \
  ag03-fake-macserver:test

# Restart tunnel
kill $(cat tunnel.pid) 2>/dev/null || true
sleep 1
ssh -i test_id_ed25519 \
  -o StrictHostKeyChecking=yes \
  -o UserKnownHostsFile=known_hosts \
  -o GatewayPorts=yes \
  -p 2222 \
  -N \
  -L "$GATEWAY_IP:18765:127.0.0.1:18765" \
  root@172.30.55.10 >/dev/null 2>&1 &
echo $! > tunnel.pid
sleep 1

if run_client_container "permission_denied" "http://$GATEWAY_IP:18765"; then
  echo "TEST 4 PASS: 403 returned PERMISSION_DENIED; zero fake empty list."
  T4_STATUS="PASS"
else
  echo "TEST 4 FAIL"
  T4_STATUS="FAIL"
fi

# Summary
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
GIT_COMMIT=$(git rev-parse HEAD 2>/dev/null || echo "unknown")

cat << EOF > "$RECEIPT_FILE"
{
  "receiptType": "AG03_REAL_NETWORK_INTEGRATION",
  "timestamp": "$TIMESTAMP",
  "gitCommit": "$GIT_COMMIT",
  "environment": {
    "network": "$NETWORK_NAME",
    "subnet": "172.30.55.0/24",
    "gatewayIp": "$GATEWAY_IP",
    "sshPort": 2222,
    "forwardTarget": "127.0.0.1:18765",
    "isolation": "Real Docker container + Real OpenSSH client/server + Fake Bridge"
  },
  "tests": [
    {
      "testId": "T1_NORMAL_READ",
      "description": "Container reading through Docker bridge gateway & SSH port forward",
      "status": "$T1_STATUS",
      "assertion": "HTTP 200, items length == 2, field fidelity preserved"
    },
    {
      "testId": "T2_WRONG_HOSTKEY",
      "description": "Mismatched host key in known_hosts",
      "status": "$T2_STATUS",
      "assertion": "SSH client strictly refuses connection; container fails with UPSTREAM_ERROR"
    },
    {
      "testId": "T3_BROKEN_TUNNEL",
      "description": "SSH tunnel terminated / port unreachable",
      "status": "$T3_STATUS",
      "assertion": "Container request aborts and throws UPSTREAM_ERROR; zero fake empty array"
    },
    {
      "testId": "T4_PERMISSION_DENIED",
      "description": "Bridge EVENTKIT_BRIDGE_PRODUCTION_AUTHORIZED=false",
      "status": "$T4_STATUS",
      "assertion": "HTTP 403 throws PERMISSION_DENIED; zero fallback to empty array"
    }
  ],
  "overallResult": "$([ "$T1_STATUS" = "PASS" ] && [ "$T2_STATUS" = "PASS" ] && [ "$T3_STATUS" = "PASS" ] && [ "$T4_STATUS" = "PASS" ] && echo "PASS" || echo "FAIL")"
}
EOF

echo ""
echo "=== Test Receipt Generated: $RECEIPT_FILE ==="
cat "$RECEIPT_FILE"
