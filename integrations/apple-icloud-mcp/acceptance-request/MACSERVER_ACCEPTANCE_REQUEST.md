# MacServer EventKit Readonly Candidate — AG-02 安装准入与限定只读试运行申请书
<!-- AG-02 | feat/macserver-eventkit-readonly | 2026-11-07 -->

## 1. 概述与申请目标

本文件为 **MacServer EventKit 只读候选守护进程** 的正式安装准入与限定只读试运行申请书。
在 AG-01 功能范围已严格冻结的前提下，本阶段已在既有有效权限内自主完成：
1. **候选打包与签名完整性验证**（产物已固化为自包含部署包）。
2. **目标平台实机只读核对**（通过 Tailscale/SSH 对 Intel MacServer 系统版本、架构、GUI 登录域、端口占用及已有服务完成实地核查）。
3. **受限配置存储与权限规范**（配置与程序定义 100% 对齐，文件权限严格最小化）。
4. **TCC 授权入口及状态管理**（明确 macOS 15 Sequoia 体系下的首次弹窗触发与重置路径）。
5. **基于 Fake 的进程级完整冒烟验证**（双架构二进制与配置加载全通）。

> [!IMPORTANT]
> **试运行边界声明**：未取得用户明确安装批准前，绝不向 MacServer 写入生产文件、不启动真实 Store、不申请真实 TCC 授权、不访问 Apple 实体数据、不修改 Seoul 网关。

---

## 2. 目标平台实机只读核对证据 (MacServer Live State)

通过既有授权对目标宿主 `macserver-ts` (`100.100.172.91`) 执行只读核对，确凿事实如下：

| 核对项 | 实际检测值 | 准入结论 |
|---|---|---|
| **主机名 / 节点** | `MacServer` (`macserver-ts` / `100.100.172.91`) | ✅ 正常在线 |
| **操作系统** | `macOS 15.7.7` (`BuildVersion 24G720`, Darwin Kernel 24.6.0) | ✅ 完全受支持（macOS 13+ 兼容） |
| **硬件架构** | `x86_64` (`RELEASE_X86_64`) | ✅ 与候选 `Mach-O thin (x86_64)` 100% 匹配 |
| **执行用户与组** | `uid=501(jin) gid=20(staff)` | ✅ 用户权限就绪 |
| **GUI 登录会话** | `jin console`, session = `Aqua`, creator = `loginwindow[6593]` | ✅ 处于活动图形界面，可正常响应 TCC 授权 |
| **目标监听端口** | `127.0.0.1:18765` | ✅ `lsof` 检查确认当前完全空闲、无任何占用 |
| **现有服务排查** | `launchctl list \| grep muse` 无匹配项 | ✅ 无冲突服务，可干净注册 |
| **目标目录结构** | `/Users/Shared` (drwxrwxrwt), `~/bin` (drwxr-xr-x), `~/Library/LaunchAgents` (drwxr-xr-x) | ✅ 权限完备，无需 root 提权 |

---

## 3. 候选打包产物与签名完整性证据

所有候选部署产物已打包并固化于 `integrations/apple-icloud-mcp/candidate-package/`：

| 交付文件 | 文件格式 / 属性 | SHA-256 校验和 / CDHash |
|---|---|---|
| **部署总包** | `macserver-eventkit-candidate-x86_64.tar.gz` | `b86543fe9aec1abb362b867282c870999b10f5fad9b5e87ab275e9c31e578f1f` |
| **可执行二进制** | `bin/EventKitBridgeServer` (`Mach-O thin x86_64`) | 签名后 SHA-256: `223d624c8bf455543f36499fc448c072a5b34087c119e4b8d4a15829f95df8d4`<br>签名签名 CDHash: `6d8862157803a2fc7863818acdcb2b0e7ee2b103` |
| **签名标识符** | `com.muse.macserver-eventkit` | Hardened Runtime 标志: `0x10002(adhoc,runtime)` |
| **安装守护模板** | `com.muse.macserver-eventkit.plist.template` | 程序代码原生输出，`plutil -lint` 验证通过 |
| **安装脚本** | `install.sh` (支持 `--dry-run`) | 权限 `0755`，集成前置检查与原子部署 |
| **恢复卸载脚本** | `uninstall.sh` | 权限 `0755`，集成服务卸载与 TCC 重置 |
| **状态核验脚本** | `verify.sh` | 权限 `0755`，集成 200/405/元数据检查 |
| **冒烟验证脚本** | `smoke_test.sh` | 权限 `0755`，全自动本地回环进程级冒烟测试 |

---

## 4. 目标文件与权限清单 (File & Permission Matrix)

在获准试运行安装后，落地于 MacServer 的目标文件及权限定义严格如下：

