# AG-03: Seoul → MacServer 只读 Gateway 隔离集成测试证据 (Test Evidence)

- **执行时间**：2026-11-07 23:09:06 CST
- **测试环境**：
  - OS: Darwin 27.0.0 arm64 (macOS)
  - Node.js: v24.18.0
  - Runner: `node --experimental-strip-types --test tests/*.test.ts`
  - 依赖状态：零外部三方依赖（使用 Node.js 原生 HTTP、Fetch 与 Test Runner）
- **覆盖模块与套件**：
  1. `tests/config.test.ts` (配置解析、通配地址防范与显式列表—来源 ID 绑定校验)
  2. `tests/container-tunnel.test.ts` (容器→宿主隧道→Fake Bridge 多跳网络隔离集成)
  3. `tests/protocol.test.ts` (MCP 协议级工具装配、输入契约校验与零写转发验证)
  4. `tests/service.test.ts` (ReminderService 适配、跨列表条目归属校验与确定性排序)
  5. `tests/swift-encoding.test.ts` (真实 Swift JSONEncoder 编码兼容性与 Cocoa 日期转换)
  6. `tests/transport.test.ts` (响应体截止时间覆盖、大小超限熔断与错误映射)
  7. `tests/index.test.ts` (模块公共导出完整性)

---

## 一、测试套件执行日志 (45/45 PASS)

```
> seoul-macserver-readonly-gateway@1.0.0 test
> node --experimental-strip-types --test tests/*.test.ts

✔ validateGatewayConfig - parses valid config with explicit list-source bindings (0.521208ms)
✔ validateGatewayConfig - rejects config without explicit source ID binding (0.25325ms)
✔ validateGatewayConfig - rejects non-object or null config (0.077959ms)
✔ validateGatewayConfig - rejects invalid endpoints and wildcards (0.083542ms)
✔ validateGatewayConfig - rejects short or empty tokens (0.070125ms)
✔ validateGatewayConfig - rejects invalid timeout range (0.071833ms)
✔ loadGatewayConfigFromEnv - parses env variables with explicit bindings (6.930542ms)
▶ Container -> Host Tunnel -> Fake Bridge Multi-Hop Integration
  ✔ Container -> Docker Gateway -> SSH Tunnel -> Fake Bridge successfully queries lists (12.518625ms)
  ✔ Container -> Docker Gateway -> SSH Tunnel -> Fake Bridge successfully queries items (6.029583ms)
  ✔ Loopback boundaries verified: servers listen on 127.0.0.1, not 0.0.0.0 (0.302959ms)
  ✔ Zero M5 Pro dependency: no M5 Pro IP or port exists in topology (0.07825ms)
  ✔ Error propagation across tunnel: Fake Bridge 403 propagates without being masked as empty array (2.831583ms)
✔ Container -> Host Tunnel -> Fake Bridge Multi-Hop Integration (31.573375ms)
✔ index exports all required classes, functions and errors (0.537375ms)
▶ MCP Protocol-Level Tool Assembly & Write Rejection Verification
  ✔ MCP Protocol: reminders_lists tool returns standard MCP text payload (11.039875ms)
  ✔ MCP Protocol: reminders_list tool returns reminders matching standard schema (3.6095ms)
  ✔ MCP Protocol: reminders_create is rejected with PERMISSION_DENIED and ZERO write forwarding (0.2755ms)
  ✔ MCP Protocol: reminders_update is rejected with PERMISSION_DENIED and ZERO write forwarding (0.099708ms)
  ✔ MCP Protocol: reminders_delete is rejected with PERMISSION_DENIED and ZERO write forwarding (0.066541ms)
✔ MCP Protocol-Level Tool Assembly & Write Rejection Verification (25.922666ms)
▶ MacServerReminderService with Fake Bridge
  ✔ listLists filters out non-iCloud sources and mismatched source IDs, marks writable: false (11.87925ms)
  ✔ list queries all lists and sorts deterministically with Swift Cocoa dates (4.782458ms)
  ✔ list filtering by completed: true and false (10.152667ms)
  ✔ list filtering by due_before and due_after (4.835ms)
  ✔ list limit and truncation flag (4.534125ms)
  ✔ list targeting specific list_ids (3.923375ms)
  ✔ list throws NOT_FOUND when requested list_id is missing or unbound (2.066834ms)
  ✔ Item ownership validation: cross-list item mismatch throws UPSTREAM_ERROR (3.42225ms)
  ✔ Write operations (create, update, remove) are strictly rejected with PERMISSION_DENIED (0.194375ms)
  ✔ NEGATIVE ASSERTION: When backend server fails, service throws error instead of returning empty list (1.816084ms)
✔ MacServerReminderService with Fake Bridge (58.020792ms)
▶ Swift JSONEncoder Compatibility & Field Fidelity
  ✔ parseBridgeDate converts Swift Cocoa Reference Date (815961600) to ISO string (8.532083ms)
  ✔ Service parses Swift JSONEncoder payload with omitted nil fields and numeric dates (13.460041ms)
  ✔ Cross-list ownership enforcement rejects items returned with foreign listID (1.15925ms)
✔ Swift JSONEncoder Compatibility & Field Fidelity (23.630708ms)
▶ EventKitReadonlyTransport with Fake Bridge
  ✔ healthCheck succeeds without Bearer token (12.883416ms)
  ✔ fetchListsMetadata succeeds with valid Bearer token (1.71475ms)
  ✔ fetchReminders returns items for allowed list (1.6085ms)
  ✔ 401 AUTH_FAILED when invalid token is presented (2.360792ms)
  ✔ 403 PERMISSION_DENIED when Bridge production switch is false (2.526542ms)
  ✔ 403 PERMISSION_DENIED (LIST_NOT_ALLOWED) when querying unallowed list (2.472167ms)
  ✔ 404 NOT_FOUND when list items route reports list missing (1.462042ms)
  ✔ Timeout covers response body read: stalled body stream triggers UPSTREAM_ERROR (402.868292ms)
  ✔ Max response size limit enforcement: payload exceeding limit aborts and throws UPSTREAM_ERROR (4.279042ms)
  ✔ 500 internal error throws UPSTREAM_ERROR (3.496041ms)
  ✔ Corrupt non-JSON response throws UPSTREAM_ERROR (0.705334ms)
  ✔ rejectWrite throws PERMISSION_DENIED client-side without network call (0.110833ms)
  ✔ parseBridgeDate correctly converts numeric Cocoa dates and ISO strings (0.062541ms)
  ✔ NEGATIVE ASSERTION: Network errors never return empty array or fake success (1.927291ms)
✔ EventKitReadonlyTransport with Fake Bridge (445.28025ms)
ℹ tests 45
ℹ suites 5
ℹ pass 45
ℹ fail 0
ℹ cancelled 0
ℹ skipped 0
ℹ todo 0
ℹ duration_ms 719.696709
```

