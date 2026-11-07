#!/bin/bash
set -e

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DIR"

echo "=== [AG-03 Network Integration] Starting isolated Docker environment ==="

# 1. Generate ephemeral SSH key pair
rm -f test_id_ed25519 test_id_ed25519.pub test_authorized_keys known_hosts known_hosts_bad tunnel.pid
ssh-keygen -t ed25519 -N "" -f test_id_ed25519 -C "ag03-isolated-test-key" >/dev/null 2>&1
chmod 600 test_id_ed25519

# Build authorized_keys with strict permitopen & no-pty
echo "permitopen=\"127.0.0.1:18765\",no-pty $(cat test_id_ed25519.pub)" > test_authorized_keys
chmod 600 test_authorized_keys

# 2. Create isolated Docker network
NETWORK_NAME="ag03_test_network"
SUBNET="172.30.55.0/24"
GATEWAY_IP="172.30.55.1"

if ! docker network inspect "$NETWORK_NAME" >/dev/null 2>&1; then
  docker network create --subnet "$SUBNET" --gateway "$GATEWAY_IP" "$NETWORK_NAME"
fi

# 3. Build Fake MacServer Image
echo "Building Fake MacServer Docker image..."
docker build -f Dockerfile.macserver -t ag03-fake-macserver:test .

# 4. Start Fake MacServer container
docker rm -f ag03-fake-macserver >/dev/null 2>&1 || true
docker run -d \
  --name ag03-fake-macserver \
  --network "$NETWORK_NAME" \
  --ip 172.30.55.10 \
  -v "$DIR/test_authorized_keys:/root/.ssh/authorized_keys:ro" \
  -e EVENTKIT_BRIDGE_PRODUCTION_AUTHORIZED=true \
  -e EVENTKIT_BRIDGE_AUTH_TOKEN="ag03-test-token-at-least-32-chars-long!" \
  ag03-fake-macserver:test

# 5. Wait for SSHD inside container to become ready
echo "Waiting for Fake MacServer SSHD..."
for i in {1..30}; do
  if ssh-keyscan -p 2222 172.30.55.10 > known_hosts 2>/dev/null && [ -s known_hosts ]; then
    break
  fi
  sleep 0.5
done

if [ ! -s known_hosts ]; then
  echo "Error: Failed to obtain host key from Fake MacServer"
  exit 1
fi

echo "Fake MacServer host key scanned successfully."

# 6. Start Host SSH Tunnel: Gateway IP 172.30.55.1:18765 -> 127.0.0.1:18765 via container 172.30.55.10:2222
echo "Starting Host SSH Tunnel bound to Docker Gateway ($GATEWAY_IP:18765)..."
ssh -i test_id_ed25519 \
  -o StrictHostKeyChecking=yes \
  -o UserKnownHostsFile=known_hosts \
  -o GatewayPorts=yes \
  -p 2222 \
  -N \
  -L "$GATEWAY_IP:18765:127.0.0.1:18765" \
  root@172.30.55.10 &

TUNNEL_PID=$!
echo $TUNNEL_PID > tunnel.pid

# Wait briefly for tunnel port to bind
sleep 1
if ! kill -0 $TUNNEL_PID 2>/dev/null; then
  echo "Error: SSH Tunnel process failed to start"
  exit 1
fi

echo "=== Environment Ready: Fake MacServer running, SSH Tunnel active (PID: $TUNNEL_PID) ==="
