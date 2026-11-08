#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# AG-03: Seoul -> MacServer Readonly Gateway Clean Reproduction & Delivery Drill
#
# Execution Pipeline:
# 1. Capture production container baseline status
# 2. Check port availability (fail directly if occupied; zero hijacking / kill)
# 3. Verify canonical patch checksum (actual comparison)
# 4. Extract pristine upstream baseline (commit 92bd313) into clean isolated dir
# 5. Apply canonical patch (0001-shared-gateway-wiring.patch, 33 tools restored)
# 6. Run full unit & regression test suite (326 tests across 21 suites)
# 7. Build candidate Docker image & record image ID
# 8. Start Fake EventKit Bridge with recorded PID
# 9. Start Candidate container on isolated Compose stack (port 17799)
# 10. Verify injected environment variables inside container runtime
# 11. Execute external acceptance probe suite (13 assertions, full 33 tools set)
# 12. Verify deterministic rollback to recorded baseline image ID via Compose (port 17798)
# 13. Resource cleanup & zero-residual validation
# 14. Production integrity assertion
# 15. Generate final PASS receipt ONLY after all checks and cleanups pass
# ==============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GATEWAY_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PATCH_FILE="$GATEWAY_ROOT/patches/0001-shared-gateway-wiring.patch"
COMPOSE_FILE="$GATEWAY_ROOT/config/compose.candidate.yaml"

# Node 22 environment detection
if [ -d "/opt/englishpod-runner/_work/_tool/node/22.23.3/x64/bin" ]; then
  export PATH="/opt/englishpod-runner/_work/_tool/node/22.23.3/x64/bin:$PATH"
fi

BASE_COMMIT="92bd313154cfbc51fce7e8df5b3f73ea86a6f1c7"
BASELINE_IMAGE_ID="sha256:f3e697fe266f58910c01985f9c906a84479705846c88fd7d2ea1ccf12c0da2f0"
EXPECTED_PATCH_SHA256="70ee262ee062a64c076ee0c935ea74cd33e9238bca8cd1ff3b755147b2798980"
UPSTREAM_SOURCE_DIR="/opt/insurance-carddav-mcp/source"

# Ports strictly used during drill
BRIDGE_PORT=18765
CANDIDATE_PORT=17799
ROLLBACK_PORT=17798

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
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
RUN_ID="ag03-${TIMESTAMP}"
CANDIDATE_PROJECT="ag03-candidate-${TIMESTAMP}"
ROLLBACK_PROJECT="ag03-rollback-${TIMESTAMP}"
BRIDGE_PID=""
WORK_DIR=""

check_port_free() {
  local port="$1"
  local host="${2:-127.0.0.1}"
  if (exec 3<>/dev/tcp/"$host"/"$port") 2>/dev/null; then
    exec 3<&-
    exec 3>&-
    return 1
  fi
  if ss -tln | grep -E "[: ]${port}[[:space:]]" >/dev/null 2>&1; then
    return 1
  fi
  if lsof -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1; then
    return 1
  fi
  return 0
}

