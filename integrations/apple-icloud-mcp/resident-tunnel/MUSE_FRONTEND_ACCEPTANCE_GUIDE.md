# MUSE 前台独立验收执行指引 (MUSE Frontend Independent Acceptance Guide)
**项目编号**: AG-05  
**基线版本**: PR #22 (`feat/seoul-macserver-readonly-gateway`, commit `a6f1a9c`)  
**候选分支**: `feat/ag05-resident-readonly-candidate`  
**执行原则**: 必须由用户在 MUSE 客户端前台界面交互发起，由 MUSE 原生发现并调用工具，严禁使用非 MUSE 外部脚本代打。

---

## 1. 验收前置条件 (Pre-flight Checklist)
在用户启动受限窗口前，确认以下状态：
1. **Seoul 统一 MCP 网关**: 正常运行于 Docker 容器中，挂载只读配置。
2. **MacServer EventKit 桥接**: 处于活跃状态，绑定指定 iCloud 账户及只读列表 `9D9A5AAD-E3F0-4459-8756-BBCDBCB703F3`。
3. **反向 SSH 隧道**: 通过 MacServer `launchd` 常驻守护进程 (`com.muse.macserver-tunnel`) 连接至 Seoul `172.19.0.1:18765`。
4. **安全模式状态**:
   - `writes_enabled = false` (全链路写隔离，禁止任何写入调用)。
   - 目标列表已预置只读测试条目（见建议测试数据）。

---

## 2. MUSE 前台可直接复制的对话提示词 (Copy-Pasteable User Prompts)

请在 MUSE 客户端的前台对话框中分步输入以下提示词：

### 阶段一：MCP 工具与服务状态发现 (Tool Discovery)
```text
请列出当前可用的 iCloud / Reminders 相关工具，核对工具名称与输入参数要求，并确认当前连接状态是否正常。
```
- **预期行为**: MUSE 自动调用 `tools/list`，识别出 `reminders_lists` 与 `reminders_list` 等工具（确认无写入权限或明确只读标记）。

### 阶段二：查询可访问的提醒事项列表 (List Discovery)
```text
请查询当前账号下可见的提醒事项列表，告诉我列表名称、ID 以及是否允许写入。
```
- **预期行为**: MUSE 自动调用 `reminders_lists`，返回 1 条列表：
  - 名称: `MUSE 测试`
  - ID: `9D9A5AAD-E3F0-4459-8756-BBCDBCB703F3`
  - 属性: `writable: false`

### 阶段三：只读拉取测试列表条目 (Non-Empty Items Verification)
```text
请查询列表 ID 为 "9D9A5AAD-E3F0-4459-8756-BBCDBCB703F3"（MUSE 测试）中的所有提醒事项条目，列出它们的标题、优先级、截止时间（注意是否全天事项及所在时区）、完成状态及备注说明。
```
- **预期行为**: MUSE 自动调用 `reminders_list` 并传入参数 `{"list_ids": ["9D9A5AAD-E3F0-4459-8756-BBCDBCB703F3"]}`，成功返回测试条目的完整非空字段。

---

## 3. 原始工具调用记录与脱敏留存格式 (Audit Log Standard)

验收完成后，请用户从 MUSE 前台界面导出或截图/复制原始调用日志，标准留存格式如下：

```json
{
  "acceptance_session_id": "MUSE-FRONTEND-20261109-XXXX",
  "client_origin": "MUSE-Desktop-Native-Chat",
  "operator": "user_interactive",
  "invocations": [
    {
      "step": 1,
      "tool": "tools/list",
      "status": "OK",
      "discovered_tools_count": 33
    },
    {
      "step": 2,
      "tool": "reminders_lists",
      "status": "OK",
      "returned_lists": [
        {
          "id": "9D9A5AAD-E3F0-4459-8756-BBCDBCB703F3",
          "title": "MUSE 测试",
          "writable": false
        }
      ]
    },
    {
      "step": 3,
      "tool": "reminders_list",
      "params": {
        "list_ids": ["9D9A5AAD-E3F0-4459-8756-BBCDBCB703F3"]
      },
      "status": "OK",
      "returned_items_count": 2,
      "items_sample_fields_verified": [
        "title",
        "notes",
        "priority",
        "is_all_day",
        "due_date",
        "time_zone",
        "completed"
      ]
    }
  ],
  "write_attempt_verification": {
    "invoked_writes": 0,
    "writes_enabled_state": false
  }
}
```

---

## 4. 判定标准与关闭流程 (Acceptance Criteria & Immediate Tear-down)

### 成功判定 (PASS Criteria)
1. **会话归属真实**: 调用由 MUSE 前台客户端原生发起并记录。
2. **只读约束坚固**: 全程无写操作调用，返回字段 `writable: false`。
3. **数据忠实无损**: `title`, `notes`, `priority`, `isAllDay`, `dueDate`, `timeZone` 字段忠实保留，未退化为默认值。
4. **即开即关**: 验收对话结束，立即关闭反向隧道，MacServer 恢复安全隔离模式。
