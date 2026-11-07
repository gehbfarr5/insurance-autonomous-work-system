# AG-03: Seoul → MacServer 只读网关部署与恢复方案 (Deployment & Recovery Plan)

- **编制日期**：2026-11-07
- **方案基线**：`feat/seoul-macserver-readonly-gateway` (AG-03)
- **目标环境**：
  - Seoul MCP 主机 (`VM-0-10-ubuntu`, 容器 `insurance-carddav-mcp-carddav-1`)
  - Intel MacServer (`macserver-ts`, LaunchAgent `gui/501/com.muse.macserver-eventkit`)
- **安全红线**：
  - 本方案为**候选部署方案**；未获用户显式命令前，**绝不连接生产环境执行部署或重启**。
  - 回滚操作必须做到：**仅影响 Reminders 模块，绝不破坏现存 Contacts 原生分组及 Calendar 功能**。

---

## 一、部署前准入核验检查单 (Pre-flight Checklist)

在获得用户专项授权后，执行以下核验：

1. **分支与版本核验**：
   - 确认合并基线为 `feat/seoul-macserver-readonly-gateway`；
   - 确认测试套件（27 项测试）全部 PASS。
2. **凭据一致性核验**：
   - 检查 MacServer 本地 `~/.config/muse-macserver/bridge.env`（0600）中的 `EVENTKIT_BRIDGE_AUTH_TOKEN`；
   - 检查已绑定的测试列表 UUID（`9D9A****03F3`），确保与 Seoul 候选配置一致。
3. **网络与端口核验**：
   - 从 Seoul 主机运行 `tailscale status`，确认 MacServer (`100.100.172.91`) 在线；
   - 检查 Seoul 主机 18765 端口未被占用。

---

## 二、部署执行步骤 (Deployment Steps)

### 步骤 1：部署常驻 SSH 隧道服务（Seoul Host）
1. 在 Seoul 宿主机安装专用 Systemd 单元：
   ```bash
   cp config/seoul-macserver-tunnel.service.candidate /etc/systemd/system/seoul-macserver-tunnel.service
   systemctl daemon-reload
   systemctl enable --now seoul-macserver-tunnel.service
   ```
2. 校验隧道健康：
   ```bash
   curl -s http://127.0.0.1:18765/health | grep '"status":"ok"'
   ```

### 步骤 2：启用 MacServer 临时业务访问开关
1. 由用户在 MacServer 执行或授权更新 `bridge.env`：
   ```bash
   EVENTKIT_BRIDGE_PRODUCTION_AUTHORIZED=true
   ```
2. 重启守护进程以加载生产授权：
   ```bash
   launchctl kickstart -k gui/501/com.muse.macserver-eventkit
   ```

### 步骤 3：注入 Seoul MCP 网关配置并重启服务
1. 将 `seoul-gateway` 模块代码加载至 Seoul 容器源码树；
2. 在环境变量中注入网关配置：
   - `MACSERVER_EVENTKIT_ENDPOINT=http://127.0.0.1:18765`
   - `MACSERVER_EVENTKIT_TOKEN=<SECRET_TOKEN>`
   - `MACSERVER_EVENTKIT_ALLOWED_LIST_IDS=9D9A5AAD-E3F0-4459-8756-BBCDBCB703F3`
   - `ALLOW_REMINDERS_READ_1=true`
   - `ALLOW_REMINDERS_WRITE_1=false` (写闸保持严格关闭)
3. 重启容器 `insurance-carddav-mcp-carddav-1`。

### 步骤 4：网关只读可用性门禁核验
1. 调用 MCP `reminders_lists` 工具，验证仅返回已绑定的测试列表，且 `writable: false`；
2. 调用 MCP `reminders_list` 工具，验证正常读取返回空列表（`reminders: []`）；
3. 调用写操作 `reminders_create`，验证被网关立即拒绝（返回 `PERMISSION_DENIED`）。

---

## 三、故障回滚与恢复预案 (Rollback Plan)

若部署期间出现任何异常（连接超时、鉴权失败、服务健康检查不通过或干扰其他模块）：

### 紧急回滚动作（1 分钟内完成）：

1. **第一步：关闭 Seoul 提醒事项入口（隔离故障）**
   在 Seoul 主机配置中将 `ALLOW_REMINDERS_READ_1=false`，或回退网关配置：
   ```bash
   # 重启容器，提醒事项工具立即下线，防止故障扩散
   docker restart insurance-carddav-mcp-carddav-1
   ```
   **隔离保障**：Contacts（CardDAV）与 Calendar 模块完全独立，不受任何影响。

2. **第二步：关闭 MacServer 业务激活开关**
   在 MacServer 上恢复安全状态：
   ```bash
   launchctl setenv EVENTKIT_BRIDGE_PRODUCTION_AUTHORIZED false
   launchctl kickstart -k gui/501/com.muse.macserver-eventkit
   ```
   验证业务接口重回 HTTP 403 `PERMISSION_DENIED`。

3. **第三步：停止并禁用 Seoul SSH 隧道**
   ```bash
   systemctl stop seoul-macserver-tunnel.service
   systemctl disable seoul-macserver-tunnel.service
   ```

### 恢复后状态校验：
- 确认 Seoul `GET /health` 为 200 OK；
- 确认 Contacts 联系人分组功能与 Calendar 日历读取完全正常；
- 确认 MacServer 进程无内存泄漏、端口 18765 回归安全锁定。
