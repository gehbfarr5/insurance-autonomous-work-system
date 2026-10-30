# 首尔 CardDAV MCP：各 Agent 实际连接手册（2026-10-30）

> **部署已存在，禁止重建。** 本轮仅连接客户端和验证工具发现。统一权限决定：所有经用户授权接入的 Agent 均可使用 iCloud Contacts 搜索/读/创建/更新/删除，不分读写角色。根据 [Issue #4](https://github.com/gehbfarr5/insurance-autonomous-work-system/issues/4) 的 Antigravity 云端完整 CRUD 报告，不再无意义重复真实写入。

## 1. 统一入口及验收状态

- Endpoint（**Streamable HTTP**，不是传统 SSE URL）：`https://seoul-forge-01.tail4db0d9.ts.net/mcp`
- Base HTTPS Origin：`https://seoul-forge-01.tail4db0d9.ts.net`
- OAuth Discovery：`/.well-known/oauth-authorization-server`
- OAuth：动态客户端注册（DCR）+ Authorization Code + S256 PKCE；授权页输入 **MCP Access Key**（不是 Apple 专用密码，也不是管理员密码）。
- 首尔实例已配置 Apple 账号与 Contacts READ/WRITE，邮件/日历/提醒事项仍关闭。当前登录前要先给**连接此 Agent 的用户**分配一个有效的 MCP Access Key。
- 完整 OAuth + Apple 真实 CRUD 由 Antigravity 测试套件此前验证通过。本手册涉及的新客户端尚未声称真正连接成功。

### 无副作用预检

在具备 Node.js 18+ 的任何可访问公网的 Agent 执行环境：

```sh
MCP_SERVER_URL=https://seoul-forge-01.tail4db0d9.ts.net \
  node tests/integrations/carddav/test-carddav-public-smoke.mjs
```

此脚本只做 HTTPS health、OAuth discovery，以及匿名 MCP initialize 预期 HTTP 401；**不创建 OAuth 客户端，不读取联系人，不写入 iCloud**。只有其输出 `PUBLIC_SMOKE_PASS` 才可以声明「该客户端网络侧公共入口可达」，**不代表该 Agent 已授权成功**。

如果客户端使用了 Tailscale，注意 split DNS：相同 ts.net 域名在 Tailnet 内外可能解析不同 IP；遇到证书名称不匹配或 443 命中其他服务时，先核对 DNS 及 HTTPS 入口，不能以禁用证书校验掩盖问题。

## 2. Access Key：统一联系人权限、按 Agent 分别保存

**重要区别**：Access Key 仅用于 OAuth 授权页面。正常 MCP 请求凭 OAuth Access Token 发出。直接把 `amk_...` 当 HTTP Bearer Token 无效。

上游 `/admin` 支持创建、启用、停用和销毁 Access Key。当前运行实例尚未为各 Agent 分别完成发放；已有测试 Key 不应作为所有客户端的永久共享 Key。

安全操作：

1. 通过已有 SSH/Tailscale 或云控制台的可信管理会话读取服务器私有管理员口令文件：`/root/insurance-carddav-admin-password`（root-only 0600）；**不要上传、提交 GitHub 或发回对话**。
2. 在浏览器打开 `https://seoul-forge-01.tail4db0d9.ts.net/admin`，使用管理员口令登录。
3. 为目标连接创建 `agent-codex`、`agent-antigravity` 等不同名称的 Key（不需要设置不同功能权限）。
4. 每把 Key 只展示一次，立刻存到相应 Agent 的 Keychain/Secret Store；如果客户端 OAuth 授权当场完成，可直接粘贴到授权页。不要将 Key 写入仓库中的 `mcp_config.json`、共享提示词或明文日志。
5. 记录 Key 的**名称、创建时间和 Agent 名称**（非明文密钥）以便以后单独停用。
6. 如果密钥创建/存储的工具执行被安全策略拦截，应由用户在可信管理浏览器手动创建，不应改写或隐藏密钥来规避安全检测。

不同 Key 目前都具备账号级 Contacts CRUD 权限；分开 Key 只是让授权、吊销和审计更明确，不改变用户要求的统一能力。

## 3. Codex CLI / IDE

Codex 支持远程 Streamable HTTP MCP，CLI 与 IDE 使用同一 MCP 配置。

```sh
codex mcp add icloud-carddav --url https://seoul-forge-01.tail4db0d9.ts.net/mcp
codex mcp list
codex mcp login icloud-carddav
```

当出现浏览器 OAuth 页面时，输入本 Agent 专用的 MCP Access Key。确认登录成功后重新加载 Codex，调用工具发现并核对 `apple_accounts`、`apple_login`、`contacts_search`、`contacts_read`、`contacts_create`、`contacts_update`、`contacts_delete`、`work_done`。

如果 Codex CLI 与远程 OAuth 的兼容性不一致，先记录本机 `codex --version`、`codex mcp --help`、`codex mcp list` 和脱敏错误；不要随意把 Access Key 放入 Bearer Header。

参考：<https://developers.openai.com/resources/docs-mcp> 以及 <https://github.com/openai/codex/blob/main/codex-rs/cli/src/mcp_cmd.rs>。

## 4. Google Antigravity IDE / CLI

已有 Antigravity 测试脚本成功通过云端 MCP，但不代表 Antigravity **IDE 工具面板**已经安装。

使用 UI：Agent 侧栏 `… → MCP Servers → Manage MCP Servers → View raw config`，或直接编辑全局 `~/.gemini/config/mcp_config.json`（工作区 `.agents/mcp_config.json`）。**请合并现有配置，不得整文件覆盖。**

加入一个 Remote MCP Entry：

```json
{
  "mcpServers": {
    "icloud-carddav": {
      "serverUrl": "https://seoul-forge-01.tail4db0d9.ts.net/mcp"
    }
  }
}
```

官方文档说明服务支持 DCR 时可自动进行 OAuth，故不需在 JSON 中填写长期 Bearer Token。然后从设置 `Customizations → Authenticate` 完成浏览器 OAuth，必要时复制授权码回设置页，输入此 Agent 的 MCP Access Key。完成后检查工具列表及只读查询。Agent 使用 `tools/list` 不应触发写入。

参考：<https://antigravity.google/docs/mcp>。

## 5. ChatGPT 自定义 MCP 当前平台限制

2026-10-30 官方文档明确：自定义 MCP 完整读写能力目前面向 **ChatGPT Business / Enterprise/Edu** 的网页版工作空间。**Plus 不应被标记为已获得自定义 MCP 完整写入能力**；是否显示具体入口以用户实际工作空间权限为准，且手机端目前不能执行完整自定义 MCP 创建流程。

如账号/工作空间支持：打开网页版 ChatGPT → Plugins → `+` → `Add custom MCP server`，指定上述 MCP URL、OAuth，阅读并确认风险提示，授权后扫描工具。对外部服务的 OAuth 通常要求客户端具有可刷新 Token 支持；需实际验证刷新功能，不能仅以 discovery 200 推断长期可用。

完成后必须在**该 ChatGPT 工作空间本身**验证 `tools/list` 与真实工具调用。没有工具列表/调用回执，状态仍是 **BLOCKED / NOT TESTED**，不可以根据 Antigravity 的成功直接标记 PASS。

官方：<https://help.openai.com/en/articles/12584461-connecting-custom-mcp-servers-in-chatgpt>。

## 6. 逐 Agent 的验收表（每个客户端单独填写）

| 验收项 | 成功条件 |
| --- | --- |
| Network | 从该客户端运行无副作用脚本输出 `PUBLIC_SMOKE_PASS` |
| OAuth | 用户完成该 Agent 独立 Access Key 登录，且 Token 获取成功 |
| Discover | 从该 Agent 实际获得 `tools/list`，看到联系人 CRUD 工具 |
| Account | `apple_accounts`（脱敏）列出目标账号与 Contacts READ/WRITE |
| Login | `apple_login` 成功，返回 session_id |
| Search | 查询唯一虚构/无敏感测试标签，得到合理结果（无实际客户内容进入 GitHub） |
| Session | `work_done` 成功退出；必要时重连继续只读 |
| Write | **只在需要检验该 Agent 的写入路径时**用新生成的唯一虚构联系人做 CRUD，必须 try/finally 清理。已有同路径测试记录不可当作新 Agent UI 的直接证据 |
| Persistence | OAuth Access Token 过期刷新（至少一次）由该 Agent 实测；不要仅用容器重启替代 Token 刷新 |
| Audit | GitHub 只记录 Agent 名称、时间、操作、状态和脱敏 trace，不存客户资料、Token、访问密钥 |

**执行底线**：用户已授权所有 Agent 具有统一联系人 CRUD 功能，不要求角色隔离网关；但每次操作仍需唯一联系人定位、去重、尽量使用最新 ETag 和写后核验。真实客户外联或批量不可恢复处理需符合具体业务任务的授权。

## 7. 交付回执模板

```text
Agent:
Client version:
MCP base URL: https://seoul-forge-01.tail4db0d9.ts.net
Public smoke: PASS / FAIL
OAuth DCR/PKCE: PASS / FAIL / BLOCKED
tools/list: PASS / FAIL / BLOCKED (tool count; names)
apple_accounts / apple_login: PASS / FAIL / BLOCKED
contacts_search: PASS / FAIL / BLOCKED (only non-sensitive summary)
CRUD: NOT RUN / PASS / FAIL (synthetic tag only)
refresh after expiry: PASS / NOT TESTED / FAIL
Other data touched: NONE / describe anonymized scope
Key name: (not secret)
Open problem:
```

将结果提交 [Issue #6](https://github.com/gehbfarr5/insurance-autonomous-work-system/issues/6)。不要在已有 React/iOS 项目中直接提交 MCP 密钥，客户端配置与密钥分开管理。
