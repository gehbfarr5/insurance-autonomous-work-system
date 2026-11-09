# MUSE 前台独立验收执行指引 (MUSE Frontend Independent Acceptance Guide)
**项目编号**: AG-05  
**基线版本**: PR #22 (`feat/seoul-macserver-readonly-gateway`, commit `a6f1a9c`)  
**候选分支**: `feat/ag05-resident-readonly-candidate`  
**执行原则**: 必须由用户在 MUSE 客户端前台界面交互发起，由 MUSE 原生发现并调用工具，严禁使用非 MUSE 外部脚本代打。  
**公开脱敏声明**: 本文档中出现的 `00000000-0000-0000-0000-000000000001` 均为公开文档使用的合成 fixture 占位符。真实绑定的测试列表 ID 仅存放于 MacServer 本地受限文件（`bridge.env`，权限 `0600`），绝不上传至 GitHub。

---

## 1. 验收前置条件 (Pre-flight Checklist)
在用户启动受限窗口前，确认以下状态：
1. **Seoul 统一 MCP 网关**:
   - 候选镜像: `sha256:faa6e380ee4b9f9d96dd424ced56bf27a0778722a02323efedd542b29f362929` (`candidate-ag05-delivery-20261108`, Registry RepoDigest: `null`)
   - 业务切换停机窗口: 5-10 秒（MCP 容器重启期间暂时中断，不影响原生 CardDAV / Mail 服务）
   - 接触面影响: Contacts / Calendar / Reminders 在容器切换重启瞬间经历 5-10 秒不可达窗口
2. **MacServer EventKit 桥接**:
   - Release Binary SHA256: `6b4a0b826b904c9d844c890e3f39062775b0fecec5df439eb78217395bf657b6`
   - 架构格式: **Mach-O Universal Binary (x86_64 + arm64)**，原生支持 Intel x86_64 MacServer
   - 处于活跃状态，仅绑定本地受限配置指定的 iCloud 测试列表。
3. **反向 SSH 隧道**:
   - 通过 MacServer `launchd` 常驻守护进程 (`com.muse.macserver-tunnel`) 连接至 Seoul `127.0.0.1:18765`。
   - 启用 MacServer 1800 秒本地硬超时，网络中断时自主退出。
4. **安全模式与 30 分钟看门狗状态**:
   - `writes_enabled = false` (全链路写隔离，禁止任何写入调用)。
   - 独立事前看门狗（在首次生产变更前启动），30 分钟硬约束倒计时，超时自动调用 `orchestrated-recovery.sh` 回滚至基线镜像 `sha256:f3e697fe...`，严禁任何自动或人工续期。
   - 目标列表由用户按需置入 2 条最小合成测试条目（见建议测试数据，验收前不预先创建真实条目）。

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
  - ID: `<返回的具体测试列表 ID>` (如 `00000000-0000-0000-0000-000000000001`)
  - 属性: `writable: false`

### 阶段三：只读拉取测试列表条目 (Non-Empty Items Verification)
```text
请查询刚才返回的测试列表中（名称为 MUSE 测试）的所有提醒事项条目，列出它们的标题、优先级、截止时间（注意是否全天事项及所在时区）、完成状态及备注说明。
```
- **预期行为**: MUSE 自动调用 `reminders_list` 并传入参数 `{"list_ids": ["<步骤二返回的测试列表 ID>"]}`，成功返回测试条目的完整非空字段。

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
          "id": "00000000-0000-0000-0000-000000000001",
          "title": "MUSE 测试",
          "writable": false
        }
      ]
    },
    {
      "step": 3,
      "tool": "reminders_list",
      "params": {
        "list_ids": ["00000000-0000-0000-0000-000000000001"]
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
1. **会话归属真实**: 调用由 MUSE 前台客户端原生发起并记录（包含原始会话与工具交互记录）。
2. **只读约束坚固**: 全程无写操作调用，返回字段 `writable: false`。
3. **数据忠实无损**: `title`, `notes`, `priority`, `isAllDay`, `dueDate`, `timeZone` 字段忠实保留，未退化为默认值。
4. **即开即关**: 验收对话结束，立即关闭反向隧道并卸载 LaunchAgent，MacServer 恢复安全隔离模式。
