#!/bin/bash
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DIR"

echo "=== [AG-03 Network Integration] Cleaning up isolated test environment ==="

if [ -f tunnel.pid ]; then
  kill $(cat tunnel.pid) 2>/dev/null || true
  rm -f tunnel.pid
fi

docker rm -f ag03-fake-macserver >/dev/null 2>&1 || true
docker network rm ag03_test_network >/dev/null 2>&1 || true

rm -f test_id_ed25519 test_id_ed25519.pub test_authorized_keys known_hosts known_hosts_bad bad_hostkey.log

echo "Cleanup complete."
