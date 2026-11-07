import assert from 'node:assert';
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { SSEClientTransport } from '@modelcontextprotocol/sdk/client/sse.js';

const TARGET_URL = process.env.TARGET_URL || 'http://127.0.0.1:17799';
const TEST_MODE = process.argv[2] || 'all';

console.log(`[ExternalAcceptance] Target: ${TARGET_URL}, Mode: ${TEST_MODE}`);

async function run() {
  // 1. Health check from outside container
  console.log('[ExternalAcceptance] Probing container /health endpoint...');
  const healthRes = await fetch(`${TARGET_URL}/health`);
  assert.strictEqual(healthRes.status, 200, `Health check must return 200, got ${healthRes.status}`);
  const healthJson = await healthRes.json();
  assert.strictEqual(healthJson.status, 'ok');
  assert.strictEqual(healthJson.mode, 'readonly');
  console.log('[ExternalAcceptance] Health check 200 OK verified:', healthJson.service);

  // 2. Connect MCP Client over SSE from outside container
  console.log('[ExternalAcceptance] Connecting MCP Client via SSE...');
  const transport = new SSEClientTransport(new URL(`${TARGET_URL}/sse`));
  const client = new Client(
    { name: 'external-acceptance-client', version: '1.0.0' },
    { capabilities: {} }
  );
  await client.connect(transport);
  console.log('[ExternalAcceptance] MCP Client connected successfully.');

  try {
    // 3. MCP Tool Discovery
    console.log('[ExternalAcceptance] Testing Tool Discovery...');
    const toolsResult = await client.listTools();
    const toolNames = toolsResult.tools.map((t) => t.name);
    console.log('[ExternalAcceptance] Discovered tools:', toolNames);

    const expectedTools = [
      'reminders_lists',
      'reminders_list',
      'reminders_create',
      'reminders_update',
      'reminders_delete',
    ];
    for (const t of expectedTools) {
      assert(toolNames.includes(t), `Tool ${t} must be discovered`);
    }
    console.log('[ExternalAcceptance] Tool Discovery: 5/5 reminder tools discovered.');

    if (TEST_MODE === 'normal' || TEST_MODE === 'all') {
      // 4. Bound List Reading
      console.log('[ExternalAcceptance] Testing Bound List Reading...');
      const listsCall = await client.callTool({
        name: 'reminders_lists',
        arguments: { session_id: 'ag03-acceptance-session' },
      });
      if (listsCall.isError) {
        console.error('[ExternalAcceptance] reminders_lists error payload:', JSON.stringify(listsCall, null, 2));
      }
      assert(!listsCall.isError, 'reminders_lists must not error');
      const listsText = listsCall.content[0].text;
      const listsData = JSON.parse(listsText);
      assert(Array.isArray(listsData), 'Result must be array');
      assert.strictEqual(listsData.length, 1);
      assert.strictEqual(listsData[0].list_id, '9D9A****03F3');
      assert.strictEqual(listsData[0].writable, false);
      console.log('[ExternalAcceptance] Bound List Reading verified: list_id=9D9A****03F3, writable=false');

      // 5. Bound Item Reading
      console.log('[ExternalAcceptance] Testing Reminders Item Reading...');
      const itemsCall = await client.callTool({
        name: 'reminders_list',
        arguments: { session_id: 'ag03-acceptance-session', list_ids: ['9D9A****03F3'] },
      });
      assert(!itemsCall.isError, 'reminders_list must not error');
      const itemsData = JSON.parse(itemsCall.content[0].text);
      assert(itemsData.reminders.length >= 1, 'Must return reminders');
      console.log(`[ExternalAcceptance] Reminders Item Reading verified: count=${itemsData.reminders.length}`);

      // 6. Fault Blocking: Client-side write rejection
      console.log('[ExternalAcceptance] Testing Write Rejection (reminders_create)...');
      const createCall = await client.callTool({
        name: 'reminders_create',
        arguments: {
          session_id: 'ag03-acceptance-session',
          reminder: { title: '外部写入拦截探测' },
        },
      });
      assert.strictEqual(createCall.isError, true, 'Write call must return isError: true');
      const createErr = JSON.parse(createCall.content[0].text);
      assert.strictEqual(createErr.error.code, 'PERMISSION_DENIED');
      console.log('[ExternalAcceptance] Write Rejection verified: PERMISSION_DENIED caught cleanly.');

      console.log(JSON.stringify({ status: 'PASS', mode: TEST_MODE, lists: listsData.length, items: itemsData.reminders.length }));
    } else if (TEST_MODE === 'fault_403') {
      console.log('[ExternalAcceptance] Testing Fault Blocking: Bridge 403...');
      const listsCall = await client.callTool({
        name: 'reminders_lists',
        arguments: { session_id: 'ag03-acceptance-session' },
      });
      assert.strictEqual(listsCall.isError, true, 'Must return isError: true on bridge 403');
      const err = JSON.parse(listsCall.content[0].text);
      assert.strictEqual(err.error.code, 'PERMISSION_DENIED');
      console.log('[ExternalAcceptance] Fault Blocking (403) verified: PERMISSION_DENIED caught cleanly.');
      console.log(JSON.stringify({ status: 'PASS', mode: TEST_MODE, errorCaught: err.error.code }));
    } else if (TEST_MODE === 'fault_tunnel') {
      console.log('[ExternalAcceptance] Testing Fault Blocking: Broken Tunnel...');
      const listsCall = await client.callTool({
        name: 'reminders_lists',
        arguments: { session_id: 'ag03-acceptance-session' },
      });
      assert.strictEqual(listsCall.isError, true, 'Must return isError: true on broken tunnel');
      const err = JSON.parse(listsCall.content[0].text);
      assert.strictEqual(err.error.code, 'UPSTREAM_ERROR');
      console.log('[ExternalAcceptance] Fault Blocking (Broken Tunnel) verified: UPSTREAM_ERROR caught cleanly.');
      console.log(JSON.stringify({ status: 'PASS', mode: TEST_MODE, errorCaught: err.error.code }));
    }
  } finally {
    await client.close();
  }
}

run().catch((err) => {
  console.error('[ExternalAcceptance] FAILED with error:', err);
  process.exit(1);
});