---

## 二、专项关键断言证明

1. **容器网络与多跳拓扑 (Container -> Tunnel -> Fake Bridge)**:
   - 证明容器发起的请求经宿主 Docker 网桥网关（`172.19.0.1:18765`）转发至 SSH 隧道（`127.0.0.1:18765`）再抵达 Fake Bridge，完整返回 200 OK；
   - 证明服务端监听严格绑定在 `127.0.0.1`，无 `0.0.0.0` 暴露；
   - 证明链路绝对不经过 M5 Pro (`100.69.145.3`)。

2. **显式列表—来源 ID 绑定与条目归属校验**:
   - 证明未在 `allowedLists` 显式配置 `expectedSourceId` 的列表在配置阶段即刻被抛错拒绝；
   - 证明若后端返回的条目 `listID` 与当前请求的列表 ID 不一致，即刻抛出 `UPSTREAM_ERROR`，杜绝跨列表数据串扰。

3. **Swift 原生 JSON 编码与 Cocoa 日期转换保真**:
   - 证明对 Swift 默认编码的 Cocoa Reference Date (`815961600`，即以 2001-01-01 为起点的秒数) 精确转换为 ISO 8601 (`2026-11-10T00:00:00.000Z`)；
   - 证明对 Swift 缺省的 optional 键（`nil` 时直接省略键名）具备完整反序列化容错。

4. **响应体截止时间覆盖与体积超限熔断**:
   - 证明慢速响应体在读取过程中超时时，精确触发 `AbortSignal.abort()` 并抛出可重试的 `UPSTREAM_ERROR`；
   - 证明体积超过 `maxResponseSizeBytes` 的响应流在边读边检阶段即刻中断流传输并抛错。

5. **MCP 协议级工具装配与零写转发**:
   - 证明装配至真实 MCP ToolRegistrar 的 5 个工具均符合输入 Schema；
   - 证明 `reminders_create`、`reminders_update`、`reminders_delete` 在客户端即刻返回 `{ isError: true, error.code: "PERMISSION_DENIED" }`，捕获到后端网络请求次数完全为零，绝无回落旧 VTODO。
