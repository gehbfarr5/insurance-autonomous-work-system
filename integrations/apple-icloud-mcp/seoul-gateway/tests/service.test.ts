import { test, describe, before, after } from 'node:test';
import assert from 'node:assert';
import { FakeEventKitBridge } from '../src/fake-bridge.ts';
import { EventKitReadonlyTransport } from '../src/transport.ts';
import { createMacServerReminderService } from '../src/service.ts';
import { AppError, type MacServerGatewayConfig, type ReminderService } from '../src/types.ts';

describe('MacServerReminderService with Fake Bridge', () => {
  const token = 'valid-test-bearer-token-at-least-32chars!';
  let fakeBridge: FakeEventKitBridge;
  let bridgeUrl: string;
  let config: MacServerGatewayConfig;
  let service: ReminderService;

  before(async () => {
    fakeBridge = new FakeEventKitBridge({
      validToken: token,
      productionAuthorized: true,
      allowedListIds: ['list-icloud-01', 'list-icloud-02'],
      mockLists: [
        {
          listID: 'list-icloud-01',
          title: '工作',
          sourceID: 'src-icloud',
          sourceType: 'calDAV',
          sourceName: 'iCloud',
          color: '#007AFF',
          isImmutable: true,
        },
        {
          listID: 'list-icloud-02',
          title: '个人',
          sourceID: 'src-icloud',
          sourceType: 'calDAV',
          sourceName: 'iCloud',
          color: '#34C759',
          isImmutable: true,
        },
        {
          listID: 'list-foreign-source-id',
          title: '伪造来源列表',
          sourceID: 'src-foreign-fake',
          sourceType: 'calDAV',
          sourceName: 'iCloud',
          color: '#FF9500',
          isImmutable: true,
        },
        {
          listID: 'list-local-foreign',
          title: '本地杂项',
          sourceID: 'src-local',
          sourceType: 'local',
          sourceName: 'On My Mac',
          color: '#8E8E93',
          isImmutable: true,
        },
      ],
      mockItems: {
        'list-icloud-01': [
          {
            itemID: 'item-01',
            title: 'B：明天上午核保会议',
            isCompleted: false,
            // 815926800 in Cocoa seconds = 2026-11-09T15:20:00.000Z
            dueDate: 815926800,
            priority: 1,
            notes: '核实理赔条款附录',
            listID: 'list-icloud-01',
          },
          {
            itemID: 'item-02',
            title: 'A：今天下午客户电话',
            isCompleted: true,
            // 815840400 in Cocoa seconds = 2026-11-08T15:20:00.000Z
            dueDate: 815840400,
            priority: 5,
            notes: '解答免赔额疑问',
            listID: 'list-icloud-01',
          },
          {
            itemID: 'item-03',
            title: 'C：无截止日期待办',
            isCompleted: false,
            dueDate: null,
            priority: 0,
            notes: null,
            listID: 'list-icloud-01',
          },
        ],
        'list-icloud-02': [
          {
            itemID: 'item-04',
            title: 'D：私人账单',
            isCompleted: false,
            // 816187200 in Cocoa seconds = 2026-11-12T15:20:00.000Z
            dueDate: 816187200,
            priority: 9,
            notes: null,
            listID: 'list-icloud-02',
          },
        ],
      },
    });

    bridgeUrl = await fakeBridge.start();
    config = {
      macserverEndpoint: bridgeUrl,
      authToken: token,
      timeoutMs: 2000,
      maxResponseSizeBytes: 1024 * 1024,
      allowedLists: [
        {
          listId: 'list-icloud-01',
          expectedSourceId: 'src-icloud',
          expectedSourceName: 'iCloud',
          expectedSourceType: 'calDAV',
        },
        {
          listId: 'list-icloud-02',
          expectedSourceId: 'src-icloud',
          expectedSourceName: 'iCloud',
          expectedSourceType: 'calDAV',
        },
        {
          listId: 'list-foreign-source-id',
          expectedSourceId: 'src-legit-expected-not-matching', // Mismatched!
          expectedSourceName: 'iCloud',
          expectedSourceType: 'calDAV',
        },
      ],
      expectedSourceType: 'calDAV',
      expectedSourceName: 'iCloud',
    };
    const transport = new EventKitReadonlyTransport(config);
    service = createMacServerReminderService({ transport, config });
  });

  after(async () => {
    await fakeBridge.stop();
  });

  test('listLists filters out non-iCloud sources and mismatched source IDs, marks writable: false', async () => {
    const lists = await service.listLists();
    assert.strictEqual(lists.length, 2, 'Filtered out On My Mac, unbound lists, and mismatched source ID lists');

    const ids = lists.map((l) => l.list_id);
    assert(ids.includes('list-icloud-01'));
    assert(ids.includes('list-icloud-02'));
    assert(!ids.includes('list-local-foreign'));
    assert(!ids.includes('list-foreign-source-id'));

    for (const l of lists) {
      assert.strictEqual(l.writable, false, 'Gateway lists are strictly non-writable');
    }
  });

  test('list queries all lists and sorts deterministically with Swift Cocoa dates', async () => {
    const res = await service.list({});
    assert.strictEqual(res.reminders.length, 4);

    // Expected order:
    // 1. item-02 (2026-11-08)
    // 2. item-01 (2026-11-09)
    // 3. item-04 (2026-11-12)
    // 4. item-03 (due is undefined, placed last)
    assert.strictEqual(res.reminders[0]?.reminder_id, 'item-02');
    assert.strictEqual(res.reminders[1]?.reminder_id, 'item-01');
    assert.strictEqual(res.reminders[2]?.reminder_id, 'item-04');
    assert.strictEqual(res.reminders[3]?.reminder_id, 'item-03');

    // Verify converted ISO dates
    assert(res.reminders[0]?.due?.startsWith('2026-11-08'));
    assert(res.reminders[1]?.due?.startsWith('2026-11-09'));
    assert(res.reminders[2]?.due?.startsWith('2026-11-12'));
  });

  test('list filtering by completed: true and false', async () => {
    const completedRes = await service.list({ completed: true });
    assert.strictEqual(completedRes.reminders.length, 1);
    assert.strictEqual(completedRes.reminders[0]?.reminder_id, 'item-02');

    const pendingRes = await service.list({ completed: false });
    assert.strictEqual(pendingRes.reminders.length, 3);
    assert(pendingRes.reminders.every((r) => r.completed === false));
  });

  test('list filtering by due_before and due_after', async () => {
    const rangeRes = await service.list({
      due_after: '2026-11-09T00:00:00.000Z',
      due_before: '2026-11-10T00:00:00.000Z',
    });
    assert.strictEqual(rangeRes.reminders.length, 1);
    assert.strictEqual(rangeRes.reminders[0]?.reminder_id, 'item-01');
  });

  test('list limit and truncation flag', async () => {
    const limitedRes = await service.list({ limit: 2 });
    assert.strictEqual(limitedRes.reminders.length, 2);
    assert.strictEqual(limitedRes.truncated, true);
  });

  test('list targeting specific list_ids', async () => {
    const res = await service.list({ list_ids: ['list-icloud-02'] });
    assert.strictEqual(res.reminders.length, 1);
    assert.strictEqual(res.reminders[0]?.reminder_id, 'item-04');
    assert.strictEqual(res.reminders[0]?.list_id, 'list-icloud-02');
  });

  test('list throws NOT_FOUND when requested list_id is missing or unbound', async () => {
    await assert.rejects(
      async () => service.list({ list_ids: ['non-existent-uuid'] }),
      (err: unknown) => {
        assert(err instanceof AppError);
        assert.strictEqual(err.code, 'NOT_FOUND');
        assert(err.message.includes('不对应任何已显式绑定的 iCloud 提醒列表'));
        return true;
      }
    );
  });

  test('Item ownership validation: cross-list item mismatch throws UPSTREAM_ERROR', async () => {
    // Inject a rogue item into list-icloud-01 that claims listID="list-another-leak"
    fakeBridge.mockItems.set('list-icloud-01', [
      {
        itemID: 'rogue-item-999',
        title: '跨列表泄漏条目',
        isCompleted: false,
        dueDate: null,
        priority: 0,
        notes: null,
        listID: 'list-another-leak', // Mismatch!
      },
    ]);

    try {
      await assert.rejects(
        async () => service.list({ list_ids: ['list-icloud-01'] }),
        (err: unknown) => {
          assert(err instanceof AppError);
          assert.strictEqual(err.code, 'UPSTREAM_ERROR');
          assert(err.message.includes('与请求的目标列表'));
          return true;
        }
      );
    } finally {
      // Restore valid items
      fakeBridge.mockItems.set('list-icloud-01', [
        {
          itemID: 'item-01',
          title: 'B：明天上午核保会议',
          isCompleted: false,
          dueDate: 815926800,
          priority: 1,
          notes: '核实理赔条款附录',
          listID: 'list-icloud-01',
        },
      ]);
    }
  });

  test('Write operations (create, update, remove) are strictly rejected with PERMISSION_DENIED', async () => {
    await assert.rejects(
      async () => service.create({ title: 'New Test Reminder' }),
      (err: unknown) => {
        assert(err instanceof AppError);
        assert.strictEqual(err.code, 'PERMISSION_DENIED');
        assert(err.message.includes('禁止写入并禁止回落旧 VTODO'));
        return true;
      }
    );

    await assert.rejects(
      async () => service.update('item-01', { title: 'Updated' }),
      (err: unknown) => {
        assert(err instanceof AppError);
        assert.strictEqual(err.code, 'PERMISSION_DENIED');
        assert(err.message.includes('禁止写入并禁止回落旧 VTODO'));
        return true;
      }
    );

    await assert.rejects(
      async () => service.remove('item-01'),
      (err: unknown) => {
        assert(err instanceof AppError);
        assert.strictEqual(err.code, 'PERMISSION_DENIED');
        assert(err.message.includes('禁止写入并禁止回落旧 VTODO'));
        return true;
      }
    );
  });

  test('NEGATIVE ASSERTION: When backend server fails, service throws error instead of returning empty list', async () => {
    fakeBridge.simulateServerError = true;
    try {
      await assert.rejects(
        async () => service.list({ list_ids: ['list-icloud-01'] }),
        (err: unknown) => {
          assert(err instanceof AppError);
          assert.strictEqual(err.code, 'UPSTREAM_ERROR');
          return true;
        }
      );
    } finally {
      fakeBridge.simulateServerError = false;
    }
  });
});
