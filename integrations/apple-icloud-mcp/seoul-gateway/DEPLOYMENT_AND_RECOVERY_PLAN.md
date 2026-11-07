# AG-03: Seoul → MacServer 只读网关部署与恢复方案 (Deployment & Recovery Plan)

- **编制日期**：2026-11-07
- **方案基线**：`feat/seoul-macserver-readonly-gateway` (AG-03)
- **目标环境**：
  - Seoul MCP 主机 (`VM-0-10-ubuntu`, 容器 `insurance-carddav-mcp-carddav-1`)
  - Intel MacServer (`macserver-ts`, LaunchAgent `gui/501/com.muse.macserver-eventkit`)
- **安全红线**：
  - 本方案为**候选部署方案**；未获用户显式命令前，**绝不连接生产环境执行部署或重启**。
  - **绝不执行真实写探针**：生产验收门禁仅限只读探测（`GET /health`、`reminders_lists` 与绑定测试列表的 `reminders_list`），严禁在真实服务上调用写操作。
  - **标识脱敏**：全案禁止出现未脱敏的完整原始 UUID，仅使用脱敏标识 `9D9A****03F3`。

---

## 一、实际共享服务影响分析 (Shared Services Impact Analysis)

在评估部署与故障恢复时，必须严格区分同宿主机及同容器内各个共享服务的影响范围：

### 1. 同宿主机其他独立容器（零影响，完全隔离）
- **受保护服务**：
  - `ydisks-xianyu-helper-app-1`（闲鱼助手，端口 18880）
  - `ydisks-xianyu-helper-postgres-1`（PostgreSQL 数据库，端口 5432）
  - `englishpod-web`（端口 8888）与 `englishpod-http-validation`
- **隔离机制**：属于独立的 Docker Compose 网络与不同的宿主映射端口。本网关的任何安装、启停或回滚**绝不触碰**上述容器。

### 2. 同容器内的其他业务模块（严格隔离，保持在线）
- **联系人模块 (`contacts`)**：基于 CardDAV 运行，承载 PR #14 引入的原生联系人分组功能；
- **日历模块 (`calendar`)**：基于 CalDAV 运行，承载 ETag 并发冲突检测功能；
- **邮件模块 (`mail`)**：已在配置中禁用。
- **影响评估**：Reminders 只读网关作为独立的服务适配器插入，与 Contacts 及 Calendar 无代码级交叉依赖。在重启容器加载环境变量期间，存在秒级的容器重启窗口，重启完成后 Contacts 与 Calendar 立即恢复正常工作。

### 3. 多 Agent 租户共用影响（只读安全，零并发写冲突）
- **获授权 Agent**：Antigravity、MUSE、WorkBuddy 共用同一套 Apple ID (`gehbfarr5@i.softbank.jp`)；
- **只读保证**：网关在客户端和服务端硬编码拦截所有写操作（`PERMISSION_DENIED`），因此开启网关**绝不会**向 iCloud 写入任何脏数据，**绝不会**引发多 Agent 间的数据并发修改或覆盖。

---

## 二、部署前准入核验检查单 (Pre-flight Checklist)

在获得用户专项命令后，核验以下条件：

1. **版本与测试验证**：
   - 确认合并基线为 `feat/seoul-macserver-readonly-gateway`；
   - 确认测试套件（45 项测试，含多跳隧道与 Swift 编码测试）在本地环境全部 PASS。
2. **凭据与绑定核验**：
   - 检查 MacServer 本地受限文件 `~/.config/muse-macserver/bridge.env`（0600）中的 `EVENTKIT_BRIDGE_AUTH_TOKEN`；
   - 确认待绑定的测试列表 `M****试`（脱敏标识：`9D9A****03F3`）具备显式来源绑定（`sourceType: calDAV`, `sourceName: iCloud`）。
3. **网络与接口核验**：
   - 确认 Tailscale 状态正常，MacServer (`100.100.172.91`) 在线；
   - 确认 Seoul 主机 18765 端口未被其他服务占用。

---

## 三、部署执行步骤 (Deployment Steps)

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
1. 由用户在 MacServer 图形环境更新 `bridge.env`（保持受限权限 `0600`）：
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
   - `MACSERVER_EVENTKIT_TOKEN=<SECRET_TOKEN_FROM_BRIDGE_ENV>`
   - `MACSERVER_EVENTKIT_ALLOWED_LISTS=9D9A****03F3:REDACTED_SOURCE_UUID:iCloud:calDAV`
   - `ALLOW_REMINDERS_READ_1=true`
   - `ALLOW_REMINDERS_WRITE_1=false` (写闸保持严格关闭)
3. 重启容器 `insurance-carddav-mcp-carddav-1`。

### 步骤 4：只读可用性门禁核验（严禁写探针）
1. 调用 MCP `reminders_lists` 工具，验证仅返回已绑定的测试列表，且 `writable: false`；
2. 调用 MCP `reminders_list` 工具，验证正常读取返回空列表（`reminders: []`）；
3. **特别声明**：不调用任何写工具（`reminders_create`）向生产发起真实探针，写保护已由离线协议测试（28 项）严格证明。

---

## 四、原版本与配置恢复步骤 (Rollback & Restoration Plan)

若部署期间出现任何异常（连接超时、鉴权失败、服务健康检查不通过或干扰其他模块）：

### 1. 恢复基线版本定义
- **生产基线 Commit**：`92bd313154cfbc51fce7e8df5b3f73ea86a6f1c7` (Author: Muse, `calendar: surface CalDAV ETag in listEvents`)
- **生产基线配置**：
  - `ALLOW_REMINDERS_READ_1=false`
  - `ALLOW_REMINDERS_WRITE_1=false`

### 2. 具体执行步骤

#### 步骤 A：恢复 Seoul MCP 容器与配置
1. 还原环境配置中的提醒事项开关：
   ```bash
   # 关闭 Reminders 读取开关
   sed -i 's/ALLOW_REMINDERS_READ_1=true/ALLOW_REMINDERS_READ_1=false/' /opt/insurance-carddav-mcp/config/env
   ```
2. 若涉及源码改动，检出基线提交：
   ```bash
   cd /opt/insurance-carddav-mcp/source
   git checkout 92bd313154cfbc51fce7e8df5b3f73ea86a6f1c7
   ```
3. 重启容器恢复服务：
   ```bash
   docker restart insurance-carddav-mcp-carddav-1
   ```
   **恢复验证**：验证 Contacts 原生分组及 Calendar 日历功能完全恢复正常。

#### 步骤 B：关闭 MacServer 业务激活开关
在 MacServer 上恢复安全锁定状态：
```bash
launchctl setenv EVENTKIT_BRIDGE_PRODUCTION_AUTHORIZED false
launchctl kickstart -k gui/501/com.muse.macserver-eventkit
```
验证业务接口恢复返回 HTTP 403 `PERMISSION_DENIED`。

#### 步骤 C：停止并禁用 Seoul SSH 隧道
```bash
systemctl stop seoul-macserver-tunnel.service
systemctl disable seoul-macserver-tunnel.service
```

### 3. 恢复后验收准则
- 确认 Seoul `GET /health` 返回 200 OK；
- 确认 Contacts 联系人分组功能与 Calendar 日历读取完全正常；
- 确认 MacServer 守护进程处于非激活锁定状态（双端点 403）；
- 确认同宿主机其他容器（`ydisks`, `englishpod`）运行稳定，无异常日志。
