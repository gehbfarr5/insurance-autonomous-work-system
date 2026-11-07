# BUILD_EVIDENCE.md
<!-- AG-01-B | MacServer EventKit Readonly Candidate | 2026-11-07 -->
<!-- REAL EXECUTION EVIDENCE — commands and output are actual from clean checkout, not synthesized -->

## Execution Environment

| Item | Value |
|------|-------|
| Date | 2026-11-07 |
| Clean Checkout Base | `/tmp/clean-checkout-ag01` |
| Tested Commit | `a5b2c9d8dea5371ac3a477e14d5e0e53bc70c58d` |
| Swift version | Apple Swift version 6.4 (swiftlang-6.4.0.27.1 clang-2100.3.27.1) |
| Native Host Architecture | arm64-apple-macosx27.0.0 (M5 Pro Host) |
| Target Machine Architecture | x86_64-apple-macosx (Intel MacServer) |
| Xcode Version | Xcode 27.0 (Build 27A5228h) |
| Working Directory | `integrations/apple-icloud-mcp/macserver-eventkit/` |

---

## 1. Multi-Architecture Clean Build Evidence

### A. Intel MacServer Target (`x86_64-apple-macosx`)
**Command executed:**
```bash
swift build --triple x86_64-apple-macosx -c release --scratch-path .build-x86_64 2>&1
```
**Result:** ✅ Exit code 0 (Build complete in 3.13s)
- Binary Format: `Mach-O 64-bit executable x86_64`
- Binary Size: 448 KB
- SHA-256 Digest: `c01b3d2b5f60f60a13d643d1087d9a87b73bca0b92990e5765a8aa70102dc181`
- Symbol Audit: Contains native `ProductionEventKitStore`, `ProductionStoreAssembly`, and `SourceVerifier` Mach-O symbols.

### B. M5 Pro Host Target (`arm64-apple-macosx`)
**Command executed:**
```bash
swift build --triple arm64-apple-macosx -c release --scratch-path .build-arm64 2>&1
```
**Result:** ✅ Exit code 0 (Build complete in 3.10s)
- Binary Format: `Mach-O 64-bit executable arm64`
- Binary Size: 460 KB
- SHA-256 Digest: `6ef70927f5e5053f481f9e499767748a5bd09ae232e93defe5292399e3807983`

---

## 2. Test Execution Evidence (Clean Checkout)

**Command executed:**
```bash
swift test 2>&1
```

**Result:** ✅ Exit code 0 (74 executed, 0 failures in 3.60s)

**Suite Summary Breakdown:**
```
Test Suite 'AllowlistValidatorTests' passed.
     Executed 10 tests, with 0 failures in 0.002 seconds
Test Suite 'AuthTests' passed.
     Executed 10 tests, with 0 failures in 0.002 seconds
Test Suite 'ErrorHandlingTests' passed.
     Executed 10 tests, with 0 failures in 0.001 seconds
Test Suite 'MetadataOnlyTests' passed.
     Executed 8 tests, with 0 failures in 0.005 seconds
Test Suite 'SourceVerifierTests' passed.
     Executed 10 tests, with 0 failures in 0.002 seconds
Test Suite 'WriteIsolationTests' passed.
     Executed 8 tests, with 0 failures in 0.003 seconds
Test Suite 'HttpIntegrationTests' passed.
     Executed 18 tests, with 0 failures in 3.566 seconds
---------------------------------------------------------------------------------
TOTAL: Executed 74 tests, with 0 failures (0 unexpected) in 3.608 seconds
```

---

## 3. Detailed Acceptance Matrix

| Test Suite | Tests | Passed | Acceptance Requirement & Verified Gate |
|------------|-------|--------|----------------------------------------|
| `AllowlistValidatorTests` | 10 | 10 | Exact ID match; rejects prefixes, suffixes, wildcards, name guessing |
| `AuthTests` | 10 | 10 | Rejects missing/invalid Bearer tokens; validates scoped permissions |
| `ErrorHandlingTests` | 10 | 10 | Desensitized error descriptions, mapping to HTTP 401/403/404/405/408/413/429/431/504/500 |
| `MetadataOnlyTests` | 8 | 8 | **FIX-R4A-01**: `contentAccessCount` strictly 0 on metadata queries; no count fields |
| `SourceVerifierTests` | 10 | 10 | **FIX-R4A-02**: Enforces calDAV source type, iCloud source title, source UUID & exact list identity binding |
| `WriteIsolationTests` | 8 | 8 | All write verbs rejected with 405 Method Not Allowed; store writes = 0 |
| `HttpIntegrationTests` | 18 | 18 | **Real Loopback HTTP**: Native socket listener, auth, allowlist, metadata-only (contentCount=0), source rejection matrix (4 targets: unbound, wrong UUID, local type, spoofed title with contentCount=0), 405 write block, chunked headers, 16KB header limit (431), client early disconnect resilience, slow request header deadline (408), slow request body deadline, hanging store watchdog (504 within deadline while /health remains 200), large response partial send loop, stop-and-restart counter isolation, strict production config validation |
| **TOTAL** | **74** | **74** | **ALL ACCEPTANCE CRITERIA VERIFIED (100% PASS)** |

