# MacServer EventKit Readonly Candidate — Formal Acceptance Protocol
<!-- AG-01-B | feat/macserver-eventkit-readonly | 2026-11-07 -->

## 1. Summary & Scope

This document specifies the formal acceptance request and protocol for the **MacServer EventKit Read-Only Candidate**.
It defines:
1. Candidate build digests and target architecture (Intel MacServer x86_64 and M5 Pro arm64).
2. Human review and installation approval criteria.
3. MUSE independent verification task routed strictly through the **Seoul MCP** security gateway.
4. Subsequent dependency tracking for the Seoul MCP Reminders Gateway adapter.

---

## 2. Delivery & Build Verification

| Field | Value |
|-------|-------|
| Task ID | AG-01 (Phase B) |
| Feature Branch | `feat/macserver-eventkit-readonly` |
| Base Branch | `reconcile/icloud-source-baseline` (Stacked PR #21) |
| arm64 Binary SHA-256 | `96741acbc054cbdef75431bbf9a40f52444ffe10304b95cfdbfecd877d02e119` |
| x86_64 Binary SHA-256 (Intel MacServer) | `0c507fe946be20e23e2f30312ef324e80c0a35b2713fcc64c49401c89e50b872` |
| Isolation Test Suite | **67 passed, 0 failed** (including 9 real loopback HTTP integration tests) |
| Apple Live Writes | **0** (strictly read-only protocol, write methods return 405) |
| Production Changes | **0** (no service restarted, no deployment applied) |

---

## 3. Review Fixes Confirmed

| Item | Problem Addressed | Offline Verification Evidence |
|------|-------------------|--------------------------------|
| **FIX-R4A-01** | Metadata queries must never query reminder counts or items | `MetadataOnlyTests` + `HttpIntegrationTests.testRealHttpMetadataOnlyNeverQueriesReminderContent` (store query count = 0) |
| **FIX-R4A-02** | Content query must enforce iCloud source identity & type | `SourceVerifierTests` (calDAV type, source UUID & list binding check) + `HttpIntegrationTests.testRealHttpContentQueryEnforcesICloudSource` |
| **Write Isolation** | Non-GET HTTP methods must be rejected with 0 downstream calls | `WriteIsolationTests` + `HttpIntegrationTests.testRealHttpWriteOperationsRejectedWith405` (POST/PUT/DELETE/PATCH -> 405) |
| **Listener & Shutdown** | Real HTTP loopback server with graceful stop/restart | `HttpIntegrationTests.testRealHttpGracefulStopAndRecovery` (verified socket lifecycle) |

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

When Gate B is granted by human approval:
1. Target Host: Intel MacServer (x86_64), logged-in user graphical session.
2. Deploy Binary: Copy x86_64 binary (`0c507fe94...`) to `~/bin/EventKitBridgeServer`.
3. Configure `com.muse.macserver-eventkit.plist` in `~/Library/LaunchAgents/` with `127.0.0.1` and explicit allowlist.
4. Enable LaunchAgent:
   ```bash
   launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.muse.macserver-eventkit.plist
   ```
5. Rollback:
   ```bash
   launchctl bootout gui/$(id -u) ~/Library/LaunchAgents/com.muse.macserver-eventkit.plist
   rm -f ~/bin/EventKitBridgeServer
   ```
