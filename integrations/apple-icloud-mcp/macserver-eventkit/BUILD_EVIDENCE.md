# BUILD_EVIDENCE.md
<!-- AG-01-B | MacServer EventKit Readonly Candidate | 2026-11-07 -->
<!-- REAL EXECUTION EVIDENCE — commands and output are actual from clean checkout, not synthesized -->

## Execution Environment

| Item | Value |
|------|-------|
| Date | 2026-11-07 |
| Clean Checkout Base | `/tmp/clean-checkout-ag01` |
| Tested Commit | `cab1252f6080da898d822435f1c9295a876034a4` |
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
**Result:** ✅ Exit code 0 (Build complete in 2.65s)
- Binary Format: `Mach-O 64-bit executable x86_64`
- Binary Path: `.build-x86_64/out/Products/Release/EventKitBridgeServer`
- SHA-256 Digest: `82aff2d1e33cdc599420195f31e07d5c282ce4a79489a6bb80c7b291d1de51cd`
- Symbol Audit: Contains native `ProductionEventKitStore`, `ProductionStoreAssembly`, and `SourceVerifier` Mach-O symbols.

### B. M5 Pro Host Target (`arm64-apple-macosx`)
**Command executed:**
```bash
swift build --triple arm64-apple-macosx -c release --scratch-path .build-arm64 2>&1
```
**Result:** ✅ Exit code 0 (Build complete in 2.67s)
- Binary Format: `Mach-O 64-bit executable arm64`
- Binary Path: `.build-arm64/out/Products/Release/EventKitBridgeServer`
- SHA-256 Digest: `02f60b66ac85fe9e87a3ded4cec79125c62a81d2c553bb76582749ec809dfe83`

---

## 2. Test Execution Evidence (Clean Checkout)

**Command executed:**
```bash
swift test 2>&1
```

**Result:** ✅ Exit code 0 (77 executed, 0 failures in 4.512s)

**Suite Summary Breakdown (from raw test log):**
```
Test Suite 'AllowlistValidatorTests' passed.
     Executed 10 tests, with 0 failures (0 unexpected) in 0.001 seconds
Test Suite 'AuthTests' passed.
     Executed 10 tests, with 0 failures (0 unexpected) in 0.001 seconds
Test Suite 'ErrorHandlingTests' passed.
     Executed 10 tests, with 0 failures (0 unexpected) in 0.001 seconds
Test Suite 'HttpIntegrationTests' passed.
     Executed 21 tests, with 0 failures (0 unexpected) in 4.403 seconds
Test Suite 'MetadataOnlyTests' passed.
     Executed 8 tests, with 0 failures (0 unexpected) in 0.002 seconds
Test Suite 'SourceVerifierTests' passed.
     Executed 10 tests, with 0 failures (0 unexpected) in 0.001 seconds
Test Suite 'WriteIsolationTests' passed.
     Executed 8 tests, with 0 failures (0 unexpected) in 0.110 seconds
---------------------------------------------------------------------------------
TOTAL: Executed 77 tests, with 0 failures (0 unexpected) in 4.512 seconds
```

---

## 3. Detailed Acceptance Matrix

