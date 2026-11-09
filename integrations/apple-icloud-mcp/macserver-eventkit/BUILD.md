# MacServer EventKit Bridge — BUILD.md
<!-- AG-01-B | MacServer EventKit Readonly Candidate | 2026-11-07 -->

## Overview

This directory contains the MacServer EventKit Read-Only Candidate: a Swift Package
providing a local HTTP bridge to Apple EventKit reminder lists, with strict read-only
enforcement and iCloud source verification.

**Status**: `NEW_IMPLEMENTATION` | Fake/offline mode only  
**FIX-R4A-01**: Metadata-only paths never access reminder content or counts  
**FIX-R4A-02**: Content reads verify iCloud source before returning data

---

## Environment Requirements

| Requirement | Version |
|-------------|---------|
| macOS | 14.0 or later |
| Swift | 6.0 or later (tested on 6.4) |
| Xcode | 15 or later (or Xcode Command Line Tools) |
| EventKit TCC | NOT required for Fake/test mode |

---

## Package Structure

```
macserver-eventkit/
├── Package.swift
├── Info.plist                              — Embedded TCC usage descriptions
├── BUILD_METADATA.json                     — Multi-architecture digest & signature records
├── scripts/
│   └── build-and-sign-universal.sh         — Universal build & strict signing pipeline
├── Sources/
│   ├── EventKitBridge/
│   │   ├── Protocol/
│   │   │   ├── EventKitProtocol.swift      — Replaceable interface
│   │   │   ├── RemindersList.swift         — List metadata type (FIX-R4A-01)
│   │   │   ├── ReminderItem.swift          — Reminder content type (read-only)
│   │   │   └── EventKitBridgeError.swift   — Desensitized error type
│   │   ├── Implementation/
│   │   │   ├── FakeEventKitStore.swift     — 100% deterministic Fake
│   │   │   └── ProductionEventKitStore.swift  — Real EK stub (NOT active)
│   │   ├── Security/
│   │   │   ├── AllowlistValidator.swift    — Exact-match list ID gating
│   │   │   ├── SourceVerifier.swift        — iCloud source verification
│   │   │   ├── RequestLimiter.swift        — Token-bucket rate limiting
│   │   │   └── AuthValidator.swift         — Token/scope validation
│   │   ├── Bridge/
│   │   │   ├── EventKitBridgeServer.swift  — HTTP bridge routing
│   │   │   └── RequestHandler.swift        — Desensitized error formatting
│   │   └── Config/
│   │       ├── BridgeConfig.swift          — Config template (no credentials)
│   │       └── SessionConfig.swift         — Session resident config
│   └── EventKitBridgeServerExec/
│       └── main.swift                      — Executable entry point
└── Tests/
    ├── test-universal-bridge-offline.sh    — Strict multi-arch offline lifecycle validation
    └── EventKitBridgeTests/
        ├── AllowlistValidatorTests.swift   — 10 tests
        ├── SourceVerifierTests.swift       — 10 tests
        ├── MetadataOnlyTests.swift         — 8 tests (FIX-R4A-01 core)
        ├── WriteIsolationTests.swift       — 8 tests
        ├── ErrorHandlingTests.swift        — 10 tests
        ├── AuthTests.swift                 — 10 tests
        ├── HttpIntegrationTests.swift      — 24 tests
        └── NonEmptyReminderFieldTests.swift— 9 tests
```

---

## Multi-Architecture Universal Build & Signing Pipeline

```bash
# 1. Navigate to package directory
cd integrations/apple-icloud-mcp/macserver-eventkit

# 2. Execute hardened universal build and signing
./scripts/build-and-sign-universal.sh

# 3. Verify strict multi-architecture signature
codesign --verify --strict --all-architectures -vvv .build/release/EventKitBridgeServer

# 4. Run comprehensive offline multi-architecture test (x86_64 & arm64)
./Tests/test-universal-bridge-offline.sh

# 5. Run full package test suite
swift test
```

---

## Expected Test Output Summary

```
AllowlistValidatorTests       — 10 passed, 0 failed
AuthTests                     — 10 passed, 0 failed
ErrorHandlingTests            — 10 passed, 0 failed
HttpIntegrationTests          — 24 passed, 0 failed
MetadataOnlyTests             — 8 passed,  0 failed
NonEmptyReminderFieldTests    — 9 passed,  0 failed
SourceVerifierTests           — 10 passed, 0 failed
WriteIsolationTests           — 8 passed,  0 failed
─────────────────────────────────────────────
TOTAL                         — 91 passed, 0 failed
```

---

## Acceptance Criteria Status

| Criterion | Status |
|-----------|--------|
| metadata_only: Fake asserts content/count queries = 0 | ✅ PASS (MetadataOnlyTests) |
| Identity & scope: invalid auth rejected | ✅ PASS (AuthTests) |
| Non-allowlisted list rejected | ✅ PASS (AuthTests, AllowlistValidatorTests) |
| Source mismatch rejected (FIX-R4A-02) | ✅ PASS (SourceVerifierTests, AuthTests) |
| Write isolation: all write requests rejected | ✅ PASS (WriteIsolationTests) |
| Downstream write calls = 0 | ✅ PASS (WriteIsolationTests) |
| Timeout/revocation/missing → explicit failure | ✅ PASS (ErrorHandlingTests) |
| ProductionEventKitStore compiles but not active | ✅ PASS (compile + stub check) |

---

## Security Notes

- `ProductionEventKitStore` is a stub. All methods throw `permissionDenied`.
  Activation requires human authorization (see AGENTS.md §1.3).
- No real Apple credentials, tokens, or iCloud account data in any file.
- All errors are desensitized (see `EventKitBridgeError.localizedDescription`).

---

*Generated by AG-01 Engineering Agent | 2026-11-07*
