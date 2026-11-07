#!/bin/bash
set -e

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SEMAPHORE_DIR="$(cd "$DIR/../.." && pwd)"

if [ -d "/opt/englishpod-runner/_work/_tool/node/22.23.3/x64/bin" ]; then
  export PATH="/opt/englishpod-runner/_work/_tool/node/22.23.3/x64/bin:$PATH"
fi

DRILL_ROOT="/tmp/ag03-delivery-drill"
TIMESTAMP=$(date -u +"%Y%m%d_%H%M%S")
BACKUP_DIR="$DRILL_ROOT/backup"
DATA_DIR="$DRILL_ROOT/isolated-data"
RECEIPT_FILE="$DIR/RECEIPT_INSTALL_AND_ROLLBACK_DRILL.json"

echo "=== [AG-03 Delivery & Recovery Drill] Starting Isolated Drill ==="
echo "Drill root: $DRILL_ROOT"

# Ensure clean directory with isolated synthetic data directory
rm -rf "$DRILL_ROOT"
mkdir -p "$BACKUP_DIR" "$DATA_DIR"
chmod 777 "$DATA_DIR"

# Cleanup trap for drill containers and background bridges
cleanup() {
  local exit_code=$?
  if [ -n "$FAKE_BRIDGE_PID" ]; then
    kill $FAKE_BRIDGE_PID 2>/dev/null || true
  fi
  docker rm -f ag03-drill-candidate 2>/dev/null || true
  docker rm -f ag03-drill-rollback-verify 2>/dev/null || true
  if [ $exit_code -ne 0 ]; then
    echo "=== DRILL FAILED with exit code $exit_code. Receipt NOT marked as PASS. ==="
  fi
}
trap cleanup EXIT

# ==============================================================================
# Step 1: Real Production State Inspection & Backup (Zero Production Modification)
# ==============================================================================
echo ""
echo "--- Step 1: Inspecting production baseline & generating full backup ---"
PROD_CONTAINER="insurance-carddav-mcp-carddav-1"

PROD_IMAGE_ID=$(docker inspect "$PROD_CONTAINER" --format '{{.Image}}' 2>/dev/null || echo "image_unavailable")
PROD_CONTAINER_ID=$(docker inspect "$PROD_CONTAINER" --format '{{.Id}}' 2>/dev/null || echo "container_unavailable")

if [ "$PROD_IMAGE_ID" = "image_unavailable" ]; then
  echo "CRITICAL FAILURE: Production container $PROD_CONTAINER not found!"
  exit 1
fi

echo "Live Production Container ID: $PROD_CONTAINER_ID"
echo "Live Production Image ID: $PROD_IMAGE_ID"

# Backup production compose template (strictly NO secrets.env copying)
if [ -f "/opt/insurance-carddav-mcp/compose.yaml" ]; then
  cp /opt/insurance-carddav-mcp/compose.yaml "$BACKUP_DIR/compose.yaml.bak"
  echo "Backed up compose.yaml template to $BACKUP_DIR"
fi

# Tag production image with explicit backup tag
BACKUP_IMAGE_TAG="insurance-carddav-mcp-carddav:backup-pre-ag03-$TIMESTAMP"
docker tag "$PROD_IMAGE_ID" "$BACKUP_IMAGE_TAG"
echo "Created explicit Docker image backup tag: $BACKUP_IMAGE_TAG"

# ==============================================================================
# Step 2: Build Candidate Image from Pinned Baseline (92bd313) + Gateway Server
# ==============================================================================
echo ""
echo "--- Step 2: Building Candidate Image with Real MCP Gateway Entrypoint ---"
CANDIDATE_TAG="insurance-carddav-mcp-carddav:candidate-ag03-drill-$TIMESTAMP"

docker build --no-cache -t "$CANDIDATE_TAG" -f "$SEMAPHORE_DIR/Dockerfile.candidate" "$SEMAPHORE_DIR"

CANDIDATE_IMAGE_ID=$(docker inspect "$CANDIDATE_TAG" --format '{{.Id}}')
echo "Candidate Image Built: $CANDIDATE_TAG (ID: $CANDIDATE_IMAGE_ID)"

# ==============================================================================
# Step 3: Deploy Candidate Container to Isolated Port (17799) with Synthetic Config
# ==============================================================================
echo ""
echo "--- Step 3: Deploying Candidate Container to Isolated Port 17799 ---"
DRILL_CONTAINER="ag03-drill-candidate"
docker rm -f "$DRILL_CONTAINER" >/dev/null 2>&1 || true

# Determine docker gateway IP for host communication
DOCKER_GW_IP=$(docker network inspect bridge --format '{{(index .IPAM.Config 0).Gateway}}' 2>/dev/null || echo "172.17.0.1")
echo "Docker Gateway IP for Bridge: $DOCKER_GW_IP"

