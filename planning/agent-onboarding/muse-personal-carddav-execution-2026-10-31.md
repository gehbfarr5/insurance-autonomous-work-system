# MUSE 云端 Agent → iCloud CardDAV MCP 实际接入交接（2026-10-31）

> 此交接直接发给**已有阳光森林每日任务的 MUSE 个人 Agent 同一会话**。**不是 Muse Code CLI**。现有 MUSE 的唯一 09:00 自动化、相关 state、锁、cron、Pixel 操作流程完全保留，不新建定时任务、不迁移运行器。该个人 Agent 运行在 Meta Muse Secure VM，可能有权限控制和专用连接器能力；**尚未实测该账户是否支持任意远程 MCP 的 OAuth**。

## 目标

将个人 MUSE Agent 作为新的**云端 MCP 客户端**连接现有首尔 iCloud 联系人服务，获得联系人 search/read/create/update/delete 的统一工具能力。不要改首尔端服务、现有权限、部署或 Apple ID。

- 真实 MCP URL（Streamable HTTP）：`https://seoul-forge-01.tail4db0d9.ts.net/mcp`
- 服务器 HTTPS：`https://seoul-forge-01.tail4db0d9.ts.net`
- OAuth discovery：`https://seoul-forge-01.tail4db0d9.ts.net/.well-known/oauth-authorization-server`
- OAuth 授权、Token、动态客户端注册分别为 `/authorize`、`/token`、`/register`，PKCE S256，scope `mcp`。
- Apple 联系人账号：`gehbfarr5@i.softbank.jp`，服务器已经配置 Contacts READ/WRITE。
- GitHub 任务：[Issue #6](https://github.com/gehbfarr5/insurance-autonomous-work-system/issues/6)。云端 CardDAV 真实 CRUD 已由 Antigravity 在 Issue #4 通过，不重新跑相同测试。

## 请 MUSE 自主执行

1. **先识别该 Muse 个人 VM 的可用工具**：检查是否允许建立自定义连接器、使用浏览器 OAuth、配置 HTTP Streamable MCP Client、或在现有持久环境安装受控 MCP SDK。不要把 Muse Code 配置路径视作个人 MUSE 的运行时。
2. **无凭据网络预检**：从**MUSE VM 本身**访问 `/health`（200 + `{"status":"ok"}`）；读取 OAuth metadata 并比对 issuer 和 endpoints；不带 Bearer Token 请求 `/mcp` 的 initialize 应为 401。若运行 Node 18+ 可复用本仓库 `tests/integrations/carddav/test-carddav-public-smoke.mjs`，使用 `MCP_SERVER_URL=https://seoul-forge-01.tail4db0d9.ts.net`。这仅为网络检查，不等于 MUSE 授权成功。
3. **优先原生连接器**：如果个人 MUSE 支持 Custom MCP / Connectors，登记 URL、Transport=Streamable HTTP、Auth=OAuth/DCR/PKCE。允许它按自身平台要求完成浏览器授权。若需要 Access Key，请在 `/admin` 为 `muse-personal` 新建专用 MCP Access Key，保存在可信凭据存储中；**不是 Apple app-specific password，也不是后台管理员密码**。这一步若无法由 MUSE 合法完成，请明确列出操作入口，不猜测或绕过平台凭据权限。
4. **若原生 Custom MCP 不可用**：优先检查 Muse 是否能安全使用自己的持久 VM 工具或 SDK。只有在确认可执行并保留 OAuth/Refresh Token 时，才部署最小 Streamable HTTP MCP Client 包装器，**不要自建第二套 Apple CardDAV 服务**。无法证明可用就报告 `BLOCKED_BY_PLATFORM`，不要假装已接。
5. **独立验收**：在 MUSE 当前真实对话中执行 `tools/list`，确认 `apple_accounts`、`apple_login`、`contacts_search`、`contacts_read`、`contacts_create`、`contacts_update`、`contacts_delete`、`work_done` 可用。调用 `apple_accounts` 和 `apple_login`；查询只包含唯一不存在标签（例如 `MUSE_MCP_SMOKE_NO_CONTACT_20261031`），预期 0 匹配；调用 `work_done`。此轮不添加、修改或删除真实联系人。
6. **持久化验收**：在 MUSE 会话间重新打开时，验证连接可复用（若需重新授权，记录实际平台行为）。不要通过新建 MUSE 每日计划或重启 Pixel 验证。
7. **回报**：写出真实状态：`network`、`oauth`、`tools/list`、`apple_login`、`contacts_search`、`work_done`、`persisted_after_reopen` 分别标记 PASS / FAIL / BLOCKED / NOT TESTED。提供实际错误码、当前采用的接入路径、是否创建新的 MUSE Access Key、是否触发任何用户审批（不披露密钥本身）。如已连接 GitHub，把结果更新 Issue #6；否则返回可复制的报告。

## 禁止范围

- 不重复执行此前已经通过的完整 Apple 联系人 CRUD。
- 不改动原有阳光森林任务、日程、状态、Pixel 执行器、保单或真实客户资料。
- 不把授权成功误认为完整工具调用成功。
- 不为图方便绕过服务器 OAuth 或将 Apple 专用密码作为 MCP Bearer。
- 不编造 Muse 产品自身的原生 MCP 能力：有界检查、真实证据、如实阻断。

## 需要回报的最小证据格式

```text
Agent: MUSE personal agent (not Muse Code)
Runtime / VM: actual environment observed
MCP server: https://seoul-forge-01.tail4db0d9.ts.net/mcp
MCP mechanism: native connector / persistent SDK bridge / blocked
Network: PASS|FAIL|BLOCKED
OAuth/DCR/PKCE: PASS|FAIL|BLOCKED|NOT TESTED
Tools discovered: names/count or evidence of block
Apple login: PASS|FAIL|BLOCKED|NOT TESTED
Synthetic not-found search: PASS|FAIL|BLOCKED|NOT TESTED
work_done: PASS|FAIL|BLOCKED|NOT TESTED
Cross-session persistence: PASS|FAIL|NOT TESTED
Existing 09:00 daily automation: UNCHANGED (verified / not independently verified)
User intervention necessary:
Relevant logs (no raw credentials):
```

官方参考：<https://ai.meta.com/muse/> 与 <https://research.meta.ai/blog/security-and-safety-for-ai-agents-our-approach-with-muse>。官方证明 Muse Secure VM 持久，**但不证明特定账户能自助安装任何第三方 MCP**。
