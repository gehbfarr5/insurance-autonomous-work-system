# AG-03: MUSE 前台独立验收任务说明书 (MUSE Acceptance Task)

- **任务定位**：MUSE 客户端独立交互验收指南
- **验收目标**：在 MUSE 前台聊天界面中，通过调用 Seoul MCP 网关验证提醒事项只读访问与写保护
- **参与角色**：人类操作员（User）与 MUSE Agent
- **防冒充准则**：恪守独立验收原则，Antigravity 不得代跑 MUSE 验收，必须由用户在 MUSE 交互界面手动发起。

---

## 一、验收前置条件

1. Seoul 网关与 MacServer 隧道已按照《部署与恢复方案》完成部署与健康核验；
2. MacServer `EVENTKIT_BRIDGE_PRODUCTION_AUTHORIZED` 已置为 `true`；
3. MUSE 客户端已成功连接到 Seoul MCP 统一网关：
   - MCP 端点：`https://seoul-forge-01.tail4db0d9.ts.net/mcp`
   - 目标 Apple 账号：`gehbfarr5@i.softbank.jp`

---

## 二、MUSE 交互验收步骤清单

### 步骤 1：能力矩阵核验 (apple_accounts)
- **用户对 MUSE 发送指令**：
  > “请查看当前连接的 Apple 账号及其功能权限。”
- **预期 MUSE 行为**：
  - 调用工具：`apple_accounts()`
  - 返回账号能力矩阵：
    - `contacts`: read: true, write: true
    - `calendar`: read: true, write: false
    - `reminders`: **read: true, write: false** (只读网关生效)
    - `mail`: read: false, write: false

---

### 步骤 2：会话建立与列表元数据查询 (reminders_lists)
- **用户对 MUSE 发送指令**：
  > “请列出我所有的提醒事项列表。”
- **预期 MUSE 行为**：
  - 调用 `apple_login({ account: "gehbfarr5@i.softbank.jp" })` 获取 `session_id`；
  - 调用工具：`reminders_lists({ session_id })`；
  - 返回列表清单：
    - 包含已绑定的测试列表 `M****试`（脱敏标识：`9D9A****03F3`）；
    - 列表属性中明确标注 `writable: false`；
    - 确认无任何外部或本地未授权列表泄露。

---

### 步骤 3：条目查询与结构保真核验 (reminders_list)
- **用户对 MUSE 发送指令**：
  > “请查询‘M****试’列表里的所有提醒事项。”
- **预期 MUSE 行为**：
  - 调用工具：`reminders_list({ session_id, list_ids: ["9D9A****03F3"] })`；
  - 网关经 Tailscale 隧道安全查询 MacServer EventKit；
  - 返回结果：
    - 响应结构符合 MCP 标准协议；
    - 当前测试列表为空，返回 `reminders: []`；
    - MUSE 如实向用户报告列表为空，未发生任何超时、崩坏或异常。

---

### 步骤 4：严格写拦截与零回落验证 (Negative Test: reminders_create)
- **用户对 MUSE 发送指令**：
  > “请帮我在‘M****试’列表中新建一条提醒：明天上午跟进客户。”
- **预期 MUSE 行为**：
  - 调用工具：`reminders_create(...)`；
  - **核心断言**：Seoul MCP 网关在客户端即刻拦截，返回明确错误：
    ```json
    {
      "error": {
        "code": "PERMISSION_DENIED",
        "message": "MacServer EventKit Gateway 运行于严格只读模式，禁止写入并禁止回落旧 VTODO (create)"
      }
    }
    ```
  - **红线验证**：
    - 网关绝不向 MacServer 发起任何写请求；
    - 网关绝不尝试回退至已废弃的旧 VTODO 写入机制；
    - MUSE 明确提示用户：“当前提醒事项服务为只读网关模式，不支持新建提醒事项”。

---

### 步骤 5：会话清理 (work_done)
- **用户对 MUSE 发送指令**：
  > “任务结束，谢谢。”
- **预期 MUSE 行为**：
  - 调用工具：`work_done({ session_id })` 释放服务端连接。

---

## 三、验收结论标准

| 验收项 | 期望结果 | 判定 |
|---|---|---|
| 能力发现 | `reminders.read == true`, `reminders.write == false` | PASS / FAIL |
| 列表探测 | 成功返回绑定的测试列表，`writable == false` | PASS / FAIL |
| 条目读取 | 成功响应结构化结果，无崩溃 | PASS / FAIL |
| 写操作防护 | 显式返回 `PERMISSION_DENIED`，零写调用，零 VTODO 回落 | PASS / FAIL |
| 故障真实性 | 异常时报错明确，禁止将异常伪装为空列表成功 | PASS / FAIL |