# Start transient background Fake Bridge bound to Docker gateway IP
TOKEN="ag03-test-token-at-least-32-chars-long!"
node -e '
const http = require("http");
const validToken = process.argv[1];
const host = process.argv[2] || "0.0.0.0";

const lists = [{
  listID: "9D9A****03F3",
  title: "M****试",
  sourceID: "src-icloud-test-01",
  sourceType: "calDAV",
  sourceName: "iCloud",
  color: "#007AFF",
  isImmutable: true
}];

const items = [{
  itemID: "item-drill-01",
  title: "候选容器外部验收条目 1",
  isCompleted: false,
  dueDate: 815961600,
  priority: 1,
  notes: "从容器外部通过真实 MCP SSE 协议读取",
  listID: "9D9A****03F3"
}];

const server = http.createServer((req, res) => {
  if (req.url === "/health") {
    res.writeHead(200, { "Content-Type": "application/json" });
    res.end(JSON.stringify({ status: "ok" }));
    return;
  }
  if (req.headers.authorization !== "Bearer " + validToken) {
    res.writeHead(401, { "Content-Type": "application/json" });
    res.end(JSON.stringify({ error: { code: "AUTH_FAILED" } }));
    return;
  }
  if (req.url === "/reminders/lists") {
    res.writeHead(200, { "Content-Type": "application/json" });
    res.end(JSON.stringify(lists));
    return;
  }
  if (req.url.startsWith("/reminders/lists/")) {
    res.writeHead(200, { "Content-Type": "application/json" });
    res.end(JSON.stringify(items));
    return;
  }
  res.writeHead(404, { "Content-Type": "application/json" });
  res.end(JSON.stringify({ error: { code: "NOT_FOUND" } }));
});

server.listen(18765, host, () => {
  console.log("[FakeBridge] Listening on " + host + ":18765");
});
' "$TOKEN" "0.0.0.0" >/dev/null 2>&1 &
FAKE_BRIDGE_PID=$!
sleep 1

# Deploy candidate container with SYNTHETIC configurations and INDEPENDENT data volume
docker run -d \
  --name "$DRILL_CONTAINER" \
  -p 127.0.0.1:17799:17733 \
  -v "$DATA_DIR:/app/data" \
  -e PORT=17733 \
  -e HOST=0.0.0.0 \
  -e TRUST_PROXY=true \
  -e ALLOW_REMINDERS_READ_1=true \
  -e ALLOW_REMINDERS_WRITE_1=false \
  -e MACSERVER_EVENTKIT_ENDPOINT="http://$DOCKER_GW_IP:18765" \
  -e MACSERVER_EVENTKIT_TOKEN="$TOKEN" \
  -e MACSERVER_EVENTKIT_ALLOWED_LISTS='[{"listId":"9D9A****03F3","expectedSourceId":"src-icloud-test-01"}]' \
  -e EVENTKIT_GATEWAY_ENDPOINT="http://$DOCKER_GW_IP:18765" \
  -e EVENTKIT_BRIDGE_AUTH_TOKEN="$TOKEN" \
  -e EVENTKIT_ALLOWED_LISTS='[{"listId":"9D9A****03F3","expectedSourceId":"src-icloud-test-01"}]' \
  "$CANDIDATE_TAG"

# Wait for container healthy
echo "Waiting for Candidate Container HEALTHCHECK..."
CANDIDATE_HEALTHY=false
for i in {1..30}; do
  HEALTH_STATUS=$(docker inspect "$DRILL_CONTAINER" --format '{{.State.Health.Status}}' 2>/dev/null || echo "starting")
  if [ "$HEALTH_STATUS" = "healthy" ]; then
    CANDIDATE_HEALTHY=true
    break
  fi
  if curl -s "http://127.0.0.1:17799/health" | grep -q '"status":"ok"'; then
    CANDIDATE_HEALTHY=true
    break
  fi
  sleep 1
done

if [ "$CANDIDATE_HEALTHY" != "true" ]; then
  echo "CRITICAL FAILURE: Candidate container healthcheck failed!"
  docker logs "$DRILL_CONTAINER"
  exit 1
fi
echo "Candidate Container HEALTHCHECK verified: 200 OK via /health"

# ==============================================================================
# Step 4: External MCP Acceptance Test from OUTSIDE the Container
# ==============================================================================
echo ""
echo "--- Step 4: External MCP Acceptance (Tool Discovery, Read, Write Rejection) ---"
ACCEPTANCE_SCRIPT="$SEMAPHORE_DIR/test-harness/acceptance/test_external_acceptance.mjs"
if ! TARGET_URL="http://127.0.0.1:17799" node --experimental-strip-types "$ACCEPTANCE_SCRIPT" normal; then
  echo "--- Candidate Container Logs on Failure: ---"
  docker logs "$DRILL_CONTAINER"
  exit 1
fi
echo "Step 4 PASS: External MCP Tool Discovery, Bound List Read, and Write Rejection verified."

# Stop Fake Bridge
kill $FAKE_BRIDGE_PID 2>/dev/null || true
FAKE_BRIDGE_PID=""

