import test from 'node:test';
import assert from 'node:assert/strict';
import {
  CarddavWorkflowError,
  planFollowupNote,
  resolveUniqueContact,
  updateFollowupNote,
} from '../../src/customer-ops/carddav-followup.mjs';

const ONE = {
  contact_id: 'contact-1', address_book_id: 'book-A', name: { full: '示例客户甲' },
  phones: [{ value: '+86 138 0000 0000' }], note: '客户原有备注',
};

const event = { id: 'activity-A001', date: '2026-10-31', kind: '平台会', status: '待回访' };

function fakeTool({ contacts = [ONE], partial = [], truncated = false } = {}) {
  const state = { contact: structuredClone(ONE), calls: [] };
  async function callTool(name, args) {
    state.calls.push({ name, args });
    if (name === 'contacts_search') {
      return { contacts: structuredClone(contacts), partial_failures: partial, truncated };
    }
    if (name === 'contacts_read') return structuredClone(state.contact);
    if (name === 'contacts_update') {
      assert.deepEqual(Object.keys(args.patch), ['note'], 'must only patch note');
      state.contact.note = args.patch.note;
      return structuredClone(state.contact);
    }
    throw Error('unexpected tool: ' + name);
  }
  return { state, callTool };
}

const rejectsCode = async (cb, code) => {
  await assert.rejects(cb, err => err instanceof CarddavWorkflowError && err.code === code);
};

test('search + exact name + read chooses only one contact', async () => {
  const { callTool, state } = fakeTool();
  const out = await resolveUniqueContact(callTool, {
    sessionId: 'session-1', query: '示例', exactName: '示例客户甲',
  });
  assert.equal(out.contact_id, ONE.contact_id);
  assert.deepEqual(state.calls.map(x => x.name), ['contacts_search', 'contacts_read']);
});

test('one fuzzy candidate without exact identity is rejected', async () => {
  const { callTool } = fakeTool();
  await rejectsCode(() => resolveUniqueContact(callTool, {
    sessionId: 'session-1', query: '示例', exactName: '示例客户乙',
  }), 'NOT_FOUND');
  await rejectsCode(() => resolveUniqueContact(callTool, {
    sessionId: 'session-1', query: '示例',
  }), 'EXACT_MATCH_REQUIRED');
});

test('exact phone comparison handles formatted mainland numbers', async () => {
  const { callTool } = fakeTool();
  const c = await resolveUniqueContact(callTool, {
    sessionId: 'session-1', query: '138', exactPhone: '13800000000',
  });
  assert.equal(c.contact_id, 'contact-1');
});

test('duplicate names are ambiguous', async () => {
  const { callTool } = fakeTool({ contacts: [ONE, { ...ONE, contact_id: 'other-id' }] });
  await rejectsCode(() => resolveUniqueContact(callTool, {
    sessionId: 'session-1', query: '示例', exactName: '示例客户甲',
  }), 'AMBIGUOUS');
});

test('truncated or partially failed search cannot be trusted', async () => {
  for (const options of [{ truncated: true }, { partial: [{ address_book_id: 'bad' }] }]) {
    const { callTool } = fakeTool(options);
    await rejectsCode(() => resolveUniqueContact(callTool, {
      sessionId: 'session-1', query: '示例', exactName: '示例客户甲',
    }), 'INCOMPLETE_SEARCH');
  }
});

test('note planning appends without overwriting existing notes and is idempotent', () => {
  const a = planFollowupNote('客户原有备注', event);
  assert.equal(a.changed, true);
  assert.ok(a.note.startsWith('客户原有备注\n'));
  assert.ok(a.note.includes('[#FUP:activity-A001] 2026-10-31 | 平台会 | 待回访'));
  const b = planFollowupNote(a.note, event);
  assert.equal(b.changed, false);
  assert.equal(b.note, a.note);
});

test('same id updates its own line but preserves other notes', () => {
  const first = planFollowupNote('私人备注\n其他内容', event);
  const second = planFollowupNote(first.note, { ...event, status: '已回访' });
  assert.ok(second.note.startsWith('私人备注\n其他内容'));
  assert.equal(second.note.match(/\[#FUP:activity-A001\]/g)?.length, 1);
  assert.ok(second.note.includes('| 已回访'));
  assert.equal(second.note.includes('| 待回访'), false);
});

test('malformed follow-up record is rejected', () => {
  assert.throws(() => planFollowupNote('', { ...event, id: 'bad/id' }), e => e.code === 'INVALID_ENTRY_ID');
  assert.throws(() => planFollowupNote('', { ...event, kind: 'A\nB' }), e => e.code === 'INVALID_KIND');
});

test('one-record MCP update patches only note and verifies readback', async () => {
  const { callTool, state } = fakeTool();
  const result = await updateFollowupNote(callTool, {
    sessionId: 'session-1', contactId: 'contact-1', addressBookId: 'book-A', entry: event,
    expectedEtag: 'sample-etag',
  });
  assert.equal(result.status, 'updated');
  assert.deepEqual(state.calls.map(x => x.name), ['contacts_read', 'contacts_update', 'contacts_read']);
  assert.equal(state.calls[1].args.expected_etag, 'sample-etag');
  assert.deepEqual(state.contact.phones, ONE.phones);
  assert.ok(state.contact.note.includes('客户原有备注'));
  assert.equal((await updateFollowupNote(callTool, {
    sessionId: 'session-1', contactId: 'contact-1', addressBookId: 'book-A', entry: event,
  })).status, 'unchanged');
  assert.equal(state.calls.filter(x => x.name === 'contacts_update').length, 1);
});

test('unexpected contact id after read is rejected without write', async () => {
  const { state, callTool } = fakeTool();
  await rejectsCode(() => updateFollowupNote(callTool, {
    sessionId: 'session-1', contactId: 'different-id', addressBookId: 'book-A', entry: event,
  }), 'CONTACT_CHANGED');
  assert.equal(state.calls.some(x => x.name === 'contacts_update'), false);
});

test('inconsistent post-write readback is reported and not retried automatically', async () => {
  let reads = 0;
  const writes = [];
  const callTool = async (name, args) => {
    if (name === 'contacts_read') {
      reads++;
      return { ...ONE, note: reads === 1 ? ONE.note : 'other writer changed note' };
    }
    if (name === 'contacts_update') {
      writes.push(args);
      return { ok: true };
    }
  };
  await rejectsCode(() => updateFollowupNote(callTool, {
    sessionId: 'session-1', contactId: 'contact-1', addressBookId: 'book-A', entry: event,
  }), 'WRITE_NOT_VERIFIED');
  assert.equal(writes.length, 1);
});
