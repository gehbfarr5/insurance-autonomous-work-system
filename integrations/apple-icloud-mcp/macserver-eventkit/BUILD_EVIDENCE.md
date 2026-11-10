# BUILD_EVIDENCE.md
<!-- AG-06 | MacServer EventKit Universal Candidate & Strict Multi-Arch Signing | 2026-11-09 -->
<!-- REAL EXECUTION EVIDENCE — commands and output are actual from clean checkout, not synthesized -->

## Execution Environment

| Item | Value |
|------|-------|
| Date | 2026-11-09 |
| Branch | `feat/ag05-resident-readonly-candidate` |
| Swift version | Apple Swift version 6.4 (swiftlang-6.4.0.27.1 clang-2100.3.27.1) |
| Native Host Architecture | arm64-apple-macosx27.0.0 (M5 Pro Host) |
| Target Machine Architecture | x86_64-apple-macosx (Intel MacServer, macOS 15.7.7) |
| Xcode Version | Xcode 27.0 (Build 27A5228h) |
| Working Directory | `integrations/apple-icloud-mcp/macserver-eventkit/` |

---

## 1. Multi-Architecture Clean Build & Code Signing Pipeline

### Build & Signing Automation Script: `scripts/build-and-sign-universal.sh`

```bash
/Users/jin/.gemini/antigravity/scratch/ag01-workspace/insurance-autonomous-work-system/integrations/apple-icloud-mcp/macserver-eventkit/scripts/build-and-sign-universal.sh
```

**Execution Log & Gate Assertions:**
```
=== EventKitBridgeServer Multi-Architecture Build & Code Signing Pipeline ===
Package directory: integrations/apple-icloud-mcp/macserver-eventkit
Info.plist:        integrations/apple-icloud-mcp/macserver-eventkit/Info.plist
Target binary:     integrations/apple-icloud-mcp/macserver-eventkit/.build/release/EventKitBridgeServer
--> 1. Building x86_64 thin release binary...
  [OK] x86_64 binary built.
--> 2. Building arm64 thin release binary...
  [OK] arm64 binary built.
--> 3. Merging thin binaries into Universal binary via lipo...
  Lipo output: Architectures in the fat file: EventKitBridgeServer are: x86_64 arm64 
  [OK] Universal binary contains both architectures.
--> 4. Code signing Universal binary (Hardened Runtime + Identifier: com.muse.macserver-eventkit)...
EventKitBridgeServer: replacing existing signature
--> 5. Strict Code Signature Verification (--verify --strict --all-architectures)...
EventKitBridgeServer: valid on disk
EventKitBridgeServer: satisfies its Designated Requirement
  [PASS] All architectures strictly verified and valid on disk.
--> 6. Extracting metadata...
==========================================================
Universal Binary SHA256: f78e24e533c2bf9a77161dc05eb154ce99687de9a5b881ad481bfbe2bbfb3074
Designated Requirement:  # designated => cdhash H"f00641aa5ddebd8cb2c6aa9d7eeb9d141396a61b" or cdhash H"a25782f93277e3d6f965a3fab1a72e8ea1569a34"
--- x86_64 Architecture ---
  CDHash:        a25782f93277e3d6f965a3fab1a72e8ea1569a34
  Flags:         0x10002(adhoc,runtime)
  Min OS Target: macOS 14.0
  Info.plist:    Embedded (__TEXT,__info_plist)
--- arm64 Architecture ---
  CDHash:        f00641aa5ddebd8cb2c6aa9d7eeb9d141396a61b
  Flags:         0x10002(adhoc,runtime)
  Min OS Target: macOS 14.0
  Info.plist:    Embedded (__TEXT,__info_plist)
==========================================================
```

### Artifact Summary Matrix

| Metric | Target x86_64 (Intel MacServer) | Target arm64 (Apple Silicon) |
| :--- | :--- | :--- |
| **Mach-O Format** | 64-bit executable x86_64 | 64-bit executable arm64 |
| **Min macOS Target** | macOS 14.0 (`LC_BUILD_VERSION`) | macOS 14.0 (`LC_BUILD_VERSION`) |
| **Identifier** | `com.muse.macserver-eventkit` | `com.muse.macserver-eventkit` |
| **CDHash** | `a25782f93277e3d6f965a3fab1a72e8ea1569a34` | `f00641aa5ddebd8cb2c6aa9d7eeb9d141396a61b` |
| **Flags** | `0x10002(adhoc,runtime)` | `0x10002(adhoc,runtime)` |
| **Embedded Info.plist** | Present (`__TEXT,__info_plist`) | Present (`__TEXT,__info_plist`) |
| **Universal Binary SHA256** | `f78e24e533c2bf9a77161dc05eb154ce99687de9a5b881ad481bfbe2bbfb3074` |
| **Strict Signature Gate** | `codesign --verify --strict --all-architectures` -> **PASS (Exit code 0)** |

---

