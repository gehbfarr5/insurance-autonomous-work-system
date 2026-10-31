# CardDAV 客户经营最小工作流：本轮代码与客户端接续（2026-10-31）

## 进度基线

- 云端首尔服务器已通过 Antigravity 的 Apple iCloud CardDAV 真实认证、OAuth、虚构联系人 CRUD 及容器重启复验；[Issue #4](https://github.com/gehbfarr5/insurance-autonomous-work-system/issues/4#issuecomment-6525726042)。本轮不重复真实 CRUD。
- 2026-10-31 最新[本地客户端回执](https://github.com/gehbfarr5/insurance-autonomous-work-system/issues/6#issuecomment-6527350475)：Codex CLI `0.162.0` 已注册远程 MCP 并打开 OAuth 浏览器授权页，**尚未完成**；Antigravity.app `2.27.0` 配置写入 `~/.gemini/config/mcp_config.json` 但 UI 未识别新 MCP，**尚未完成**。
- 本轮服务器再次独立确认：CardDAV Healthy、本机自动备份 active、加密 Auth Store 5 个 OAuth 客户端、3 把启用 Access Key（原测试、codex、antigravity）、.env 账号启用。
- 各 Agent 共享同等联系人 CRUD 权限；**不等待分角色 RBAC**。

## 1. 已编写的业务代码（独立于客户端 UI）

路径：`src/customer-ops/carddav-followup.mjs`

该模块可直接供任一已连接 MCP 的 Agent 使用，它接收 `callTool(name,args)` 适配器；`callTool` 应将 MCP `callTool` 结果解析成业务 JSON，遇 `isError` 抛错（本仓库已存在相同形式的适配器，见 `test-carddav-oauth-crud.mjs`）。

- `resolveUniqueContact`：调用 `contacts_search`，要求**精确姓名或精确电话**匹配；0 条、同名多条、部分通讯簿同步失败、结果截断均拒绝自动匹配；随后 `contacts_read` 核验同一 `address_book_id + contact_id`。
- `planFollowupNote`：无副作用生成单行跟进记录 `[#FUP:activity-id] YYYY-MM-DD | 场景 | 状态`；保留联系人原有 Notes，按 activity-id 复用或替换该行，避免重复追加。
- `updateFollowupNote`：只向 `contacts_update` 发送单个 `patch: {note}`，**不改手机号/邮箱/地址**；写后重新 `contacts_read` 比较值。如已是相同记录则不再次写入；读后冲突或无法确认时返回错误，绝不自动重复提交。

以上是可供 Agent 调用的**业务逻辑函数**，不是新的 MCP 服务器，也不会自行定时运行、批量遍历通讯录或自动发送邀请。

### 接入已建立会话后的示例

```js
import { resolveUniqueContact, updateFollowupNote } from './src/customer-ops/carddav-followup.mjs';

// callTool(name, arguments) 须由已连接 MCP 的客户端提供，
// 不能用这里的示例代替 OAuth / apple_login。
const contact = await resolveUniqueContact(callTool, {
  sessionId,
  query: '示例客户甲',
  exactName: '示例客户甲',
});

const receipt = await updateFollowupNote(callTool, {
  sessionId,
  contactId: contact.contact_id,
  addressBookId: contact.address_book_id,
  entry: {
    id: 'platform-event-001',
    date: '2026-10-31',
    kind: '活动邀约',
    status: '待回访',
  },
});
// receipt.status: updated | unchanged
```

**示例姓名与业务事件均为虚构。** 不要直接拿该示例运行真实通讯录写入，除非 Agent 已明确定位唯一的授权目标。实际日常联系人写入按用户确认的统一 CRUD 权限执行，不需先实现权限分工。

### ETag 的现状

上游 MCP 的 `contacts_update` / `contacts_delete` 接受可选 `expected_etag`，但目前返回的 `Contact` 类型**不包含 ETag**（只有 `updated_at`），所以本模块只能在**已有可信 ETag**时透传 `expectedEtag`，不能凭空生成或把 `updated_at` 冒充 ETag。默认写后回读可发现结果偏差，但**不能完全避免并发时原 Notes 被另一 Agent 覆盖**。如果未来多 Agent 高频同步写同一联系人，再升级服务端按记录加锁/版本化或添加取 ETag 的能力。

## 2. 离线验收

```sh
node --test tests/customer-ops/carddav-followup.test.mjs
```

本轮已在首尔现有 Node Docker 镜像的独立 `--network none` 测试容器中真实运行，**11 项单元测试通过**，包括：

- 精确姓名与电话候选、模糊误命中防护；
- 重名、缺失、搜索截断、部分通讯簿失败；
- Notes 保留、同一活动幂等、状态更新；
- 不带其他个人字段的单联系人写入、回读确认；
- 对象引用变化、写后冲突不自动重试。

测试用内存假 MCP，**不能算已接入真实 iCloud，也不能算现有 Codex/Antigravity 客户端通过**。

## 3. 客户端当前卡点与恢复顺序

### A. Codex CLI

已有配置，不要重复 `mcp add` 或再生成 Key。先：

```sh
codex mcp get icloud-carddav
codex mcp login icloud-carddav
```

用本机已保存的 `codex` Access Key 完成当前浏览器授权流程（不需要 Apple 专用密码）。检查 **本地回调端口**、浏览器最终 OAuth 结果，再新开 Codex 会话验证实际工具发现。若浏览器授权已完成但 CLI 仍等待，定位回调服务监听、OS 防火墙、本机浏览器是否在另一台机器、是否被代理影响；记录脱敏错误。

本地 Key 可能位于 `~/.config/insurance-carddav-mcp/agent-keys/`，以 [Issue #6 最新回执](https://github.com/gehbfarr5/insurance-autonomous-work-system/issues/6#issuecomment-6527350475) 实际路径为准，**不要覆盖已有 Key**。

### B. Antigravity IDE

已有 `~/.gemini/config/mcp_config.json`，其余 5 个 MCP 已保留。不要直接覆写整个 JSON。IDE 当前未显示新 `icloud-carddav`，因此先定位**实际读取的配置文件**。

按照 [Antigravity 官方 MCP 文档](https://antigravity.google/docs/mcp)：IDE Agent 侧栏 `… → MCP Servers → Manage MCP Servers → View raw config`。核对打开的文件是否正是已编辑文件、`mcpServers.icloud-carddav.serverUrl` 是否准确；随后刷新 Installed MCP Servers，必要时使用 IDE 的 `Developer: Reload Window`。如 `~/.gemini/antigravity/mcp_config.json` 或当前工作区 `.agents/mcp_config.json` 被使用，**先确认优先级与来源**，不能未核验就重复写很多份。

服务器进入列表后再点 `Authenticate`，按官方流程完成授权并粘贴返回的授权码。Google 官方说明可在设置中认证且 OAuth Token 存在本机用户目录；如本机版本不支持需以实际客户端日志为准，不可将配置文件存在报告为接入成功。

### C. 二者共同验收

各自在**真实客户端**核验 OAuth、`tools/list`、`apple_accounts`、`apple_login`、`contacts_search`（可搜索唯一不存在的测试标签，应得 0 条）、`work_done`。检查 CRUD 工具存在，不重复云端已通过的完整写入测试。

所有阶段标记 PASS / FAIL / BLOCKED / NOT TESTED，回报中可以保留真实 URL、Apple ID 和版本号；Access Key / Apple 专用密码不要放入公开 GitHub。

## 4. 保险工作流拓展顺序

1. **客户检索**：按精确身份唯一定位，供邀约或回访 Agent 处理；身份证号、保单等并不由 CardDAV 自行提供。
2. **跟进备注**：按活动 ID 单行更新，有明确记录来源和状态；已获授权 Agent 可自行调用，不需要角色区分。
3. **生日关怀**：联系人 birthday 可提供生日线索，是否主动发送仍须以具体客户触达工作流为准；不需要全量下载通讯录做首轮联调。
4. **保单到期关怀**：**CardDAV 联系人不包含保单到期日事实来源**；将来需从已授权的保单或客户档案系统关联，不能从通讯录猜测。
5. **活动邀约与私有台账**：联系行为、报名状态、后续动作与保单信息可在现有或新建的私有台账关联；不把敏感保单信息上传到公开 GitHub，也不混入已有 Postgres 业务表。

## 5. 本轮结论

- 新增复用型联系人查询/备注处理代码 + 11 项离线自动测试 PASS。
- 首尔现有云端服务和 3 把 Key 不变；旧 Render 回退保留。
- **Codex / Antigravity OAuth 尚未取得新的客户端 PASS 回执**，下一轮应由本地 Agent 处理授权 UI 与 IDE 配置加载问题，不应重复服务器部署或申请 Apple 密码。
