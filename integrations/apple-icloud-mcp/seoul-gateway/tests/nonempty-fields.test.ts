// nonempty-fields.test.ts
// AG-05 | feat/ag05-resident-readonly-candidate
//
// Tests rich non-empty reminder fields mapping, date semantics, timezone handling,
// priority mappings, completion status, sorting, and negative assertions.

import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { createMacServerReminderService } from '../src/service.ts';
import { EventKitReadonlyTransport } from '../src/transport.ts';
import { AppError, type MacServerGatewayConfig, type ReminderItem, type RemindersList } from '../src/types.ts';

const TEST_LIST_ID = '00000000-0000-0000-0000-000000000001';
const TEST_SOURCE_ID = '00000000-0000-0000-0000-000000000002';

const testConfig: MacServerGatewayConfig = {
  macserverEndpoint: 'http://127.0.0.1:18765',
  authToken: 'test-token-valid-00000000000000000000000000000000',
  timeoutMs: 3000,
  maxResponseSizeBytes: 1048576,
  allowedLists: [
    {
      listId: TEST_LIST_ID,
      expectedSourceId: TEST_SOURCE_ID,
      expectedSourceName: 'iCloud',
      expectedSourceType: 'calDAV',
    },
  ],
  expectedSourceName: 'iCloud',
  expectedSourceType: 'calDAV',
};

const syntheticMetadata: RemindersList[] = [
  {
    listID: TEST_LIST_ID,
    title: 'MUSE 测试',
    sourceID: TEST_SOURCE_ID,
    sourceName: 'iCloud',
    sourceType: 'calDAV',
    color: '#007AFF',
    isImmutable: false,
  },
];

// Rich non-empty synthetic items representing actual Apple EventKit mapping
const syntheticRichItems: ReminderItem[] = [
  {
    itemID: 'item-001',
    listID: TEST_LIST_ID,
    title: '📋 投保人保单复核 (高优先 ⚠️)',
    isCompleted: false,
    priority: 1, // High
    notes: '详细需求：\n1. 重疾险保额确认 ¥1,000,000\n2. 附加医疗特约条款',
    // 2026-11-09T08:30:00Z -> Cocoa epoch: (1794126600 - 978307200) = 815819400
    dueDate: 815819400,
    creationDate: 815700000,
    isAllDay: false,
    timeZone: 'Asia/Shanghai',
  },
  {
    itemID: 'item-002',
    listID: TEST_LIST_ID,
    title: '全天合规申报节点',
    isCompleted: false,
    priority: 5, // Medium
    notes: '年检申报截止日（全天事项，无指定时分）',
    // 2026-11-10T00:00:00Z -> Cocoa epoch: 815875200
    dueDate: 815875200,
    creationDate: 815700000,
    isAllDay: true,
  },
  {
    itemID: 'item-003',
    listID: TEST_LIST_ID,
    title: '已完成理赔回访',
    isCompleted: true,
    priority: 9, // Low
    notes: '结案回访确认满意度 5 星',
    dueDate: 815600000,
    completionDate: 815650000,
    creationDate: 815500000,
  },
  {
    itemID: 'item-004',
    listID: TEST_LIST_ID,
    title: '无截止日期备忘事项',
    isCompleted: false,
    priority: 0, // None
    notes: undefined,
    dueDate: undefined,
    creationDate: 815700000,
  },
];

