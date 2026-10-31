# WorkBuddy Desktop 接入回执（2026-10-31，本机实测）

**客户端：** WorkBuddy 桌面版 5.9.3（macOS 27.0.1 / arm64 / 本地 Mac，非云端任务沙箱）
**MCP：** `https://seoul-forge-01.tail4db0d9.ts.net/mcp`，Streamable HTTP + OAuth 2.1（Authorization Code + PKCE S256，DCR）

## 已实际执行的步骤

1. `/health` → 200 `{"status":"ok"}`；OAuth metadata 可读（含 `registration_endpoint`）。
2. Dynamic Client Registration：`client_name=WorkBuddy-Desktop-5.9.3`，`token_endpoint_auth_method=none`（公共客户端 + PKCE），scope `mcp`。
3. 复用本机既有 MCP Access Key（`~/.config/insurance-carddav-mcp/access_key`，非 Apple 密码、非管理员口令）完成 `/access-login` → `/token`，取得 `scope=mcp`、`expires_in=3600` 的 Bearer 与 refresh_token。**未新建 Key，未撤销或改动 `codex` / `antigravity` / `muse-personal` 三把 Key。**
4. `~/.workbuddy/mcp.json` 由既有助手脚本 `scripts/agent-onboarding/workbuddy_carddav.py --apply` 写入 `icloud-carddav":{"type":"http",...}`，原文件完整备份为 `mcp.json.backup-20261031T062806Z`（0600），`andromeld` 与 `seoul-forge-management` 两项保留不变。
5. 以官方 MCP Python SDK（`mcp` 2.3.0，Streamable HTTP 客户端）在真实会话中调用：`initialize` → `tools/list`（25 个工具）→ 各业务工具 → `work_done`。

## 实测结果

| 阶段 | 结果 | 证据 |
| --- | --- | --- |
| Health / OAuth metadata | PASS | 200 / 完整字段 |
| DCR + PKCE 换令牌 | PASS | `POST /token` 200，refresh 轮换成功 |
| MCP 工具发现 | PASS | `apple-icloud-mcp` v2.0.0，protocol 2025-11-25，25 工具 |
| `apple_accounts` / `apple_login` | PASS | `gehbfarr5@i.softbank.jp`：contacts/calendar/reminders 读写 true，mail false |
| `contacts_search` | PASS | 3 次随机标签（`zz-accept-*` / `zz-nomatch-*`）均 0 匹配 |
| `contacts_read` | PARTIAL | 仅以非法 ID 验证错误处理（`INVALID_INPUT`），无授权测试对象，未读任何真实联系人 |
| `calendar_list` | PASS | 3 个日历，`writable=true` 3 个 |
| `calendar_list_events` | PASS | 2026-10-24..2026-11-07 共 13 条，`truncated`/`partial_failures` 均未出现 |
| `reminders_lists` | PASS | 1 个列表，`writable=true` |
| `reminders_list` | PASS | 11 条，其中已完成 10 条，无截断/部分失败 |
| `work_done` | PASS | `{"success":true}` |
| 令牌复用（新进程） | PASS | 刷新后新进程直接 `initialize` + `apple_accounts` 成功 |

未执行任何写入：未新建/修改日历事件、提醒事项或联系人；未读取或输出真实客户联系方式。

## 未完成项（需人工一步）

原生连接器已在 `~/.workbuddy/mcp.json` 注册，但 WorkBuddy 要求用户在「连接器管理」里对该服务点「信任」，再由浏览器完成一次 OAuth（登录页输入的是 MCP Access Key）。该点击与浏览器授权无法由 Agent 代替，因此**应用内原生连接仍为 BLOCKED**；本回执中的 PASS 均来自本机 MCP SDK 客户端（同一 URL、同一 OAuth 语义、同一凭据）。

另：本机尚无 WorkBuddy 专用 Access Key，`/admin` 需要管理员口令（当前不可用）。建议后续在 `/admin` 新建 `workbuddy` Key，替代共享 Key，不改动其余三把。

## 复现

```bash
cd scripts/agent-onboarding/workbuddy-mcp-client
python3 oauth_login.py          # 需 ~/.config/insurance-carddav-mcp/access_key 与 dcr.json
python3 mcp_client.py list
python3 acceptance.py           # 只读验收，输出 evidence.json
```

`dcr.json` / `token.json` 仅存在本机 `~/.workbuddy/icloud-mcp/`（0600），不入库。
