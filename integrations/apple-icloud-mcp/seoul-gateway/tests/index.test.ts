import { test } from 'node:test';
import assert from 'node:assert';
import * as gateway from '../src/index.ts';

test('index exports all required classes, functions and errors', () => {
  assert(typeof gateway.AppError === 'function');
  assert(typeof gateway.validateGatewayConfig === 'function');
  assert(typeof gateway.loadGatewayConfigFromEnv === 'function');
  assert(typeof gateway.EventKitReadonlyTransport === 'function');
  assert(typeof gateway.createMacServerReminderService === 'function');
  assert(typeof gateway.FakeEventKitBridge === 'function');
});
