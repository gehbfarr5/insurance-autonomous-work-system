/**
 * Auditable, server-side-only adapter for ONE approved bridge operation.
 * It does not connect to Apple and cannot forward arbitrary MCP calls.
 * Keep ICLOUD_BRIDGE_TOKEN in a server secret, never in browser assets.
 */
export class BridgeFailure extends Error {
  constructor(code, traceId) {
    super(code);
    this.name = 'BridgeFailure';
    this.code = code;
    this.traceId = traceId;
  }
}

const ALLOWED_PATH = '/v1/contacts/groups/list';
const MAX_GROUPS = 10000;

function makeTraceId() {
  return typeof crypto !== 'undefined' && typeof crypto.randomUUID === 'function'
    ? crypto.randomUUID()
    : `trace-${Date.now().toString(36)}`;
}

/**
 * @param {{
 * env: { ICLOUD_BRIDGE_URL?: string, ICLOUD_BRIDGE_TOKEN?: string },
 * fetchImpl?: typeof fetch,
 * record?: (safeEvent: {traceId:string,phase:string,status?:number,ms:number}) => void,
 * traceId?: string,
 * timeoutMs?: number
 * }} options
 * @returns {Promise<{groups: Array<{name:string,member_count:number}>}>}
 */
export async function listIcloudGroups({
  env,
  fetchImpl = fetch,
  record = () => {},
  traceId = makeTraceId(),
  timeoutMs = 15000,
}) {
  const start = Date.now();
  const emit = (phase, status) => {
    try {
      record({ traceId, phase, ...(status === undefined ? {} : { status }), ms: Date.now() - start });
    } catch {
      // Never let telemetry failure alter the authorized read operation.
    }
  };
  const fail = (code, phase) => {
    emit(phase || code);
    throw new BridgeFailure(code, traceId);
  };

  const rawUrl = env?.ICLOUD_BRIDGE_URL;
  const token = env?.ICLOUD_BRIDGE_TOKEN;
  if (!rawUrl || !token || typeof rawUrl !== 'string' || typeof token !== 'string') {
    fail('BRIDGE_UNCONFIGURED', 'config_missing');
  }
  emit('config_present');

  let base;
  try {
    base = new URL(rawUrl);
  } catch {
    fail('BRIDGE_CONFIG_INVALID', 'config_url_invalid');
  }
  // A server-side secret still needs a fixed, trusted HTTPS destination.
  // The caller cannot provide a URL, path, method, or arbitrary tool name.
  if (base.protocol !== 'https:' || !base.hostname || base.username || base.password ||
      base.search || base.hash || !['', '/', '/bridge', '/bridge/'].includes(base.pathname)) {
    fail('BRIDGE_CONFIG_INVALID', 'config_url_invalid');
  }
  const endpoint = new URL(base.pathname.replace(/\/?$/, '/') + ALLOWED_PATH.slice(1), base);
  emit('request_prepared');

  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  let response;
  try {
    emit('fetch_started');
    response = await fetchImpl(endpoint.href, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        Authorization: `Bearer ${token}`,
        'X-Request-ID': traceId,
      },
      body: '{}',
      signal: controller.signal,
      redirect: 'error',
    });
  } catch {
    fail(controller.signal.aborted ? 'BRIDGE_TIMEOUT' : 'BRIDGE_NETWORK_ERROR',
      controller.signal.aborted ? 'fetch_timeout' : 'fetch_error');
  } finally {
    clearTimeout(timer);
  }
  emit('response_received', response.status);
  if (response.status === 401 || response.status === 403) fail('BRIDGE_AUTH_FAILED', 'upstream_auth_rejected');
  if (!response.ok) fail('BRIDGE_UPSTREAM_ERROR', 'upstream_http_failure');

  let data;
  try {
    data = await response.json();
  } catch {
    fail('BRIDGE_BAD_JSON', 'response_json_invalid');
  }
  const source = Array.isArray(data) ? data : data?.groups;
  if (!Array.isArray(source) || source.length > MAX_GROUPS || source.some((g) =>
    !g || typeof g !== 'object' || typeof g.name !== 'string' ||
    !Number.isInteger(g.member_count) || g.member_count < 0)) {
    fail('BRIDGE_BAD_SCHEMA', 'response_schema_invalid');
  }
  const groups = source.map((g) => ({ name: g.name, member_count: g.member_count }));
  emit('success');
  return { groups };
}
