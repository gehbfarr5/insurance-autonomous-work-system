import { describe, it, expect, beforeAll, afterAll } from 'vitest';
import http from 'node:http';
import type { AddressInfo } from 'node:net';
import { EventKitReadonlyTransport } from '../../../src/modules/reminders/gateway/transport.js';
import { createMacServerReminderService } from '../../../src/modules/reminders/gateway/service.js';
import { getGatewayReminderService, isMacServerGatewayConfigured } from '../../../src/modules/reminders/gateway/index.js';
import type { MacServerGatewayConfig } from '../../../src/modules/reminders/gateway/types.js';
import type { Session } from '../../../src/core/session.js';
import type { AccountConfig } from '../../../src/core/config.js';

describe('MacServer Reminder Gateway Upstream Integration', () => {
  let server: http.Server;
  let serverUrl: string;
  const validToken = 'test-token-valid-gateway-secret-32b';
  let bridgeWriteCalls = 0;
  let serverConnections = 0;
  let activeSockets = new Set<any>();

  const mockLists = [
    {
      listID: 'list-allowed-1',
      title: '工作事项',
      sourceID: 'source-icloud-1',
      sourceType: 'calDAV',
      sourceName: 'iCloud',
      color: '#007AFF',
      isImmutable: true,
    },
    {
      listID: 'list-unallowed-2',
      title: '私密事项',
      sourceID: 'source-icloud-1',
      sourceType: 'calDAV',
      sourceName: 'iCloud',
      color: '#34C759',
      isImmutable: true,
    },
  ];

  const mockItems = [
    {
      itemID: 'item-001',
      listID: 'list-allowed-1',
      title: '测试提醒1',
      isCompleted: false,
      priority: 1,
      dueDate: '2026-11-08T10:00:00.000Z',
    },
    {
      itemID: 'item-002',
      listID: 'list-allowed-1',
      title: '测试提醒2（已完成）',
      isCompleted: true,
      priority: 0,
      completionDate: '2026-11-08T12:00:00.000Z',
    },
  ];

  let customItemsResponse: any = null;

  beforeAll(async () => {
    server = http.createServer((req, res) => {
      const auth = req.headers['authorization'];
      if (auth !== `Bearer ${validToken}`) {
        res.writeHead(401, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ error: 'UNAUTHORIZED' }));
        return;
      }

      if (req.method !== 'GET') {
        bridgeWriteCalls++;
        res.writeHead(405, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ error: 'METHOD_NOT_ALLOWED' }));
        return;
      }

      const url = new URL(req.url ?? '/', `http://${req.headers.host}`);

      // Stalled body stream endpoint: sends 200 headers immediately, then stalls permanently
      if (url.pathname === '/reminders/lists/stalled-stream' || url.pathname === '/reminders/lists/stalled-stream/items') {
        res.writeHead(200, {
          'Content-Type': 'application/json',
          'Transfer-Encoding': 'chunked',
        });
        res.flushHeaders?.();
        // Never send body data and never close
        return;
      }

      if (url.pathname === '/reminders/lists') {
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify(mockLists));
        return;
      }

      const itemMatch = url.pathname.match(/^\/reminders\/lists\/([^/]+)\/items$/);
      if (itemMatch) {
        const listId = decodeURIComponent(itemMatch[1]);
        if (customItemsResponse !== null) {
          res.writeHead(200, { 'Content-Type': 'application/json' });
          res.end(JSON.stringify(customItemsResponse));
          return;
        }
        if (listId === 'list-allowed-1') {
          res.writeHead(200, { 'Content-Type': 'application/json' });
          res.end(JSON.stringify(mockItems));
          return;
        }
        res.writeHead(404, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ error: 'NOT_FOUND' }));
        return;
      }

      res.writeHead(404, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ error: 'NOT_FOUND' }));
    });

    server.on('connection', (socket) => {
      serverConnections++;
      activeSockets.add(socket);
      socket.on('close', () => activeSockets.delete(socket));
    });

    await new Promise<void>((resolve) => {
      server.listen(0, '127.0.0.1', () => resolve());
    });
    const addr = server.address() as AddressInfo;
    serverUrl = `http://127.0.0.1:${addr.port}`;
  });

  afterAll(async () => {
    for (const socket of activeSockets) {
      socket.destroy();
    }
    await new Promise<void>((resolve) => server.close(() => resolve()));
  });

  function makeAccount(caps: Partial<AccountConfig['capabilities']> = {}): AccountConfig {
    return {
      id: 'acc_test_gateway',
      email: 'test@icloud.com',
      sender: 'test@icloud.com',
      label: 'test@icloud.com',
      capabilities: {
        mailRead: false,
        mailWrite: false,
        calendarRead: false,
        calendarWrite: false,
        remindersRead: true,
        remindersWrite: false,
        contactsRead: false,
        contactsWrite: false,
        ...caps,
      },
    };
  }

  it('correctly reports isMacServerGatewayConfigured', () => {
    delete process.env.MACSERVER_EVENTKIT_ENDPOINT;
    delete process.env.EVENTKIT_GATEWAY_ENDPOINT;
    delete process.env.EVENTKIT_BRIDGE_ENDPOINT;
    expect(isMacServerGatewayConfigured()).toBe(false);

    process.env.MACSERVER_EVENTKIT_ENDPOINT = serverUrl;
    expect(isMacServerGatewayConfigured()).toBe(true);
  });

  it('lists bound lists and filters unallowed lists', async () => {
    const config: MacServerGatewayConfig = {
      macserverEndpoint: serverUrl,
      authToken: validToken,
      timeoutMs: 3000,
      maxResponseSizeBytes: 1048576,
      allowedLists: [
        {
          listId: 'list-allowed-1',
          expectedSourceId: 'source-icloud-1',
          expectedSourceName: 'iCloud',
          expectedSourceType: 'calDAV',
        },
      ],
      expectedSourceType: 'calDAV',
    };

    const transport = new EventKitReadonlyTransport(config);
    const service = createMacServerReminderService({
      transport,
      config,
      account: makeAccount(),
    });

    const lists = await service.listLists();
    expect(lists).toHaveLength(1);
    expect(lists[0].list_id).toBe('list-allowed-1');
    expect(lists[0].name).toBe('工作事项');
    expect(lists[0].writable).toBe(false);
  });

  it('queries reminders in allowed list with standard Reminder schema', async () => {
    const config: MacServerGatewayConfig = {
      macserverEndpoint: serverUrl,
      authToken: validToken,
      timeoutMs: 3000,
      maxResponseSizeBytes: 1048576,
      allowedLists: [
        {
          listId: 'list-allowed-1',
          expectedSourceId: 'source-icloud-1',
          expectedSourceName: 'iCloud',
          expectedSourceType: 'calDAV',
        },
      ],
    };

    const transport = new EventKitReadonlyTransport(config);
    const service = createMacServerReminderService({
      transport,
      config,
      account: makeAccount(),
    });

    const result = await service.list({ list_ids: ['list-allowed-1'] });
    expect(result.reminders).toHaveLength(2);
    expect(result.reminders[0].reminder_id).toBe('item-001');
    expect(result.reminders[0].title).toBe('测试提醒1');
    expect(result.reminders[0].completed).toBe(false);
    expect(result.reminders[1].reminder_id).toBe('item-002');
    expect(result.reminders[1].completed).toBe(true);
  });

  it('Unified Deadline: stalled response body stream fails within timeout and releases connection', async () => {
    const shortTimeoutMs = 600;
    const config: MacServerGatewayConfig = {
      macserverEndpoint: serverUrl,
      authToken: validToken,
      timeoutMs: shortTimeoutMs,
      maxResponseSizeBytes: 1048576,
      allowedLists: [
        {
          listId: 'stalled-stream',
          expectedSourceId: 'source-icloud-1',
        },
      ],
    };

    const stalledTransport = new EventKitReadonlyTransport(config);

    const directStart = Date.now();
    await expect(
      stalledTransport.fetchReminders('stalled-stream')
    ).rejects.toThrow(/超时/);
    const elapsed = Date.now() - directStart;
    expect(elapsed).toBeGreaterThanOrEqual(500);
    expect(elapsed).toBeLessThan(1500);
  });

  describe('Strict Item Field Validation', () => {
    const getItemValidationConfig = (): MacServerGatewayConfig => ({
      macserverEndpoint: serverUrl,
      authToken: validToken,
      timeoutMs: 3000,
      maxResponseSizeBytes: 1048576,
      allowedLists: [
        {
          listId: 'list-allowed-1',
          expectedSourceId: 'source-icloud-1',
          expectedSourceName: 'iCloud',
          expectedSourceType: 'calDAV',
        },
      ],
    });

    afterAll(() => {
      customItemsResponse = null;
    });

    it('rejects items missing itemID', async () => {
      customItemsResponse = [
        { listID: 'list-allowed-1', title: '有标题无ID', isCompleted: false },
      ];
      const config = getItemValidationConfig();
      const transport = new EventKitReadonlyTransport(config);
      const service = createMacServerReminderService({ transport, config, account: makeAccount() });
      await expect(service.list({ list_ids: ['list-allowed-1'] })).rejects.toThrow(/itemID/);
    });

    it('rejects items missing listID', async () => {
      customItemsResponse = [
        { itemID: 'item-missing-list', title: '无listID', isCompleted: false },
      ];
      const config = getItemValidationConfig();
      const transport = new EventKitReadonlyTransport(config);
      const service = createMacServerReminderService({ transport, config, account: makeAccount() });
      await expect(service.list({ list_ids: ['list-allowed-1'] })).rejects.toThrow(/listID/);
    });

    it('rejects items with empty or mismatched listID', async () => {
      customItemsResponse = [
        { itemID: 'item-mismatch', listID: 'foreign-list-id', title: '篡改归属', isCompleted: false },
      ];
      const config = getItemValidationConfig();
      const transport = new EventKitReadonlyTransport(config);
      const service = createMacServerReminderService({ transport, config, account: makeAccount() });
      await expect(service.list({ list_ids: ['list-allowed-1'] })).rejects.toThrow(/不匹配|不一致/);
    });

    it('rejects items missing title', async () => {
      customItemsResponse = [
        { itemID: 'item-no-title', listID: 'list-allowed-1', isCompleted: false },
      ];
      const config = getItemValidationConfig();
      const transport = new EventKitReadonlyTransport(config);
      const service = createMacServerReminderService({ transport, config, account: makeAccount() });
      await expect(service.list({ list_ids: ['list-allowed-1'] })).rejects.toThrow(/title/);
    });

    it('rejects items missing isCompleted or with non-boolean completed state', async () => {
      customItemsResponse = [
        { itemID: 'item-bad-completed', listID: 'list-allowed-1', title: '非法完成状态', isCompleted: 'yes' },
      ];
      const config = getItemValidationConfig();
      const transport = new EventKitReadonlyTransport(config);
      const service = createMacServerReminderService({ transport, config, account: makeAccount() });
      await expect(service.list({ list_ids: ['list-allowed-1'] })).rejects.toThrow(/isCompleted/);
    });

    it('rejects error response objects masquerading as items', async () => {
      customItemsResponse = [
        { error: 'Simulated bridge error' },
      ];
      const config = getItemValidationConfig();
      const transport = new EventKitReadonlyTransport(config);
      const service = createMacServerReminderService({ transport, config, account: makeAccount() });
      await expect(service.list({ list_ids: ['list-allowed-1'] })).rejects.toThrow(/错误对象/);
    });
  });

  it('rejects unallowed list querying with clear error', async () => {
    const config: MacServerGatewayConfig = {
      macserverEndpoint: serverUrl,
      authToken: validToken,
      timeoutMs: 3000,
      maxResponseSizeBytes: 1048576,
      allowedLists: [
        {
          listId: 'list-allowed-1',
          expectedSourceId: 'source-icloud-1',
        },
      ],
    };

    const transport = new EventKitReadonlyTransport(config);
    const service = createMacServerReminderService({
      transport,
      config,
      account: makeAccount(),
    });

    await expect(service.list({ list_ids: ['list-unallowed-2'] })).rejects.toThrow(
      '指定的提醒列表不存在或不对应任何已显式绑定的 iCloud 提醒列表'
    );
  });

  it('strictly rejects write operations with 0 network calls and 0 VTODO fallback', async () => {
    const initialWriteCalls = bridgeWriteCalls;
    const config: MacServerGatewayConfig = {
      macserverEndpoint: serverUrl,
      authToken: validToken,
      timeoutMs: 3000,
      maxResponseSizeBytes: 1048576,
      allowedLists: [
        {
          listId: 'list-allowed-1',
          expectedSourceId: 'source-icloud-1',
        },
      ],
    };

    const transport = new EventKitReadonlyTransport(config);
    const service = createMacServerReminderService({
      transport,
      config,
      account: makeAccount(),
    });

    await expect(service.create({ title: '新任务' })).rejects.toThrow('只读');
    await expect(service.update('item-001', { title: '修改任务' })).rejects.toThrow('只读');
    await expect(service.remove('item-001')).rejects.toThrow('只读');

    expect(bridgeWriteCalls).toBe(initialWriteCalls);
  });

  it('enforces session account capabilities.remindersRead', async () => {
    process.env.MACSERVER_EVENTKIT_ENDPOINT = serverUrl;
    process.env.MACSERVER_EVENTKIT_AUTH_TOKEN = validToken;
    process.env.MACSERVER_EVENTKIT_ALLOWED_LISTS = 'list-allowed-1:source-icloud-1';

    const disabledAccount = makeAccount({ remindersRead: false });
    const fakeSession = {
      id: 'sess-001',
      account: disabledAccount,
      providers: {},
    } as unknown as Session;

    const gatewayService = getGatewayReminderService(fakeSession);

    await expect(gatewayService.listLists()).rejects.toThrow('读取权限未开启');
    await expect(gatewayService.list({ list_ids: ['list-allowed-1'] })).rejects.toThrow('读取权限未开启');
  });
});
