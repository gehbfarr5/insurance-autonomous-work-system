# AG-03: Seoul → MacServer 只读 Gateway 测试证据 (Test Evidence)

- **执行时间**：2026-11-07 22:57:24 CST
- **测试环境**：
  - OS: Darwin 27.0.0 arm64 (macOS)
  - Node.js: v24.18.0
  - Runner: `node --experimental-strip-types --test tests/*.test.ts`
  - 依赖状态：零外部三方依赖（使用 Node.js 原生 HTTP、Fetch 与 Test Runner）
- **覆盖模块**：
  1. `src/config.ts` (配置解析与合法性校验)
  2. `src/transport.ts` (EventKit 只读 HTTP 客户端)
  3. `src/service.ts` (Seoul MCP ReminderService 适配层)
  4. `src/fake-bridge.ts` (MacServer EventKit Fake Bridge 服务端)

---

## 一、测试执行汇总

```
> seoul-macserver-readonly-gateway@1.0.0 test
> node --experimental-strip-types --test tests/*.test.ts

✔ validateGatewayConfig - parses valid config correctly (0.575084ms)
✔ validateGatewayConfig - rejects non-object or null config (0.164375ms)
✔ validateGatewayConfig - rejects invalid endpoints and wildcards (0.0785ms)
✔ validateGatewayConfig - rejects short or empty tokens (0.045083ms)
✔ validateGatewayConfig - rejects invalid timeout range (0.06125ms)
✔ loadGatewayConfigFromEnv - parses env variables (0.0825ms)
✔ index exports all required classes, functions and errors (0.393333ms)
▶ MacServerReminderService with Fake Bridge
  ✔ listLists filters out non-iCloud sources and marks writable: false (8.43025ms)
  ✔ list queries all lists and sorts deterministically (due asc, null due last, title tiebreaker) (2.756375ms)
  ✔ list filtering by completed: true and false (9.264ms)
  ✔ list filtering by due_before and due_after (4.166125ms)
  ✔ list limit and truncation flag (3.621708ms)
  ✔ list targeting specific list_ids (2.230375ms)
  ✔ list throws NOT_FOUND when requested list_id is missing (1.143959ms)
  ✔ Write operations (create, update, remove) are strictly rejected with PERMISSION_DENIED (0.157667ms)
  ✔ NEGATIVE ASSERTION: When backend server fails, service throws error instead of returning empty list (1.718ms)
✔ MacServerReminderService with Fake Bridge (37.946542ms)
▶ EventKitReadonlyTransport with Fake Bridge
  ✔ healthCheck succeeds without Bearer token (8.997375ms)
  ✔ fetchListsMetadata succeeds with valid Bearer token (1.328584ms)
  ✔ fetchReminders returns items for allowed list (2.019375ms)
  ✔ 401 AUTH_FAILED when invalid token is presented (1.988125ms)
  ✔ 403 PERMISSION_DENIED when Bridge production switch is false (2.130708ms)
  ✔ 403 PERMISSION_DENIED (LIST_NOT_ALLOWED) when querying unallowed list (1.989334ms)
  ✔ 404 NOT_FOUND when list items route reports list missing (0.6735ms)
  ✔ 504 / timeout handling throws UPSTREAM_ERROR with retryable flag (503.958125ms)
  ✔ 500 internal error throws UPSTREAM_ERROR (4.726667ms)
  ✔ Corrupt non-JSON response throws UPSTREAM_ERROR (1.904041ms)
  ✔ rejectWrite throws PERMISSION_DENIED client-side without network call (0.32475ms)
  ✔ NEGATIVE ASSERTION: Network errors never return empty array or fake success (1.998083ms)
✔ EventKitReadonlyTransport with Fake Bridge (537.090709ms)
ℹ tests 28
ℹ suites 2
ℹ pass 28
ℹ fail 0
ℹ cancelled 0
ℹ skipped 0
ℹ todo 0
ℹ duration_ms 898.551625
```

---

## 二、关键安全红线断言证明

1. **防伪装空列表断言 (Anti-Masking Empty List Assertion)**:
   - 实测在 Fake Bridge 注入 500 内部故障时，`transport` 与 `service` 均明确抛出 `UPSTREAM_ERROR`，严禁伪装为 `reminders: []` 返回成功。
2. **写操作彻底切断断言 (Zero Write & Zero Fallback Assertion)**:
   - 实测调用 `service.create`、`service.update`、`service.remove` 时，均在发起任何网络请求前直接抛出 `PERMISSION_DENIED`；
   - 证明 zero HTTP write calls 发送至 MacServer，zero fallback 至旧 VTODO。
3. **未授权拒绝断言 (Authorization Gating Assertion)**:
   - Bearer Token 错误时返回 401 `AUTH_FAILED`；
   - MacServer 激活开关为 false 时返回 403 `PERMISSION_DENIED`；
   - 尝试读取名单外列表时返回 403 `LIST_NOT_ALLOWED`。
4. **安全超时熔断断言 (Timeout Enforcement Assertion)**:
   - 模拟延迟 800ms，在 500ms 门限下精确触发 `AbortSignal.abort()`，返回 `UPSTREAM_ERROR` (retryable: true)。
5. **通配暴露防范断言 (Network Boundary Defense Assertion)**:
   - `0.0.0.0`、`::`、`*` 等地址在配置阶段即刻被抛错拦截。
