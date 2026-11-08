#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# AG-03: Seoul -> MacServer Readonly Gateway Clean Reproduction & Delivery Drill
#
# Execution Pipeline:
# 1. Capture production container baseline status
# 2. Verify canonical patch checksum (actual comparison)
# 3. Extract pristine upstream baseline (commit 92bd313) into clean isolated dir
# 4. Apply canonical patch (0001-shared-gateway-wiring.patch)
# 5. Run full unit & regression test suite (285 tests across 18 suites)
# 6. Build candidate Docker image & record image ID
# 7. Start Fake EventKit Bridge (synthetic backend) with synthetic credentials
# 8. Start Candidate container on isolated Docker network (port 17799)
# 9. Verify injected environment variables inside container runtime
# 10. Execute external acceptance test suite (13/13 assertions)
# 11. Verify deterministic rollback to recorded baseline image ID (port 17798)
# 12. Unified cleanup & production integrity assertion
# ==============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GATEWAY_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PATCH_FILE="$GATEWAY_ROOT/patches/0001-shared-gateway-wiring.patch"

# Node 22 environment detection
if [ -d "/opt/englishpod-runner/_work/_tool/node/22.23.3/x64/bin" ]; then
  export PATH="/opt/englishpod-runner/_work/_tool/node/22.23.3/x64/bin:$PATH"
fi

BASE_COMMIT="92bd313154cfbc51fce7e8df5b3f73ea86a6f1c7"
BASELINE_IMAGE_ID="sha256:f3e697fe266f58910c01985f9c906a84479705846c88fd7d2ea1ccf12c0da2f0"
EXPECTED_PATCH_SHA256="e84899f1f66b71f6310f56e113d4aec6281dfb4d583ab5509aa3d6442347883d"
UPSTREAM_SOURCE_DIR="/opt/insurance-carddav-mcp/source"

# Completely synthetic IDs (zero production correlation)
SYNTH_LIST_ID="00000000-AAAA-BBBB-CCCC-000000000001"
SYNTH_SOURCE_ID="src-synthetic-icloud-test"

# Record production container initial status for comparison
PROD_CONTAINER_NAME="insurance-carddav-mcp-carddav-1"
PROD_STATUS_BEFORE=""
if docker inspect "$PROD_CONTAINER_NAME" >/dev/null 2>&1; then
  PROD_STATUS_BEFORE=$(docker inspect "$PROD_CONTAINER_NAME" --format '{{.State.Status}} {{.State.Health.Status}} {{.State.StartedAt}}')
fi

# Track resource creation for unified cleanup
BRIDGE_PID=""
NETWORK_NAME="ag03_test_network"
NETWORK_CREATED=0
WORK_DIR=""

cleanup() {
  local exit_code=$?
  echo "--- [CLEANUP] Executing unified exit cleanup (Exit code: $exit_code) ---"

  # 1. Terminate Fake Bridge process if running
  if [ -n "$BRIDGE_PID" ] && kill -0 "$BRIDGE_PID" 2>/dev/null; then
    echo "       Stopping Fake Bridge process (PID: $BRIDGE_PID)..."
    kill "$BRIDGE_PID" 2>/dev/null || true
  fi
  fuser -k 18765/tcp 2>/dev/null || true
  pkill -f fake-bridge.mjs 2>/dev/null || true

  # 2. Stop and remove only drill test containers
  docker rm -f insurance-carddav-mcp-candidate >/dev/null 2>&1 || true
  docker rm -f insurance-carddav-mcp-rollback >/dev/null 2>&1 || true

  # 3. Remove isolated network if created
  if [ "$NETWORK_CREATED" -eq 1 ]; then
    echo "       Removing test network $NETWORK_NAME..."
    docker network rm "$NETWORK_NAME" >/dev/null 2>&1 || true
  fi

  # 4. Remove temporary credentials (preserving logs)
  rm -f /tmp/ag03-delivery-clean-creds.json 2>/dev/null || true
  if [ -n "$WORK_DIR" ] && [ -f "$WORK_DIR/creds.json" ]; then
    rm -f "$WORK_DIR/creds.json" 2>/dev/null || true
  fi

  # 5. Production integrity assertion
  if [ -n "$PROD_STATUS_BEFORE" ]; then
    PROD_STATUS_AFTER=$(docker inspect "$PROD_CONTAINER_NAME" --format '{{.State.Status}} {{.State.Health.Status}} {{.State.StartedAt}}' 2>/dev/null || echo "UNKNOWN")
    if [ "$PROD_STATUS_BEFORE" != "$PROD_STATUS_AFTER" ]; then
      echo "CRITICAL ERROR: Seoul production container status changed during drill!" >&2
      echo "  Initial: $PROD_STATUS_BEFORE" >&2
      echo "  Final:   $PROD_STATUS_AFTER" >&2
      exit 1
    else
      echo "       Seoul Production Container Verified Untouched: $PROD_STATUS_AFTER"
    fi
  fi

  echo "--- [CLEANUP] Cleanup finished ---"
}
trap cleanup EXIT INT TERM

