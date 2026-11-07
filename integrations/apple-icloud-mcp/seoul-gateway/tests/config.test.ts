import { test } from 'node:test';
import assert from 'node:assert';
import { validateGatewayConfig, loadGatewayConfigFromEnv } from '../src/config.ts';
import { AppError } from '../src/types.ts';

test('validateGatewayConfig - parses valid config correctly', () => {
  const valid = {
    macserverEndpoint: 'http://127.0.0.1:18765',
    authToken: 'my-super-secret-token-32-chars-long!',
    timeoutMs: 8000,
    allowedListIds: ['list-uuid-1', 'list-uuid-2'],
    expectedSourceType: 'calDAV',
    expectedSourceName: 'iCloud',
  };

  const config = validateGatewayConfig(valid);
  assert.strictEqual(config.macserverEndpoint, 'http://127.0.0.1:18765');
  assert.strictEqual(config.authToken, 'my-super-secret-token-32-chars-long!');
  assert.strictEqual(config.timeoutMs, 8000);
  assert.deepStrictEqual(config.allowedListIds, ['list-uuid-1', 'list-uuid-2']);
  assert.strictEqual(config.expectedSourceType, 'calDAV');
  assert.strictEqual(config.expectedSourceName, 'iCloud');
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
  // Missing endpoint
  assert.throws(
    () => validateGatewayConfig({ authToken: '1234567890123456' }),
    (err: unknown) => err instanceof AppError && err.code === 'INVALID_INPUT'
  );

  // Wildcard 0.0.0.0
  assert.throws(
    () =>
      validateGatewayConfig({
        macserverEndpoint: 'http://0.0.0.0:18765',
        authToken: '1234567890123456',
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
      }),
    (err: unknown) => err instanceof AppError && err.code === 'INVALID_INPUT'
  );

  assert.throws(
    () =>
      validateGatewayConfig({
        macserverEndpoint: 'http://127.0.0.1:18765',
        authToken: '1234567890123456',
        timeoutMs: 100000, // too large (> 60000)
      }),
    (err: unknown) => err instanceof AppError && err.code === 'INVALID_INPUT'
  );
});

test('loadGatewayConfigFromEnv - parses env variables', () => {
  const env = {
    MACSERVER_EVENTKIT_ENDPOINT: 'http://100.100.172.91:18765',
    MACSERVER_EVENTKIT_TOKEN: 'tailscale-mesh-token-1234567890!',
    MACSERVER_EVENTKIT_TIMEOUT_MS: '6500',
    MACSERVER_EVENTKIT_ALLOWED_LIST_IDS: 'list-a, list-b',
  };

  const config = loadGatewayConfigFromEnv(env);
  assert.strictEqual(config.macserverEndpoint, 'http://100.100.172.91:18765');
  assert.strictEqual(config.authToken, 'tailscale-mesh-token-1234567890!');
  assert.strictEqual(config.timeoutMs, 6500);
  assert.deepStrictEqual(config.allowedListIds, ['list-a', 'list-b']);
});
