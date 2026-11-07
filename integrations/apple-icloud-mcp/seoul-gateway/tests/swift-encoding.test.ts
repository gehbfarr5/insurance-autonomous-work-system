import { test, describe } from 'node:test';
import assert from 'node:assert';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { EventKitReadonlyTransport, parseBridgeDate } from '../src/transport.ts';
import { createMacServerReminderService } from '../src/service.ts';
import { AppError, type MacServerGatewayConfig } from '../src/types.ts';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const SWIFT_OUTPUT_DIR = path.resolve(__dirname, '../tools/swift-synthetic-generator/output');

describe('Swift JSONEncoder Compatibility & Field Fidelity', () => {
  const SWIFT_LISTS_JSON = fs.readFileSync(path.join(SWIFT_OUTPUT_DIR, 'synthetic_lists.json'), 'utf8');
  const SWIFT_ITEMS_JSON = fs.readFileSync(path.join(SWIFT_OUTPUT_DIR, 'synthetic_items.json'), 'utf8');
  const SWIFT_LEAKED_JSON = fs.readFileSync(path.join(SWIFT_OUTPUT_DIR, 'synthetic_mismatched_ownership.json'), 'utf8');
  const SWIFT_INVALID_DATE_JSON = fs.readFileSync(path.join(SWIFT_OUTPUT_DIR, 'synthetic_invalid_date.json'), 'utf8');

  test('parseBridgeDate strictly converts Swift Cocoa Reference Date (815961600) to ISO string', () => {
    const iso = parseBridgeDate(815961600);
    assert.strictEqual(iso, '2026-11-10T00:00:00.000Z');
  });

  test('parseBridgeDate throws UPSTREAM_ERROR on invalid dates without numeric threshold guesswork', () => {
    // Non-date string
    assert.throws(
      () => parseBridgeDate('NOT_A_DATE'),
      (err: unknown) => err instanceof AppError && err.code === 'UPSTREAM_ERROR' && err.message.includes('非法日期')
    );

    // Empty string
    assert.throws(
      () => parseBridgeDate('   '),
      (err: unknown) => err instanceof AppError && err.code === 'UPSTREAM_ERROR'
    );

    // Non-finite number
    assert.throws(
      () => parseBridgeDate(NaN),
      (err: unknown) => err instanceof AppError && err.code === 'UPSTREAM_ERROR'
    );
    assert.throws(
      () => parseBridgeDate(Infinity),
      (err: unknown) => err instanceof AppError && err.code === 'UPSTREAM_ERROR'
    );

    // Non-primitive type
    assert.throws(
      () => parseBridgeDate({ bad: 'object' }),
      (err: unknown) => err instanceof AppError && err.code === 'UPSTREAM_ERROR'
    );
  });

  test('Service parses real Swift JSONEncoder payload with omitted nil fields and numeric dates', async () => {
    const mockFetch = async (input: string | URL | Request) => {
      const url = String(input);
      if (url.endsWith('/reminders/lists')) {
        return new Response(SWIFT_LISTS_JSON, {
          status: 200,
          headers: { 'Content-Type': 'application/json' },
        });
      }
      if (url.includes('/items')) {
        return new Response(SWIFT_ITEMS_JSON, {
          status: 200,
          headers: { 'Content-Type': 'application/json' },
        });
      }
      return new Response('Not Found', { status: 404 });
    };

    const config: MacServerGatewayConfig = {
      macserverEndpoint: 'http://127.0.0.1:18765',
      authToken: 'test-token-at-least-32-characters-long!',
      timeoutMs: 2000,
      maxResponseSizeBytes: 1048576,
      allowedLists: [
        {
          listId: '9D9A****03F3',
          expectedSourceId: 'src-icloud-test-01',
          expectedSourceName: 'iCloud',
          expectedSourceType: 'calDAV',
        },
      ],
      expectedSourceType: 'calDAV',
      expectedSourceName: 'iCloud',
    };

    const transport = new EventKitReadonlyTransport(config, mockFetch as unknown as typeof fetch);
    const service = createMacServerReminderService({ transport, config });

    // 1. Verify listLists
    const lists = await service.listLists();
    assert.strictEqual(lists.length, 1);
    assert.strictEqual(lists[0]?.list_id, '9D9A****03F3');
    assert.strictEqual(lists[0]?.name, 'M****试');
    assert.strictEqual(lists[0]?.color, '#007AFF');
    assert.strictEqual(lists[0]?.writable, false);

    // 2. Verify list reminders
    const result = await service.list({});
    assert.strictEqual(result.reminders.length, 3);

    const first = result.reminders[0];
    assert.strictEqual(first?.reminder_id, 'item-swift-01');
    assert.strictEqual(first?.title, 'Swift 合成提醒事项 1');
    assert.strictEqual(first?.due, '2026-11-10T00:00:00.000Z');
    assert.strictEqual(first?.notes, '核保附录条款审核');
    assert.strictEqual(first?.completed, false);
    assert.strictEqual(first?.priority, 1);

    const second = result.reminders[1];
    assert.strictEqual(second?.reminder_id, 'item-swift-03');
    assert.strictEqual(second?.due, '2026-11-11T00:00:00.000Z');
    assert.strictEqual(second?.priority, 5);

    const third = result.reminders[2];
    assert.strictEqual(third?.reminder_id, 'item-swift-02');
    assert.strictEqual(third?.title, 'Swift 合成提醒事项 2 (无截止日期/无备注)');
    assert.strictEqual(third?.due, undefined);
    assert.strictEqual(third?.notes, undefined);
    assert.strictEqual(third?.completed, true);
    assert.strictEqual(third?.priority, 0);
  });

  test('Cross-list ownership enforcement rejects items returned with foreign listID', async () => {
    const mockFetch = async (input: string | URL | Request) => {
      const url = String(input);
      if (url.endsWith('/reminders/lists')) {
        return new Response(SWIFT_LISTS_JSON, {
          status: 200,
          headers: { 'Content-Type': 'application/json' },
        });
      }
      return new Response(SWIFT_LEAKED_JSON, {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      });
    };

    const config: MacServerGatewayConfig = {
      macserverEndpoint: 'http://127.0.0.1:18765',
      authToken: 'test-token-at-least-32-characters-long!',
      timeoutMs: 2000,
      maxResponseSizeBytes: 1048576,
      allowedLists: [
        {
          listId: '9D9A****03F3',
          expectedSourceId: 'src-icloud-test-01',
        },
      ],
    };

    const transport = new EventKitReadonlyTransport(config, mockFetch as unknown as typeof fetch);
    const service = createMacServerReminderService({ transport, config });

    await assert.rejects(
      async () => service.list({ list_ids: ['9D9A****03F3'] }),
      (err: unknown) => {
        assert(err instanceof AppError);
        assert.strictEqual(err.code, 'UPSTREAM_ERROR');
        assert(err.message.includes('不匹配'));
        return true;
      }
    );
  });

  test('Invalid date format in synthetic payload throws UPSTREAM_ERROR explicitly', async () => {
    const mockFetch = async (input: string | URL | Request) => {
      const url = String(input);
      if (url.endsWith('/reminders/lists')) {
        return new Response(SWIFT_LISTS_JSON, {
          status: 200,
          headers: { 'Content-Type': 'application/json' },
        });
      }
      return new Response(SWIFT_INVALID_DATE_JSON, {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      });
    };

    const config: MacServerGatewayConfig = {
      macserverEndpoint: 'http://127.0.0.1:18765',
      authToken: 'test-token-at-least-32-characters-long!',
      timeoutMs: 2000,
      maxResponseSizeBytes: 1048576,
      allowedLists: [
        {
          listId: '9D9A****03F3',
          expectedSourceId: 'src-icloud-test-01',
        },
      ],
    };

    const transport = new EventKitReadonlyTransport(config, mockFetch as unknown as typeof fetch);
    const service = createMacServerReminderService({ transport, config });

    await assert.rejects(
      async () => service.list({ list_ids: ['9D9A****03F3'] }),
      (err: unknown) => {
        assert(err instanceof AppError);
        assert.strictEqual(err.code, 'UPSTREAM_ERROR');
        assert(err.message.includes('非法日期'));
        return true;
      }
    );
  });
});
