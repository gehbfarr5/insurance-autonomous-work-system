# ChatGPT Chat 原生调用能力 POC — Sites-hosted MCP（2026-11-01）

> 状态：**SITES_CHAT_MCP_PASS（2026-11-01）**。原下方交接规范为历史计划；实际执行回执见下一节。
> 目标：在当前账号条件下，判定 **ChatGPT 普通 Chat 会话**能否真实调用由 ChatGPT Sites 托管的 MCP 工具。**本 POC 不接入真实 iCloud，也不修改生产 MCP**。

## 2026-11-01 实际验收回执：SITES_CHAT_MCP_PASS

**结论：已通过，普通 Chat 可以调用 Sites 托管的 MCP 工具。** 本状态覆盖文档原先的 `READY FOR WORK EXECUTION / NOT STARTED`（该文字保留为历史计划）。

- 用户报告：在已安装的 **iCloud MCP Capability Test** 插件中，实际调用 `demo_contacts_groups_list`；`isError: false`，正确返回两个完全虚构分组。
- **ChatGPT 当前普通 Chat 会话独立复验**：工具目录暴露 `mcp__iCloud_MCP_Capability_Test__demo_contacts_groups_list`；实际调用 `{}` 返回 `structuredContent.groups` 为 `[{"name":"测试客户","member_count":3},{"name":"测试家庭","member_count":2}]`，无调用错误；这是 MCP 工具调用，不是插件元数据读取或静态网页展示。
- 该 POC 只注册了虚构只读工具；未触达真实 iCloud、首尔生产 MCP、联系人、日历、提醒事项或 OAuth 密钥。**不代表首尔原有 33 项工具已从 ChatGPT 接入。**
- 与此前失败分开记录：v0.1.0 / v1.0.0 **导入型私人 MCP 插件**在 Chat 中不可调用；这次 **Sites 托管插件**则独立成功，不应将旧路线直接标为 PASS。
- **下一阶段待定义，不在本次 POC 执行**：研究 Sites-hosted 工具向首尔现有 MCP 的**最小只读、经授权**连接；先确认运行时服务端私密凭据处理、OAuth / 网络链路及账户权限；通过真实只读分组查询后才考虑扩展 33 项及写入操作。
- Work Cloud / Work Local 是否能调用该 Sites 插件尚未由本次独立验证证明；Work Local 维持 `WORK_LOCAL_UNAVAILABLE` 阶段性状态。
- 测试 Site 与插件暂建议保留作为可复现基线；两份旧插件是否清理仍须依赖审计。

## 背景与已排除路线

