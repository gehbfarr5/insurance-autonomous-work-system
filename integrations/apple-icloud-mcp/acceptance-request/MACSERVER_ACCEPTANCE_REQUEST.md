# MacServer EventKit Readonly Candidate — Formal Acceptance Protocol
<!-- AG-01-B | feat/macserver-eventkit-readonly | 2026-11-07 -->

## 1. Summary & Scope

This document specifies the formal acceptance request and actionable installation protocol for the **MacServer EventKit Read-Only Candidate**.
It defines:
1. Candidate build digests and target architecture (Intel MacServer `x86_64` and M5 Pro `arm64`).
2. Human review and installation approval criteria.
3. MUSE independent verification task routed strictly through the **Seoul MCP** security gateway.
4. Subsequent dependency tracking for the Seoul MCP Reminders Gateway adapter.
5. End-to-end installation procedure: Code signing with Hardened Runtime, CDHash verification, target OS compatibility, GUI domain loading, LaunchAgent specification, health verification, and rollback recovery.

---

## 2. Delivery & Build Verification

| Field | Value |
|-------|-------|
| Task ID | AG-01 (Phase B) |
| Feature Branch | `feat/macserver-eventkit-readonly` |
| Base Branch | `reconcile/icloud-source-baseline` (Stacked PR #21) |
| Verified Clean Checkout Commit | `fd1aa15906b8bf3327cb4f82ea79cde32bb77cab` |
| x86_64 Pre-signing SHA-256 (Intel MacServer) | `13949eb3b3a212994024a0df5932a54f6f79e40de5867d83b34ac6d194fd408b` |
| x86_64 Post-signing SHA-256 (Hardened Runtime) | `223d624c8bf455543f36499fc448c072a5b34087c119e4b8d4a15829f95df8d4` |
| x86_64 CDHash | `6d8862157803a2fc7863818acdcb2b0e7ee2b103` |
| arm64 Pre-signing SHA-256 (M5 Pro Host) | `473a49987c24f3bfaa6e8aa71358b2d1bc6a95a2a233e6a298602aa363323f4f` |
| arm64 Post-signing SHA-256 (Hardened Runtime) | `40bcdcfbd7f4eb1011b4085f6210c99d91239306ebd236366097cdabc72bb7f1` |
| arm64 CDHash | `f9f2c10f5bbc6076f4e6ecf1d453327905a584b5` |
| Isolation Test Suite | **80 passed, 0 failed** (including 24 real loopback HTTP integration tests) |
| Apple Live Writes | **0** (strictly read-only protocol, write methods return 405) |
| Production Changes | **0** (no service restarted, no deployment applied) |
| PyiCloud Status | `MOCK_ONLY` |
| Seoul / MUSE Status | `PENDING` |
| Source Reconciliation | `PARTIAL` |
| M5 Pro Retirement | `PENDING_AUTHORIZATION` |

---

## 3. Architecture Guarantees & Closed Blockers

| Item | Problem Addressed | Offline Verification Evidence |
|------|-------------------|--------------------------------|
| **FIX-R4A-01** | Metadata queries must never query reminder counts or items | `MetadataOnlyTests` + `HttpIntegrationTests.testRealHttpMetadataOnlyNeverQueriesReminderContent` (store query count = 0) |
| **FIX-R4A-02** | Content query must enforce iCloud source identity & type | `SourceVerifierTests` (calDAV type, source UUID & list binding check) + `HttpIntegrationTests.testSourceRejectionMatrixZeroContentAccess` |
| **Write Isolation** | Non-GET HTTP methods must be rejected with 0 downstream calls | `WriteIsolationTests` + `HttpIntegrationTests.testRealHttpWriteOperationsRejectedWith405` (POST/PUT/DELETE/PATCH -> 405) |
| **Connection Ownership** | Socket lifecycle centralization before Worker spawn | `ManagedSocketHandle` with atomic exactly-once close; `testRapidConnectionAndDisconnectStress` (10 rapid disconnects with zero fd leaks or double closes) |
| **Store Resource Budget** | Hanging Store tasks must not accumulate unbounded across restarts | `activeStoreOperationIDs` preserved across `stop()` and `start()`; multi-round budget preservation verified in `testStoreResourceBudgetPreservedAcrossMultiRoundStopRestart` (total alive tasks capped at 2, rejects 3rd with 503) |
| **Production Provider Assembly** | Default-off real store provider, explicit runtime authorization | `ProductionEventKitProvider.makeLiveEventStoreProvider()` wired into `ProductionStoreAssembly.assemble`; offline verified in `testProductionEventKitProviderWiringDefaultOff` (unauthorized throws `permissionDenied`, 0 live store access) |
| **Template & Program Consistency** | Unified `EVENTKIT_BRIDGE_*` variables and canonical LaunchAgent plist | Program natively provides `--generate-plist-template`; verified in `testLaunchAgentTemplateConsistencyAndProcessLevelStartup` (plist XML parsed back, starts loopback server cleanly) |

---

## 4. MUSE Independent Acceptance Protocol (Via Seoul MCP)

### Architecture Contract
- **Seoul Host**: Serves as the unified entry point, OAuth 2.1 layer, and write gatekeeper.
- **MacServer EventKit**: Serves as the resident read-only helper daemon for modern Reminders lists.
- **MUSE Client**: Must be triggered independently by the user in the MUSE client UI. Antigravity direct terminal or SSH calls **cannot substitute** for MUSE acceptance.

### Dependency Gate: Seoul Gateway Adapter
> [!IMPORTANT]
> If Seoul MCP does not yet have the updated gateway adapter routing Reminders requests to MacServer EventKit, the MUSE end-to-end acceptance is marked **`PENDING_SEOUL_GATEWAY_ADAPTER`**. Acceptance must wait until the Seoul MCP router is deployed under a separate maintenance window.

### User Prompt for Independent MUSE Acceptance (Read-Only)
```text
请通过已连接的 Seoul MCP 实例执行只读提醒事项验收：
1. 列表元数据核验：调用 reminders_lists，验证返回的列表中仅包含列表 ID、名称和颜色，绝不包含任何未完成数量或提醒内容。
2. 白名单读取核验：读取指定白名单测试列表中的待办事项，验证条目结构与 iCloud 来源校验一致。
（注意：本轮为纯只读验收，严禁发送任何新建、修改或删除指令）
```

### Expected Structured Verification Receipt
```json
{
  "task": "MUSE_EVENTKIT_READONLY_ACCEPTANCE",
  "gateway": "SEOUL_MCP",
  "backend": "MACSERVER_EVENTKIT",
  "metadata_only_verified": {
    "status": "PASS",
    "reminder_counts_exposed": false,
    "items_exposed": false
  },
  "source_integrity_verified": {
    "status": "PASS",
    "source_type": "calDAV",
    "source_title": "iCloud"
  },
  "downstream_writes": 0,
  "timestamp": "<ISO-8601>"
}
```

---

## 5. MacServer Sandboxed Installation Protocol (When Authorized)

When human authorization is granted, the deployment must execute strictly according to the following protocol:

### A. Target Platform Compatibility
- **Host Hardware**: Intel MacServer (`x86_64`)
- **OS Compatibility**: macOS 13 (Ventura), macOS 14 (Sonoma), macOS 15 (Sequoia), Darwin 27.x.
- **Session Domain Requirement**: **Active Graphical User Session (`gui/$(id -u)`)**.
  > [!WARNING]
  > EventKit relies on Apple Privacy TCC (`kTCCServiceReminders`). Daemons registered in the `system` domain or headless `launchd` contexts cannot display permission authorization dialogs or access user EventKit databases. The service **must** run in the user's GUI session.

### B. Code Signing & Hardened Runtime Verification
Apply ad-hoc code signature with Hardened Runtime on the target binary:
```bash
# 1. Sign target binary with designated identifier and hardened runtime
codesign --force --sign - \
  --identifier "com.muse.macserver-eventkit" \
  --options runtime \
  /Users/shared/bin/EventKitBridgeServer

# 2. Verify signature and CDHash (must match 6d8862157803a2fc7863818acdcb2b0e7ee2b103)
codesign -dv --verbose=4 /Users/shared/bin/EventKitBridgeServer
```

### C. Installation Steps
1. **Prepare Directories & Deploy Binary**:
   ```bash
   mkdir -p /Users/shared/bin /Users/shared/log ~/Library/LaunchAgents
   install -m 755 .build-x86_64/out/Products/Release/EventKitBridgeServer /Users/shared/bin/EventKitBridgeServer
   ```

2. **Deploy Canonical LaunchAgent Configuration (`~/Library/LaunchAgents/com.muse.macserver-eventkit.plist`)**:
   Use the canonical template generated directly from the binary definition:
   ```xml
   <?xml version="1.0" encoding="UTF-8"?>
   <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
   <plist version="1.0">
   <dict>
       <key>Label</key>
       <string>com.muse.macserver-eventkit</string>
       <key>ProgramArguments</key>
       <array>
           <string>/Users/shared/bin/EventKitBridgeServer</string>
       </array>
       <key>EnvironmentVariables</key>
       <dict>
           <key>EVENTKIT_BRIDGE_MODE</key>
           <string>PRODUCTION</string>
           <key>EVENTKIT_BRIDGE_PORT</key>
           <string>18765</string>
           <key>EVENTKIT_BRIDGE_ALLOWED_LIST_IDS</key>
           <string>TARGET_ICLOUD_LIST_UUID</string>
           <key>EVENTKIT_BRIDGE_BINDINGS</key>
           <string>TARGET_ICLOUD_LIST_UUID:TARGET_ICLOUD_SOURCE_UUID:calDAV:iCloud</string>
           <key>EVENTKIT_BRIDGE_BEARER_TOKEN</key>
           <string>GENERATE_SECURE_TOKEN_AT_INSTALL</string>
           <key>EVENTKIT_BRIDGE_MAX_CONCURRENT</key>
           <string>10</string>
           <key>EVENTKIT_BRIDGE_MAX_STORE_OPS</key>
           <string>10</string>
           <key>EVENTKIT_BRIDGE_TIMEOUT</key>
           <string>5.0</string>
           <key>EVENTKIT_BRIDGE_PRODUCTION_AUTHORIZED</key>
           <string>true</string>
       </dict>
       <key>RunAtLoad</key>
       <true/>
       <key>KeepAlive</key>
       <true/>
       <key>StandardOutPath</key>
       <string>/Users/shared/log/macserver-eventkit.stdout.log</string>
       <key>StandardErrorPath</key>
       <string>/Users/shared/log/macserver-eventkit.stderr.log</string>
   </dict>
   </plist>
   ```

3. **Activate Service in GUI Domain**:
   ```bash
   chmod 644 ~/Library/LaunchAgents/com.muse.macserver-eventkit.plist
   launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.muse.macserver-eventkit.plist
   ```

4. **Verify Health & Isolation**:
   ```bash
   # 1. Health check (returns 200 without auth)
   curl -s http://127.0.0.1:18765/health
   # Expected: {"status":"ok","mode":"readonly","active_requests":0,"active_store_operations":0...}

   # 2. Write rejection check (returns 405)
   curl -s -X POST -o /dev/null -w "%{http_code}\n" http://127.0.0.1:18765/reminders/lists
   # Expected: 405

   # 3. Read metadata check
   curl -s -H "Authorization: Bearer <TOKEN>" http://127.0.0.1:18765/reminders/lists
   # Expected: 200 with list metadata only
   ```

### D. Rollback & Recovery Procedure
In the event of unexpected behavior, execute immediate rollback:
1. **Unload Daemon**:
   ```bash
   launchctl bootout gui/$(id -u) ~/Library/LaunchAgents/com.muse.macserver-eventkit.plist
   ```
2. **Remove Binary & Plist**:
   ```bash
   rm -f ~/Library/LaunchAgents/com.muse.macserver-eventkit.plist
   rm -f /Users/shared/bin/EventKitBridgeServer
   ```
3. **Reset TCC Permissions (if testing scope requires cleanup)**:
   ```bash
   tccutil reset Reminders com.muse.macserver-eventkit
   ```
4. **Confirm Port Teardown**:
   ```bash
   lsof -i :18765
   # Output must be empty
   ```