describe('AG-05: Non-Empty Reminder Fields & Semantics Verification', () => {
  it('correctly maps rich non-empty fields (title, multiline notes, priority, emojis)', async () => {
    const mockTransport = {
      fetchListsMetadata: async () => syntheticMetadata,
      fetchReminders: async (listId: string) => {
        assert.equal(listId, TEST_LIST_ID);
        return syntheticRichItems;
      },
      rejectWrite: async () => { throw new AppError('PERMISSION_DENIED', 'write blocked'); },
    } as unknown as EventKitReadonlyTransport;

    const service = createMacServerReminderService({ transport: mockTransport, config: testConfig });
    const result = await service.list({ list_ids: [TEST_LIST_ID] });

    assert.equal(result.reminders.length, 4);

    // Verify item-001 (High priority with multiline unicode & emoji)
    const item1 = result.reminders.find((r) => r.id === 'item-001');
    assert.ok(item1);
    assert.equal(item1.title, '📋 投保人保单复核 (高优先 ⚠️)');
    assert.equal(item1.priority, 1);
    assert.equal(item1.completed, false);
    assert.equal(item1.is_all_day, false);
    assert.equal(item1.time_zone, 'Asia/Shanghai');
    assert.equal(item1.due, '2026-11-08T08:30:00.000Z');
    assert.ok(item1.notes?.includes('¥1,000,000'));
    assert.ok(item1.notes?.includes('\n'));
    assert.ok(item1.created);

    // Verify item-002 (All-day milestone)
    const item2 = result.reminders.find((r) => r.id === 'item-002');
    assert.ok(item2);
    assert.equal(item2.is_all_day, true);
    assert.equal(item2.due, '2026-11-09T00:00:00.000Z');

    // Verify item-003 (Completed with completionDate)
    const item3 = result.reminders.find((r) => r.id === 'item-003');
    assert.ok(item3);
    assert.equal(item3.completed, true);
    assert.equal(item3.priority, 9);
    assert.equal(item3.completed_at, '2026-11-06T09:26:40.000Z');
    assert.equal(item3.due, '2026-11-05T19:33:20.000Z');
  });

  it('correctly handles all-day vs timed due dates', async () => {
    const mockTransport = {
      fetchListsMetadata: async () => syntheticMetadata,
      fetchReminders: async () => syntheticRichItems,
      rejectWrite: async () => { throw new AppError('PERMISSION_DENIED', 'write blocked'); },
    } as unknown as EventKitReadonlyTransport;

    const service = createMacServerReminderService({ transport: mockTransport, config: testConfig });
    const result = await service.list({ list_ids: [TEST_LIST_ID] });

    const timedItem = result.reminders.find((r) => r.id === 'item-001');
    const allDayItem = result.reminders.find((r) => r.id === 'item-002');
    const noDueItem = result.reminders.find((r) => r.id === 'item-004');

    assert.ok(timedItem?.due);
    assert.ok(allDayItem?.due);
    assert.equal(noDueItem?.due, undefined);

    // Date objects parsed from ISO strings
    const timedDate = new Date(timedItem.due!);
    const allDayDate = new Date(allDayItem.due!);
    assert.ok(!Number.isNaN(timedDate.getTime()));
    assert.ok(!Number.isNaN(allDayDate.getTime()));
    assert.ok(allDayDate.getTime() > timedDate.getTime());
  });

  it('correctly filters by completion status', async () => {
    const mockTransport = {
      fetchListsMetadata: async () => syntheticMetadata,
      fetchReminders: async () => syntheticRichItems,
      rejectWrite: async () => { throw new AppError('PERMISSION_DENIED', 'write blocked'); },
    } as unknown as EventKitReadonlyTransport;

    const service = createMacServerReminderService({ transport: mockTransport, config: testConfig });

    const completedOnly = await service.list({ list_ids: [TEST_LIST_ID], completed: true });
    assert.equal(completedOnly.reminders.length, 1);
    assert.equal(completedOnly.reminders[0].id, 'item-003');

    const pendingOnly = await service.list({ list_ids: [TEST_LIST_ID], completed: false });
    assert.equal(pendingOnly.reminders.length, 3);
    assert.ok(!pendingOnly.reminders.some((r) => r.id === 'item-003'));
  });

  it('correctly filters by due_after and due_before', async () => {
    const mockTransport = {
      fetchListsMetadata: async () => syntheticMetadata,
      fetchReminders: async () => syntheticRichItems,
      rejectWrite: async () => { throw new AppError('PERMISSION_DENIED', 'write blocked'); },
    } as unknown as EventKitReadonlyTransport;

    const service = createMacServerReminderService({ transport: mockTransport, config: testConfig });

    // Range filtering around 2026-11-08
    const filtered = await service.list({
      list_ids: [TEST_LIST_ID],
      due_after: '2026-11-08T00:00:00Z',
      due_before: '2026-11-08T23:59:59Z',
    });

    assert.equal(filtered.reminders.length, 1);
    assert.equal(filtered.reminders[0].id, 'item-001');
  });

  it('sorts reminders deterministically (due ascending, then title alphabetically)', async () => {
    const mockTransport = {
      fetchListsMetadata: async () => syntheticMetadata,
      fetchReminders: async () => syntheticRichItems,
      rejectWrite: async () => { throw new AppError('PERMISSION_DENIED', 'write blocked'); },
    } as unknown as EventKitReadonlyTransport;

    const service = createMacServerReminderService({ transport: mockTransport, config: testConfig });
    const result = await service.list({ list_ids: [TEST_LIST_ID] });

    // item-003 is oldest due date (815600000)
    // item-001 is second (815819400)
    // item-002 is third (815875200)
    // item-004 has no due date (sorted to end)
    assert.equal(result.reminders[0].id, 'item-003');
    assert.equal(result.reminders[1].id, 'item-001');
    assert.equal(result.reminders[2].id, 'item-002');
    assert.equal(result.reminders[3].id, 'item-004');
  });

  it('strictly rejects corrupted items missing essential fields', async () => {
    const corruptItems: unknown[] = [
      { listID: TEST_LIST_ID, title: 'No itemID', isCompleted: false },
    ];

    const mockTransport = {
      fetchListsMetadata: async () => syntheticMetadata,
      fetchReminders: async () => corruptItems as ReminderItem[],
      rejectWrite: async () => { throw new AppError('PERMISSION_DENIED', 'write blocked'); },
    } as unknown as EventKitReadonlyTransport;

    const service = createMacServerReminderService({ transport: mockTransport, config: testConfig });
    await assert.rejects(
      async () => service.list({ list_ids: [TEST_LIST_ID] }),
      (err: any) => err instanceof AppError && err.code === 'UPSTREAM_ERROR' && err.message.includes('必需的 itemID')
    );
  });

  it('NEGATIVE ASSERTION: upstream error is never masked as empty array', async () => {
    const mockTransport = {
      fetchListsMetadata: async () => syntheticMetadata,
      fetchReminders: async () => {
        throw new AppError('UPSTREAM_ERROR', 'MacServer bridge connection refused');
      },
      rejectWrite: async () => { throw new AppError('PERMISSION_DENIED', 'write blocked'); },
    } as unknown as EventKitReadonlyTransport;

    const service = createMacServerReminderService({ transport: mockTransport, config: testConfig });
    await assert.rejects(
      async () => service.list({ list_ids: [TEST_LIST_ID] }),
      (err: any) => err instanceof AppError && err.code === 'UPSTREAM_ERROR' && err.message.includes('connection refused')
    );
  });
});
