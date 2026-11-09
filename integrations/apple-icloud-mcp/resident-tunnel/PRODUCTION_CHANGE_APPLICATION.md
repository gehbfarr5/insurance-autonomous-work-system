# 生产变更申请：MacServer 常驻只读候选限时前台验收窗口
**申请编号**: RFC-20261108-AG05-LIMITED-READONLY-WINDOW  
**申请性质**: **受限、限时（30分钟）、即开即关的 MUSE 前台独立只读验收窗口**（非永久常驻上线）  
**申请状态**: 待用户显式审批 (PENDING EXPLICIT USER APPROVAL)  
**当前生产基线状态**:
- Seoul 宿主运行基线镜像: `sha256:f3e697fe266f58910c01985f9c906a84479705846c88fd7d2ea1ccf12c0da2f0`
- MacServer EventKit Bridge: 锁定在安全隔离模式（`writes_enabled = false`，仅监听 `127.0.0.1:18765`）
- 归属认定: AG-04 客户端协议级链路 PASS；MUSE 原生前台独立验收待完成 (PENDING)
**候选分支**: `feat/ag05-resident-readonly-candidate`  
**候选源码 Commit**: `feat/ag05-resident-readonly-candidate` 最新提交  
**公开脱敏声明**: 文档中出现的 `00000000-0000-0000-0000-000000000001` 均为合成占位符；真实测试列表 ID 仅保存在本地受限配置文件中，绝不上传 GitHub。

---

## 一、版本与构建产物唯一对应矩阵

| 组件 | 生产当前基线版本 | 本次试运行候选版本 / 构建产物 | 来源与构建依据 |
| :--- | :--- | :--- | :--- |
| **Seoul Gateway 镜像** | `sha256:f3e697fe...` (无 MacServer 路由) | `sha256:faa6e380ee4b9f9d96dd424ced56bf27a0778722a02323efedd542b29f362929` (`candidate-ag05-delivery-20261108`) | AG-05 交付候选镜像（更新 ical.ts 与 service.ts，包含 is_all_day, time_zone, last_modified, url 映射，取代无新字段的 AG-03 镜像） |
| **MacServer EventKit Bridge** | Git commit `a6f1a9c` (Safe Mode) | Release Binary SHA256: `ab5c4cbd9dd8cb1939165411bab48fe60515fd92e6b89c740ff330827991ff0f` | 纯 Swift `ReminderDateMapper`，时区/全天保真及编译级写隔离，91 个单元测试全通 |
| **反向 SSH 隧道管理** | 无（临时反向隧道已关闭） | `run-resident-tunnel.sh` / `tunnel-ctl.sh` | PR #23 交付，具备原子单例锁 (15 进程并发锤击验证)、真实退出码捕获、指数退避与 4 层可观测状态 |
| **MacServer LaunchAgent** | 无 | `~/Library/LaunchAgents/com.muse.macserver-tunnel.plist` | 极简原生 launchd 用户域配置，直调 supervisor |
| **Seoul SSH 限制配置** | 默认系统 sshd | `/etc/ssh/sshd_config.d/60-macserver-gateway.conf` | 语法经 `sshd -t` 核验，严格绑定回环反向转发 (permitlisten 127.0.0.1:18765) |

---

## 二、业务影响与中断范围评估 (Downtime Analysis)

- **Seoul MCP 容器切换业务中断**:
  - **预计中断时长**: **5 至 10 秒**。
  - **原因**: 替换容器需执行 `docker compose stop` 并启动候选镜像。在此秒级切换窗口内，正在发起的 MCP 请求会收到连接拒绝或超时，切换完成后自动恢复。
  - **禁止虚假声称**: 本次明确确认存在 5-10 秒的 MCP 服务短暂切换窗口，不声称未经证明的零中断。
- **共享服务 (CardDAV / Mail) 影响**:
  - **0 影响**。CardDAV 与 Mail 独立运行于宿主其他容器或原生端口，本次不修改共享容器配置，sshd 仅新增专有用户 Match 块并执行 `systemctl reload sshd` 平滑重载（不杀断现有活动连接）。
