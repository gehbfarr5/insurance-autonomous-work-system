import assert from 'node:assert';
import { EventKitReadonlyTransport } from '../../src/transport.ts';
import { createMacServerReminderService } from '../../src/service.ts';
import { AppError } from '../../src/types.ts';

const ENDPOINT = process.env.GATEWAY_ENDPOINT || 'http://127.0.0.1:18765';
const TOKEN = process.env.AUTH_TOKEN || 'ag03-test-token-at-least-32-chars-long!';
const MODE = process.argv[2] || 'normal';

const config = {
  macserverEndpoint: ENDPOINT,
  authToken: TOKEN,
  timeoutMs: 3000,
  maxResponseSizeBytes: 1048576,
  allowedLists: [
    {
      listId: '9D9A****03F3',
      expectedSourceId: 'src-icloud-test-01',
      expectedSourceName: 'iCloud',
      expectedSourceType: 'calDAV',
    },
  ],
};

const transport = new EventKitReadonlyTransport(config);
const service = createMacServerReminderService({ transport, config });

async function run() {
  console.log(`[TestClient] Executing test mode: ${MODE} against ${ENDPOINT}`);

  if (MODE === 'normal') {
    // 1. Health check
    const health = await transport.healthCheck();
    assert.strictEqual(health.status, 'ok');
    console.log('[TestClient] Health check OK');

    // 2. Fetch lists
    const lists = await service.listLists();
    assert.strictEqual(lists.length, 1);
    assert.strictEqual(lists[0].list_id, '9D9A****03F3');
    assert.strictEqual(lists[0].writable, false);
    console.log('[TestClient] List query OK:', lists[0].title);

    // 3. Fetch items
    const itemsResult = await service.list({ list_ids: ['9D9A****03F3'] });
    assert.strictEqual(itemsResult.reminders.length, 2);
    assert.strictEqual(itemsResult.reminders[0].reminder_id, 'item-docker-01');
    assert.strictEqual(itemsResult.reminders[0].completed, false);
    assert.strictEqual(itemsResult.reminders[0].due, '2026-11-09T00:00:00.000Z');
    console.log('[TestClient] Item query OK, count:', itemsResult.reminders.length);

    console.log(JSON.stringify({ status: 'PASS', mode: MODE, remindersCount: itemsResult.reminders.length }));
  } else if (MODE === 'permission_denied') {
    // Fake bridge should return 403
    try {
      await service.listLists();
      assert.fail('Expected PERMISSION_DENIED error, but request succeeded');
    } catch (err) {
      assert(err instanceof AppError, `Expected AppError, got: ${err}`);
      assert.strictEqual(err.code, 'PERMISSION_DENIED');
      console.log('[TestClient] Successfully verified PERMISSION_DENIED (403) explicitly caught:', err.message);
      console.log(JSON.stringify({ status: 'PASS', mode: MODE, errorCaught: err.code }));
    }
  } else if (MODE === 'broken_tunnel' || MODE === 'bad_hostkey') {
    // Tunnel is down or unreachable
    try {
      await service.listLists();
      assert.fail(`Expected failure under mode ${MODE}, but request succeeded`);
    } catch (err) {
      assert(err instanceof AppError, `Expected AppError, got: ${err}`);
      assert.strictEqual(err.code, 'UPSTREAM_ERROR');
      console.log(`[TestClient] Successfully verified network failure explicitly caught under ${MODE}:`, err.message);
      console.log(JSON.stringify({ status: 'PASS', mode: MODE, errorCaught: err.code }));
    }
  } else {
    throw new Error(`Unknown mode: ${MODE}`);
  }
}

run().catch((err) => {
  console.error('[TestClient] Test FAILED:', err);
  process.exit(1);
});