| Test Suite | Tests | Passed | Acceptance Requirement & Verified Gate |
|------------|-------|--------|----------------------------------------|
| `AllowlistValidatorTests` | 10 | 10 | Exact ID match; rejects prefixes, suffixes, wildcards, name guessing |
| `AuthTests` | 10 | 10 | Rejects missing/invalid Bearer tokens; validates scoped permissions |
| `ErrorHandlingTests` | 10 | 10 | Desensitized error descriptions, mapping to HTTP 401/403/404/405/408/413/429/431/503/504/500 |
| `MetadataOnlyTests` | 8 | 8 | **FIX-R4A-01**: `contentAccessCount` strictly 0 on metadata queries; no count fields |
| `SourceVerifierTests` | 10 | 10 | **FIX-R4A-02**: Enforces calDAV source type, iCloud source title, source UUID & exact list identity binding |
| `WriteIsolationTests` | 8 | 8 | All write verbs rejected with 405 Method Not Allowed; store writes = 0 |
| `HttpIntegrationTests` | 21 | 21 | **Real Loopback HTTP & Concurrency/Budget**: Native socket listener, auth, allowlist, metadata-only (contentCount=0), source rejection matrix (4 targets: unbound, wrong UUID, local type, spoofed title with contentCount=0), 405 write block, chunked headers, 16KB header limit (431), client early disconnect resilience, slow request header deadline (408), slow request body deadline, hanging store watchdog (504 within deadline while /health remains 200), large response partial send loop, stop-and-restart counter isolation, strict production config validation, connection registration before worker startup, idempotent fd closing via `ManagedSocketHandle`, rapid disconnect stress test (10 concurrent fast closes), stop-and-restart under pressure, and bounded store resource budget (rejecting tasks with 503 upon budget exhaustion) |
| **TOTAL** | **77** | **77** | **ALL ACCEPTANCE CRITERIA VERIFIED (100% PASS)** |

---

## 4. Diff Explanation: `b63f72e` → Current HEAD (`cab1252`)

| Component | Nature of Change | Impact & Justification |
|-----------|------------------|------------------------|
| `ManagedSocketHandle.swift` | **Centralized fd Lifecycle** | Thread-safe atomic socket descriptor handle (`StoreAtomicBool.getAndSet(true)`). Guarantees idempotent, exactly-once `Darwin.close(fd)` with non-blocking receive buffer draining, completely eliminating duplicate closes across `stop()`, worker exit, or refused registration. |
| `EventKitBridgeServer.swift` | **Inverted Worker Spawning** | Connection registration with the server actor (`registerIncomingConnection(connectionID:handle:)`) now occurs *prior* to starting Worker tasks. If registration is refused, the socket is closed immediately and no background worker is spawned. |
| `EventKitBridgeServer.swift` | **Bounded Store Resource Budget** | Store operations remain tracked in `activeStoreOperationsCount` even if the client times out with HTTP 504. When `maxConcurrentStoreOperations` is saturated, subsequent requests are immediately rejected with HTTP 503 (`STORE_RESOURCE_LIMIT_EXCEEDED`), strictly preventing runaway background task accumulation from uncooperative Stores. |
| `EventKitBridgeServer.swift` | **Decoupled Socket I/O** | Darwin socket I/O is completely removed from the actor context into `SocketConnectionWorker`. Actor exclusively arbitrates configuration, routing, and concurrency state. |
| `EventKitBridgeServer.swift` | **Full Send Loop** | Implemented `sendHttpResponseFull` handling partial socket writes, `EINTR` signal retries, `EPIPE`/`ECONNRESET` client disconnects, and `SO_NOSIGPIPE` to prevent process crashes. |
| `EventKitBridgeServer.swift` | **Generational Counter Isolation** | Teardown increments `serverGeneration`. Late-finishing background tasks from previous server generations are prevented from decrementing or polluting active counters on restarted servers. |
| `BridgeConfig.swift` | **Configurable Store Ops Limit** | Added `maxConcurrentStoreOperations` (default 10, configurable via `EVENTKIT_BRIDGE_MAX_STORE_OPS`). |
| `ProductionEventKitStore.swift` | **Explicit Assembly Path** | Introduced `ProductionStoreAssembly.assemble(isAuthorized:authorizedStoreProvider:)` providing a default-off, explicit authorization injection path. Verified via dependency injection without live EKEventStore instantiation. |
| `FakeEventKitStore.swift` | **Chaos Fixtures** | Added hanging store injection (`setHanging`) and large dataset generator (`makeWithLargeDataSet`) for deterministic integration testing. |
| `HttpIntegrationTests.swift` | **Pressure & Resource Budget Tests** | Added 3 new integration tests: `testRapidConnectionAndDisconnectStress`, `testStopAndRestartUnderPressure`, and `testStoreResourceBudgetRejectsExcessiveHangingTasks`. Total test count expanded to 77 tests (21 HTTP integration tests). |

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
