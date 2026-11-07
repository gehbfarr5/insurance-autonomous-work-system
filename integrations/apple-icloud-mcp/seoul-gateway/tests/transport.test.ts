import { test, describe, before, after } from 'node:test';
import assert from 'node:assert';
import { FakeEventKitBridge } from '../src/fake-bridge.ts';
import { EventKitReadonlyTransport, parseBridgeDate } from '../src/transport.ts';
import { AppError, type MacServerGatewayConfig } from '../src/types.ts';

describe('EventKitReadonlyTransport with Fake Bridge', () => {
  const token = 'valid-test-bearer-token-at-least-32chars!';
  let fakeBridge: FakeEventKitBridge;
  let bridgeUrl: string;
  let config: MacServerGatewayConfig;

  before(async () => {
    fakeBridge = new FakeEventKitBridge({
      validToken: token,
      productionAuthorized: true,
      allowedListIds: ['allowed-list-01'],
      mockLists: [
        {
          listID: 'allowed-list-01',
          title: '工作提醒',
          sourceID: 'src-01',
          sourceType: 'calDAV',
          sourceName: 'iCloud',
          color: '#FF2D55',
          isImmutable: true,
        },
      ],
      mockItems: {
        'allowed-list-01': [
          {
            itemID: 'item-01',
            title: '客户保单回访',
            isCompleted: false,
            dueDate: '2026-11-10T10:00:00.000Z',
            priority: 1,
            notes: '提醒跟进续保条款',
            listID: 'allowed-list-01',
          },
        ],
      },
    });
    bridgeUrl = await fakeBridge.start();
    config = {
      macserverEndpoint: bridgeUrl,
      authToken: token,
      timeoutMs: 1000,
      maxResponseSizeBytes: 1024 * 1024,
      allowedLists: [{ listId: 'allowed-list-01', expectedSourceId: 'src-01' }],
    };
  });

  after(async () => {
    await fakeBridge.stop();
  });

  test('healthCheck succeeds without Bearer token', async () => {
    const transport = new EventKitReadonlyTransport(config);
    const health = await transport.healthCheck();
    assert.strictEqual(health.status, 'ok');
    assert.strictEqual(health.mode, 'readonly');
  });

  test('fetchListsMetadata succeeds with valid Bearer token', async () => {
    const transport = new EventKitReadonlyTransport(config);
    const lists = await transport.fetchListsMetadata();
    assert.strictEqual(lists.length, 1);
    assert.strictEqual(lists[0]?.listID, 'allowed-list-01');
    assert.strictEqual(lists[0]?.title, '工作提醒');
    assert.strictEqual(lists[0]?.sourceName, 'iCloud');
  });

  test('fetchReminders returns items for allowed list', async () => {
    const transport = new EventKitReadonlyTransport(config);
    const items = await transport.fetchReminders('allowed-list-01');
    assert.strictEqual(items.length, 1);
    assert.strictEqual(items[0]?.itemID, 'item-01');
    assert.strictEqual(items[0]?.title, '客户保单回访');
  });

  test('401 AUTH_FAILED when invalid token is presented', async () => {
    const badConfig: MacServerGatewayConfig = {
      ...config,
      authToken: 'wrong-token-invalid-key-32chars!',
    };
    const transport = new EventKitReadonlyTransport(badConfig);

    await assert.rejects(
      async () => transport.fetchListsMetadata(),
      (err: unknown) => {
        assert(err instanceof AppError);
        assert.strictEqual(err.code, 'AUTH_FAILED');
        return true;
      }
    );
  });

  test('403 PERMISSION_DENIED when Bridge production switch is false', async () => {
    fakeBridge.productionAuthorized = false;
    const transport = new EventKitReadonlyTransport(config);

    try {
      await assert.rejects(
        async () => transport.fetchListsMetadata(),
        (err: unknown) => {
          assert(err instanceof AppError);
          assert.strictEqual(err.code, 'PERMISSION_DENIED');
          return true;
        }
      );
    } finally {
      fakeBridge.productionAuthorized = true;
    }
  });

  test('403 PERMISSION_DENIED (LIST_NOT_ALLOWED) when querying unallowed list', async () => {
    const transport = new EventKitReadonlyTransport(config);

    await assert.rejects(
      async () => transport.fetchReminders('unauthorized-list-99'),
      (err: unknown) => {
        assert(err instanceof AppError);
        assert.strictEqual(err.code, 'PERMISSION_DENIED');
        return true;
      }
    );
  });

  test('404 NOT_FOUND when list items route reports list missing', async () => {
    fakeBridge.simulateListNotFound = true;
    const transport = new EventKitReadonlyTransport(config);

    try {
      await assert.rejects(
        async () => transport.fetchReminders('allowed-list-01'),
        (err: unknown) => {
          assert(err instanceof AppError);
          assert.strictEqual(err.code, 'NOT_FOUND');
          return true;
        }
      );
    } finally {
      fakeBridge.simulateListNotFound = false;
    }
  });

  test('Timeout covers response body read: stalled body stream triggers UPSTREAM_ERROR', async () => {
    fakeBridge.bodyDelayMs = 600; // body read takes 600ms
    const shortTimeoutConfig: MacServerGatewayConfig = {
      ...config,
      timeoutMs: 400, // timeout triggers at 400ms during body reading
    };
    const transport = new EventKitReadonlyTransport(shortTimeoutConfig);

    try {
      await assert.rejects(
        async () => transport.fetchListsMetadata(),
        (err: unknown) => {
          assert(err instanceof AppError);
          assert.strictEqual(err.code, 'UPSTREAM_ERROR');
          assert.strictEqual(err.retryable, true);
          assert(err.message.includes('超时'));
          return true;
        }
      );
    } finally {
      fakeBridge.bodyDelayMs = 0;
    }
  });

  test('Max response size limit enforcement: payload exceeding limit aborts and throws UPSTREAM_ERROR', async () => {
    fakeBridge.simulateHugePayloadBytes = 50000; // 50KB payload
    const tinyLimitConfig: MacServerGatewayConfig = {
      ...config,
      maxResponseSizeBytes: 10000, // limit is 10KB
    };
    const transport = new EventKitReadonlyTransport(tinyLimitConfig);

    try {
      await assert.rejects(
        async () => transport.fetchListsMetadata(),
        (err: unknown) => {
          assert(err instanceof AppError);
          assert.strictEqual(err.code, 'UPSTREAM_ERROR');
          assert(err.message.includes('超出限制'));
          return true;
        }
      );
    } finally {
      fakeBridge.simulateHugePayloadBytes = 0;
    }
  });

  test('500 internal error throws UPSTREAM_ERROR', async () => {
    fakeBridge.simulateServerError = true;
    const transport = new EventKitReadonlyTransport(config);

    try {
      await assert.rejects(
        async () => transport.fetchListsMetadata(),
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

  test('Corrupt non-JSON response throws UPSTREAM_ERROR', async () => {
    fakeBridge.simulateCorruptJson = true;
    const transport = new EventKitReadonlyTransport(config);

    try {
      await assert.rejects(
        async () => transport.fetchListsMetadata(),
        (err: unknown) => {
          assert(err instanceof AppError);
          assert.strictEqual(err.code, 'UPSTREAM_ERROR');
          assert(err.message.includes('非有效 JSON'));
          return true;
        }
      );
    } finally {
      fakeBridge.simulateCorruptJson = false;
    }
  });

  test('rejectWrite throws PERMISSION_DENIED client-side without network call', async () => {
    const transport = new EventKitReadonlyTransport(config);
    const initialRequests = fakeBridge.requests.length;

    await assert.rejects(
      async () => transport.rejectWrite('reminders_create'),
      (err: unknown) => {
        assert(err instanceof AppError);
        assert.strictEqual(err.code, 'PERMISSION_DENIED');
        assert(err.message.includes('严格只读模式'));
        return true;
      }
    );

    assert.strictEqual(fakeBridge.requests.length, initialRequests, 'No network request sent');
  });

  test('parseBridgeDate correctly converts numeric Cocoa dates and ISO strings', () => {
    // 815961600 is 2026-11-10T00:00:00.000Z in Cocoa reference seconds
    const fromCocoa = parseBridgeDate(815961600);
    assert.strictEqual(fromCocoa, '2026-11-10T00:00:00.000Z');

    // ISO 8601 string
    const fromIso = parseBridgeDate('2026-11-10T00:00:00.000Z');
    assert.strictEqual(fromIso, '2026-11-10T00:00:00.000Z');

    // Null and undefined
    assert.strictEqual(parseBridgeDate(null), undefined);
    assert.strictEqual(parseBridgeDate(undefined), undefined);
  });

  test('NEGATIVE ASSERTION: Network errors never return empty array or fake success', async () => {
    fakeBridge.simulateServerError = true;
    const transport = new EventKitReadonlyTransport(config);

    try {
      let returnedValue: unknown = 'did-not-throw';
      try {
        returnedValue = await transport.fetchReminders('allowed-list-01');
      } catch {
        returnedValue = 'threw-error';
      }
      assert.strictEqual(returnedValue, 'threw-error', 'Must throw on error instead of returning empty array');
    } finally {
      fakeBridge.simulateServerError = false;
    }
  });
});
