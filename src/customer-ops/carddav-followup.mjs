/**
 * iCloud CardDAV insurance follow-up adapter.
 *
 * Works with the existing MCP tool surface. No role-based restrictions:
 * any authorized Agent may use the same Contacts CRUD tools.
 * These helpers preserve existing notes, avoid fuzzy single-match guesses
 * and verify a single-contact note update without touching other fields.
 *
 * callTool(name, args) must return parsed business JSON, like the existing
 * test-carddav-oauth-crud.mjs callMcpTool wrapper.
 */

export class CarddavWorkflowError extends Error {
  constructor(code, message) {
    super(message);
    this.name = 'CarddavWorkflowError';
    this.code = code;
  }
}

const fail = (code, msg) => { throw new CarddavWorkflowError(code, msg); };
const normalizedName = value => String(value ?? '').trim().replace(/\s+/g, ' ').toLocaleLowerCase();
const normalizedPhone = value => String(value ?? '').replace(/\D/g, '').replace(/^86(?=1\d{10}$)/, '');

function assertSession(sessionId) {
  if (typeof sessionId !== 'string' || !sessionId.trim()) fail('INVALID_SESSION', 'session_id required');
}
function assertContactId(contact) {
  if (!contact || typeof contact.contact_id !== 'string' || !contact.contact_id ||
      typeof contact.address_book_id !== 'string' || !contact.address_book_id) {
    fail('INVALID_CONTACT_REF', 'Contact must include contact_id and address_book_id');
  }
}
function ensureNoPartialSearch(result) {
  if (!result || !Array.isArray(result.contacts)) {
    fail('INVALID_SEARCH_RESULT', 'contacts_search response has no contacts array');
  }
  if (result.truncated === true || (result.partial_failures?.length ?? 0) > 0) {
    fail('INCOMPLETE_SEARCH', 'Search was truncated or an address book failed');
  }
}

/**
 * Select by an exact name or exact phone among MCP search candidates.
 * A search that happens to return only one fuzzy match is never sufficient.
 */
export async function resolveUniqueContact(callTool, {
  sessionId, query, exactName, exactPhone, limit = 50,
}) {
  assertSession(sessionId);
  if (typeof callTool !== 'function') fail('INVALID_CALLER', 'callTool required');
  if (typeof query !== 'string' || !query.trim()) fail('INVALID_QUERY', 'non-empty search query required');
  if (!exactName && !exactPhone) fail('EXACT_MATCH_REQUIRED', 'exactName or exactPhone required');
  if (!Number.isInteger(limit) || limit < 1 || limit > 500) fail('INVALID_LIMIT', 'limit must be 1..500');
  const response = await callTool('contacts_search', {
    session_id: sessionId, query: query.trim(), limit,
  });
  ensureNoPartialSearch(response);

  let candidates = response.contacts;
  if (exactName) {
    const name = normalizedName(exactName);
    candidates = candidates.filter(c => normalizedName(c?.name?.full) === name);
  }
  if (exactPhone) {
    const phone = normalizedPhone(exactPhone);
    if (!phone) fail('INVALID_PHONE', 'exactPhone invalid');
    candidates = candidates.filter(c =>
      Array.isArray(c?.phones) && c.phones.some(p => normalizedPhone(p?.value) === phone));
  }

  if (candidates.length !== 1) {
    fail(candidates.length === 0 ? 'NOT_FOUND' : 'AMBIGUOUS',
      'Exact matching selected ' + candidates.length + ' contacts, expected exactly 1');
  }
  const contact = candidates[0];
  assertContactId(contact);
  const detail = await callTool('contacts_read', {
    session_id: sessionId, contact_id: contact.contact_id,
  });
  assertContactId(detail);
  if (detail.contact_id !== contact.contact_id || detail.address_book_id !== contact.address_book_id) {
    fail('CONTACT_CHANGED', 'contacts_read returned a different contact reference');
  }
  return detail;
}

