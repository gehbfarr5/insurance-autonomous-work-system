#!/usr/bin/env node
import http from 'node:http';
import fs from 'node:fs';

const args = process.argv.slice(2);
let port = 18765;
let configFile = process.env.EVENTKIT_BRIDGE_CONFIG_FILE || '';
let pidFile = '';
let token = 'test-token-12345';
let productionAuthorized = true;

for (let i = 0; i < args.length; i++) {
  if (args[i] === '--port' && args[i + 1]) {
    port = parseInt(args[++i], 10);
  } else if (args[i] === '--config-file' && args[i + 1]) {
    configFile = args[++i];
  } else if (args[i] === '--pid-file' && args[i + 1]) {
    pidFile = args[++i];
  } else if (args[i] === '--token' && args[i + 1]) {
    token = args[++i];
  }
}

function loadConfig() {
  if (configFile && fs.existsSync(configFile)) {
    try {
      const content = fs.readFileSync(configFile, 'utf8');
      for (const line of content.split('\n')) {
        const trimmed = line.trim();
        if (!trimmed || trimmed.startsWith('#')) continue;
        const eq = trimmed.indexOf('=');
        if (eq === -1) continue;
        const k = trimmed.slice(0, eq).trim();
        let v = trimmed.slice(eq + 1).trim();
        if ((v.startsWith('"') && v.endsWith('"')) || (v.startsWith("'") && v.endsWith("'"))) {
          v = v.slice(1, -1);
        }
        if (k === 'EVENTKIT_BRIDGE_PRODUCTION_AUTHORIZED' || k === 'EVENTKIT_PRODUCTION_AUTHORIZED') {
          productionAuthorized = (v === 'true' || v === '1');
        }
        if (k === 'EVENTKIT_BRIDGE_BEARER_TOKEN') {
          token = v;
        }
      }
    } catch (e) {}
  }
}

loadConfig();

const server = http.createServer((req, res) => {
  const parsedUrl = new URL(req.url || '/', `http://127.0.0.1:${port}`);
  const pathname = parsedUrl.pathname;

  // 1. /health always returns 200 OK
  if (pathname === '/health') {
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ status: 'ok', productionAuthorized }));
    return;
  }

  // 2. Reject non-GET
  if (req.method !== 'GET') {
    res.writeHead(405, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ success: false, code: 'WRITE_OPERATION_REJECTED' }));
    return;
  }

  // Always check config file on business requests
  loadConfig();

  // 3. Auth Check
  const authHeader = req.headers.authorization;
  if (!authHeader || authHeader !== `Bearer ${token}`) {
    res.writeHead(401, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ success: false, code: 'AUTHENTICATION_FAILED' }));
    return;
  }

  // 4. Production Authorized Gate -> HTTP 403
  if (!productionAuthorized) {
    res.writeHead(403, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({
      success: false,
      error: 'EventKit production bridge not authorized.',
      code: 'PERMISSION_DENIED'
    }));
    return;
  }

  // 5. Business endpoint: /reminders/lists
  if (pathname === '/reminders/lists') {
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify([
      {
        listID: '00000000-0000-0000-0000-000000000001',
        title: 'MUSE Test',
        isDefault: true,
        color: '#4A90E2'
      }
    ]));
    return;
  }

  res.writeHead(404, { 'Content-Type': 'application/json' });
  res.end(JSON.stringify({ error: 'Not Found' }));
});

server.listen(port, '127.0.0.1', () => {
  const actualPort = server.address().port;
  if (pidFile) {
    fs.writeFileSync(pidFile, String(process.pid), { mode: 0o600 });
  }
  console.log(`[FAKE_BRIDGE] Listening on http://127.0.0.1:${actualPort} (PID: ${process.pid}, authorized: ${productionAuthorized})`);
});

process.on('SIGHUP', () => {
  loadConfig();
  console.log(`[FAKE_BRIDGE] SIGHUP received. Reloaded config. productionAuthorized: ${productionAuthorized}`);
});

process.on('SIGTERM', () => {
  server.close(() => process.exit(0));
});