| 文件绝对路径 | 建议权限 | 所属用户:组 | 用途与安全控制说明 |
|---|---|---|---|
| `/Users/shared/bin/EventKitBridgeServer` | `0755` | `jin:staff` | 带 Hardened Runtime 签名的只读服务二进制 |
| `/Users/jin/Library/LaunchAgents/com.muse.macserver-eventkit.plist` | `0644` | `jin:staff` | 仅当前用户可读写的 LaunchAgent 配置，注入环境变量 |
| `/Users/shared/log/macserver-eventkit.stdout.log` | `0644` | `jin:staff` | 标准输出日志（脱敏无密钥） |
| `/Users/shared/log/macserver-eventkit.stderr.log` | `0644` | `jin:staff` | 标准错误日志 |

---

## 5. 限定只读试运行的真实读取范围

在试运行阶段，服务被约束在极窄的安全边界内：

1. **白名单强绑定范围**：
   - 仅允许读取 `EVENTKIT_BRIDGE_ALLOWED_LIST_IDS` 环境变量中指定的特定测试列表 UUID。
   - 仅允许经过 `EVENTKIT_BRIDGE_BINDINGS` 显式绑定的 iCloud 数据源（`sourceType == calDAV` 且 `sourceTitle == iCloud`）。
2. **元数据与内容严格分离 (FIX-R4A-01)**：
   - 列表查询仅暴露 `listID`、`title`、`color`、`sourceID`。
   - 绝不暴露待办条目数量（counts）或条目内容（items）。
3. **完全写隔离**：
   - 协议内未定义任何写方法；HTTP 层面对于 POST、PUT、DELETE、PATCH 等非 GET 请求全部返回 405 Method Not Allowed。

---

## 6. 首次 TCC 授权步骤与状态检查 (Sequoia 交互)

因为 MacServer 运行 macOS 15.7.7，EventKit 访问受 Apple 隐私保护机制（TCC）管辖：

1. **授权触发点**：
   - 当服务以 `EVENTKIT_BRIDGE_PRODUCTION_AUTHORIZED=true` 运行，且首个经过鉴权的只读请求触达 `/reminders/lists` 时，macOS 系统将自动在 MacServer 的物理显示器（Aqua 图形会话 `gui/501`）弹出授权框：
     > **“EventKitBridgeServer”想要访问您的“提醒事项”。**
2. **首次授权操作**：
   - 由用户 `jin` 在 MacServer 图形控制台前台点击“允许”；或在 macOS `系统设置 -> 隐私与安全性 -> 提醒事项` 中勾选 `EventKitBridgeServer`。
3. **状态检查机制**：
   - **授权前/待确认状态**：`/health` 端点仍返回 200 OK；业务端点返回 403 `permissionDenied`（脱敏不崩溃）。
   - **授权通过状态**：业务端点返回 200 OK 及只读列表元数据。
   - **重置复原**：执行 `tccutil reset Reminders com.muse.macserver-eventkit` 即可瞬间重置为未授权状态。

---

## 7. 一键可批准的安装与原状态恢复方案

### A. 执行试运行安装（待用户批准后执行）
```bash
# 1. 登录目标机器检查预检项（干跑验证）
ssh macserver-ts "/path/to/install.sh --dry-run"

# 2. 正式安装与启动
ssh macserver-ts "/path/to/install.sh"

# 3. 验证基础连通性与写隔离（返回 200 与 405）
ssh macserver-ts "/path/to/verify.sh 18765"
```

### B. 恢复原状态方案（Rollback，遇任何异常一键执行）
```bash
# 1. 执行回退脚本
ssh macserver-ts "/path/to/uninstall.sh"

# 脚本自动执行：
# a. launchctl bootout gui/501 ~/Library/LaunchAgents/com.muse.macserver-eventkit.plist
# b. rm -f ~/Library/LaunchAgents/com.muse.macserver-eventkit.plist /Users/shared/bin/EventKitBridgeServer
# c. tccutil reset Reminders com.muse.macserver-eventkit
# d. 确认端口 18765 彻底释放
```

---

## 八、零变更与合规声明

- 本轮所有实机核查均为 **100% 只读**，未在 MacServer 上创建任何文件、未启动任何后台常驻进程。
- **真实 Apple 数据调用**：0 次。
- **生产服务变更**：0 次。
- **Seoul 网关修改**：0 次。
- GitHub PR 状态：[PR #20](https://github.com/gehbfarr5/insurance-autonomous-work-system/pull/20) 与 [PR #21](https://github.com/gehbfarr5/insurance-autonomous-work-system/pull/21) 保持 **OPEN**，等待后续指令。
