# MacServer EventKit Readonly Candidate — Formal Acceptance Protocol
<!-- AG-01-B | feat/macserver-eventkit-readonly | 2026-11-07 -->

## 1. Summary & Scope

This document specifies the formal acceptance request and production installation protocol for the **MacServer EventKit Read-Only Candidate**.
It defines:
1. Candidate build digests and target architecture (Intel MacServer `x86_64` and M5 Pro `arm64`).
2. Human review and installation approval criteria.
3. MUSE independent verification task routed strictly through the **Seoul MCP** security gateway.
4. Subsequent dependency tracking for the Seoul MCP Reminders Gateway adapter.
5. End-to-end installation procedure: Code signing, TCC identity, target OS compatibility, GUI domain loading, LaunchAgent specification, health verification, and rollback recovery.

---

## 2. Delivery & Build Verification

| Field | Value |
|-------|-------|
| Task ID | AG-01 (Phase B) |
| Feature Branch | `feat/macserver-eventkit-readonly` |
| Base Branch | `reconcile/icloud-source-baseline` (Stacked PR #21) |
| Verified Clean Checkout Commit | `cab1252f6080da898d822435f1c9295a876034a4` |
| arm64 Binary SHA-256 | `02f60b66ac85fe9e87a3ded4cec79125c62a81d2c553bb76582749ec809dfe83` |
| x86_64 Binary SHA-256 (Intel MacServer) | `82aff2d1e33cdc599420195f31e07d5c282ce4a79489a6bb80c7b291d1de51cd` |
| Isolation Test Suite | **77 passed, 0 failed** (including 21 real loopback HTTP integration tests) |
| Apple Live Writes | **0** (strictly read-only protocol, write methods return 405) |
| Production Changes | **0** (no service restarted, no deployment applied) |
| PyiCloud Status | `MOCK_ONLY` |
| Seoul / MUSE Status | `PENDING` |
| Source Reconciliation | `PARTIAL` |
| M5 Pro Retirement | `PENDING_AUTHORIZATION` |

---

## 3. Review Fixes & Architecture Guarantees

| Item | Problem Addressed | Offline Verification Evidence |
|------|-------------------|--------------------------------|
| **FIX-R4A-01** | Metadata queries must never query reminder counts or items | `MetadataOnlyTests` + `HttpIntegrationTests.testRealHttpMetadataOnlyNeverQueriesReminderContent` (store query count = 0) |
| **FIX-R4A-02** | Content query must enforce iCloud source identity & type | `SourceVerifierTests` (calDAV type, source UUID & list binding check) + `HttpIntegrationTests.testSourceRejectionMatrixZeroContentAccess` |
| **Write Isolation** | Non-GET HTTP methods must be rejected with 0 downstream calls | `WriteIsolationTests` + `HttpIntegrationTests.testRealHttpWriteOperationsRejectedWith405` (POST/PUT/DELETE/PATCH -> 405) |
| **Connection Ownership** | Socket lifecycle centralization before Worker spawn | `ManagedSocketHandle` with atomic exactly-once close; `testRapidConnectionAndDisconnectStress` (10 rapid disconnects with zero fd leaks or double closes) |
| **Store Resource Budget** | Hanging Store tasks must not accumulate unbounded | `activeStoreOperationsCount` tracked across timeouts; returns 503 (`STORE_RESOURCE_LIMIT_EXCEEDED`) when limit reached; verified in `testStoreResourceBudgetRejectsExcessiveHangingTasks` |
| **Production Assembly Gate** | Store provider must be default-off and reject unauthorized activation | `ProductionStoreAssembly.assemble(isAuthorized:authorizedStoreProvider:)`; verified in `testProductionStoreAssemblyExplicitAuthorization` |

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

### B. Code Signing & TCC Identity
Ad-hoc or Developer ID code signing ensures deterministic TCC attribution:
```bash
# Entitlements configuration (entitlements.plist)
cat << 'EOF' > /tmp/bridge_entitlements.plist
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.app-sandbox</key>
    <false/>
</dict>
</plist>
EOF

# Sign binary with hardened runtime and designated identifier
codesign --force --sign - \
  --identifier "com.muse.macserver-eventkit" \
  --options runtime \
  --entitlements /tmp/bridge_entitlements.plist \
  ~/bin/EventKitBridgeServer

# Verify signature
codesign -dv --verbose=4 ~/bin/EventKitBridgeServer
```

### C. Installation Steps
1. **Copy Verified Binary**:
   Copy the `x86_64` binary (SHA-256: `82aff2d1e33cdc599420195f31e07d5c282ce4a79489a6bb80c7b291d1de51cd`) to target:
   ```bash
   mkdir -p ~/bin
   install -m 755 .build-x86_64/out/Products/Release/EventKitBridgeServer ~/bin/EventKitBridgeServer
   ```

2. **Deploy LaunchAgent Template (`~/Library/LaunchAgents/com.muse.macserver-eventkit.plist`)**:
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
           <string>production</string>
           <key>EVENTKIT_BRIDGE_PORT</key>
           <string>18765</string>
           <key>EVENTKIT_BRIDGE_ALLOWED_LIST_IDS</key>
           <string>TARGET_ICLOUD_LIST_UUID</string>
           <key>EVENTKIT_BRIDGE_ALLOWED_SOURCE_IDS</key>
           <string>TARGET_ICLOUD_SOURCE_UUID</string>
           <key>EVENTKIT_BRIDGE_BEARER_TOKEN</key>
           <string>GENERATE_SECURE_TOKEN_AT_INSTALL</string>
           <key>EVENTKIT_BRIDGE_MAX_CONCURRENT</key>
           <string>10</string>
           <key>EVENTKIT_BRIDGE_MAX_STORE_OPS</key>
           <string>10</string>
           <key>EVENTKIT_BRIDGE_TIMEOUT</key>
           <string>5.0</string>
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
   launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.muse.macserver-eventkit.plist
   ```

4. **Verify Health & Isolation**:
   ```bash
   # 1. Health check (returns 200 without auth)
   curl -s -o /dev/null -w "%{http_code}\n" http://127.0.0.1:18765/health
   # Expected: 200

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
   rm -f ~/bin/EventKitBridgeServer
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
