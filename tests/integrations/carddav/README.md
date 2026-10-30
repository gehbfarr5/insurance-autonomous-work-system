# iCloud CardDAV MCP 云端 OAuth 与联系人 CRUD 自动化验收

本目录包含「保险规划师自主工作系统」（S2 客户触达与通讯录基础设施）用于独立验收云端 iCloud CardDAV MCP 服务的自动化测试套件。

## 目标与原则

- **目标**：验证显式指定的云端 CardDAV MCP 服务（首尔云实例或另选环境）能够被远程 Agent 独立调用，完成 OAuth 2.1 认证、iCloud CardDAV 登录及联系人搜索、创建、读取、修改、删除（CRUD）闭环。
- **Mac 独立性**：测试套件既可在本地执行核验，亦可由任意具备 Node.js 运行环境的云端容器或远程 Agent 运行。正式业务能力由云端 Agent 直连云端 MCP 服务，不依赖本地 Mac 处于开机或在线状态。
- **安全与凭据保护**：本目录严禁提交任何真实的 Apple ID、App 专用密码、OAuth 访问密钥（Access Key）或客户真实隐私数据。
- **零误报与零残留**：
  - 每步工具调用严格校验 `isError` 与实际返回业务字段；
  - 采用 `try/finally` 防御性设计，遇到任何异常自动执行补偿删除清理；
  - 任务结束时自动调用 `work_done` 清理会话状态；
  - 日志严格脱敏，不输出完整邮箱或任何联系人明细列表。

---

## 凭据注入机制（支持 3 种安全途径）

脚本按以下优先级安全加载 MCP 访问密钥（Access Key），全程不在终端或日志中回显：

1. **macOS Keychain（交互式静默写入，推荐本地使用）**：
   为避免密钥出现在 shell 历史记录或系统进程参数中，请使用静默交互方式存入：
   ```bash
   read -s -p "输入 MCP Access Key: " KEY && security add-generic-password -U -s "insurance-carddav-mcp" -a "mcp-agent" -w "$KEY" && unset KEY
   ```
2. **会话级环境变量（适用于短期调试或 CI 容器）**：
   ```bash
   export MCP_ACCESS_KEY="<YOUR_MCP_ACCESS_KEY>"
   ```
3. **本地私密配置文件（权限 0600）**：
   ```bash
   mkdir -p ~/.config/insurance-carddav-mcp
   echo "<YOUR_MCP_ACCESS_KEY>" > ~/.config/insurance-carddav-mcp/access_key
   chmod 600 ~/.config/insurance-carddav-mcp/access_key
   ```

---

## 依赖与执行

测试脚本依赖官方 `@modelcontextprotocol/sdk`。

### 安装依赖并运行

```bash
# 进入工作目录并执行测试脚本
MCP_SERVER_URL="https://seoul-forge-01.tail4db0d9.ts.net" node tests/integrations/carddav/test-carddav-oauth-crud.mjs
```

**必须**显式指定测试目标（脚本已移除默认 Render 地址，避免误对回退环境执行真实 CRUD）：
```bash
MCP_SERVER_URL="https://seoul-forge-01.tail4db0d9.ts.net" node tests/integrations/carddav/test-carddav-oauth-crud.mjs
```

---

## 自动化测试阶段说明

1. **Stage 1: 存活与健康检查**：调用 `/health` 验证服务运行与冷启动响应。
2. **Stage 2: OAuth 2.1 动态注册**：调用 `/register` 动态注册客户端获得 `client_id`。
3. **Stage 3: PKCE 授权与换票**：基于 RFC 7636（S256）向 `/authorize` 发起授权请求，提交安全注入的 Access Key 置换 Bearer Token。
4. **Stage 4: MCP 工具集与会话建立**：
   - 通过 `StreamableHTTPClientTransport` 建立 MCP 协议连接并校验必备工具集。
   - 调用 `apple_accounts` 校验 `.env 账号` 开启及读写权限（若返回 0 个账号则明确拦截）。
   - 调用 `apple_login` 进行真实 Apple CardDAV 握手并换取 `session_id`。
5. **Stage 5: 虚构联系人 CRUD 闭环与断言**：
   - 注入唯一测试标签：`MCP-Test-<timestamp>`
   - `contacts_search` 确认不存在（断言 count = 0）
   - `contacts_create` 创建虚构联系人并解析 `contact_id`（若未返回则立即失败，不误报成功）
   - `contacts_read` 核验字段（断言名称、测试标签完全一致）
   - `contacts_update` 修改备注（加入 `[UPDATED]` 标记）
   - `contacts_read` 校验修改生效
   - `contacts_delete` 清理测试联系人
   - `contacts_search` 二次检索确认 0 残留（断言 count = 0）
   - `finally` 补偿删除与 `work_done` 清理会话

---

## 持久化与 Envelope 说明

- **Render Free 限制**：Render Free Web Service 没有持久化磁盘，服务在闲置 15 分钟后睡眠重置，会导致容器内的 Token Store（`tokens.json.enc`）被还原，使得后台已开启的 `.env 账号开关` 与创建的 Access Key 被抹除。
- **关于 Envelope Login**：上游的加密信封（Envelope）解决的是 Apple 账户凭据不直接落盘的问题，但不能替代 OAuth Token Store 自身的持久化。长期生产运行应采用支持持久化磁盘的云主机或 VPS 部署。


---

## 2026-10-30 首尔云端验收后的执行限制

- 已有 Antigravity 在 Seoul Forge 上真实 OAuth/CRUD 与重启后复验的脱敏证据：见 [Issue #4](https://github.com/gehbfarr5/insurance-autonomous-work-system/issues/4#issuecomment-6525726042)。**常规健康/备份检查不要再运行本脚本**，因为它会创建、修改并删除 iCloud 测试联系人。
- 要再次执行 CRUD 时，先核对执行人、目标 MCP_SERVER_URL、App 专用账号、测试 Access Key 和清理回执；保持唯一虚构标签和 try/finally。
- Render 原实例仅保留回退，不得因遗漏 `MCP_SERVER_URL` 而被误测。
- **2026-10-30 用户决定：所有获授权 Agent 暂时共享完整联系人 CRUD 能力，不做角色分级。** 上游 Access Key 不具备单 Key 读写分层，当前这属于预期的统一授权模式；建议各 Agent 分别使用可撤销的 Key 便于审计，而不以细粒度权限网关作为接入前提。参见 [多 Agent 集成基线](../../planning/carddav-multi-agent-insurance-integration-2026-10-30.md)。
- GitHub 只保存脱敏证据。ChatGPT 自定义 MCP 连接尚待独立实测，不能用本测试套件替代。