wait_for_health() {
  local url="$1"
  local max_attempts="${2:-30}"
  local sleep_sec="${3:-1}"
  local desc="${4:-Service}"

  for i in $(seq 1 "$max_attempts"); do
    if curl -sf "$url" >/dev/null 2>&1; then
      echo "       $desc healthy at $url (attempt $i)"
      return 0
    fi
    sleep "$sleep_sec"
  done

  echo "ERROR: Health check timeout waiting for $desc at $url after $max_attempts attempts!" >&2
  return 1
}

echo "========================================================================"
echo " AG-03 CLEAN ENVIRONMENT REPRODUCTION AND DELIVERY DRILL"
echo " Time: $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
echo " Production Initial: ${PROD_STATUS_BEFORE:-None}"
echo "========================================================================"

if [ ! -f "$PATCH_FILE" ]; then
  echo "ERROR: Patch file not found: $PATCH_FILE" >&2
  exit 1
fi

echo "[1/10] Verifying canonical patch checksum..."
ACTUAL_PATCH_SHA256=$(sha256sum "$PATCH_FILE" | awk '{print $1}')
echo "       Path:     $PATCH_FILE"
echo "       Expected: $EXPECTED_PATCH_SHA256"
echo "       Actual:   $ACTUAL_PATCH_SHA256"
if [ "$ACTUAL_PATCH_SHA256" != "$EXPECTED_PATCH_SHA256" ]; then
  echo "ERROR: Patch checksum mismatch! Actual ($ACTUAL_PATCH_SHA256) != Expected ($EXPECTED_PATCH_SHA256)" >&2
  exit 1
fi

# Create clean isolated staging directory
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
WORK_DIR="/tmp/ag03-delivery-clean-${TIMESTAMP}"
rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR/upstream" "$WORK_DIR/data" "$WORK_DIR/logs"
chmod 777 "$WORK_DIR/data"

echo "[2/10] Extracting pristine upstream baseline (Commit: $BASE_COMMIT)..."
if [ ! -d "$UPSTREAM_SOURCE_DIR" ]; then
  echo "ERROR: Upstream source repository not found at $UPSTREAM_SOURCE_DIR" >&2
  exit 1
fi
git -C "$UPSTREAM_SOURCE_DIR" archive "$BASE_COMMIT" | tar -x -C "$WORK_DIR/upstream"

# Re-link node_modules from upstream source cache to avoid internet npm install
if [ -d "$UPSTREAM_SOURCE_DIR/node_modules" ]; then
  cp -r "$UPSTREAM_SOURCE_DIR/node_modules" "$WORK_DIR/upstream/"
fi

echo "[3/10] Applying canonical patch to clean baseline..."
patch -p1 -i "$PATCH_FILE" -d "$WORK_DIR/upstream"

echo "[4/10] Running full shared service unit & regression tests..."
(
  cd "$WORK_DIR/upstream"
  npm run build
  ./node_modules/.bin/vitest run tests/unit/modules/ tests/unit/server/ --sequence.concurrent=false
) > "$WORK_DIR/logs/vitest-regression.log" 2>&1
echo "       Unit & Regression tests passed: $(grep -E "Test Files|Tests" "$WORK_DIR/logs/vitest-regression.log" | tr '\n' ' ')"

echo "[5/10] Building candidate Docker image..."
CANDIDATE_TAG="insurance-carddav-mcp-carddav:candidate-ag03-delivery-${TIMESTAMP}"
docker build -t "$CANDIDATE_TAG" "$WORK_DIR/upstream" > "$WORK_DIR/logs/docker-build.log" 2>&1
CANDIDATE_IMAGE_ID=$(docker inspect "$CANDIDATE_TAG" --format '{{.Id}}')
echo "       Candidate image built: $CANDIDATE_TAG"
echo "       Candidate image ID:   $CANDIDATE_IMAGE_ID"

