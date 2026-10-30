# iCloud CardDAV MCP 云端 OAuth 与联系人 CRUD 自动化验收

本目录包含「保险规划师自主工作系统」（S2 客户触达与通讯录基础设施）用于独立验收云端 iCloud CardDAV MCP 服务的测试套件。

## 目标与原则

- **目标**：验证云端托管的 CardDAV MCP 服务（Render）能够被远程 Agent 独立调用，完成 OAuth 2.1 认证、iCloud CardDAV 登录及联系人搜索、创建、读取、修改、删除（CRUD）闭环。
- **Mac 独立性**：测试套件既可在本地执行核验，亦可由任意具备 Node.js 运行环境的云端容器或远程 Agent 运行。正式业务能力由云端 Agent 直连云端 MCP 服务，不依赖本地 Mac 处于开机或在线状态。
- **安全与凭据保护**：本目录严禁提交任何真实的 Apple ID、App 专用密码、OAuth 访问密钥（Access Key）或客户真实隐私数据。

---

## 凭据注入机制（支持 3 种安全途径）

脚本按以下优先级安全加载 MCP 访问密钥（Access Key），全程不向日志或终端回显明文：

1. **macOS Keychain（推荐本地使用）**：
   ```bash
   security add-generic-password -U -s "insurance-carddav-mcp" -a "mcp-agent" -w "<YOUR_MCP_ACCESS_KEY>"
   ```
2. **安全环境变量（适用于容器 / CI）**：
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
4. **Stage 4: MCP 工具集与会话建立**：通过 `StreamableHTTPClientTransport` 建立 MCP 协议连接，列出工具，调用 `apple_accounts` 与 `apple_login` 进行真实 Apple CardDAV 握手。
5. **Stage 5: 虚构联系人 CRUD 闭环**：
   - 注入唯一测试标签：`MCP-Test-<timestamp>`
   - `contacts_search` 确认不存在
   - `contacts_create` 创建虚构联系人
   - `contacts_read` 核验字段
   - `contacts_update` 修改备注
   - `contacts_read` 校验修改生效
   - `contacts_delete` 清理测试联系人
   - `contacts_search` 二次检索确认 0 残留