---

## 4. Diff Explanation: `b63f72e` → Current HEAD

| Component | Nature of Change | Impact & Justification |
|-----------|------------------|------------------------|
| `EventKitBridgeServer.swift` | **Decoupled Socket I/O** | Moved all blocking Darwin socket read/write operations out of the server Actor into non-blocking `SocketConnectionWorker`. The Actor now strictly handles business logic and server state. |
| `EventKitBridgeServer.swift` | **Full Send Loop** | Implemented `sendHttpResponseFull` handling partial socket writes, `EINTR` signal retries, `EPIPE`/`ECONNRESET` client disconnects, and `SO_NOSIGPIPE` to prevent process crashes. |
| `EventKitBridgeServer.swift` | **Hanging Store Watchdog** | Replaced `withThrowingTaskGroup` with unstructured task race using `StoreAtomicBool`. An uncooperative or hanging Store continuation cannot block HTTP response or drag out timeout; 504 Gateway Timeout is returned promptly. |
| `EventKitBridgeServer.swift` | **Teardown & Counter Isolation** | `stop()` closes all active client sockets, cancels tasks, and increments `serverGeneration`. Any late-finishing tasks from previous runs cannot pollute restarted server counters. |
| `BridgeConfig.swift` | **Deadlines & Capacities** | Added `headerReadTimeoutSeconds` (default 3.0s), `bodyReadTimeoutSeconds` (default 3.0s), `maxBodySizeBytes` (default 1MB), `sendTimeoutSeconds` (default 5.0s), and `isProductionAuthorized`. |
| `ProductionEventKitStore.swift` | **Explicit Assembly Path** | Introduced `ProductionStoreAssembly.assemble(isAuthorized:...)` providing a default-off, explicit authorization injection path. Verified via dependency injection without live EKEventStore instantiation. |
| `FakeEventKitStore.swift` | **Chaos Fixtures** | Added hanging store injection (`setHanging`) and large dataset generator (`makeWithLargeDataSet`) for deterministic integration testing. |
| `HttpIntegrationTests.swift` | **Fault/Chaos Test Suite** | Added 6 new integration tests covering slow headers, slow bodies, hanging stores, large responses, stop-and-restart counter isolation, and production assembly authorization. Total tests expanded from 68 to 74. |

---

## 5. Architectural Component Status Classifications

| Component | Status | Operational Notes |
|-----------|--------|-------------------|
| **PyiCloud** | `MOCK_ONLY` | Fully tested offline candidate (30 unit tests); no live credentials loaded. Mainline preserved. |
| **Seoul / MUSE** | `PENDING` | End-to-end acceptance requires user initiation in MUSE UI; blocked on Seoul Reminders Gateway deployment (`PENDING_SEOUL_GATEWAY_ADAPTER`). |
| **Source Baseline Reconciliation** | `PARTIAL` | Contacts/Groups deployed in PR #14; Calendar ETag and MUSE SafeWriteManager classified as `SOURCE_MISSING`. |
| **M5 Pro Experimental Retirement** | `PENDING_AUTHORIZATION` | Strictly scoped to M5 Pro A4 experimental resources (historical port 18443); unverified plists marked `RESOURCE_STATUS_UNKNOWN`. Requires human approval. |

---

## 6. Desensitization & Zero Live Mutation

- Apple ID / Real Email Count: **0**
- Real Apple Credentials / Tokens: **0**
- Live Network Requests to Apple: **0** (all tests run on local loopback 127.0.0.1)
- Write Operations to Apple Store: **0**
- Production Service Alterations: **0**

---

*Clean checkout build and test evidence verified by Antigravity Agent | 2026-11-07*
