import { test, describe, before, after } from 'node:test';
import assert from 'node:assert';
import { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js';
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { InMemoryTransport } from '@modelcontextprotocol/sdk/inMemory.js';

// REAL upstream files pinned from commit 92bd313154cfbc51fce7e8df5b3f73ea86a6f1c7
import { registerReminderTools } from '../upstream/pinned/modules/reminders/tools.ts';
import type { ToolRegistrar } from '../upstream/pinned/server/types.ts';

import { FakeEventKitBridge } from '../src/fake-bridge.ts';
import { EventKitReadonlyTransport } from '../src/transport.ts';
import { createMacServerReminderService } from '../src/service.ts';
import type { MacServerGatewayConfig, ReminderService } from '../src/types.ts';

describe('Real MCP Tool Assembly & Protocol Discovery/Invocation [Pinned 92bd313]', () => {
  const token = 'protocol-test-token-at-least-32chars!';
  let fakeBridge: FakeEventKitBridge;
  let bridgeUrl: string;
  let config: MacServerGatewayConfig;
  let service: ReminderService;

  let mcpServer: McpServer;
  let mcpClient: Client;

  before(async () => {
    // 1. Start Fake Bridge
    fakeBridge = new FakeEventKitBridge({
      validToken: token,
      productionAuthorized: true,
      allowedListIds: ['test-list-01'],
      mockLists: [
        {
          listID: 'test-list-01',
          title: '真实MCP装配测试列表',
          sourceID: 'src-01',
          sourceType: 'calDAV',
          sourceName: 'iCloud',
          color: '#007AFF',
          isImmutable: true,
        },
      ],
      mockItems: {
        'test-list-01': [
          {
            itemID: 'item-proto-1',
            title: '真实 MCP 协议查询成功',
            isCompleted: false,
            dueDate: 815961600,
            priority: 1,
            notes: '端到端客户端调用',
            listID: 'test-list-01',
          },
        ],
      },
    });

    bridgeUrl = await fakeBridge.start();
    config = {
      macserverEndpoint: bridgeUrl,
      authToken: token,
      timeoutMs: 2000,
      maxResponseSizeBytes: 1048576,
      allowedLists: [
        {
          listId: 'test-list-01',
          expectedSourceId: 'src-01',
          expectedSourceName: 'iCloud',
          expectedSourceType: 'calDAV',
        },
      ],
      expectedSourceType: 'calDAV',
      expectedSourceName: 'iCloud',
    };

    const transport = new EventKitReadonlyTransport(config);
    service = createMacServerReminderService({ transport, config });

    // 2. Initialize REAL McpServer instance
    mcpServer = new McpServer({
      name: 'apple-icloud-mcp-test',
      version: '2.0.0',
    });

    // 3. Assemble using REAL upstream registerReminderTools from commit 92bd313
    const mockSessions = {
      get: (_id: string) => ({ id: 'mock-session-account' }),
    };
    const mockLogger = {
      debug: () => {},
      warn: () => {},
      info: () => {},
      error: () => {},
    };

    // Registrar adapter matching ToolRegistrar interface into McpServer
    const toolRegistrar: ToolRegistrar = {
      registerTool(name, toolConfig, handler) {
        // Registers onto real McpServer tool registry
        mcpServer.tool(
          name,
          toolConfig.description,
          toolConfig.inputSchema as any,
          async (args: any, extra: any) => {
            const res = await handler(args, extra);
            return res as any;
          }
        );
      },
    };

    // Perform REAL assembly
    registerReminderTools(toolRegistrar, {
      sessions: mockSessions as any,
      logger: mockLogger,
      reminderFor: (_session: any) => service,
    });

    // 4. Connect REAL MCP Client via InMemoryTransport
    const [clientTransport, serverTransport] = InMemoryTransport.createLinkedPair();
    await mcpServer.connect(serverTransport);

    mcpClient = new Client(
      { name: 'test-mcp-client', version: '1.0.0' },
      { capabilities: {} }
    );
    await mcpClient.connect(clientTransport);
  });

  after(async () => {
    await mcpClient.close();
    await mcpServer.close();
    await fakeBridge.stop();
  });

  test('Real MCP Discovery: client.listTools discovers all 5 reminder tools', async () => {
    const response = await mcpClient.listTools();
    const toolNames = response.tools.map((t) => t.name);

    assert(toolNames.includes('reminders_lists'), 'Must include reminders_lists');
    assert(toolNames.includes('reminders_list'), 'Must include reminders_list');
    assert(toolNames.includes('reminders_create'), 'Must include reminders_create');
    assert(toolNames.includes('reminders_update'), 'Must include reminders_update');
    assert(toolNames.includes('reminders_delete'), 'Must include reminders_delete');
  });

  test('Real MCP Invocation: reminders_lists tool returns JSON list array with writable: false', async () => {
    const res = await mcpClient.callTool({
      name: 'reminders_lists',
      arguments: { session_id: 'test-sess-01' },
    });

    assert.strictEqual(res.isError, undefined);
    assert(Array.isArray(res.content));
    assert.strictEqual(res.content.length, 1);
    const content = res.content[0] as { type: 'text'; text: string };
    assert.strictEqual(content.type, 'text');

    const lists = JSON.parse(content.text);
    assert.strictEqual(lists.length, 1);
    assert.strictEqual(lists[0].list_id, 'test-list-01');
    assert.strictEqual(lists[0].writable, false);
  });

  test('Real MCP Invocation: reminders_list tool returns reminders matching standard schema', async () => {
    const res = await mcpClient.callTool({
      name: 'reminders_list',
      arguments: { session_id: 'test-sess-01', list_ids: ['test-list-01'] },
    });

    assert.strictEqual(res.isError, undefined);
    const content = res.content[0] as { type: 'text'; text: string };
    const data = JSON.parse(content.text);

    assert(Array.isArray(data.reminders));
    assert.strictEqual(data.reminders.length, 1);
    assert.strictEqual(data.reminders[0].reminder_id, 'item-proto-1');
    assert.strictEqual(data.reminders[0].title, '真实 MCP 协议查询成功');
    assert(data.reminders[0].due.startsWith('2026-11-10'));
  });

  test('Real MCP Invocation: reminders_create is rejected with PERMISSION_DENIED; backend write = 0', async () => {
    const initialRequests = fakeBridge.requests.length;

    const res = await mcpClient.callTool({
      name: 'reminders_create',
      arguments: {
        session_id: 'test-sess-01',
        reminder: { title: '试图调用真实创建工具' },
      },
    });

    assert.strictEqual(res.isError, true, 'MCP tool result must have isError: true');
    const content = res.content[0] as { type: 'text'; text: string };
    const errPayload = JSON.parse(content.text);

    assert.strictEqual(errPayload.error.code, 'PERMISSION_DENIED');
    assert(errPayload.error.message.includes('禁止写入并禁止回落旧 VTODO'));

    // Assert zero backend write requests
    assert.strictEqual(
      fakeBridge.requests.length,
      initialRequests,
      'Backend must receive ZERO HTTP write calls'
    );
  });

  test('Real MCP Invocation: reminders_update is rejected with PERMISSION_DENIED; backend write = 0', async () => {
    const initialRequests = fakeBridge.requests.length;

    const res = await mcpClient.callTool({
      name: 'reminders_update',
      arguments: {
        session_id: 'test-sess-01',
        reminder_id: 'item-proto-1',
        patch: { title: '更新标题' },
      },
    });

    assert.strictEqual(res.isError, true);
    const content = res.content[0] as { type: 'text'; text: string };
    const errPayload = JSON.parse(content.text);

    assert.strictEqual(errPayload.error.code, 'PERMISSION_DENIED');
    assert(errPayload.error.message.includes('禁止写入并禁止回落旧 VTODO'));
    assert.strictEqual(fakeBridge.requests.length, initialRequests);
  });

  test('Real MCP Invocation: reminders_delete is rejected with PERMISSION_DENIED; backend write = 0', async () => {
    const initialRequests = fakeBridge.requests.length;

    const res = await mcpClient.callTool({
      name: 'reminders_delete',
      arguments: {
        session_id: 'test-sess-01',
        reminder_id: 'item-proto-1',
      },
    });

    assert.strictEqual(res.isError, true);
    const content = res.content[0] as { type: 'text'; text: string };
    const errPayload = JSON.parse(content.text);

    assert.strictEqual(errPayload.error.code, 'PERMISSION_DENIED');
    assert(errPayload.error.message.includes('禁止写入并禁止回落旧 VTODO'));
    assert.strictEqual(fakeBridge.requests.length, initialRequests);
  });
});
