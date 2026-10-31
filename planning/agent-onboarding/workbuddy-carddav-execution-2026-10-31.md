# WorkBuddy Desktop → CardDAV MCP 接入执行（2026-10-31）

**对象：** 用户的 M5 Pro Mac 上 WorkBuddy 桌面版（2026-10-27 历史实测为 5.9.2）。不等同于 WorkBuddy 云端任务沙箱。当前 ChatGPT 无该 Mac 本地 GUI/文件系统执行权，因此在首尔隔离容器测试好配置助手后，请在 **WorkBuddy 本地 Agent 的 Mac** 执行安装并完成 OAuth，不能在首尔运行安装脚本来冒充客户端已接入。

## 一次性配置（不清除原连接器）

在保险项目仓库的本地工作副本：

```bash
git pull --ff-only
python3 scripts/agent-onboarding/workbuddy_carddav.py --check
python3 scripts/agent-onboarding/workbuddy_carddav.py --apply
```

- 默认路径：`~/.workbuddy/mcp.json`。
- 只合并 `mcpServers.icloud-carddav`：`{"type":"http","url":"https://seoul-forge-01.tail4db0d9.ts.net/mcp"}`，保留其他已有连接器，修改前备份，不改任何 OAuth Token。
- 已配置则返回 `ALREADY_CONFIGURED`；同名冲突则退出而不覆盖；无效 JSON 则退出而不覆盖。
- 备份和新配置分别用 0600 权限；既有 `.workbuddy` 目录用户级使用。

## 在真实 WorkBuddy UI 完成 OAuth

WorkBuddy 左侧导航进入 **专家·技能·连接器 → 自定义连接器 / MCP 服务管理 → 配置 MCP**，检查 `icloud-carddav` 是否出现在列表。按照客户端提示 **信任**，显示「需要认证」时点击「连接」，浏览器完成 OAuth Authorization Code + PKCE。登录页输入的是从服务器 `/admin` 分配给 WorkBuddy 的**MCP Access Key**，不是 Apple ID 密码。

> 当前首尔已有名称 `codex` 和 `antigravity` 的两把 Agent Key；**WorkBuddy 尚无已验收的专用 Key**。由本地 Agent 使用可信管理浏览器新建 WorkBuddy Key，不要覆盖另外两把。创建后可以直接执行授权，不需要将明文 Key 放进 GitHub。

完成后在 WorkBuddy 对话中通过其 MCP tool panel 验证 `tools/list` 和 Contacts CRUD 工具可见，并调用 `apple_accounts`、`apple_login`、只查唯一不存在标签的 `contacts_search`、`work_done`。**直到真实 WorkBuddy 调用有结果才标记 PASS**。

## WorkBuddy 云端任务另行验收

云端任务是另一套隔离执行环境，可能无法复用本地的私有 OAuth 凭据。不要将本地 `~/.workbuddy/mcp.json` 复制到云任务后就声称通过。先从云任务本身执行无副作用的 `PUBLIC_SMOKE_PASS`；检查云任务是否支持连接器和 OAuth 重定向，并单独核实凭据能否跨云任务持续保存。用户未要求采购新云服务。

## 当前已有证据

- 腾讯官方 WorkBuddy MCP 文档：<https://www.workbuddy.ai/docs/zh/workbuddy/From-Beginner-to-Expert-Guide/Function-Description/MCP-Guide>；
- 自定义连接器开发文档：<https://open.workbuddy.cn/docs/connector>；支持 streamableHttp 远程连接和 OAuth 2.1 + PKCE。
- 2026-10-31 在首尔临时隔离目录以 Python 3 标准库执行 6 个自动测试：**6/6 PASS**，涵盖 dry-run、新增、备份/原配置保留、幂等、同名冲突以及损坏 JSON；只是 **配置助手验证**，不是 Mac 安装或 WorkBuddy OAuth。

将 WorkBuddy 本机 `tools/list` / OAuth / 搜索的真实回执按 PASS/FAIL/BLOCKED 分项写到 [Issue #6](https://github.com/gehbfarr5/insurance-autonomous-work-system/issues/6)。不要读取、发送或发布真实联系人原文。
