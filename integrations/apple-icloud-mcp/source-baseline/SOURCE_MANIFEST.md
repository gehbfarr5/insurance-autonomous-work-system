# iCloud MCP Source Baseline Manifest
<!-- AG-01-A | reconcile/icloud-source-baseline | Generated: 2026-11-07 -->

## Purpose

This manifest records the provenance, current status, and disposition of all five component classes
involved in the AG-01 iCloud integration work. It is the authoritative inventory for source
reconciliation decisions before any further code is promoted to `main`.

---

## Component Class 1 — Contacts / Groups (CardDAV Agent Tools)

**Reference**: PR #14 (merged)  
**Status**: `HISTORICAL_DEPLOYED`

| # | Tool Name | Source Location | Disposition |
|---|-----------|----------------|-------------|
| 1 | `list_contacts` | `integrations/chatgpt-sites/` (PR #14) | HISTORICAL_DEPLOYED |
| 2 | `get_contact` | `integrations/chatgpt-sites/` (PR #14) | HISTORICAL_DEPLOYED |
| 3 | `create_contact` | `integrations/chatgpt-sites/` (PR #14) | HISTORICAL_DEPLOYED |
| 4 | `update_contact` | `integrations/chatgpt-sites/` (PR #14) | HISTORICAL_DEPLOYED |
| 5 | `delete_contact` | `integrations/chatgpt-sites/` (PR #14) | HISTORICAL_DEPLOYED |
| 6 | `list_groups` | `integrations/chatgpt-sites/` (PR #14) | HISTORICAL_DEPLOYED |
| 7 | `get_group` | `integrations/chatgpt-sites/` (PR #14) | HISTORICAL_DEPLOYED |
| 8 | `add_contact_to_group` | `integrations/chatgpt-sites/` (PR #14) | HISTORICAL_DEPLOYED |

**Notes**:  
- All 8 tools shipped via PR #14 and are verified merged to `origin/main`.  
- CardDAV transport is production-active; no further action required for source reconciliation.  
- Write tools (create/update/delete) are gated by MUSE auth layer (not in scope for EventKit readonly candidate).

---

## Component Class 2 — Calendar ETag Source

**Reference**: User reports of ETag-based conflict detection implementation  
**Status**: `SOURCE_MISSING`

| Item | Description | Disposition |
|------|-------------|-------------|
| Calendar ETag conflict handler | Conditional PUT/GET with ETag headers | SOURCE_MISSING |
| ETag persistence store | Local store for server-side ETags | SOURCE_MISSING |
| ETag reconciliation logic | Three-way merge on conflict | SOURCE_MISSING |

**Notes**:  
- User described working ETag implementation in prior sessions; no corresponding diff or PR is visible
  on GitHub as of 2026-11-07.  
- The branch `icloud/persist-vtodo-fix-20261031` exists on origin but covers vTODO persistence only;
  ETag conflict handling code is not present in that diff.  
- **Action**: SOURCE_MISSING — cannot reconstruct without user-provided diff or file export.  
  Marked for explicit authorization before any re-implementation attempt.

---

## Component Class 3 — MUSE SafeWriteManager / Ledger / Transport

**Reference**: MUSE architectural design documents  
**Status**: `SOURCE_MISSING` (DESIGN_ONLY on GitHub)

| Item | Description | Disposition |
|------|-------------|-------------|
| `SafeWriteManager` | Idempotency / write-once ledger gate | SOURCE_MISSING (DESIGN_ONLY) |
| Write Ledger | Append-only operation ledger | SOURCE_MISSING (DESIGN_ONLY) |
| MUSE Transport | Secure credential-free transport layer | SOURCE_MISSING (DESIGN_ONLY) |
| MUSE Auth Validator | Token/scope validation for agent calls | SOURCE_MISSING (DESIGN_ONLY) |

**Notes**:  
- MUSE components exist as architecture plans and design documents in `planning/` and `docs/`
  directories but no implementation source is present in any branch.  
- These are listed as DESIGN_ONLY: the design intent is captured, but executable code does not exist
  in the GitHub repository.  
- Re-implementation requires explicit MUSE authorization. Not in scope for AG-01-B.

---

## Component Class 4 — A4 Bridge / rev3 / E2 Allowlist Candidate

**Reference**: A4 Bridge architectural discussions, rev3 design, R4 review comments  
**Status**: `PARTIAL`

| Item | Description | Disposition |
|------|-------------|-------------|
| A4 Bridge rev1/rev2 | Early bridge designs | HISTORICAL — superseded |
| A4 Bridge rev3 | Current design target | PARTIAL (rev3 offline) |
| E2 Allowlist Candidate | Exact-match allowlist for list IDs | PARTIAL — implemented in AG-01-B |
| R4 Review Fixes (FIX-R4A-01) | Metadata-only constraint | PARTIAL — implemented in AG-01-B |
| R4 Review Fixes (FIX-R4A-02) | iCloud source verification | PARTIAL — implemented in AG-01-B |

**Notes**:  
- rev3 is offline; R4 review marked BLOCKED for production activation pending this reconciliation.  
- FIX-R4A-01 and FIX-R4A-02 are addressed in `feat/macserver-eventkit-readonly` (AG-01-B).  
- The E2 exact-match allowlist validator is implemented as `AllowlistValidator.swift` (AG-01-B).  
- Full production activation remains BLOCKED pending MUSE independent verification.

---

## Component Class 5 — PyiCloud Mock Candidate

**Reference**: pyicloud library interface  
**Status**: `MOCK_ONLY`

| Item | Description | Disposition |
|------|-------------|-------------|
| `pyicloud_mock/__init__.py` | Package init, version, exports | MOCK_ONLY — NEW_IMPLEMENTATION |
| `pyicloud_mock/reminders.py` | Mock RemindersList/Reminder | MOCK_ONLY — NEW_IMPLEMENTATION |
| `pyicloud_mock/contacts.py` | Mock Contact/ContactGroup | MOCK_ONLY — NEW_IMPLEMENTATION |
| Test suite | pytest, ≥10 cases each module | MOCK_ONLY — NEW_IMPLEMENTATION |

**Notes**:  
- No real pyicloud session is loaded. All data is in-memory / deterministic.  
- Implements the same interface contract as the real pyicloud library to allow downstream code
  to swap implementations via dependency injection.  
- Files located in: `source-baseline/pyicloud-mock/`

---

## Disposition Summary

| Component Class | Status | Action Required |
|----------------|--------|----------------|
| Contacts/Groups (8 tools) | HISTORICAL_DEPLOYED | None — already on main |
| Calendar ETag | SOURCE_MISSING | User must provide diff/export |
| MUSE SafeWriteManager/Ledger/Transport | SOURCE_MISSING (DESIGN_ONLY) | Authorization required for re-impl |
| A4 Bridge/rev3/E2 Allowlist | PARTIAL | FIX-R4A-01/02 addressed in AG-01-B |
| PyiCloud Mock | MOCK_ONLY (NEW_IMPLEMENTATION) | Merged with this PR |

---

*Last updated: 2026-11-07 | Maintainer: AG-01 Engineering Agent*
