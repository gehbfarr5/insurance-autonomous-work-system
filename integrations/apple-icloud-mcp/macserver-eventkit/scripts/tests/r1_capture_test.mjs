#!/usr/bin/env node
/**
 * r1_capture_test.mjs — offline differential test for r1_capture_readonly.py.
 *
 * Why this test exists
 * --------------------
 * The R1 blocker is that every historical read returned "200 + []" and nothing
 * ever distinguished "the list is genuinely empty" from "the tooling cannot
 * report a non-empty list". This test drives the capture tool against the
 * gateway's own in-memory FakeEventKitBridge (no EventKit, no TCC, no Apple
 * account, no network) and asserts that each outcome is classified differently:
 *
 *   empty list            -> EMPTY_ARRAY_CONFIRMED_BY_BRIDGE      (exit 0)
 *   synthetic item absent -> NON_EMPTY_BUT_SYNTHETIC_ITEM_ABSENT  (exit 0)
 *   synthetic item present-> NON_EMPTY_SYNTHETIC_ITEM_PRESENT     (exit 0)
 *   switch closed         -> ERROR_PERMISSION_DENIED_SWITCH_CLOSED (exit 2)
 *   bad bearer token      -> ERROR_LIST_METADATA_HTTP_401          (exit 2)
 *
 * It also asserts the receipt never contains the bearer token or an unmasked
 * UUID, because these receipts are meant to be archivable.
 *
 * Run: node --experimental-strip-types scripts/tests/r1_capture_test.mjs
 */