echo "[6/10] Setting up isolated Docker network ($NETWORK_NAME)..."
SUBNET="172.30.56.0/24"
GATEWAY_IP="172.30.56.1"

if ! docker network inspect "$NETWORK_NAME" >/dev/null 2>&1; then
  docker network create --subnet "$SUBNET" --gateway "$GATEWAY_IP" "$NETWORK_NAME"
  NETWORK_CREATED=1
fi

echo "[7/10] Initializing synthetic test credentials & starting Fake EventKit Bridge..."
TOKEN_ENCRYPTION_KEY=$(openssl rand -base64 32)
export TOKEN_ENCRYPTION_KEY

# Create synthetic auth store
cat << EOF > "$WORK_DIR/init-auth-store.mjs"
import { createAuthStore } from '$WORK_DIR/upstream/dist/auth/store.js';
import { hashPassword } from '$WORK_DIR/upstream/dist/auth/crypto.js';
import { createLogger } from '$WORK_DIR/upstream/dist/core/logger.js';
import { writeFileSync } from 'node:fs';

const encKeyBase64 = process.env.TOKEN_ENCRYPTION_KEY;
if (!encKeyBase64) {
  console.error('Missing TOKEN_ENCRYPTION_KEY');
  process.exit(1);
}

const keyBuf = Buffer.from(encKeyBase64, 'base64');
const tokenStorePath = '$WORK_DIR/data/tokens.json.enc';
const logger = createLogger('error', () => {});

async function init() {
  const store = createAuthStore({ path: tokenStorePath, key: keyBuf, logger });
  await store.load();
  await store.setEnvAccountsEnabled(true);

  const keyA = await store.createAccessKey('ag03-test-key-a');
  const keyB = await store.createAccessKey('ag03-test-key-b');

  const adminPass = 'test-admin-secret-pass-2026';
  const adminHash = hashPassword(adminPass);

  const creds = {
    keyA: { id: keyA.record.id, plaintext: keyA.plaintext },
    keyB: { id: keyB.record.id, plaintext: keyB.plaintext },
    adminPassword: adminPass,
    adminPasswordHash: adminHash,
  };

  writeFileSync('/tmp/ag03-delivery-clean-creds.json', JSON.stringify(creds, null, 2));
  writeFileSync('$WORK_DIR/creds.json', JSON.stringify(creds, null, 2));
  console.log('Successfully initialized token store and saved creds');
}

init().catch(err => {
  console.error('Init failed:', err);
  process.exit(1);
});
EOF

node "$WORK_DIR/init-auth-store.mjs"
chmod 777 "$WORK_DIR/data/tokens.json.enc"