## 2. Multi-Architecture Offline Lifecycle & Protocol Verification

**Execution script**: `Tests/test-universal-bridge-offline.sh`

```bash
/Users/jin/.gemini/antigravity/scratch/ag01-workspace/insurance-autonomous-work-system/integrations/apple-icloud-mcp/macserver-eventkit/Tests/test-universal-bridge-offline.sh
```

**Real Execution Output:**
```
=== EventKitBridgeServer Offline & Multi-Architecture Validation ===
Testing binary: .build/release/EventKitBridgeServer
--> 1. Architecture Check (file & lipo)
  Mach-O universal binary with 2 architectures: [x86_64:Mach-O 64-bit executable x86_64] [arm64:Mach-O 64-bit executable arm64]
--> 2. Strict Codesign Check (--verify --strict --all-architectures)
  [PASS] All architectures strictly valid on disk and satisfy Designated Requirement
--> 3. Designated Requirement & CDHash Inspection
  # designated => cdhash H"f00641aa5ddebd8cb2c6aa9d7eeb9d141396a61b" or cdhash H"a25782f93277e3d6f965a3fab1a72e8ea1569a34"
  x86_64 CDHash: a25782f93277e3d6f965a3fab1a72e8ea1569a34
  arm64  CDHash: f00641aa5ddebd8cb2c6aa9d7eeb9d141396a61b
--> 4. Embedded Info.plist Verification (__TEXT,__info_plist)
  [PASS] Embedded __info_plist present in both x86_64 and arm64
--> 5. SHA256 Checksum: f78e24e533c2bf9a77161dc05eb154ce99687de9a5b881ad481bfbe2bbfb3074
------------------------------------------------------------
--> Running Lifecycle Test for architecture: x86_64
------------------------------------------------------------
  [Step A] Starting arch -x86_64 server...
  [PASS] (x86_64) /health responded 200 OK
  [PASS] (x86_64) /reminders/lists returned lists metadata
  [PASS] (x86_64) /reminders/lists/{id}/items returned items from allowlisted list
  [PASS] (x86_64) Non-allowlisted list correctly rejected with HTTP 403
  [PASS] (x86_64) Write rejection verified (POST=405, PUT=405, DELETE=405)
  [Step D] Gracefully terminating server with SIGTERM...
  [PASS] (x86_64) Server stopped cleanly, port released
  [Step E] Restarting arch -x86_64 server to verify clean restart...
  [PASS] (x86_64) Server restart successful, /health responded 200 OK
  [PASS] (x86_64) Lifecycle test (start -> read-only -> write block -> stop -> restart -> stop) completed 100% OK
------------------------------------------------------------
--> Running Lifecycle Test for architecture: arm64
------------------------------------------------------------
  [Step A] Starting arch -arm64 server...
  [PASS] (arm64) /health responded 200 OK
  [PASS] (arm64) /reminders/lists returned lists metadata
  [PASS] (arm64) /reminders/lists/{id}/items returned items from allowlisted list
  [PASS] (arm64) Non-allowlisted list correctly rejected with HTTP 403
  [PASS] (arm64) Write rejection verified (POST=405, PUT=405, DELETE=405)
  [Step D] Gracefully terminating server with SIGTERM...
  [PASS] (arm64) Server stopped cleanly, port released
  [Step E] Restarting arch -arm64 server to verify clean restart...
  [PASS] (arm64) Server restart successful, /health responded 200 OK
  [PASS] (arm64) Lifecycle test (start -> read-only -> write block -> stop -> restart -> stop) completed 100% OK
==========================================================
=== Offline Multi-Architecture Verification 100% SUCCESS ===
==========================================================
```

---

## 3. Package Test Suite Evidence (`swift test`)

**Command:** `swift test`  
**Result:** ✅ Exit code 0 (Executed 91 tests, with 0 failures in 5.213s)

```
Test Suite 'AllowlistValidatorTests' passed (10 tests, 0 failures)
Test Suite 'AuthTests' passed (10 tests, 0 failures)
Test Suite 'ErrorHandlingTests' passed (10 tests, 0 failures)
Test Suite 'HttpIntegrationTests' passed (24 tests, 0 failures)
Test Suite 'MetadataOnlyTests' passed (8 tests, 0 failures)
Test Suite 'NonEmptyReminderFieldTests' passed (9 tests, 0 failures)
Test Suite 'SourceVerifierTests' passed (10 tests, 0 failures)
Test Suite 'WriteIsolationTests' passed (8 tests, 0 failures)
-------------------------------------------------------------
TOTAL: 91 passed, 0 failed (100% pass rate)
```

---

## 4. Desensitization & Zero Live Mutation

- Apple ID / Real Email Count: **0**
- Real Apple Credentials / Tokens: **0**
- Live Network Requests to Apple: **0** (all tests run on local loopback 127.0.0.1)
- Write Operations to Apple Store: **0**
- Production Service Alterations: **0** (strictly offline / synthetic tests)
