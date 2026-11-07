import { test, describe, before, after } from 'node:test';
import assert from 'node:assert';
import { FakeEventKitBridge } from '../src/fake-bridge.ts';
import { EventKitReadonlyTransport } from '../src/transport.ts';
import { createMacServerReminderService } from '../src/service.ts';
import { AppError, type MacServerGatewayConfig, type ReminderService } from '../src/types.ts';

// Emulating Seoul MCP server wrapTool and tool registration mechanics
// (src/server/wrap.ts and src/modules/reminders/tools.ts)
interface ToolResult {
  content: Array<{ type: 'text'; text: string }>;
  isError?: boolean;
}

interface RegisteredTool {
  name: string;
  metadata: Record<string, unknown>;
  handler: (args: Record<string, unknown>, extra?: unknown) => Promise<ToolResult>;
}

class MockToolRegistrar {
  public tools = new Map<string, RegisteredTool>();

  registerTool(
    name: string,
    metadata: Record<string, unknown>,
    handler: (args: Record<string, unknown>, extra?: unknown) => Promise<ToolResult>
  ) {
    this.tools.set(name, { name, metadata, handler });
  }
}

function wrapTool<T extends Record<string, unknown>>(
  name: string,
  handler: (args: T) => Promise<unknown>
): (args: Record<string, unknown>) => Promise<ToolResult> {
  return async (args: Record<string, unknown>): Promise<ToolResult> => {
    try {
      const result = await handler(args as T);
      return {
        content: [{ type: 'text', text: JSON.stringify(result, null, 2) }],
      };
    } catch (err: unknown) {
      const errorPayload = {
        error: {
          code: err instanceof AppError ? err.code : 'INTERNAL',
          message: err instanceof Error ? err.message : String(err),
          retryable: err instanceof AppError ? err.retryable : false,
        },
      };
      return {
        content: [{ type: 'text', text: JSON.stringify(errorPayload, null, 2) }],
        isError: true,
      };
    }
  };
}

