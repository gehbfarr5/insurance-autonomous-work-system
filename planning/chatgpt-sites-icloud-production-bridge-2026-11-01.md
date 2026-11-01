# ChatGPT Sites → 现有 iCloud MCP 正式接入与密钥治理（2026-11-01）

> 当前状态：**PRODUCTION_BRIDGE_PENDING**。这是已通过 Sites MCP Chat POC 之后的下一阶段执行单；尚未声明生产真实 iCloud 已连接。此文件无密码、Token、客户数据。

## 执行目标

继续修改**已经存在且已在 Chat 普通会话通过**的私人 Site / 插件：`iCloud MCP Capability Test`。**不要创建第三份旧式 `mcp.json` 导入型插件，也不要因为权限问题重建整个 Site**。

成功标准：ChatGPT 普通 Chat 经该 Site 的 MCP 工具调用，实际从首尔现有生产 iCloud MCP 读取**真实**联系人分组名称和成员数；然后按受控步骤扩展联系人、日历、提醒事项功能，并对高风险写操作单独审批。用户希望最终覆盖现有 33 项能力，但不得跳过安全的只读数据链路与授权验收。

背景：
- Chat Sites POC 已真实 PASS：`demo_contacts_groups_list` 固定返回两个虚构分组。
- 现有首尔生产 MCP：`https://seoul-forge-01.tail4db0d9.ts.net/mcp`，Streamable HTTP、OAuth 2.1（DCR、Authorization Code + PKCE、refresh token）、33 项工具；其他 Agent 已可用。
- 原导入型私人插件 v0.1.0/v1.0.0 在网页及桌面 Chat 不暴露工具；Sites 插件是已证明有效的另一条路径。
- 真实 Site 源码/环境与发布需要在 **ChatGPT Work / Sites 原站点编辑界面** 中执行。仅调用 Plugin Creator 修改 `.app.json`、插件元数据或仅在 Chat 工具里发送 Prompt **不能更改 Site 后端 MCP 工具逻辑**。
- 官方 Sites 文档指出可接入外部 API，但须确认 Site 的网络、认证、环境 Secret 和插件授权分别成功。

## 密钥/身份设计（最终建议）

**现在只建立一个独立的 `ChatGPT-Sites-iCloud` 连接身份**。不要把此前 Codex/MUSE/Antigravity/WorkBuddy/Vela 的 Access Key、OAuth Token 重用到 Site；不要因为 Chat 与 Work 是两个 UI 模式就预先建立两份密钥。

```
ChatGPT Chat --               > 同一个 Sites-hosted 私人插件 → Site 安全服务端 → 专用已授权连接 → 首尔 MCP → iCloud
ChatGPT Work --/   (Work 需独立完成插件可调用性验收)
```

如果未来 Work 采用**绕过该 Site 的独立直连客户端**，届时另建 `ChatGPT-Work-Direct` OAuth 客户端/授权身份，单独撤销；与本轮 Site 凭据无关。

**安全缺口必须先处理**：现有服务端 `scope=mcp` 并非强制“只读” Scope，OAuth access token 不自动限制 33 个工具中的写操作。不能把该 Token 的范围误称为只读。必须在服务端可信边界实施实际的可调用工具白名单；Site 端展示只读工具但后端握有全权限 Token，仍有权限扩大风险。优先采用服务端拥有独立授权验证、方法白名单、审计、限流、可独立撤销的**限制型 Site 桥接层**。不添加接受任意 MCP tool name/参数的万能转发端点。

## 工作步骤（一个 Work 任务内执行到能推进的最远阶段）

### A. 现有 Site 更新能力核验
1. 在 **ChatGPT Work → Sites** 中打开已创建的 `iCloud MCP Capability Test`，核对 Site 所有者/编辑权、实际服务端源码、MCP 工具定义、Site private 访问、发布路径。
2. 保留 `demo_contacts_groups_list` 作为无数据回归用例。
3. 检查 **Site 服务端** 能否向首尔 HTTPS MCP 发网络请求，能否安全存储服务器侧 Secret、OAuth 授权是否具备可用回调/refresh token 机制。只做无凭据的 health / metadata 或明确授权的只读探测；不要把 Token 输出给聊天。
4. 具体回答 Site 能否直接处理首尔 OAuth DCR + Authorization Code + PKCE。如果不行，不要循环申请 Client / Access Key，转到 B 的最小可信桥接层。