# ==============================================================================
# Step 5: Exercising Rollback Drill to Baseline Image & Config
# ==============================================================================
echo ""
echo "--- Step 5: Exercising Rollback Drill to Baseline Image & Synthetic Config ---"
# Remove candidate container
docker stop "$DRILL_CONTAINER" >/dev/null 2>&1 || true
docker rm "$DRILL_CONTAINER" >/dev/null 2>&1 || true

# Deploy rollback container from BACKUP_IMAGE_TAG on isolated port 17798
# Using SYNTHETIC test config and INDEPENDENT data volume (ZERO production credentials)
ROLLBACK_CONTAINER="ag03-drill-rollback-verify"
docker rm -f "$ROLLBACK_CONTAINER" >/dev/null 2>&1 || true

docker run -d \
  --name "$ROLLBACK_CONTAINER" \
  -p 127.0.0.1:17798:17733 \
  -v "$DATA_DIR:/app/data" \
  -e PORT=17733 \
  -e TOKEN_STORE_PATH=/app/data/tokens.json.enc \
  -e TOKEN_ENCRYPTION_KEY="c3ludGhldGljLWVuY3J5cHRpb24ta2V5LTMyLWJ5dGVzISE=" \
  -e TRUST_PROXY=true \
  "$BACKUP_IMAGE_TAG"

# Wait for rollback container response
sleep 2
ROLLBACK_STATUS=$(docker inspect "$ROLLBACK_CONTAINER" --format '{{.State.Status}}')
RESTORED_IMAGE_ID=$(docker inspect "$ROLLBACK_CONTAINER" --format '{{.Image}}')
echo "Rollback Container Status: $ROLLBACK_STATUS"
echo "Restored Image ID: $RESTORED_IMAGE_ID"

# CRITICAL ASSERTIONS:
# 1. Container status must be running
if [ "$ROLLBACK_STATUS" != "running" ]; then
  echo "CRITICAL FAILURE: Rollback container failed to run!"
  exit 1
fi

# 2. Image ID must match baseline EXACTLY
if [ "$RESTORED_IMAGE_ID" != "$PROD_IMAGE_ID" ]; then
  echo "CRITICAL FAILURE: Restored image ID ($RESTORED_IMAGE_ID) does not match baseline ($PROD_IMAGE_ID)!"
  exit 1
fi

# 3. Verify interface response on 17798/health
RESTORED_HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:17798/health || echo "000")
echo "Restored container /health HTTP code: $RESTORED_HTTP_CODE"
if [ "$RESTORED_HTTP_CODE" != "200" ]; then
  echo "CRITICAL FAILURE: Restored container /health returned $RESTORED_HTTP_CODE (expected 200)!"
  exit 1
fi

echo "Step 5 PASS: Rollback container verified with 200 OK, identical Image ID, and synthetic config."

# Clean up drill images and containers
docker rm -f "$ROLLBACK_CONTAINER" >/dev/null 2>&1 || true
docker rmi "$CANDIDATE_TAG" >/dev/null 2>&1 || true

# Generate sanitized drill receipt
cat << EOF > "$RECEIPT_FILE"
{
  "receiptType": "AG03_INSTALL_AND_ROLLBACK_DRILL",
  "timestamp": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
  "drillRoot": "$DRILL_ROOT",
  "isolation": {
    "syntheticCredentials": true,
    "productionSecretsMounted": false,
    "productionDataMounted": false,
    "independentDataDir": "$DATA_DIR"
  },
  "productionBaseline": {
    "container": "$PROD_CONTAINER",
    "imageId": "$PROD_IMAGE_ID",
    "backupTag": "$BACKUP_IMAGE_TAG"
  },
  "candidateStaging": {
    "imageTag": "$CANDIDATE_TAG",
    "imageId": "$CANDIDATE_IMAGE_ID",
    "isolatedPort": 17799,
    "entrypoint": "node src/server.ts (Real MCP Gateway HTTP Server)",
    "healthcheckStatus": "healthy",
    "externalAcceptance": {
      "toolDiscovery": "5/5 tools discovered",
      "boundListRead": "9D9A****03F3 read verified",
      "remindersItemRead": "items returned verified",
      "writeRejection": "PERMISSION_DENIED caught cleanly"
    }
  },
  "rollbackVerification": {
    "restoredFromTag": "$BACKUP_IMAGE_TAG",
    "restoredImageId": "$RESTORED_IMAGE_ID",
    "imageIdMatch": true,
    "healthcheckHttpCode": $RESTORED_HTTP_CODE,
    "containerStatus": "$ROLLBACK_STATUS",
    "result": "PASS"
  },
  "sharedServiceImpact": "ZERO (Production container $PROD_CONTAINER was never restarted or modified)"
}
EOF

echo ""
echo "=== Drill Receipt Generated: $RECEIPT_FILE ==="
cat "$RECEIPT_FILE"