- 已有首尔自建 iCloud MCP 生产服务，Streamable HTTP + OAuth DCR，服务端注册 33 项工具，其中 8 项联系人分组工具；其他多个 Agent 已连接。
- 两份导入型私人插件 `insurance-icloud-mcp`（v0.1.0/v1.0.0）均指向既有首尔 MCP；Web 插件目录显示 Desktop only，Web Chat、桌面 Chat 都没有暴露目标工具。**不要重试导入包创建/安装路径**。
- Work Local 报告为 `WORK_LOCAL_UNAVAILABLE`：本地执行环境未被有效建立；不是 Work Local MCP 的端到端失败证据。
- 详细历史见 [Issue #6](https://github.com/gehbfarr5/insurance-autonomous-work-system/issues/6) 和 [多 Agent 台账](./icloud-mcp-agent-connection-status-2026-11-01.md)。
- 官方依据：[Creating Sites](https://help.openai.com/en/articles/20001339-creating-and-using-chatgpt-sites)；[Hosting MCP tools on Sites](https://help.openai.com/en/articles/20001547-hosting-a-plugin-with-chatgpt-sites)。

## 本轮严格范围

**只允许创建新的私人测试 Site，命名** `iCloud MCP Capability Test`（若名称冲突则使用唯一的测试后缀），并在 Site 侧托管一个**真正注册为 MCP 工具**的只读工具：

- 工具名：`demo_contacts_groups_list`。
- 固定返回虚构数据（可采用结构化 JSON）：`[{"name":"测试客户","member_count":3},{"name":"测试家庭","member_count":2}]`。
- 不允许只在网页界面显示静态信息并冒充工具；必须可通过插件发生真实 tool call。
- 不接入 Apple/iCloud、首尔 MCP、CardDAV/CalDAV、OAuth Key、Tailscale、真实客户信息。
- 不要求写入工具，不添加用户资料检索，不使用其他新服务器或第三方代管平台。
- Site 保持私人访问。不得为了测试扩大公开分享；按实际产品权限设置部署和关联插件。

## 执行顺序与证据门槛

1. **运行面与权限确认**：从 ChatGPT Work（Cloud）明确记录真实执行环境和当前账号的 Sites/托管 MCP/插件创建权限。若缺失必需能力，**停止并提供准确限制或 UI 证据**，不得改用 Codex、Replit 或重新创建导入型 `mcp.json` 插件。
2. **创建 Site**：构建最小可用 Site、在 Site 托管 MCP 工具；只包含上述虚构只读能力。
3. **Tool 可用性**：记录 Site 内工具注册实际情况（工具名、输入/输出示例）。若只能制作一个网站而不能注册 MCP 工具，应报告 `SITES_MCP_TOOL_REGISTRATION_BLOCKED`。
4. **私人发布并关联插件**：使用官方 Sites 的发布/插件安装流程；记录生成插件的准确名称、ID（若 UI 提供）、安装和连接状态。只看到插件卡片不等于工具调用通过。
5. **Chat 独立验收**：必须由 ChatGPT 原生 Chat 会话，通过关联的 **Sites-hosted plugin** 调用 `demo_contacts_groups_list`，实际返回两项虚构分组及成员数。如果当前 Work 会话无法替你切换进入 Chat，应将此步标记 `CHAT_USER_ACTION_REQUIRED` 并留下一个最短的验证说明；**不得借用 Work/Codex 或其他 MCP 结果冒充 Chat**。
6. **可选 Work 对照**：在 Chat PASS 后，若现有权限允许，再测试 Work Cloud 能否调用同一插件；不要阻塞 Chat POC 的结论。
7. **汇报明确证据**：Site URL（只在权限允许时）、插件 ID/URL、工具注册数和名字、实际工具调用及其虚构返回、运行模式、安装/OAuth/平台错误、是否保留测试资产。

## 验收结论

- `SITES_CHAT_MCP_PASS`：Chat 实际调用并得到预期虚构数据。
- `SITES_PLUGIN_INSTALLED_TOOLS_MISSING`：插件存在/可装，但 Chat 无工具。
- `SITES_ACCOUNT_OR_PERMISSION_BLOCKED`：官方权限限制已证实。
- `SITES_MCP_TOOL_REGISTRATION_BLOCKED`：不能托管/注册工具。
- `CHAT_USER_ACTION_REQUIRED`：Site/插件已做好，仍需用户在另一个 Chat 界面做一次真实调用。
- `UNVERIFIED`：仅部分证据，不能归因为平台限制或宣称成功。

## 安全与停止条件

- 一次最小 POC 为限；权限不符即停止；不反复新建插件、不盲目删旧插件、不撤销有效 Token。
- 不改动现有首尔生产 MCP、两份旧插件、其他 Agent 配置或 GitHub 历史。
- 只有 POC 真实 PASS 后，才另起任务研究既有首尔 MCP 的安全 OAuth 桥接；**不要在本轮投入 33 项工具集成**。

## Work 会话最短启动语

> 请读取本仓库文件 `planning/chatgpt-chat-sites-mcp-poc-2026-11-01.md`，按其约束在 Work 中创建并验证 ChatGPT Sites 托管的单个虚构只读 MCP 工具，重点验证普通 Chat 可调用。先执行，遇到账号/权限阻断如实停止；不要接入生产 iCloud。
