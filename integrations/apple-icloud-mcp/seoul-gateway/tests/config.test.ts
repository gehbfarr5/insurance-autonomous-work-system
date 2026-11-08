import { test } from 'node:test';
import assert from 'node:assert';
import { validateGatewayConfig, loadGatewayConfigFromEnv } from '../src/config.ts';
import { AppError } from '../src/types.ts';

test('validateGatewayConfig - parses valid config with explicit list-source bindings', () => {
  const valid = {
    macserverEndpoint: 'http://127.0.0.1:18765',
    authToken: 'my-super-secret-token-32-chars-long!',
    timeoutMs: 8000,
    maxResponseSizeBytes: 1048576,
    allowedLists: [
      {
        listId: 'list-uuid-1',
        expectedSourceId: 'src-icloud-01',
        expectedSourceName: 'iCloud',
        expectedSourceType: 'calDAV',
      },
    ],
    expectedSourceType: 'calDAV',
    expectedSourceName: 'iCloud',
  };

  const config = validateGatewayConfig(valid);
  assert.strictEqual(config.macserverEndpoint, 'http://127.0.0.1:18765');
  assert.strictEqual(config.authToken, 'my-super-secret-token-32-chars-long!');
  assert.strictEqual(config.timeoutMs, 8000);
  assert.strictEqual(config.maxResponseSizeBytes, 1048576);
  assert.strictEqual(config.allowedLists.length, 1);
  assert.strictEqual(config.allowedLists[0]?.listId, 'list-uuid-1');
  assert.strictEqual(config.allowedLists[0]?.expectedSourceId, 'src-icloud-01');
});

test('validateGatewayConfig - rejects config without explicit source ID binding', () => {
  // Missing expectedSourceId in allowedLists
  assert.throws(
    () =>
      validateGatewayConfig({
        macserverEndpoint: 'http://127.0.0.1:18765',
        authToken: 'my-super-secret-token-32-chars-long!',
        allowedLists: [
          {
            listId: 'list-uuid-1',
            // expectedSourceId missing!
          },
        ],
      }),
    (err: unknown) =>
      err instanceof AppError &&
      err.code === 'INVALID_INPUT' &&
      err.message.includes('缺失显式 expectedSourceId 绑定')
  );

  // Missing allowedLists altogether
  assert.throws(
    () =>
      validateGatewayConfig({
        macserverEndpoint: 'http://127.0.0.1:18765',
        authToken: 'my-super-secret-token-32-chars-long!',
      }),
    (err: unknown) =>
      err instanceof AppError &&
      err.code === 'INVALID_INPUT' &&
      err.message.includes('缺失或空的 allowedLists')
  );
});

test('validateGatewayConfig - rejects non-object or null config', () => {
  assert.throws(
    () => validateGatewayConfig(null),
    (err: unknown) => err instanceof AppError && err.code === 'INVALID_INPUT'
  );
  assert.throws(
    () => validateGatewayConfig('not-an-object'),
    (err: unknown) => err instanceof AppError && err.code === 'INVALID_INPUT'
  );
});

test('validateGatewayConfig - rejects invalid endpoints and wildcards', () => {
  // Wildcard 0.0.0.0
  assert.throws(
    () =>
      validateGatewayConfig({
        macserverEndpoint: 'http://0.0.0.0:18765',
        authToken: '1234567890123456',
        allowedLists: [{ listId: 'l1', expectedSourceId: 's1' }],
      }),
    (err: unknown) =>
      err instanceof AppError &&
      err.code === 'INVALID_INPUT' &&
      err.message.includes('禁止使用通配监听地址')
  );

  // Invalid protocol
  assert.throws(
    () =>
      validateGatewayConfig({
        macserverEndpoint: 'ftp://127.0.0.1:18765',
        authToken: '1234567890123456',
        allowedLists: [{ listId: 'l1', expectedSourceId: 's1' }],
      }),
    (err: unknown) =>
      err instanceof AppError &&
      err.code === 'INVALID_INPUT' &&
      err.message.includes('必须是 http 或 https')
  );
});

test('validateGatewayConfig - rejects short or empty tokens', () => {
  assert.throws(
    () =>
      validateGatewayConfig({
        macserverEndpoint: 'http://127.0.0.1:18765',
        authToken: 'short',
        allowedLists: [{ listId: 'l1', expectedSourceId: 's1' }],
      }),
    (err: unknown) => err instanceof AppError && err.code === 'INVALID_INPUT'
  );
});

test('validateGatewayConfig - rejects invalid timeout range', () => {
  assert.throws(
    () =>
      validateGatewayConfig({
        macserverEndpoint: 'http://127.0.0.1:18765',
        authToken: '1234567890123456',
        timeoutMs: 100, // too small (< 500)
        allowedLists: [{ listId: 'l1', expectedSourceId: 's1' }],
      }),
    (err: unknown) => err instanceof AppError && err.code === 'INVALID_INPUT'
  );

  assert.throws(
    () =>
      validateGatewayConfig({
        macserverEndpoint: 'http://127.0.0.1:18765',
        authToken: '1234567890123456',
        timeoutMs: 100000, // too large (> 60000)
        allowedLists: [{ listId: 'l1', expectedSourceId: 's1' }],
      }),
    (err: unknown) => err instanceof AppError && err.code === 'INVALID_INPUT'
  );
});

test('loadGatewayConfigFromEnv - parses env variables with explicit bindings', () => {
  const env = {
    MACSERVER_EVENTKIT_ENDPOINT: 'http://100.100.172.91:18765',
    MACSERVER_EVENTKIT_TOKEN: 'tailscale-mesh-token-1234567890!',
    MACSERVER_EVENTKIT_TIMEOUT_MS: '6500',
    MACSERVER_EVENTKIT_MAX_RESPONSE_SIZE: '4194304',
    MACSERVER_EVENTKIT_ALLOWED_LISTS: 'list-a:src-a,list-b:src-b',
  };

  const config = loadGatewayConfigFromEnv(env);
  assert.strictEqual(config.macserverEndpoint, 'http://100.100.172.91:18765');
  assert.strictEqual(config.authToken, 'tailscale-mesh-token-1234567890!');
  assert.strictEqual(config.timeoutMs, 6500);
  assert.strictEqual(config.maxResponseSizeBytes, 4194304);
  assert.strictEqual(config.allowedLists.length, 2);
  assert.strictEqual(config.allowedLists[0]?.listId, 'list-a');
  assert.strictEqual(config.allowedLists[0]?.expectedSourceId, 'src-a');
  assert.strictEqual(config.allowedLists[1]?.listId, 'list-b');
  assert.strictEqual(config.allowedLists[1]?.expectedSourceId, 'src-b');
});
