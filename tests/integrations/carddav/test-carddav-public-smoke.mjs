#!/usr/bin/env node
/**
 * Safe smoke check of the cloud CardDAV MCP public endpoint.
 *
 * No credentials, no OAuth registration, no Apple access and no contact writes.
 * Usage: MCP_SERVER_URL=https://seoul-forge-01.tail4db0d9.ts.net node test-carddav-public-smoke.mjs
 */
const raw = process.env.MCP_SERVER_URL?.trim();
if (!raw) {
  console.error('BLOCKED: MCP_SERVER_URL must be set explicitly.');
  process.exit(2);
}
let base;
try {
  base = new URL(raw);
  if (base.protocol !== 'https:' || base.pathname !== '/' || base.search || base.hash || base.username || base.password) {
    throw new Error('Require a bare HTTPS origin, without path, query or credentials.');
  }
} catch (err) {
  console.error('BLOCKED: invalid MCP_SERVER_URL:', err.message);
  process.exit(2);
}
const origin = base.origin;
const timeout = 15000;
const check = (condition, message) => {
  if (!condition) throw new Error(message);
};

async function run() {
  const health = await fetch(origin + '/health', { signal: AbortSignal.timeout(timeout), redirect: 'error' });
  check(health.status === 200, '/health expected HTTP 200, got ' + health.status);
  const body = await health.json();
  check(body.status === 'ok', '/health did not return status=ok');
  console.log('PASS health: HTTP 200');

  const metadataRes = await fetch(origin + '/.well-known/oauth-authorization-server', { signal: AbortSignal.timeout(timeout), redirect: 'error' });
  check(metadataRes.status === 200, 'OAuth discovery expected HTTP 200, got ' + metadataRes.status);
  const m = await metadataRes.json();
  check(m.issuer?.replace(/\/$/, '') === origin, 'OAuth issuer differs from MCP origin');
  for (const [name, suffix] of Object.entries({
    authorization_endpoint: '/authorize',
    token_endpoint: '/token',
    registration_endpoint: '/register',
  })) {
    check(m[name] === origin + suffix, 'OAuth ' + name + ' differs from expected HTTPS endpoint');
  }
  console.log('PASS OAuth metadata: issuer, authorize, token and register endpoints');

  const unauthorized = await fetch(origin + '/mcp', {
    method: 'POST',
    signal: AbortSignal.timeout(timeout),
    redirect: 'manual',
    headers: { 'Content-Type': 'application/json', 'Accept': 'application/json, text/event-stream' },
    body: JSON.stringify({
      jsonrpc: '2.0', id: 1, method: 'initialize',
      params: { protocolVersion: '2025-06-18', capabilities: {}, clientInfo: { name: 'public-smoke-check', version: '1.0' } },
    }),
  });
  check(unauthorized.status === 401, 'Unauthenticated /mcp expected 401, got ' + unauthorized.status);
  console.log('PASS unauthenticated /mcp: HTTP 401');
  console.log('PUBLIC_SMOKE_PASS: this is NOT an OAuth login or contacts CRUD acceptance test.');
}

run().catch(e => {
  console.error('PUBLIC_SMOKE_FAIL:', e.message);
  process.exit(1);
});
