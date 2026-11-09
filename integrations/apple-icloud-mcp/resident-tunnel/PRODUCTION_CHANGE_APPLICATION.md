# 生产变更申请：MacServer 常驻只读候选限时前台验收窗口
**申请编号**: RFC-20261108-AG05-LIMITED-READONLY-WINDOW  
**申请性质**: **受限、限时（30分钟硬约束）、即开即关的 MUSE 前台独立只读验收窗口**（严禁常驻上线、严禁未经审批续期）  
**申请状态**: 待用户显式审批 (PENDING EXPLICIT USER APPROVAL)  
**基线状态与有效性说明**:
- **此前生产审计基准时间**: 2026-11-08T21:30:00Z（Seoul 宿主运行基线镜像 `sha256:f3e697fe266f58910c01985f9c906a84479705846c88fd7d2ea1ccf12c0da2f0`，容器健康；MacServer 处于锁定状态）。
- **真实生产接触声明**: 本轮严守安全边界，**未重新对生产主机执行任何变更或侵入式操作**；本文档不虚假声称“已现场重新核验生产”，基线数据严格继承此前审计凭据。
- **候选分支**: `feat/ag05-resident-readonly-candidate` (PR #23)  
- **候选源码 Commit**: 参见 PR #23 最新提交记录  
- **公开脱敏声明**: 文档中出现的 `00000000-0000-0000-0000-000000000001` 均为公开合成占位符；真实测试列表 ID 仅保存在本地受限配置文件中，绝不上传 GitHub。

---

## 一、版本与构建产物唯一对应矩阵

| 组件 | 生产当前基线版本 | 本次试运行候选版本 / 构建产物 | 来源与构建依据 |
| :--- | :--- | :--- | :--- |
| **Seoul Gateway 镜像** | `sha256:f3e697fe...` (无 MacServer 路由) | Local Image ID: `sha256:faa6e380ee4b9f9d96dd424ced56bf27a0778722a02323efedd542b29f362929`<br>(Registry RepoDigest: `null`，本地构建镜像，未推送到远端仓库) | AG-05 交付候选镜像（更新 ical.ts 与 service.ts，包含 is_all_day, time_zone, last_modified, url 映射，取代无新字段的旧镜像） |
| **MacServer EventKit Bridge** | Git commit `a6f1a9c` (Safe Mode) | Release Binary SHA256: `6b4a0b826b904c9d844c890e3f39062775b0fecec5df439eb78217395bf657b6`<br>格式: **Mach-O Universal Binary (x86_64 + arm64)**，最低 macOS 14.0，已签名 | 原生适配目标 Intel x86_64 MacServer，纯 Swift `ReminderDateMapper`，时区/全天保真及编译级写隔离，91 个单元测试全通 |
| **反向 SSH 隧道管理** | 无（临时反向隧道已关闭） | `run-resident-tunnel.sh` / `tunnel-ctl.sh` | PR #23 交付，具备原子单例锁 (15 进程并发锤击验证)、真实退出码捕获、指数退避、4 层可观测状态及本地会话硬超时保护 |
| **MacServer LaunchAgent** | 无 | `~/Library/LaunchAgents/com.muse.macserver-tunnel.plist` | 极简原生 launchd 用户域配置，直调 supervisor |
| **Seoul SSH 限制配置** | 默认系统 sshd | `/etc/ssh/sshd_config.d/60-macserver-gateway.conf` | 语法经 `sshd -t` 核验，严格绑定回环反向转发 (permitlisten 127.0.0.1:18765) |
| **看门狗与跨设备编排** | 无 | `production-entry.sh` (首次变更前启动看门狗)<br>`orchestrated-recovery.sh` (跨设备联动编排) | 覆盖整个试运行窗口（前置启动），严禁人工与自动续期，具备并发防踩踏与 100% 隔离演练验证 |

---

## 二、业务影响与停机接触面评估 (Downtime Analysis)

- **Seoul MCP 容器切换业务中断评估**:
  - **预计接触面中断时长**: **5 至 10 秒**。
  - **受影响功能接触面**: **Contacts（联系人）、Calendar（日历）及 Reminders（提醒事项）**。
  - **业务表现**: 在执行 `docker compose stop` 与候选容器启动初始化的 5-10 秒秒级切换窗口内，任何向 Seoul MCP 网关发起的联系人、日历或提醒事项查询/操作请求均会遭遇短暂连接拒绝或 HTTP 502/超时。容器健康检查通过（200 OK）后瞬间恢复。
  - **禁止虚假声称**: 明确通报各业务方存在该 5-10 秒的 MCP 服务停机重启窗口，严禁宣称未经证明的“零中断”。
- **独立共享服务 (CardDAV / Mail) 影响**:
  - **0 影响**。CardDAV 存储与原生 Mail 服务独立运行，sshd 采用 `Match User mac-operator` 局部限制并通过 `systemctl reload sshd` 平滑重载，不杀断已存在的管理员 SSH 会话。
- **管理账户审查**:
  - 生产 SSH 限制仅匹配专用隧道账户 `mac-operator`，绝不修改全局 `sshd_config` 或 root 账户。

---

## 三、部署步骤与事前看门狗保护 (Deployment with Pre-Change Watchdog)

1. **现场快照与原子备份**:
   ```bash
   BACKUP_DIR="/root/backup/pre_ag05_$(date +%s)"
   mkdir -p "$BACKUP_DIR"
   cp -a /etc/ssh/sshd_config.d "$BACKUP_DIR/"
   cp -a ~mac-operator/.ssh/authorized_keys "$BACKUP_DIR/"
   docker inspect insurance-carddav-mcp-carddav-1 > "$BACKUP_DIR/running_container.json"
   ```
2. **启动事前独立恢复看门狗 (30 分钟硬约束，前置启动)**:
   - 在向生产容器写入任何候选配置或打 Tag 之前，`production-entry.sh` 自动在后台启动脱离终端会话的独立看门狗进程（记录 PID 与启动时间戳）。
   - **硬性约束**: 30 分钟硬倒计时从首次生产变更前立即起算。
   - **严禁续期**: 严禁任何自动或人工指令延长窗口。倒计时一到，看门狗强制调用基线回滚。
   - **MacServer 本地硬超时**: MacServer 端隧道守护同步启动 1800 秒本地硬超时，即使跨设备网络完全中断，MacServer 也将根据本地硬超时自主锁定 Bridge 并终止隧道。
3. **应用 Seoul SSH 限制配置**:
   - 部署 `/etc/ssh/sshd_config.d/60-macserver-gateway.conf` 并经 `sshd -t` 校验通过。
   - 向 `~mac-operator/.ssh/authorized_keys` 追加受限公钥条目并执行 `systemctl reload sshd`。
4. **部署 MacServer Universal Bridge 与 LaunchAgent**:
   - 部署 Universal Release Binary（SHA256: `6b4a0b82...`）至 `/opt/muse-macserver/bin/EventKitBridgeServer`。
   - 载入 `~/Library/LaunchAgents/com.muse.macserver-tunnel.plist`。
   - 执行 `/opt/muse-macserver/scripts/tunnel-ctl.sh health` 验证 4 层健康状态。
5. **部署 Seoul 候选容器**:
   - 部署 `compose.production.yaml` 并重启 MCP 容器（经历 5-10 秒停机窗口），校验候选镜像与健康端点。

---

## 四、跨设备联动关闭与确定性回滚编排 (Orchestrated Rollback)

验收完成或出现任何异常（或 30 分钟看门狗硬超时触发）时，通过编排脚本执行跨设备联动回滚：

```bash
# 统一跨设备联动回滚入口
/opt/insurance-carddav-mcp/scripts/orchestrated-recovery.sh "$BACKUP_DIR"
```

编排脚本内联执行以下 5 项原子步骤：
1. **联动停止 MacServer 业务开关**:
   - 触发 MacServer 桥接进入安全隔离锁定模式，探测验证 `/health` 返回 403 阻断。
2. **停止反向隧道与 LaunchAgent**:
   - MacServer 执行 `tunnel-ctl.sh orchestrated-stop`，卸载 LaunchAgent。
   - 探测验证 Seoul 宿主回环端口 `18765` 残留监听数严格为 0。
3. **恢复 Seoul MCP 容器与配置**:
   - 停止候选容器，通过 `rsync` 还原原配置文件（排除运行时 OAuth 令牌）。
   - 将基线镜像 `sha256:f3e697fe...` 重新打标为 `:latest`。
   - 启动基线 Compose 服务并等待健康检查（经历 5-10 秒重启窗口）。
4. **清理 Seoul SSH 配置与临时文件**:
   - 彻底删除新增的 `/etc/ssh/sshd_config.d/60-macserver-gateway.conf` 文件。
   - 还原 `~mac-operator/.ssh/authorized_keys`，平滑重载 sshd。
5. **端到端闭环验证**:
   - 校验 Seoul MCP 健康检查通过（200 OK）。
   - 校验运行中容器镜像严格等于基线 `sha256:f3e697fe...`。
   - 校验联系人、日历权限配置与基线原始记录逐项一致。
   - 校验反向转发端口 `18765` 监听完全消失。

---

## 五、建议的最小测试数据范围 (Proposed Minimal Test Data)
为验证全天、带时间、时区及多行备注等非空字段，正式开启窗口后，由用户在 Mac 本地提醒事项中向专用测试列表手动添加 2 条合成条目（**验收前不提前创建**）：

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
- **严禁未经授权操作**: 未经用户明确发送“批准执行本次受限窗口”指令前，严格禁止在生产环境执行任何命令、修改配置或开启反向隧道。
