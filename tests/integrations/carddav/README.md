# iCloud CardDAV MCP 云端 OAuth 与联系人 CRUD 自动化验收

本目录包含「保险规划师自主工作系统」（S2 客户触达与通讯录基础设施）用于独立验收云端 iCloud CardDAV MCP 服务的自动化测试套件。

## 目标与原则

- **目标**：验证云端托管的 CardDAV MCP 服务（Render）能够被远程 Agent 独立调用，完成 OAuth 2.1 认证、iCloud CardDAV 登录及联系人搜索、创建、读取、修改、删除（CRUD）闭环。
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
node tests/integrations/carddav/test-carddav-oauth-crud.mjs
```

如指定自定义服务地址（默认为 Render pilot 服务）：
```bash
MCP_SERVER_URL="https://insurance-carddav-mcp-pilot.onrender.com" node tests/integrations/carddav/test-carddav-oauth-crud.mjs
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