describe('MCP Protocol-Level Tool Assembly & Write Rejection Verification', () => {
  const token = 'protocol-test-token-at-least-32chars!';
  let fakeBridge: FakeEventKitBridge;
  let bridgeUrl: string;
  let config: MacServerGatewayConfig;
  let service: ReminderService;
  let registrar: MockToolRegistrar;

  before(async () => {
    fakeBridge = new FakeEventKitBridge({
      validToken: token,
      productionAuthorized: true,
      allowedListIds: ['test-list-01'],
      mockLists: [
        {
          listID: 'test-list-01',
          title: '协议测试列表',
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
            title: '测试条目 1',
            isCompleted: false,
            dueDate: 815961600,
            priority: 1,
            notes: '备注内容',
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

    // Assemble tools onto MockToolRegistrar exactly matching registerReminderTools
    registrar = new MockToolRegistrar();

    // 1. reminders_lists
    registrar.registerTool(
      'reminders_lists',
      { title: '列出提醒列表', annotations: { readOnlyHint: true } },
      wrapTool('reminders_lists', async (_args: { session_id: string }) => service.listLists())
    );

    // 2. reminders_list
    registrar.registerTool(
      'reminders_list',
      { title: '查询提醒事项', annotations: { readOnlyHint: true } },
      wrapTool(
        'reminders_list',
        async (args: {
          session_id: string;
          list_ids?: string[];
          completed?: boolean;
          due_before?: string;
          due_after?: string;
          limit?: number;
        }) =>
          service.list({
            list_ids: args.list_ids,
            completed: args.completed,
            due_before: args.due_before,
            due_after: args.due_after,
            limit: args.limit,
          })
      )
    );

    // 3. reminders_create
    registrar.registerTool(
      'reminders_create',
      { title: '创建提醒事项', annotations: { readOnlyHint: false, destructiveHint: false } },
      wrapTool(
        'reminders_create',
        async (args: { session_id: string; list_id?: string; reminder: any }) =>
          service.create(args.reminder, args.list_id)
      )
    );

    // 4. reminders_update
    registrar.registerTool(
      'reminders_update',
      { title: '修改提醒事项', annotations: { readOnlyHint: false, destructiveHint: false } },
      wrapTool(
        'reminders_update',
        async (args: { session_id: string; reminder_id: string; patch: any }) =>
          service.update(args.reminder_id, args.patch)
      )
    );

    // 5. reminders_delete
    registrar.registerTool(
      'reminders_delete',
      { title: '删除提醒事项', annotations: { readOnlyHint: false, destructiveHint: true } },
      wrapTool('reminders_delete', async (args: { session_id: string; reminder_id: string }) =>
        service.remove(args.reminder_id)
      )
    );
  });

  after(async () => {
    await fakeBridge.stop();
  });

  test('MCP Protocol: reminders_lists tool returns standard MCP text payload', async () => {
    const tool = registrar.tools.get('reminders_lists')!;
    const res = await tool.handler({ session_id: 'sess-123' });

    assert.strictEqual(res.isError, undefined);
    assert.strictEqual(res.content.length, 1);
    assert.strictEqual(res.content[0]?.type, 'text');

    const data = JSON.parse(res.content[0]!.text);
    assert.strictEqual(data.length, 1);
    assert.strictEqual(data[0].list_id, 'test-list-01');
    assert.strictEqual(data[0].writable, false);
  });

  test('MCP Protocol: reminders_list tool returns reminders matching standard schema', async () => {
    const tool = registrar.tools.get('reminders_list')!;
    const res = await tool.handler({ session_id: 'sess-123', list_ids: ['test-list-01'] });

    assert.strictEqual(res.isError, undefined);
    const data = JSON.parse(res.content[0]!.text);
    assert.strictEqual(data.reminders.length, 1);
    assert.strictEqual(data.reminders[0].reminder_id, 'item-proto-1');
    assert.strictEqual(data.reminders[0].title, '测试条目 1');
  });

  test('MCP Protocol: reminders_create is rejected with PERMISSION_DENIED and ZERO write forwarding', async () => {
    const tool = registrar.tools.get('reminders_create')!;
    const initialRequestsCount = fakeBridge.requests.length;

    const res = await tool.handler({
      session_id: 'sess-123',
      reminder: { title: '试图创建新提醒' },
    });

    assert.strictEqual(res.isError, true, 'Result must be flagged isError: true');
    const errData = JSON.parse(res.content[0]!.text);
    assert.strictEqual(errData.error.code, 'PERMISSION_DENIED');
    assert(errData.error.message.includes('禁止写入并禁止回落旧 VTODO'));

    // Assert zero write requests were forwarded over HTTP
    assert.strictEqual(
      fakeBridge.requests.length,
      initialRequestsCount,
      'Fake Bridge must receive ZERO HTTP write requests'
    );
  });

  test('MCP Protocol: reminders_update is rejected with PERMISSION_DENIED and ZERO write forwarding', async () => {
    const tool = registrar.tools.get('reminders_update')!;
    const initialRequestsCount = fakeBridge.requests.length;

    const res = await tool.handler({
      session_id: 'sess-123',
      reminder_id: 'item-proto-1',
      patch: { title: '试图更新' },
    });

    assert.strictEqual(res.isError, true);
    const errData = JSON.parse(res.content[0]!.text);
    assert.strictEqual(errData.error.code, 'PERMISSION_DENIED');
    assert(errData.error.message.includes('禁止写入并禁止回落旧 VTODO'));
    assert.strictEqual(fakeBridge.requests.length, initialRequestsCount);
  });

  test('MCP Protocol: reminders_delete is rejected with PERMISSION_DENIED and ZERO write forwarding', async () => {
    const tool = registrar.tools.get('reminders_delete')!;
    const initialRequestsCount = fakeBridge.requests.length;

    const res = await tool.handler({
      session_id: 'sess-123',
      reminder_id: 'item-proto-1',
    });

    assert.strictEqual(res.isError, true);
    const errData = JSON.parse(res.content[0]!.text);
    assert.strictEqual(errData.error.code, 'PERMISSION_DENIED');
    assert(errData.error.message.includes('禁止写入并禁止回落旧 VTODO'));
    assert.strictEqual(fakeBridge.requests.length, initialRequestsCount);
  });
});
