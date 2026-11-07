# MacServer EventKit Readonly Candidate — Acceptance Request
<!-- AG-01-B | feat/macserver-eventkit-readonly | 2026-11-07 -->

## Summary

This document is the formal acceptance request for the MacServer EventKit Read-Only Candidate
(AG-01-B). It requests MUSE independent verification and human authorization to proceed
with the next phase (production activation consideration).

---

## Delivery Identification

| Field | Value |
|-------|-------|
| Task ID | AG-01-B |
| Branch | `feat/macserver-eventkit-readonly` |
| Base branch | `reconcile/icloud-source-baseline` |
| Requesting agent | AG-01 Engineering Agent |
| Date | 2026-11-07 |

---

## Commits (feat branch, in order)

1. `feat(eventkit): add EventKit protocol and type definitions [FIX-R4A-01 FIX-R4A-02]`
   - Files: `Protocol/EventKitProtocol.swift`, `Protocol/RemindersList.swift`,
     `Protocol/ReminderItem.swift`, `Protocol/EventKitBridgeError.swift`

2. `feat(eventkit): add FakeEventKitStore and security layer`
   - Files: `Implementation/FakeEventKitStore.swift`, `Implementation/ProductionEventKitStore.swift`,
     `Security/AllowlistValidator.swift`, `Security/SourceVerifier.swift`,
     `Security/RequestLimiter.swift`, `Security/AuthValidator.swift`

3. `feat(eventkit): add bridge server and config templates`
   - Files: `Bridge/EventKitBridgeServer.swift`, `Bridge/RequestHandler.swift`,
     `Config/BridgeConfig.swift`, `Config/SessionConfig.swift`

4. `test(eventkit): add full isolation test suite`
   - Files: `Tests/EventKitBridgeTests/AllowlistValidatorTests.swift`,
     `SourceVerifierTests.swift`, `MetadataOnlyTests.swift`,
     `WriteIsolationTests.swift`, `ErrorHandlingTests.swift`, `AuthTests.swift`

5. `docs(eventkit): add build evidence and acceptance request`
   - Files: `BUILD_EVIDENCE.md`, `BUILD.md`, `SESSION_TEMPLATE.md`,
     `m5-retirement/RETIREMENT_CHECKLIST.md`, this file

---

## Permissions Requested

| Permission | Scope | Required For |
|-----------|-------|-------------|
| Merge `feat/macserver-eventkit-readonly` → `main` | This PR only | Human reviewer |
| MUSE independent verification run | EventKit candidate functionality | MUSE verifier |
| M5 retirement authorization | Each Group A–E item | Named authorizers (see RETIREMENT_CHECKLIST.md) |
| Production activation (future) | `ProductionEventKitStore` only | Requires separate authorization after MUSE sign-off |

---

## Review Fixes Addressed

| Fix ID | Description | Evidence |
|--------|-------------|---------|
| FIX-R4A-01 | Metadata-only paths never access reminder content or counts | `MetadataOnlyTests` — 8 tests, 0 failures; `RemindersList` type has no count field |
| FIX-R4A-02 | Content reads verify iCloud source before returning data | `SourceVerifierTests` — 10 tests; `FakeEventKitStore.fetchReminders` calls source check before content access |

---

## Build Evidence Summary

| Item | Result |
|------|--------|
| `swift build` exit code | 0 ✅ |
| `swift test` exit code | 0 ✅ |
| Total tests | 56 |
| Passed | 56 |
| Failed | 0 |
| Binary SHA-256 | `a0bc6f0f4e6ef2cc1ab8c873e0a5538bac1861400bc726a84bd44b03dd5b35ee` |

See `BUILD_EVIDENCE.md` for complete output.

---

## Test Matrix (All Acceptance Criteria)

| Criterion | Test Suite | Result |
|-----------|-----------|--------|
| metadata_only: Fake asserts content/count queries = 0 | MetadataOnlyTests | ✅ PASS |
| Invalid authentication rejected | AuthTests | ✅ PASS |
| Non-allowlisted list rejected | AllowlistValidatorTests, AuthTests | ✅ PASS |
| Non-iCloud source rejected (FIX-R4A-02) | SourceVerifierTests, AuthTests | ✅ PASS |
| All write requests rejected | WriteIsolationTests | ✅ PASS |
| Downstream write calls = 0 | WriteIsolationTests | ✅ PASS |
| Timeout → explicit failure | ErrorHandlingTests | ✅ PASS |
| Permission revocation → explicit failure | ErrorHandlingTests | ✅ PASS |
| Missing object → explicit failure | ErrorHandlingTests | ✅ PASS |
| Desensitized error messages | ErrorHandlingTests | ✅ PASS |

---

## Desensitization Confirmation

- ✅ No Apple ID, iCloud credential, or real account data in any file.
- ✅ All test data uses synthetic identifiers and `@example.invalid` emails.
- ✅ `ProductionEventKitStore` compiles but is not activated (throws `permissionDenied`).
- ✅ All error messages desensitized (no real IDs in `localizedDescription`).
- ✅ `BridgeConfig.productionTemplate` contains only `<PLACEHOLDER>` values.

---

## Items Not Run (Deferred)

| Item | Reason | Required Authorization |
|------|--------|----------------------|
| `ProductionEventKitStore` live activation | TCC permission not granted | Human + MUSE |
| M5 Retirement (Groups A–E) | RETIREMENT_PENDING_AUTHORIZATION | Named authorizers per RETIREMENT_CHECKLIST.md |
| Production HTTP server activation | Stub only in this candidate | Separate authorization required |

---

## MUSE Independent Verification Task

**Task format for MUSE verifier:**

```
MUSE_VERIFICATION_TASK: AG-01-B
Branch: feat/macserver-eventkit-readonly
SHA: [to be filled after final commit]

Verify:
1. FIX-R4A-01: fetchListsMetadata() does not increment contentAccessCount.
   Test: MetadataOnlyTests.testListsMetadataDoesNotAccessContent
   
2. FIX-R4A-02: fetchReminders(listID:) with Local source throws sourceNotAllowed.
   Test: SourceVerifierTests.testLocalSourceRejected + MetadataOnlyTests.testLocalListAppearsInMetadataButContentRejected
   
3. Write isolation: POST/PUT/PATCH/DELETE all return writeOperationRejected.
   Test: WriteIsolationTests (all 8 tests)
   
4. Auth: Unknown token returns authenticationFailed; scope mismatch returns unauthorizedScope.
   Test: AuthTests.testInvalidTokenThrows, AuthTests.testValidTokenMissingScopeThrows
   
5. ProductionEventKitStore is a stub: fetchListsMetadata() throws permissionDenied.
   Test: ErrorHandlingTests.testProductionStoreStubThrowsPermissionDenied

Expected result: 56 tests pass, 0 fail.
Command: swift test (from integrations/apple-icloud-mcp/macserver-eventkit/)
```

---

*Acceptance request prepared by AG-01 Engineering Agent | 2026-11-07*