### B. 最小安全生产桥接
1. 沿用首尔现有账号/权限架构，不重新保存 Apple ID 密码到 Site 或公共 GitHub。
2. 创建**一个**名称用途明确、可撤销的 Sites 专用连接身份（若采用 OAuth，DCR 客户端和用户授权按既有合法流程申请；不借用其他 Agent 的凭据）。在真实 Site 服务端有可靠 Secret 存储前不得创建后把明文 Token 粘贴到对话或仓库。
3. 一开始只允许读取联系人分组及其人数。若服务器不能对 OAuth 凭据强制方法级限制，须通过服务器侧**限制型桥接 API**执行此读操作、认证、审计及权限裁剪。不要把 bearer token 放在浏览器 JavaScript 或公开 Site 页面，也不要以仅 UI 隐藏写按钮作为安全边界。
4. 先运行受控测试，验证网络、认证、Apple session 与目标 `contacts_groups_list` 的真实数据链路。错误时返回脱敏错误类型，避免回显 Token、客户详情、Apple 凭据或完整的通讯录。
5. 任何新的 HTTPS 路由需支持最小权限、限流、请求校验、审计、撤销；不修改现有 MCP 原有 OAuth 行为，不中断其他 Agent。

### C. Site MCP 和 Chat 端端到端验收
1. 在现有 Site 新增真实只读工具，例如 `icloud_contacts_groups_list`，并保持 demo 独立，避免真假混淆；工具通过 B 的安全服务端连接读取真实 iCloud。
2. 由 Site 所有者重新发布 Site，刷新关联插件的工具列表与连接状态。
3. 在**真正的普通 Chat** 会话独立调用 `icloud_contacts_groups_list` 并核验返回来自真实数据源（分组名称/人数即可，不汇出所有联系人信息）；禁止将固定 mock 数据或旧 demo 的返回当成生产通过。
4. 若工具加载成功但首尔认证失败，分开记录 `SITE_TOOL_PASS_BACKEND_AUTH_FAIL`；若服务端只读成功而 Chat 无工具，记录 `SITE_BACKEND_PASS_CHAT_TOOL_MISSING`。
5. 成功标准 `SITES_CHAT_ICLOUD_READ_PASS`：Chat 实际工具调用→Site 服务端认证→首尔真实 iCloud MCP→分组结果→Chat 回显，全链路。

### D. 扩展至完整功能（须保留安全门槛）
1. 在真实只读 PASS 后，分批扩展联系人、分组、日历与提醒事项的只读操作；核对是否确实需要对外展示 33 个工具，以及其中哪些涉及 Apple 会话、批量操作、删除或授权管理。
2. 为写入类工具建立 **可信服务端白名单、审批与幂等检查**；确认同一联系人匹配、ETag、重复创建风险、失败回滚/补偿操作。用户在 Chat 或 Work 中批准具体目标和写入动作后再执行；不得为验收随意修改真实客户通讯录。
3. Work 若通过**同一个 Site 插件**接入，不另配密钥，但独立验收 `WORK_SITES_MCP_PASS`；Work Local 原 `WORK_LOCAL_UNAVAILABLE` 状态不因 Chat 成功而改变。
4. 记录各类工具的真实可见性、只读/写入权限、失败恢复、审计与撤销流程。保留其他 Agent 的独立身份/授权，不轮换它们正在使用的凭据。

## 必须输出的执行回执

- 原有 Site 是否成功修改/重新发布（必须具备实际 Site 编辑证据）
- Site 服务端外连首尔 HTTPS 的实际结果与 OAuth 交互能力
- 采用哪种认证设计，是否**实际**创建 Sites 专用身份（只输出标识/状态，不输出任何密钥值）
- 服务器是否实施了真实的只读调用限制，而不是仅 `scope=mcp`
- 工具名、MCP `tools/list` 或可见性、真实 Chat 调用结果（只能展示用户明确需要的分组名称/数量）
- 扩展后的只读及写入工具逐项验收程度
- 如果无法在当前 Work 中编辑 Site / 保存 Secret / 进行浏览器授权，应准确说明阻断位置，并附下一次可继续的具体操作；**禁止以 mock 代替生产**。
- 最终状态：`SITES_CHAT_ICLOUD_READ_PASS` / `SITE_BRIDGE_BLOCKED` / `SITE_AUTH_BLOCKED` / `SITE_EDIT_UNAVAILABLE` / `PARTIAL`。

## 保密与非目标

- 不把 Apple app-specific password、Access Key、OAuth access/refresh token、client secret、真实联系人记录放进 GitHub、Chat 文本、Site 前端、工具报错或普通应用日志。
- 不在当前阶段删除旧版私人插件或撤销现有 Agent 使用的 OAuth 客户端。
- 不重复创建旧式 `mcp.json` 插件；不额外部署一套独立通讯录。
- 不用 `demo_contacts_groups_list` 成功冒充真实读写 PASS。
