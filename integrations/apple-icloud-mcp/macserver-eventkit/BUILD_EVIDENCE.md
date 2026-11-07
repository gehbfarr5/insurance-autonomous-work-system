# BUILD_EVIDENCE.md
<!-- AG-01-B | MacServer EventKit Readonly Candidate | 2026-11-07 -->
<!-- REAL EXECUTION EVIDENCE — commands and output are actual, not synthesized -->

## Environment

| Item | Value |
|------|-------|
| Date | 2026-11-07 |
| Swift version | swift-driver version: 1.168.5 Apple Swift version 6.4 (swiftlang-6.4.0.27.1 clang-2100.3.27.1) |
| Target | arm64-apple-macosx27.0.0 |
| Xcode | 27 (MacOSX27.0.sdk) |
| Machine | macOS arm64 |
| Working directory | `integrations/apple-icloud-mcp/macserver-eventkit/` |

---

## Phase 1: swift build

**Command executed:**
```bash
cd integrations/apple-icloud-mcp/macserver-eventkit
swift build 2>&1
```

**Result:** ✅ Exit code 0

**Output:**
```
Building for debugging...
[2 / 26] EventKitBridge
[17 / 41] EventKitBridge
[26 / 42]
[28 / 44] EventKitBridgeServerExec
[36 / 45] EventKitBridge
[40 / 45] EventKitBridgeServer-product
[45 / 47] EventKitBridgeServer-product
Build complete! (4.85秒)
```

> [!NOTE] First build attempt failed due to `enableStrictConcurrency` SwiftSetting
> not being available in this toolchain. Removed the setting from Package.swift.
> The actor-isolation conformance errors were fixed by making `contentAccessCount`
> and `resetCounters()` async in the protocol. All fixes were made and build
> succeeded on the second attempt.

---

## Phase 2: swift test

**Command executed:**
```bash
cd integrations/apple-icloud-mcp/macserver-eventkit
swift test 2>&1
```

**Result:** ✅ Exit code 0

**Output (condensed):**
```
Build complete! (3.88秒)
Test Suite 'All tests' started at 2026-11-07 13:17:57.572.
Test Suite 'EventKitBridgeTests.xctest' started at 2026-11-07 13:17:57.574.

Test Suite 'AllowlistValidatorTests' passed.
     Executed 10 tests, with 0 failures (0 unexpected) in 0.003 (0.003) seconds

Test Suite 'AuthTests' passed.
     Executed 10 tests, with 0 failures (0 unexpected) in 0.001 (0.002) seconds

Test Suite 'ErrorHandlingTests' passed.
     Executed 10 tests, with 0 failures (0 unexpected) in 0.000 (0.001) seconds

Test Suite 'MetadataOnlyTests' passed.
     Executed 8 tests, with 0 failures (0 unexpected) in 0.002 (0.002) seconds

Test Suite 'SourceVerifierTests' passed.
     Executed 10 tests, with 0 failures (0 unexpected) in 0.001 (0.002) seconds

Test Suite 'WriteIsolationTests' passed.
     Executed 8 tests, with 0 failures (0 unexpected) in 0.001 (0.002) seconds

Test Suite 'EventKitBridgeTests.xctest' passed.
     Executed 56 tests, with 0 failures (0 unexpected) in 0.009 (0.013) seconds
Test Suite 'All tests' passed at 2026-11-07 13:17:57.587.
     Executed 56 tests, with 0 failures (0 unexpected) in 0.009 (0.015) seconds
✔ Test run with 0 tests in 0 suites passed after 0.001 seconds.
```

---

## Test Matrix

| Test Suite | Tests | Passed | Failed | Acceptance Criterion |
|-----------|-------|--------|--------|---------------------|
| AllowlistValidatorTests | 10 | 10 | 0 | FIX-R4A-01: exact-match allowlist ✅ |
| AuthTests | 10 | 10 | 0 | Invalid auth / non-allowlist / source mismatch rejected ✅ |
| ErrorHandlingTests | 10 | 10 | 0 | Timeout/revocation/missing → explicit failure ✅ |
| MetadataOnlyTests | 8 | 8 | 0 | FIX-R4A-01: metadata never touches content ✅ |
| SourceVerifierTests | 10 | 10 | 0 | FIX-R4A-02: iCloud source verification ✅ |
| WriteIsolationTests | 8 | 8 | 0 | All write requests rejected; downstream writes = 0 ✅ |
| **TOTAL** | **56** | **56** | **0** | **ALL PASS** ✅ |

---

## Build Artifact Summary

| Artifact | SHA-256 |
|----------|---------|
| `.build/debug/EventKitBridgeServer` | `a0bc6f0f4e6ef2cc1ab8c873e0a5538bac1861400bc726a84bd44b03dd5b35ee` |

---

## Desensitization Confirmation

- No Apple ID, iCloud credential, token, or real account data appears in any file.
- All test data uses synthetic identifiers (`fake-list-icloud-001`, `test-token-001`, etc.).
- `ProductionEventKitStore` compiles but throws `permissionDenied` on all calls (stub not activated).
- No network calls were made during build or test.

---

*Build evidence recorded by AG-01 Engineering Agent | 2026-11-07*
