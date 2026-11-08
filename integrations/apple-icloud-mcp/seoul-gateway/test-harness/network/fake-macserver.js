import http from 'node:http';

const PORT = 18765;
const HOST = '127.0.0.1';
const VALID_TOKEN = process.env.EVENTKIT_BRIDGE_AUTH_TOKEN || 'ag03-test-token-at-least-32-chars-long!';
let isAuthorized = process.env.EVENTKIT_BRIDGE_PRODUCTION_AUTHORIZED === 'true';

const lists = [
  {
    listID: '9D9A****03F3',
    title: 'M****试',
    sourceID: 'src-icloud-test-01',
    sourceType: 'calDAV',
    sourceName: 'iCloud',
    color: '#007AFF',
    isImmutable: true,
  },
];

const items = [
  {
    itemID: 'item-docker-01',
    title: 'Docker 隔离网络条目 1',
    isCompleted: false,
    dueDate: 815961600, // Swift Cocoa date: 2026-11-09T00:00:00Z
    priority: 1,
    notes: '经由真实 SSH 隧道及 Docker 网关获取',
    listID: '9D9A****03F3',
  },
  {
    itemID: 'item-docker-02',
    title: 'Docker 隔离网络条目 2',
    isCompleted: true,
    dueDate: 816048000,
    priority: 5,
    listID: '9D9A****03F3',
  },
];

const server = http.createServer((req, res) => {
  const url = new URL(req.url || '/', `http://${req.headers.host || 'localhost'}`);

  // Re-read authorization toggle if updated dynamically
  if (process.env.EVENTKIT_BRIDGE_PRODUCTION_AUTHORIZED !== undefined) {
    isAuthorized = process.env.EVENTKIT_BRIDGE_PRODUCTION_AUTHORIZED === 'true';
  }

  if (url.pathname === '/health' || url.pathname === '/healthz') {
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ status: 'ok', authorized: isAuthorized }));
    return;
  }

  // Auth header verification
  const authHeader = req.headers.authorization;
  if (!authHeader || authHeader !== `Bearer ${VALID_TOKEN}`) {
    res.writeHead(401, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ error: { code: 'AUTH_FAILED', message: 'Token 无效或缺失' } }));
    return;
  }

  // Production authorization verification
  if (!isAuthorized) {
    res.writeHead(403, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ error: { code: 'PERMISSION_DENIED', message: 'Bridge 生产激活开关未开启' } }));
    return;
  }

  if (req.method !== 'GET') {
    res.writeHead(405, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ error: { code: 'METHOD_NOT_ALLOWED', message: '只允许只读 GET 请求' } }));
    return;
  }

  if (url.pathname === '/reminders/lists') {
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify(lists));
    return;
  }

  const itemsMatch = url.pathname.match(/^\/reminders\/lists\/([^/]+)\/items$/);
  if (itemsMatch) {
    const listId = decodeURIComponent(itemsMatch[1]);
    if (listId === '9D9A****03F3') {
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify(items));
      return;
    }
    res.writeHead(404, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ error: { code: 'NOT_FOUND', message: '列表不存在' } }));
    return;
  }

  res.writeHead(404, { 'Content-Type': 'application/json' });
  res.end(JSON.stringify({ error: { code: 'NOT_FOUND', message: '路由不存在' } }));
});

server.listen(PORT, HOST, () => {
  console.log(`[FakeMacServer] EventKitBridge listening strictly on http://${HOST}:${PORT}`);
});
