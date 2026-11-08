# 生产变更申请：MacServer 常驻只读候选上线与 MUSE 前台验收
**申请编号**: RFC-20261108-AG05-RESIDENT-READONLY  
**申请状态**: 待用户审批 (PENDING APPROVAL)  
**基线状态**: Commit `a6f1a9c` (PR #22), 镜像 `sha256:f3e697fe...` (基线正常运行)  
**候选分支**: `feat/ag05-resident-readonly-candidate`  
**约束声明**: 本文档仅为变更准备与方案申请，未经用户显式审批，绝对不执行生产部署、不重启生产服务、不修改生产凭据、不开启公网监听、不退役 M5。

---

## 1. 变更背景与目标
在 AG-04 中已成功验证了 MUSE → Seoul 统一 MCP → 受限反向 SSH 隧道 → MacServer EventKit → iCloud 测试列表的真实只读链路。
AG-05 的目标是：
1. 提供彻底脱离 M5 的 MacServer 常驻只读反向隧道工程架构（通过 macOS `launchd` + 单例守护 Supervisor），具备自动重连、封顶指数退避与可观测状态；
2. 固化 OpenSSH 最小权限配置（禁止交互 Shell、禁止任意命令、仅允许特定端口转发）；
3. 申请一次受限、限时、即开即关的 MUSE 原生前台独立验收窗口，验证非空提醒事项字段与真实端到端只读链路。

---

## 2. 变更具体内容与对象清单

| 变更目标 | 操作类型 | 具体路径 / 资源 | 变更详情与最小权限防护 |
| :--- | :--- | :--- | :--- |
| **MacServer** | 新增常驻服务 | `/Library/LaunchAgents/com.muse.macserver-tunnel.plist` | 由 `launchd` 管理，调用 `run-resident-tunnel.sh`，仅在连接异常中断时拉起，正常退出不狂刷 |
| **MacServer** | 部署管理脚本 | `/opt/muse-macserver/scripts/run-resident-tunnel.sh`<br>`/opt/muse-macserver/scripts/tunnel-ctl.sh` | 单例文件锁 (`tunnel.pid`)，指数退避 (2s -> 30s)，状态可观测 (`tunnel_status.json`) |
| **MacServer** | 专用密钥对 | `~/.ssh/id_ed25519_macserver_resident_tunnel` | 权限 `0600`，仅用于反向端口转发 |
| **Seoul 宿主** | SSH 限制配置 | `/etc/ssh/sshd_config.d/60-macserver-gateway.conf` | `Match User mac-operator`<br>`PermitListen 172.19.0.1:18765 127.0.0.1:18765`<br>`ForceCommand /bin/false`<br>`GatewayPorts clientspecified` |
| **Seoul 宿主** | 授权公钥限制 | `~mac-operator/.ssh/authorized_keys` | `restrict,port-forwarding,permitlisten="172.19.0.1:18765",permitlisten="127.0.0.1:18765",command="/bin/false",no-pty` |

---

## 3. 共享服务中断范围与安全性分析
- **共享服务影响**: **0 中断**。
  - 本次变更完全独立于现有的 CardDAV / 邮件等共享生产服务。
  - sshd 仅新增独立用户匹配块，不修改全局 `sshd_config` 主干，无需重启 sshd 守护进程（仅执行 `systemctl reload sshd` 平滑重载）。
  - 不存在公网通配监听（`0.0.0.0`），监听严格限定在 Docker 网桥 `172.19.0.1` 及本地环回 `127.0.0.1`。
- **只读保证与写入隔离**:
  - MacServer `EventKitBridge` 编译级别移除全部写方法，生产开关 `writes_enabled = false`。
  - 即使前端发起写请求，亦在网关层及 Bridge 层分别触发 `PERMISSION_DENIED` 403 拒绝，无任何 iCloud 写操作。

---

## 4. 备份对象与确定性恢复 (Rollback) 入口

### 备份对象
1. Seoul 宿主: `/etc/ssh/sshd_config.d/60-macserver-gateway.conf` (若已存在)、`~mac-operator/.ssh/authorized_keys`。
2. MacServer: `/Library/LaunchAgents/com.muse.macserver-tunnel.plist`、当前安全模式状态文件。

### 一键独立恢复步骤 (Rollback Procedure)
若在试运行期间出现任何异常，可直接在独立终端中执行以下恢复操作：
1. **停止并卸载 MacServer 隧道**:
   ```bash
   launchctl bootout gui/501/com.muse.macserver-tunnel || true
   /opt/muse-macserver/scripts/tunnel-ctl.sh stop
   rm -f ~/Library/LaunchAgents/com.muse.macserver-tunnel.plist
   ```
2. **清理 Seoul SSH 配置**:
   ```bash
   rm -f /etc/ssh/sshd_config.d/60-macserver-gateway.conf
   sed -i '/macserver_resident_tunnel/d' ~mac-operator/.ssh/authorized_keys
   systemctl reload sshd
   ```
3. **确认无残留监听**:
   - 检查 Seoul: `ss -tulpn | grep 18765` 输出为空。
   - 检查 MacServer: `pgrep -f run-resident-tunnel` 输出为空。

---

## 5. 建议的非空测试数据范围 (Proposed Test Data Scope)
为了避免 AG-04 中列表虽恢复但条目为空（0 条）导致非空字段未能端到端验证的问题，建议在正式前台验收前，由用户在 Mac 本地提醒事项中向专用测试列表手动添加 2 条合成测试数据：

| 字段 | 测试条目 1 (定时高优先级) | 测试条目 2 (全天里程碑事项) |
| :--- | :--- | :--- |
| **所属列表** | `MUSE 测试` (`9D9A5AAD-E3F0-4459-8756-BBCDBCB703F3`) | `MUSE 测试` (`9D9A5AAD-E3F0-4459-8756-BBCDBCB703F3`) |
| **标题 (Title)** | `[AG-05] 核心链路只读定时验收` | `[AG-05] 全天里程碑测试条目` |
| **优先级 (Priority)** | 高 (High, 对应 Priority 1) | 无 / 默认 (None, 对应 Priority 0) |
| **截止时间 (DueDate)** | `2026-11-09 14:30:00 (Asia/Shanghai)` | `2026-11-10 (无具体时分秒)` |
| **全天标记 (isAllDay)**| `false` | `true` |
| **完成状态 (Completed)**| `false` (未完成) | `false` (未完成) |
| **备注说明 (Notes)** | `多行备注测试：\n1. 验证时区解析\n2. 验证非空字段忠实传输` | `单行备注：验证全天事项日期无偏移` |

> [!NOTE]
> 本测试数据仅包含合成占位符，不包含任何个人隐私或客户敏感信息。验收完成后可一键清空或保留。

---

## 6. 申请审批流程与时间窗口
- **申请生效条件**: 仅在用户回复明确批准后方可执行。
- **时间窗口建议**: 预计持续 15 分钟，验收结束后即时关闭反向隧道，恢复常驻安全模式。