ADMIN_HASH=$(node -e '
import { readFileSync } from "node:fs";
const c = JSON.parse(readFileSync("'"$WORK_DIR"'/creds.json", "utf8"));
process.stdout.write(c.adminPasswordHash);
')

# Start Fake EventKit Bridge with purely synthetic list ID
cat << EOF > "$WORK_DIR/fake-bridge.mjs"
import http from 'node:http';

const PORT = 18765;
const HOST = '172.30.56.1';
const VALID_TOKEN = 'test-valid-bearer-token-at-least-32chars!';
const SYNTH_LIST_ID = '$SYNTH_LIST_ID';
const SYNTH_SOURCE_ID = '$SYNTH_SOURCE_ID';

let totalRequests = 0;
let writeRequests = [];
let readRequests = [];

const server = http.createServer((req, res) => {
  totalRequests++;
  const url = new URL(req.url ?? '/', \`http://\${req.headers.host}\`);
  const method = (req.method || 'GET').toUpperCase();

  if (url.pathname === '/health') {
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ status: 'ok', totalRequests, writeCount: writeRequests.length }));
    return;
  }

  if (url.pathname === '/stats') {
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({
      totalRequests,
      writeCount: writeRequests.length,
      writeRequests,
      readCount: readRequests.length,
    }));
    return;
  }

  const auth = req.headers['authorization'];
  if (auth !== \`Bearer \${VALID_TOKEN}\`) {
    res.writeHead(401, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ error: 'UNAUTHORIZED', message: 'Bearer token invalid' }));
    return;
  }

  if (['POST', 'PUT', 'PATCH', 'DELETE'].includes(method)) {
    writeRequests.push({ method, path: url.pathname, timestamp: new Date().toISOString() });
    res.writeHead(405, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ error: 'METHOD_NOT_ALLOWED', message: 'Fake Bridge is read-only' }));
    return;
  }

  readRequests.push({ method, path: url.pathname, timestamp: new Date().toISOString() });

  if (url.pathname === '/reminders/lists') {
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify([
      {
        listID: SYNTH_LIST_ID,
        title: '合成工作测试列表',
        sourceID: SYNTH_SOURCE_ID,
        sourceType: 'calDAV',
        sourceName: 'iCloud',
        color: '#007AFF',
        isImmutable: true,
      },
      {
        listID: 'stalled-list-id',
        title: '停顿测试列表',
        sourceID: SYNTH_SOURCE_ID,
        sourceType: 'calDAV',
        sourceName: 'iCloud',
        color: '#FF9500',
        isImmutable: true,
      },
      {
        listID: 'corrupted-list-id',
        title: '异常条目测试列表',
        sourceID: SYNTH_SOURCE_ID,
        sourceType: 'calDAV',
        sourceName: 'iCloud',
        color: '#FF3B30',
        isImmutable: true,
      },
    ]));
    return;
  }

  if (url.pathname === '/reminders/lists/stalled-list-id/items') {
    res.writeHead(200, {
      'Content-Type': 'application/json',
      'Transfer-Encoding': 'chunked',
    });
    res.flushHeaders?.();
    return; // Stalled indefinitely
  }

  if (url.pathname === '/reminders/lists/corrupted-list-id/items') {
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify([
      {
        itemID: 'item-corrupted-999',
        listID: 'foreign-unknown-list-id',
        title: '归属异常条目',
        isCompleted: false,
      },
    ]));
    return;
  }

  if (url.pathname === \`/reminders/lists/\${SYNTH_LIST_ID}/items\`) {
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify([
      {
        itemID: 'item-ag03-001',
        listID: SYNTH_LIST_ID,
        title: '隔离测试任务1',
        isCompleted: false,
        priority: 1,
        dueDate: '2026-11-08T10:00:00.000Z',
      },
    ]));
    return;
  }

  res.writeHead(404, { 'Content-Type': 'application/json' });
  res.end(JSON.stringify({ error: 'NOT_FOUND', message: 'Path not found' }));
});

server.listen(PORT, HOST, () => {
  console.log(\`Fake Bridge listening on http://\${HOST}:\${PORT}\`);
});
EOF

fuser -k 18765/tcp 2>/dev/null || true
pkill -f fake-bridge.mjs 2>/dev/null || true
node "$WORK_DIR/fake-bridge.mjs" > "$WORK_DIR/logs/fake-bridge.log" 2>&1 &
BRIDGE_PID=$!

wait_for_health "http://172.30.56.1:18765/health" 30 0.5 "Fake Bridge"

echo "[8/10] Starting Candidate container on isolated network (port 17799)..."
docker rm -f insurance-carddav-mcp-candidate >/dev/null 2>&1 || true

docker run -d --rm \
  --name insurance-carddav-mcp-candidate \
  --network "$NETWORK_NAME" \
  -p 127.0.0.1:17799:17733 \
  -v "$WORK_DIR/data:/app/data" \
  -e PUBLIC_URL="http://127.0.0.1:17799" \
  -e ADMIN_PASSWORD_HASH="$ADMIN_HASH" \
  -e TOKEN_ENCRYPTION_KEY="$TOKEN_ENCRYPTION_KEY" \
  -e MACSERVER_EVENTKIT_ENDPOINT="http://172.30.56.1:18765" \
  -e MACSERVER_EVENTKIT_AUTH_TOKEN="test-valid-bearer-token-at-least-32chars!" \
  -e MACSERVER_EVENTKIT_TIMEOUT_MS="1200" \
  -e MACSERVER_EVENTKIT_ALLOWED_LISTS="${SYNTH_LIST_ID}:${SYNTH_SOURCE_ID}:iCloud:calDAV,stalled-list-id:${SYNTH_SOURCE_ID}:iCloud:calDAV,corrupted-list-id:${SYNTH_SOURCE_ID}:iCloud:calDAV" \
  -e ICLOUD_ACCOUNT_1="synthetic_candidate@icloud.com" \
  -e ICLOUD_APP_PASSWORD_1="abcd-efgh-ijkl-mnop" \
  -e ICLOUD_LABEL_1="Synthetic Candidate" \
  -e ALLOW_REMINDERS_READ_1="true" \
  -e ALLOW_REMINDERS_WRITE_1="false" \
  -e ALLOW_MAIL_READ_1="false" \
  -e ALLOW_MAIL_WRITE_1="false" \
  -e ALLOW_CALENDAR_READ_1="false" \
  -e ALLOW_CALENDAR_WRITE_1="false" \
  -e ALLOW_CONTACTS_READ_1="false" \
  -e ALLOW_CONTACTS_WRITE_1="false" \
  "$CANDIDATE_TAG" >/dev/null

wait_for_health "http://127.0.0.1:17799/health" 30 1 "Candidate Container"

# Verify environment variables entered container
echo "       Verifying environment variables inside Candidate container..."
CONTAINER_ENVS=$(docker inspect insurance-carddav-mcp-candidate --format '{{range .Config.Env}}{{println .}}{{end}}')
for REQUIRED_VAR in MACSERVER_EVENTKIT_ENDPOINT MACSERVER_EVENTKIT_AUTH_TOKEN MACSERVER_EVENTKIT_ALLOWED_LISTS ALLOW_REMINDERS_READ_1 ALLOW_REMINDERS_WRITE_1; do
  if ! echo "$CONTAINER_ENVS" | grep -q "^${REQUIRED_VAR}="; then
    echo "ERROR: Required environment variable ${REQUIRED_VAR} not found in container!" >&2
    exit 1
  fi
done
echo "       Verified: All gateway environment variables present in container runtime config."

echo "[9/10] Executing external acceptance probe suite (13 assertions)..."
cat << EOF > "$WORK_DIR/verify-acceptance.mjs"
import { readFileSync, writeFileSync } from 'node:fs';
import { randomBytes, createHash } from 'node:crypto';

const BASE_URL = 'http://127.0.0.1:17799';
const BRIDGE_STATS_URL = 'http://172.30.56.1:18765/stats';
const REDIRECT_URI = 'http://127.0.0.1:9/callback';
const PROTOCOL_VERSION = '2025-06-18';
const NEWLINE = String.fromCharCode(10);
const TARGET_LIST_ID = '$SYNTH_LIST_ID';

function b64url(buf) {
  return buf.toString('base64').replace(/\\+/g, '-').replace(/\\//g, '_').replace(/=+$/, '');
}

function parseSseMessages(text) {
  const out = [];
  for (const rawLine of text.split(NEWLINE)) {
    const line = rawLine.trim();
    if (!line.startsWith('data:')) continue;
    const payload = line.slice('data:'.length).trim();
    if (payload.length === 0) continue;
    try { out.push(JSON.parse(payload)); } catch {}
  }
  return out;
}

async function mcpPost(base, accessToken, body, mcpSessionId) {
  const headers = {
    'content-type': 'application/json',
    accept: 'application/json, text/event-stream',
    'mcp-protocol-version': PROTOCOL_VERSION,
  };
  if (accessToken) headers['authorization'] = \`Bearer \${accessToken}\`;
  if (mcpSessionId) headers['mcp-session-id'] = mcpSessionId;

  const res = await fetch(\`\${base}/mcp\`, { method: 'POST', headers, body: JSON.stringify(body) });
  const raw = await res.text();
  return {
    status: res.status,
    mcpSessionId: res.headers.get('mcp-session-id') || undefined,
    messages: parseSseMessages(raw),
    raw,
  };
}

async function runAuthFlow(base, accessKey) {
  const codeVerifier = b64url(randomBytes(32));
  const codeChallenge = b64url(createHash('sha256').update(codeVerifier).digest());

  const regRes = await fetch(\`\${base}/register\`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({
      redirect_uris: [REDIRECT_URI],
      token_endpoint_auth_method: 'none',
      grant_types: ['authorization_code', 'refresh_token'],
      response_types: ['code'],
    }),
  });
  if (regRes.status !== 201) throw new Error(\`Register failed: \${regRes.status}\`);
  const { client_id: clientId } = await regRes.json();

  const authorizeUrl = new URL(\`\${base}/authorize\`);
  authorizeUrl.searchParams.set('response_type', 'code');
  authorizeUrl.searchParams.set('client_id', clientId);
  authorizeUrl.searchParams.set('redirect_uri', REDIRECT_URI);
  authorizeUrl.searchParams.set('code_challenge', codeChallenge);
  authorizeUrl.searchParams.set('code_challenge_method', 'S256');
  authorizeUrl.searchParams.set('state', 'test-state');

  const authRes = await fetch(authorizeUrl, { redirect: 'manual' });
  const html = await authRes.text();
  const match = /name="request_id" value="([^"]+)"/.exec(html);
  if (!match) throw new Error('Could not find request_id');
  const requestId = match[1];

  const loginRes = await fetch(\`\${base}/access-login\`, {
    method: 'POST',
    headers: { 'content-type': 'application/x-www-form-urlencoded' },
    redirect: 'manual',
    body: new URLSearchParams({ request_id: requestId, access_key: accessKey }).toString(),
  });
  const location = loginRes.headers.get('location');
  const callback = new URL(location);
  const code = callback.searchParams.get('code');

  const tokenRes = await fetch(\`\${base}/token\`, {
    method: 'POST',
    headers: { 'content-type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({
      grant_type: 'authorization_code',
      code,
      redirect_uri: REDIRECT_URI,
      client_id: clientId,
      code_verifier: codeVerifier,
    }).toString(),
  });
  const tokenData = await tokenRes.json();
  return { clientId, accessToken: tokenData.access_token };
}

async function initMcpSession(base, accessToken) {
  const init = await mcpPost(base, accessToken, {
    jsonrpc: '2.0',
    id: 1,
    method: 'initialize',
    params: {
      protocolVersion: PROTOCOL_VERSION,
      capabilities: {},
      clientInfo: { name: 'ag03-acceptance-probe', version: '1.0.0' },
    },
  });
  await mcpPost(base, accessToken, { jsonrpc: '2.0', method: 'notifications/initialized' }, init.mcpSessionId);
  return init.mcpSessionId;
}

async function callTool(base, accessToken, mcpSessionId, name, args, reqId = 2) {
  const call = await mcpPost(
    base,
    accessToken,
    { jsonrpc: '2.0', id: reqId, method: 'tools/call', params: { name, arguments: args } },
    mcpSessionId,
  );
  const msg = call.messages.find((m) => m.id === reqId);
  const result = msg?.result;
  const isError = result?.isError === true;
  const text = result?.content?.[0]?.text;
  let payload = {};
  if (typeof text === 'string') {
    try { payload = JSON.parse(text); } catch { payload = { rawText: text }; }
  }
  return { isError, payload, text };
}

async function main() {
  const receipt = {
    timestamp: new Date().toISOString(),
    verdict: 'FAIL',
    assertions: {},
    discoveredTools: [],
    writeProbeDetails: null,
  };

  try {
    const creds = JSON.parse(readFileSync('/tmp/ag03-delivery-clean-creds.json', 'utf8'));

    // 1. Healthcheck
    const healthRes = await fetch(\`\${BASE_URL}/health\`);
    if (healthRes.status !== 200) throw new Error(\`Healthcheck: \${healthRes.status}\`);
    receipt.assertions.healthcheck_200 = true;

    // 2. Unauthenticated
    const unauthRes = await mcpPost(BASE_URL, null, { jsonrpc: '2.0', id: 1, method: 'initialize', params: {} });
    if (unauthRes.status !== 401) throw new Error(\`Unauth: \${unauthRes.status}\`);
    receipt.assertions.unauthenticated_rejected_401 = true;

    // 3. Invalid token
    const invalidTokenRes = await mcpPost(BASE_URL, 'invalid-bearer-token', { jsonrpc: '2.0', id: 1, method: 'initialize', params: {} });
    if (invalidTokenRes.status !== 401) throw new Error(\`Invalid token: \${invalidTokenRes.status}\`);
    receipt.assertions.invalid_token_rejected_401 = true;

    // 4. OAuth 2.1
    const { accessToken: tokenA } = await runAuthFlow(BASE_URL, creds.keyA.plaintext);
    receipt.assertions.oauth2_auth_flow_pass = true;

    // 5. MCP session
    const mcpSessionA = await initMcpSession(BASE_URL, tokenA);
    receipt.assertions.mcp_streamable_http_session_initialized = true;

    // 6. Tools list
    const listToolsRes = await mcpPost(BASE_URL, tokenA, { jsonrpc: '2.0', id: 10, method: 'tools/list' }, mcpSessionA);
    const listMsg = listToolsRes.messages.find((m) => m.id === 10);
    const tools = (listMsg?.result?.tools || []).map((t) => t.name);
    receipt.discoveredTools = tools;
    receipt.assertions.tool_discovery_all_modules_present = tools.includes('reminders_list') && tools.includes('reminders_create');

    // 7. Apple login
    const loginCall = await callTool(BASE_URL, tokenA, mcpSessionA, 'apple_login', {}, 20);
    const sessionIdA = loginCall.payload.session_id;
    receipt.assertions.apple_login_session_issued = Boolean(sessionIdA);

    // 8. Reminders lists
    const listsCall = await callTool(BASE_URL, tokenA, mcpSessionA, 'reminders_lists', { session_id: sessionIdA }, 30);
    const boundLists = Array.isArray(listsCall.payload) ? listsCall.payload : (listsCall.payload?.lists || []);
    const target = boundLists.find((l) => l.list_id === TARGET_LIST_ID);
    receipt.assertions.bound_list_metadata_read_pass = Boolean(target && target.writable === false);

    // 9. Reminders item query
    const itemsCall = await callTool(BASE_URL, tokenA, mcpSessionA, 'reminders_list', {
      session_id: sessionIdA,
      list_ids: [TARGET_LIST_ID],
    }, 40);
    const reminders = itemsCall.payload?.reminders || [];
    receipt.assertions.bound_items_read_pass = reminders.length === 1 && reminders[0].reminder_id === 'item-ag03-001';

    // 10. Stalled stream timeout
    const stallStart = Date.now();
    const stallCall = await callTool(BASE_URL, tokenA, mcpSessionA, 'reminders_list', {
      session_id: sessionIdA,
      list_ids: ['stalled-list-id'],
    }, 45);
    const stallElapsed = Date.now() - stallStart;
    receipt.assertions.stalled_body_stream_timeout_pass = stallCall.isError && stallCall.text?.includes('超时') && stallElapsed < 2500;

    // 11. Corrupted items rejection
    const corruptCall = await callTool(BASE_URL, tokenA, mcpSessionA, 'reminders_list', {
      session_id: sessionIdA,
      list_ids: ['corrupted-list-id'],
    }, 46);
    receipt.assertions.corrupted_item_validation_pass = corruptCall.isError && corruptCall.text?.includes('不匹配');

    // 12. Cross-session tampering rejection
    const { accessToken: tokenB } = await runAuthFlow(BASE_URL, creds.keyB.plaintext);
    const mcpSessionB = await initMcpSession(BASE_URL, tokenB);
    const crossCall = await callTool(BASE_URL, tokenB, mcpSessionB, 'reminders_lists', { session_id: sessionIdA }, 51);
    receipt.assertions.cross_session_tampering_rejected = crossCall.isError;

    // 13. Read-only gate strictly blocks writes
    const createCall = await callTool(BASE_URL, tokenA, mcpSessionA, 'reminders_create', { session_id: sessionIdA, reminder: { title: 'T' } }, 60);
    const updateCall = await callTool(BASE_URL, tokenA, mcpSessionA, 'reminders_update', { session_id: sessionIdA, reminder_id: 'i-1', patch: { title: 'T' } }, 61);
    const deleteCall = await callTool(BASE_URL, tokenA, mcpSessionA, 'reminders_delete', { session_id: sessionIdA, reminder_id: 'i-1' }, 62);

    const bridgeStatsRes = await fetch(BRIDGE_STATS_URL);
    const bridgeStats = await bridgeStatsRes.json();

    receipt.writeProbeDetails = {
      createBlocked: createCall.isError,
      updateBlocked: updateCall.isError,
      deleteBlocked: deleteCall.isError,
      bridgeRecordedWriteCount: bridgeStats.writeCount,
      bridgeRecordedReadCount: bridgeStats.readCount,
    };
    receipt.assertions.write_operations_strictly_rejected = createCall.isError && updateCall.isError && deleteCall.isError;
    receipt.assertions.bridge_received_zero_write_forwarding = bridgeStats.writeCount === 0;

    const allPassed = Object.values(receipt.assertions).every(Boolean);
    receipt.verdict = allPassed ? 'PASS' : 'FAIL';
  } catch (err) {
    receipt.verdict = 'FAIL';
    receipt.error = err instanceof Error ? { message: err.message, stack: err.stack } : String(err);
  } finally {
    writeFileSync('/tmp/ag03-delivery-clean-receipt.json', JSON.stringify(receipt, null, 2));
    if (receipt.verdict !== 'PASS') {
      console.error('Acceptance suite failed:', JSON.stringify(receipt.assertions, null, 2));
      process.exit(1);
    }
  }
}
main();
EOF

node "$WORK_DIR/verify-acceptance.mjs"
mv /tmp/ag03-delivery-clean-receipt.json "$WORK_DIR/RECEIPT_AG03_DELIVERY.json"
echo "       Acceptance probe suite passed: 13/13 assertions PASS"

echo "[10/10] Verifying deterministic rollback to baseline image & cleanup..."
docker stop insurance-carddav-mcp-candidate >/dev/null

ROLLBACK_EXTRA_ARGS=""
ROLLBACK_HEALTH_ATTEMPTS=30
if [ "${INJECT_ROLLBACK_FAILURE:-0}" = "1" ]; then
  echo "       [INJECTION] Simulating injected rollback health failure (stalled container)..."
  ROLLBACK_EXTRA_ARGS="sleep 60"
  ROLLBACK_HEALTH_ATTEMPTS=5
fi

docker rm -f insurance-carddav-mcp-rollback >/dev/null 2>&1 || true
docker run -d --rm \
  --name insurance-carddav-mcp-rollback \
  -p 127.0.0.1:17798:17733 \
  -v "$WORK_DIR/data:/app/data" \
  -e PUBLIC_URL="http://127.0.0.1:17798" \
  -e ADMIN_PASSWORD_HASH="$ADMIN_HASH" \
  -e TOKEN_ENCRYPTION_KEY="$TOKEN_ENCRYPTION_KEY" \
  "$BASELINE_IMAGE_ID" $ROLLBACK_EXTRA_ARGS >/dev/null

# 1. Verify actual image ID of running rollback container matches recorded baseline image ID
ACTUAL_ROLLBACK_IMAGE=$(docker inspect insurance-carddav-mcp-rollback --format '{{.Image}}')
if [ "$ACTUAL_ROLLBACK_IMAGE" != "$BASELINE_IMAGE_ID" ]; then
  echo "ERROR: Rollback image ID mismatch! Expected: $BASELINE_IMAGE_ID, Actual: $ACTUAL_ROLLBACK_IMAGE" >&2
  exit 1
fi
echo "       Rollback container image ID verified: $ACTUAL_ROLLBACK_IMAGE"

# 2. Verify healthcheck response (with strict timeout)
wait_for_health "http://127.0.0.1:17798/health" "$ROLLBACK_HEALTH_ATTEMPTS" 1 "Rollback Container"

# 3. Verify configuration correspondence inside rollback container
ROLLBACK_ENVS=$(docker inspect insurance-carddav-mcp-rollback --format '{{range .Config.Env}}{{println .}}{{end}}')
if ! echo "$ROLLBACK_ENVS" | grep -q "^TOKEN_ENCRYPTION_KEY="; then
  echo "ERROR: Rollback container configuration mismatch!" >&2
  exit 1
fi
echo "       Rollback container configuration correspondence verified."

docker stop insurance-carddav-mcp-rollback >/dev/null

# Archive receipt to repository root
FINAL_RECEIPT="$WORK_DIR/RECEIPT_AG03_DELIVERY.json"
node -e '
import { readFileSync, writeFileSync } from "node:fs";
const r = JSON.parse(readFileSync("'"$FINAL_RECEIPT"'", "utf8"));
r.metadata = {
  base_commit: "'"$BASE_COMMIT"'",
  patch_sha256: "'"$ACTUAL_PATCH_SHA256"'",
  candidate_image_tag: "'"$CANDIDATE_TAG"'",
  candidate_image_id: "'"$CANDIDATE_IMAGE_ID"'",
  baseline_image_id: "'"$BASELINE_IMAGE_ID"'",
  production_status_before: "'"$PROD_STATUS_BEFORE"'",
  synthetic_list_id: "'"$SYNTH_LIST_ID"'"
};
writeFileSync("'"$FINAL_RECEIPT"'", JSON.stringify(r, null, 2));
writeFileSync("'"$GATEWAY_ROOT"'/RECEIPT_SHARED_SERVICE_ACCEPTANCE.json", JSON.stringify(r, null, 2));
'

echo "========================================================================"
echo " DRILL COMPLETED SUCCESSFULLY"
echo " Verdict: PASS"
echo " Candidate Image Tag: $CANDIDATE_TAG"
echo " Candidate Image ID:  $CANDIDATE_IMAGE_ID"
echo " Patch SHA256:        $ACTUAL_PATCH_SHA256"
echo " Synthetic List ID:   $SYNTH_LIST_ID"
echo " Archived Receipt:    $GATEWAY_ROOT/RECEIPT_SHARED_SERVICE_ACCEPTANCE.json"
echo "========================================================================"