function encodeNoteField(value, field) {
  if (typeof value !== 'string' || !value.trim() || value.length > 240 || /[\r\n|]/.test(value)) {
    fail('INVALID_' + field.toUpperCase(), field + ' must be non-empty, <=240 chars and single line');
  }
  return value.trim();
}
function entryLine(entry) {
  if (!entry || typeof entry !== 'object') fail('INVALID_ENTRY', 'followup entry required');
  const id = String(entry.id ?? '');
  if (!/^[A-Za-z0-9_-]{3,64}$/.test(id)) fail('INVALID_ENTRY_ID', 'entry id must be 3-64 ASCII-safe characters');
  const date = String(entry.date ?? '');
  if (!/^\d{4}-\d{2}-\d{2}$/.test(date) || Number.isNaN(Date.parse(date + 'T00:00:00Z'))) {
    fail('INVALID_DATE', 'date must be YYYY-MM-DD');
  }
  const kind = encodeNoteField(entry.kind, 'kind');
  const status = encodeNoteField(entry.status, 'status');
  return '[#FUP:' + id + '] ' + date + ' | ' + kind + ' | ' + status;
}

/**
 * Update/append one marked business note. Other notes remain unchanged.
 * The same entry id is an idempotency key; identical content is a no-op.
 */
export function planFollowupNote(existingNote, entry) {
  const original = String(existingNote ?? '');
  const line = entryLine(entry);
  const marker = line.slice(0, line.indexOf(']') + 1);
  const parts = original ? original.split(/\r?\n/) : [];
  const found = parts.some(p => p.startsWith(marker + ' '));
  const merged = parts.filter(p => !p.startsWith(marker + ' '));
  if (found) {
    const first = parts.findIndex(p => p.startsWith(marker + ' '));
    merged.splice(Math.min(first, merged.length), 0, line);
  } else {
    merged.push(line);
  }
  const proposed = merged.join('\n');
  return { changed: proposed !== original, note: proposed, marker, replaced: found };
}

/**
 * Real write of ONE contact, with before/after readback.
 * Optional expectedEtag is passed through when actually available.
 * MCP contacts_read currently does not expose ETag; never fabricate one.
 */
export async function updateFollowupNote(callTool, {
  sessionId, contactId, addressBookId, entry, expectedEtag,
}) {
  assertSession(sessionId);
  if (typeof contactId !== 'string' || !contactId) fail('INVALID_CONTACT_REF', 'contactId required');
  if (typeof addressBookId !== 'string' || !addressBookId) fail('INVALID_CONTACT_REF', 'addressBookId required');
  const before = await callTool('contacts_read', {
    session_id: sessionId, contact_id: contactId,
  });
  assertContactId(before);
  if (before.contact_id !== contactId || before.address_book_id !== addressBookId) {
    fail('CONTACT_CHANGED', 'Target contact reference changed');
  }
  const plan = planFollowupNote(before.note, entry);
  if (!plan.changed) return { status: 'unchanged', contact_id: contactId, marker: plan.marker };

  const args = {
    session_id: sessionId, contact_id: contactId, patch: { note: plan.note },
  };
  if (expectedEtag !== undefined) {
    if (typeof expectedEtag !== 'string' || !expectedEtag) fail('INVALID_ETAG', 'expectedEtag invalid');
    args.expected_etag = expectedEtag;
  }
  await callTool('contacts_update', args);
  const after = await callTool('contacts_read', {
    session_id: sessionId, contact_id: contactId,
  });
  assertContactId(after);
  if (after.contact_id !== contactId || after.address_book_id !== addressBookId || after.note !== plan.note) {
    fail('WRITE_NOT_VERIFIED', 'Follow-up note changed or not visible on readback; inspect actual state before retrying');
  }
  return { status: 'updated', contact_id: contactId, marker: plan.marker };
}