import { execFile } from 'node:child_process';
import { mkdtemp, readFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { promisify } from 'node:util';

import { FakeEventKitBridge } from '../../../seoul-gateway/src/fake-bridge.ts';

const execFileAsync = promisify(execFile);

const HERE = path.dirname(fileURLToPath(import.meta.url));
const CAPTURE = path.resolve(HERE, '..', 'r1_capture_readonly.py');

const TOKEN = 'test-valid-bridge-token-at-least-32chars!';
const LIST_ID = '9D9A5AAD-E3F0-4459-8756-BBCDBCB703F3';
const LIST_TITLE = 'SYNTHETIC-LIST';
const ITEM_TITLE = '[MUSE-R1-SYN-20261107-01] 只读读取保真核验';
const ITEM_NOTES = 'R1-01 合成事项，仅用于只读字段保真核验，验收后精准清理。';
const UUID_RE = /[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/i;

const results = [];
function check(name, condition, detail = '') {
  results.push({ name, ok: Boolean(condition), detail });
  const status = condition ? 'PASS' : 'FAIL';
  console.log(`  [${status}] ${name}${detail ? ` (${detail})` : ''}`);
}

async function runCapture({ endpoint, token, listId = LIST_ID, expectTitle = ITEM_TITLE }) {
  const dir = await mkdtemp(path.join(tmpdir(), 'r1-capture-'));
  const out = path.join(dir, 'receipt.json');
  const args = [
    CAPTURE,
    '--endpoint', endpoint,
    '--list-id', listId,
    '--expect-title', expectTitle,
    '--expect-notes', ITEM_NOTES,
    '--expect-priority', '5',
    '--out', out,
    '--label', 'offline-differential-test',
    '--timeout', '5',
  ];
  let code = 0;
  let stderr = '';
  try {
    const res = await execFileAsync('python3', args, {
      env: { ...process.env, EVENTKIT_BRIDGE_TOKEN: token },
      timeout: 20000,
    });
    stderr = res.stderr;
  } catch (err) {
    code = typeof err.code === 'number' ? err.code : -1;
    stderr = err.stderr || String(err);
  }
  let receipt = null;
  try {
    receipt = JSON.parse(await readFile(out, 'utf8'));
  } catch {
    receipt = null;
  }
  const raw = receipt ? JSON.stringify(receipt) : '';
  return { code, receipt, raw, stderr };
}

function assertionsOf(receipt) {
  const map = new Map();
  for (const entry of receipt?.assertions ?? []) map.set(entry.name, entry);
  return map;
}

function newBridge(options = {}) {
  return new FakeEventKitBridge({
    validToken: TOKEN,
    productionAuthorized: true,
    allowedListIds: [LIST_ID],
    mockLists: [
      {
        listID: LIST_ID,
        title: LIST_TITLE,
        sourceID: '7B0B0000-0000-4000-8000-000000000001',
        sourceType: 'calDAV',
        sourceName: 'iCloud',
        color: '#007AFF',
        isImmutable: true,
      },
    ],
    ...options,
  });
}

async function scenarioEmpty() {
  console.log('\n[scenario 1] bound list is genuinely empty');
  const bridge = newBridge({ mockItems: { [LIST_ID]: [] } });
  const url = await bridge.start();
  try {
    const { code, receipt, raw } = await runCapture({ endpoint: url, token: TOKEN });
    check('receipt written', receipt !== null);
    check('exit code 0 (empty is a valid observation)', code === 0, `code=${code}`);
    check(
      'classified as empty, not as a success claim',
      receipt?.classification === 'EMPTY_ARRAY_CONFIRMED_BY_BRIDGE',
      receipt?.classification,
    );
    check('returns to zero items', receipt?.items?.returned_count === 0);
    const a = assertionsOf(receipt);
    check(
      'synthetic item visibility asserted FAIL, not silently skipped',
      a.get('synthetic_item_visible_to_eventkit')?.result === 'FAIL',
    );
    check('no bearer token in receipt', !raw.includes(TOKEN));
    check('no unmasked uuid in receipt', !UUID_RE.test(raw.replace(/"list_id_masked":\s*"[^"]*"/g, '')));
  } finally {
    await bridge.stop();
  }
}

async function scenarioNonEmptyPresent() {
  console.log('\n[scenario 2] non-empty list containing the synthetic item');
  const bridge = newBridge({
    mockItems: {
      [LIST_ID]: [
        {
          itemID: '11111111-2222-4333-8444-555555555555',
          title: ITEM_TITLE,
          isCompleted: false,
          priority: 5,
          listID: LIST_ID,
          notes: ITEM_NOTES,
          dueDate: 833558400, // 2027-06-01T16:00:00Z (Cocoa reference seconds)
        },
        {
          itemID: '66666666-7777-4888-8999-AAAAAAAAAAAA',
          title: 'unrelated production reminder',
          isCompleted: true,
          priority: 0,
          listID: LIST_ID,
          notes: null,
        },
      ],
    },
  });
  const url = await bridge.start();
  try {
    const { code, receipt, raw } = await runCapture({ endpoint: url, token: TOKEN });
    check('exit code 0', code === 0, `code=${code}`);
    check(
      'classified as non-empty with synthetic item present',
      receipt?.classification === 'NON_EMPTY_SYNTHETIC_ITEM_PRESENT',
      receipt?.classification,
    );
    check('counts both items', receipt?.items?.returned_count === 2);
    check('matches exactly one synthetic item', receipt?.items?.matched_synthetic_count === 1);
    const a = assertionsOf(receipt);
    check('title fidelity PASS', a.get('title_exact_match')?.result === 'PASS');
    check('notes fidelity PASS', a.get('notes_exact_match')?.result === 'PASS');
    check('priority fidelity PASS', a.get('priority_match')?.result === 'PASS');
    check('due date present PASS', a.get('due_date_present')?.result === 'PASS');
    check('list attribution PASS', a.get('list_id_attribution_match')?.result === 'PASS');
    check('due date decoded from Cocoa epoch', receipt?.items?.field_probe?.[0]?.due_date_iso === '2027-06-01T16:00:00Z', receipt?.items?.field_probe?.[0]?.due_date_iso);
    check(
      'unrelated production title never persisted',
      !raw.includes('unrelated production reminder'),
    );
    check('no bearer token in receipt', !raw.includes(TOKEN));
  } finally {
    await bridge.stop();
  }
}

async function scenarioNonEmptyAbsent() {
  console.log('\n[scenario 3] non-empty list that lacks the synthetic item');
  const bridge = newBridge({
    mockItems: {
      [LIST_ID]: [
        {
          itemID: '66666666-7777-4888-8999-AAAAAAAAAAAA',
          title: 'some other reminder',
          isCompleted: false,
          priority: 0,
          listID: LIST_ID,
        },
      ],
    },
  });
  const url = await bridge.start();
  try {
    const { code, receipt } = await runCapture({ endpoint: url, token: TOKEN });
    check('exit code 0', code === 0, `code=${code}`);
    check(
      'classified as non-empty without the synthetic item',
      receipt?.classification === 'NON_EMPTY_BUT_SYNTHETIC_ITEM_ABSENT',
      receipt?.classification,
    );
  } finally {
    await bridge.stop();
  }
}

async function scenarioSwitchClosed() {
  console.log('\n[scenario 4] production switch closed (403)');
  const bridge = newBridge({ productionAuthorized: false });
  const url = await bridge.start();
  try {
    const { code, receipt } = await runCapture({ endpoint: url, token: TOKEN });
    check('exit code 2 (precondition, not a data verdict)', code === 2, `code=${code}`);
    check(
      'classified as permission denied, not as empty',
      receipt?.classification === 'ERROR_PERMISSION_DENIED_SWITCH_CLOSED',
      receipt?.classification,
    );
  } finally {
    await bridge.stop();
  }
}

async function scenarioBadToken() {
  console.log('\n[scenario 5] wrong bearer token (401)');
  const bridge = newBridge();
  const url = await bridge.start();
  try {
    const { code, receipt } = await runCapture({
      endpoint: url,
      token: 'wrong-token-but-long-enough-to-pass-cli-check',
    });
    check('exit code 2', code === 2, `code=${code}`);
    check(
      'classified as auth/metadata failure, not as empty',
      receipt?.classification === 'ERROR_LIST_METADATA_HTTP_401',
      receipt?.classification,
    );
  } finally {
    await bridge.stop();
  }
}

async function main() {
  console.log('r1_capture_readonly.py — offline differential test');
  await scenarioEmpty();
  await scenarioNonEmptyPresent();
  await scenarioNonEmptyAbsent();
  await scenarioSwitchClosed();
  await scenarioBadToken();

  const failed = results.filter((entry) => !entry.ok);
  console.log(`\n${results.length - failed.length}/${results.length} assertions passed`);
  if (failed.length > 0) {
    for (const entry of failed) console.log(`  FAILED: ${entry.name}`);
    process.exit(1);
  }
  console.log('R1 capture tooling: OFFLINE_DIFFERENTIAL_TEST_PASS');
}

await main();