cleanup() {
  local exit_code=$?
  echo "--- [CLEANUP] Executing exit cleanup (Exit code: $exit_code) ---"

  # 1. Terminate only Fake Bridge PID if recorded and alive (no batch killing)
  if [ -n "$BRIDGE_PID" ] && kill -0 "$BRIDGE_PID" 2>/dev/null; then
    echo "       Stopping Fake Bridge process (PID: $BRIDGE_PID)..."
    kill -15 "$BRIDGE_PID" 2>/dev/null || true
    wait "$BRIDGE_PID" 2>/dev/null || true
  fi

  # 2. Stop and remove test containers and networks via Compose
  if [ -n "$CANDIDATE_PROJECT" ]; then
    echo "       Stopping candidate compose project $CANDIDATE_PROJECT..."
    docker compose -p "$CANDIDATE_PROJECT" -f "$COMPOSE_FILE" down -v --remove-orphans >/dev/null 2>&1 || true
  fi
  if [ -n "$ROLLBACK_PROJECT" ]; then
    echo "       Stopping rollback compose project $ROLLBACK_PROJECT..."
    docker compose -p "$ROLLBACK_PROJECT" -f "$COMPOSE_FILE" down -v --remove-orphans >/dev/null 2>&1 || true
  fi

  # 3. Clean any labeled containers specifically created by this run
  if [ -n "$RUN_ID" ]; then
    local residual_containers
    residual_containers=$(docker ps -aq --filter "label=ag03_run_id=${RUN_ID}" 2>/dev/null || true)
    if [ -n "$residual_containers" ]; then
      echo "       Removing residual containers for run $RUN_ID: $residual_containers"
      docker rm -f $residual_containers >/dev/null 2>&1 || true
    fi
  fi

  # 4. Remove temporary credentials (preserving logs)
  rm -f /tmp/ag03-delivery-clean-creds.json 2>/dev/null || true
  if [ -n "$WORK_DIR" ] && [ -f "$WORK_DIR/creds.json" ]; then
    rm -f "$WORK_DIR/creds.json" 2>/dev/null || true
  fi

  # 5. Production integrity assertion
  if [ -n "$PROD_STATUS_BEFORE" ]; then
    local prod_status_after
    prod_status_after=$(docker inspect "$PROD_CONTAINER_NAME" --format '{{.State.Status}} {{.State.Health.Status}} {{.State.StartedAt}}' 2>/dev/null || echo "UNKNOWN")
    if [ "$PROD_STATUS_BEFORE" != "$prod_status_after" ]; then
      echo "CRITICAL ERROR: Seoul production container status changed during drill!" >&2
      echo "  Initial: $PROD_STATUS_BEFORE" >&2
      echo "  Final:   $prod_status_after" >&2
      exit 1
    else
      echo "       Seoul Production Container Verified Untouched: $prod_status_after"
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
echo " Run ID: $RUN_ID"
echo " Production Initial: ${PROD_STATUS_BEFORE:-None}"
echo "========================================================================"

# Pre-flight check: Port availability (strict rejection if occupied)
echo "[1/11] Checking port availability (zero process killing policy)..."
for p in "$BRIDGE_PORT" "$CANDIDATE_PORT" "$ROLLBACK_PORT"; do
  if ! check_port_free "$p"; then
    echo "ERROR: Port $p is already occupied by an external process! Aborting without modifying existing process." >&2
    exit 1
  fi
done
echo "       Verified: All required ports ($BRIDGE_PORT, $CANDIDATE_PORT, $ROLLBACK_PORT) are free."

if [ ! -f "$PATCH_FILE" ]; then
  echo "ERROR: Patch file not found: $PATCH_FILE" >&2
  exit 1
fi

echo "[2/11] Verifying canonical patch checksum..."
ACTUAL_PATCH_SHA256=$(sha256sum "$PATCH_FILE" | awk '{print $1}')
echo "       Path:     $PATCH_FILE"
echo "       Expected: $EXPECTED_PATCH_SHA256"
echo "       Actual:   $ACTUAL_PATCH_SHA256"
if [ "$ACTUAL_PATCH_SHA256" != "$EXPECTED_PATCH_SHA256" ]; then
  echo "ERROR: Patch checksum mismatch! Actual ($ACTUAL_PATCH_SHA256) != Expected ($EXPECTED_PATCH_SHA256)" >&2
  exit 1
fi

# Create clean isolated staging directory
WORK_DIR="/tmp/ag03-delivery-clean-${TIMESTAMP}"
rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR/upstream" "$WORK_DIR/data" "$WORK_DIR/logs"
chmod 777 "$WORK_DIR/data"

echo "[3/11] Extracting pristine upstream baseline (Commit: $BASE_COMMIT)..."
if [ ! -d "$UPSTREAM_SOURCE_DIR" ]; then
  echo "ERROR: Upstream source repository not found at $UPSTREAM_SOURCE_DIR" >&2
  exit 1
fi
git -C "$UPSTREAM_SOURCE_DIR" archive "$BASE_COMMIT" | tar -x -C "$WORK_DIR/upstream"

# Re-link node_modules from upstream source cache to avoid internet npm install
if [ -d "$UPSTREAM_SOURCE_DIR/node_modules" ]; then
  cp -r "$UPSTREAM_SOURCE_DIR/node_modules" "$WORK_DIR/upstream/"
fi

echo "[4/11] Applying canonical patch to clean baseline (restoring all 8 contacts groups tools + gateway)..."
patch -p1 -i "$PATCH_FILE" -d "$WORK_DIR/upstream"

echo "[5/11] Running full shared service unit & regression tests (21 suites, 326 tests)..."
(
  cd "$WORK_DIR/upstream"
  npm run build
  ./node_modules/.bin/vitest run tests/unit/modules/ tests/unit/server/ --sequence.concurrent=false
) > "$WORK_DIR/logs/vitest-regression.log" 2>&1
echo "       Unit & Regression tests passed: $(grep -E "Test Files|Tests" "$WORK_DIR/logs/vitest-regression.log" | tr '\n' ' ')"

echo "[6/11] Building candidate Docker image..."
CANDIDATE_TAG="insurance-carddav-mcp-carddav:candidate-ag03-delivery-${TIMESTAMP}"
docker build -t "$CANDIDATE_TAG" "$WORK_DIR/upstream" > "$WORK_DIR/logs/docker-build.log" 2>&1
CANDIDATE_IMAGE_ID=$(docker inspect "$CANDIDATE_TAG" --format '{{.Id}}')
echo "       Candidate image built: $CANDIDATE_TAG"
echo "       Candidate image ID:   $CANDIDATE_IMAGE_ID"

echo "[7/11] Initializing synthetic test credentials & starting Fake EventKit Bridge..."
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

const PORT = $BRIDGE_PORT;
const HOST = '0.0.0.0';
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

# Start fake bridge with explicit PID recording (no fuser -k, no pkill)
node "$WORK_DIR/fake-bridge.mjs" > "$WORK_DIR/logs/fake-bridge.log" 2>&1 &
BRIDGE_PID=$!
echo "       Fake Bridge started (PID: $BRIDGE_PID)"

wait_for_health "http://127.0.0.1:${BRIDGE_PORT}/health" 30 0.5 "Fake Bridge"

echo "[8/11] Starting Candidate container via Compose stack ($CANDIDATE_PROJECT, port $CANDIDATE_PORT)..."
RUN_ID="$RUN_ID" \
CARDDAV_IMAGE="$CANDIDATE_TAG" \
BIND_PORT="127.0.0.1:${CANDIDATE_PORT}" \
PUBLIC_URL="http://127.0.0.1:${CANDIDATE_PORT}" \
DATA_DIR="$WORK_DIR/data" \
ADMIN_PASSWORD_HASH="$ADMIN_HASH" \
TOKEN_ENCRYPTION_KEY="$TOKEN_ENCRYPTION_KEY" \
MACSERVER_EVENTKIT_ENDPOINT="http://172.30.56.1:18765" \
MACSERVER_EVENTKIT_AUTH_TOKEN="test-valid-bearer-token-at-least-32chars!" \
MACSERVER_EVENTKIT_TIMEOUT_MS="1200" \
MACSERVER_EVENTKIT_ALLOWED_LISTS="${SYNTH_LIST_ID}:${SYNTH_SOURCE_ID}:iCloud:calDAV,stalled-list-id:${SYNTH_SOURCE_ID}:iCloud:calDAV,corrupted-list-id:${SYNTH_SOURCE_ID}:iCloud:calDAV" \
ICLOUD_ACCOUNT_1="synthetic_candidate@icloud.com" \
ICLOUD_APP_PASSWORD_1="abcd-efgh-ijkl-mnop" \
ICLOUD_LABEL_1="Synthetic Candidate" \
ALLOW_REMINDERS_READ_1="true" \
ALLOW_REMINDERS_WRITE_1="false" \
ALLOW_MAIL_READ_1="false" \
ALLOW_MAIL_WRITE_1="false" \
ALLOW_CALENDAR_READ_1="false" \
ALLOW_CALENDAR_WRITE_1="false" \
ALLOW_CONTACTS_READ_1="false" \
ALLOW_CONTACTS_WRITE_1="false" \
docker compose -p "$CANDIDATE_PROJECT" -f "$COMPOSE_FILE" up -d

wait_for_health "http://127.0.0.1:${CANDIDATE_PORT}/health" 30 1 "Candidate Container"

# Verify environment variables entered container
echo "       Verifying environment variables inside Candidate container..."
CANDIDATE_CONTAINER_NAME=$(docker compose -p "$CANDIDATE_PROJECT" -f "$COMPOSE_FILE" ps -q carddav)
CONTAINER_ENVS=$(docker inspect "$CANDIDATE_CONTAINER_NAME" --format '{{range .Config.Env}}{{println .}}{{end}}')
for REQUIRED_VAR in MACSERVER_EVENTKIT_ENDPOINT MACSERVER_EVENTKIT_AUTH_TOKEN MACSERVER_EVENTKIT_ALLOWED_LISTS ALLOW_REMINDERS_READ_1 ALLOW_REMINDERS_WRITE_1; do
  if ! echo "$CONTAINER_ENVS" | grep -q "^${REQUIRED_VAR}="; then
    echo "ERROR: Required environment variable ${REQUIRED_VAR} not found in container!" >&2
    exit 1
  fi
done
echo "       Verified: All gateway environment variables present in container runtime config."

echo "[9/11] Executing external acceptance probe suite (full 33 tools set assertion)..."
cat << EOF > "$WORK_DIR/verify-acceptance.mjs"
import { readFileSync, writeFileSync } from 'node:fs';
import { randomBytes, createHash } from 'node:crypto';

const BASE_URL = 'http://127.0.0.1:${CANDIDATE_PORT}';
const BRIDGE_STATS_URL = 'http://127.0.0.1:${BRIDGE_PORT}/stats';
const REDIRECT_URI = 'http://127.0.0.1:9/callback';
const PROTOCOL_VERSION = '2025-06-18';
const NEWLINE = String.fromCharCode(10);
const TARGET_LIST_ID = '$SYNTH_LIST_ID';

const EXPECTED_TOOLS = [
  'apple_accounts',
  'apple_login',
  'work_done',
  'mail_folders',
  'mail_search',
  'mail_read',
  'mail_send',
  'mail_mark',
  'mail_move',
  'mail_delete',
  'calendar_list',
  'calendar_list_events',
  'calendar_create_event',
  'calendar_update_event',
  'calendar_delete_event',
  'reminders_lists',
  'reminders_list',
  'reminders_create',
  'reminders_update',
  'reminders_delete',
  'contacts_search',
  'contacts_read',
  'contacts_create',
  'contacts_update',
  'contacts_delete',
  'contacts_groups_list',
  'contacts_groups_members',
  'contacts_groups_create',
  'contacts_groups_rename',
  'contacts_groups_add_members',
  'contacts_groups_remove_members',
  'contacts_create_in_groups',
  'contacts_groups_delete',
];

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

    // 6. Tools list & Exact 33 tool set discovery validation
    const listToolsRes = await mcpPost(BASE_URL, tokenA, { jsonrpc: '2.0', id: 10, method: 'tools/list' }, mcpSessionA);
    const listMsg = listToolsRes.messages.find((m) => m.id === 10);
    let tools = (listMsg?.result?.tools || []).map((t) => t.name);

    // Injection support for targeted negative verification drill
    if (process.env.INJECT_MISSING_TOOL) {
      tools = tools.filter(t => t !== process.env.INJECT_MISSING_TOOL);
    }

    receipt.discoveredTools = tools;

    const missing = EXPECTED_TOOLS.filter((t) => !tools.includes(t));
    const unexpected = tools.filter((t) => !EXPECTED_TOOLS.includes(t));
    if (missing.length > 0) {
      throw new Error(\`Tool discovery failed: missing expected tools: \${missing.join(', ')}\`);
    }
    if (unexpected.length > 0) {
      throw new Error(\`Tool discovery failed: unexpected tools: \${unexpected.join(', ')}\`);
    }
    if (tools.length !== EXPECTED_TOOLS.length) {
      throw new Error(\`Tool count mismatch: expected \${EXPECTED_TOOLS.length}, got \${tools.length}\`);
    }
    receipt.assertions.exact_33_tools_set_matched = true;

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
      console.error('Acceptance suite failed:', JSON.stringify(receipt, null, 2));
      process.exit(1);
    }
  }
}
main();
EOF

node "$WORK_DIR/verify-acceptance.mjs"
mv /tmp/ag03-delivery-clean-receipt.json "$WORK_DIR/RECEIPT_AG03_DELIVERY.json"
echo "       Acceptance probe suite passed: 13/13 assertions PASS (all 33 tools verified)"

echo "[10/11] Verifying deterministic rollback to baseline image via Compose ($ROLLBACK_PROJECT, port $ROLLBACK_PORT)..."
# Stop candidate container via Compose
docker compose -p "$CANDIDATE_PROJECT" -f "$COMPOSE_FILE" down -v >/dev/null
CANDIDATE_PROJECT=""

CARDDAV_COMMAND=""
ROLLBACK_HEALTH_ATTEMPTS=30
if [ "${INJECT_ROLLBACK_FAILURE:-0}" = "1" ]; then
  echo "       [INJECTION] Simulating injected rollback health failure (stalled container)..."
  CARDDAV_COMMAND="sleep 60"
  ROLLBACK_HEALTH_ATTEMPTS=5
fi

RUN_ID="$RUN_ID" \
CARDDAV_IMAGE="$BASELINE_IMAGE_ID" \
CARDDAV_COMMAND="$CARDDAV_COMMAND" \
BIND_PORT="127.0.0.1:${ROLLBACK_PORT}" \
PUBLIC_URL="http://127.0.0.1:${ROLLBACK_PORT}" \
DATA_DIR="$WORK_DIR/data" \
ADMIN_PASSWORD_HASH="$ADMIN_HASH" \
TOKEN_ENCRYPTION_KEY="$TOKEN_ENCRYPTION_KEY" \
docker compose -p "$ROLLBACK_PROJECT" -f "$COMPOSE_FILE" up -d

# 1. Verify actual image ID of running rollback container matches recorded baseline image ID
ROLLBACK_CONTAINER_NAME=$(docker compose -p "$ROLLBACK_PROJECT" -f "$COMPOSE_FILE" ps -q carddav)
ACTUAL_ROLLBACK_IMAGE=$(docker inspect "$ROLLBACK_CONTAINER_NAME" --format '{{.Image}}')
if [ "$ACTUAL_ROLLBACK_IMAGE" != "$BASELINE_IMAGE_ID" ]; then
  echo "ERROR: Rollback image ID mismatch! Expected: $BASELINE_IMAGE_ID, Actual: $ACTUAL_ROLLBACK_IMAGE" >&2
  exit 1
fi
echo "       Rollback container image ID verified: $ACTUAL_ROLLBACK_IMAGE"

# 2. Verify healthcheck response (with strict timeout)
wait_for_health "http://127.0.0.1:${ROLLBACK_PORT}/health" "$ROLLBACK_HEALTH_ATTEMPTS" 1 "Rollback Container"

# 3. Verify configuration correspondence inside rollback container
ROLLBACK_ENVS=$(docker inspect "$ROLLBACK_CONTAINER_NAME" --format '{{range .Config.Env}}{{println .}}{{end}}')
if ! echo "$ROLLBACK_ENVS" | grep -q "^TOKEN_ENCRYPTION_KEY="; then
  echo "ERROR: Rollback container configuration mismatch!" >&2
  exit 1
fi
echo "       Rollback container configuration correspondence verified."

# Stop rollback container via Compose
docker compose -p "$ROLLBACK_PROJECT" -f "$COMPOSE_FILE" down -v >/dev/null
ROLLBACK_PROJECT=""

echo "[11/11] Unified post-drill verification (zero residual resources & production integrity)..."
# Terminate fake bridge explicitly
if [ -n "$BRIDGE_PID" ] && kill -0 "$BRIDGE_PID" 2>/dev/null; then
  kill -15 "$BRIDGE_PID" 2>/dev/null || true
  wait "$BRIDGE_PID" 2>/dev/null || true
  BRIDGE_PID=""
fi

# Verify all ports released
for p in "$BRIDGE_PORT" "$CANDIDATE_PORT" "$ROLLBACK_PORT"; do
  if ! check_port_free "$p"; then
    echo "ERROR: Post-drill port leak: Port $p is still occupied!" >&2
    exit 1
  fi
done

# Verify zero residual containers with this run label
RESIDUAL_CONTAINERS=$(docker ps -aq --filter "label=ag03_run_id=${RUN_ID}" 2>/dev/null || true)
if [ -n "$RESIDUAL_CONTAINERS" ]; then
  echo "ERROR: Post-drill container leak: Residual containers exist: $RESIDUAL_CONTAINERS" >&2
  exit 1
fi

# Verify production container untouched
if [ -n "$PROD_STATUS_BEFORE" ]; then
  PROD_STATUS_AFTER=$(docker inspect "$PROD_CONTAINER_NAME" --format '{{.State.Status}} {{.State.Health.Status}} {{.State.StartedAt}}' 2>/dev/null || echo "UNKNOWN")
  if [ "$PROD_STATUS_BEFORE" != "$PROD_STATUS_AFTER" ]; then
    echo "CRITICAL ERROR: Seoul production container status changed during drill!" >&2
    echo "  Initial: $PROD_STATUS_BEFORE" >&2
    echo "  Final:   $PROD_STATUS_AFTER" >&2
    exit 1
  fi
fi
echo "       Verified: All test resources cleaned up, zero residuals, production untouched."

# Archive receipt to repository root ONLY after all cleanup & checks pass
FINAL_RECEIPT="$WORK_DIR/RECEIPT_AG03_DELIVERY.json"
node -e '
import { readFileSync, writeFileSync } from "node:fs";
const r = JSON.parse(readFileSync("'"$FINAL_RECEIPT"'", "utf8"));
r.metadata = {
  run_id: "'"$RUN_ID"'",
  base_commit: "'"$BASE_COMMIT"'",
  patch_sha256: "'"$ACTUAL_PATCH_SHA256"'",
  candidate_image_tag: "'"$CANDIDATE_TAG"'",
  candidate_image_id: "'"$CANDIDATE_IMAGE_ID"'",
  baseline_image_id: "'"$BASELINE_IMAGE_ID"'",
  production_status_before: "'"$PROD_STATUS_BEFORE"'",
  production_status_after: "'"$PROD_STATUS_AFTER"'",
  synthetic_list_id: "'"$SYNTH_LIST_ID"'",
  expected_tools_count: 33,
  discovered_tools_count: r.discoveredTools.length
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
echo " Discovered Tools:    33/33 exact match"
echo " Production Untouched: $PROD_STATUS_AFTER"
echo " Archived Receipt:    $GATEWAY_ROOT/RECEIPT_SHARED_SERVICE_ACCEPTANCE.json"
echo "========================================================================"