- **管理账户依赖审查**:
  - 生产 SSH 限制仅匹配专用隧道账户（如 `mac-operator`），严禁使用全局管理员账户，保证系统管理 SSH 不受任何 `ForceCommand` 限制。

---

## 三、部署步骤与超时看门狗保护 (Deployment with Watchdog)

1. **现场快照与原子备份**:
   ```bash
   BACKUP_DIR="/root/backup/pre_ag05_$(date +%s)"
   mkdir -p "$BACKUP_DIR"
   cp -a /etc/ssh/sshd_config.d "$BACKUP_DIR/"
   cp -a ~mac-operator/.ssh/authorized_keys "$BACKUP_DIR/"
   docker inspect insurance-carddav-mcp-carddav-1 > "$BACKUP_DIR/running_container.json"
   ```
2. **应用 Seoul SSH 限制配置**:
   - 部署 `/etc/ssh/sshd_config.d/60-macserver-gateway.conf` 并经 `sshd -t` 校验通过。
   - 向 `~mac-operator/.ssh/authorized_keys` 追加受限公钥条目。
   - 执行 `systemctl reload sshd`。
3. **部署 MacServer LaunchAgent**:
   - 安装至 `~/Library/LaunchAgents/com.muse.macserver-tunnel.plist`。
   - 执行 `launchctl load -w ~/Library/LaunchAgents/com.muse.macserver-tunnel.plist`。
   - 通过 `/opt/muse-macserver/scripts/tunnel-ctl.sh health` 验证链路就绪。
4. **启动独立超时看门狗 (30 分钟硬约束)**:
   - 启动独立 background watchdog 进程：若 30 分钟内未收到人工延长信号，看门狗自动触发一键恢复并关闭隧道。

---

## 四、确定性回滚步骤 (Rollback Procedure)

若验收完成或出现任何异常，独立执行以下回滚操作：

1. **MacServer 端**:
   ```bash
   launchctl unload -w ~/Library/LaunchAgents/com.muse.macserver-tunnel.plist || true
   /opt/muse-macserver/scripts/tunnel-ctl.sh stop
   rm -f ~/Library/LaunchAgents/com.muse.macserver-tunnel.plist
   ```
2. **Seoul 端精确恢复**:
   ```bash
   cp -a "$BACKUP_DIR/sshd_config.d/"* /etc/ssh/sshd_config.d/
   cp -a "$BACKUP_DIR/authorized_keys" ~mac-operator/.ssh/authorized_keys
   systemctl reload sshd
   # 恢复基线容器
   docker compose -f /opt/insurance-carddav-mcp/docker-compose.yml up -d
   ```
3. **闭环核验**:
   - 检查 `ss -tulpn | grep 18765` 输出为空。
   - 检查 `docker ps` 确认运行容器镜像为预期基线 `sha256:f3e697fe...`。

---

## 五、建议的最小测试数据范围 (Proposed Minimal Test Data)
为验证全天、带时间、时区及多行备注等非空字段，建议在正式开启窗口后，由用户在 Mac 本地提醒事项中向专用测试列表手动添加 2 条合成条目（**验收前不提前创建**）：

| 字段 | 测试条目 1 (定时高优先级) | 测试条目 2 (全天里程碑事项) |
| :--- | :--- | :--- |
| **所属列表** | `MUSE 测试` (本地受限配置指定的测试列表) | `MUSE 测试` |
| **标题 (Title)** | `[AG-05] 核心链路只读定时验收` | `[AG-05] 全天里程碑测试条目` |
| **优先级 (Priority)** | 高 (High / 1) | 无 (None / 0) |
| **截止时间 (DueDate)** | `2026-11-09 14:30:00 (Asia/Shanghai)` | `2026-11-10 (无具体时分秒)` |
| **全天标记 (isAllDay)**| `false` | `true` |
| **完成状态 (Completed)**| `false` | `false` |
| **备注说明 (Notes)** | `多行备注测试：\n1. 验证时区解析\n2. 验证非空字段保真` | `单行备注：验证全天事项日期无偏移` |

---

## 六、审批与执行门禁
- **禁止操作**: 未经用户明确发送“批准执行本次受限窗口”指令前，严格禁止在生产环境执行任何命令、修改文件或开启隧道。
