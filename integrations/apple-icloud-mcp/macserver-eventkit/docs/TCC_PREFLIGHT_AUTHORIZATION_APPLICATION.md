# MacServer EventKit TCC 授权前置就绪申请

- **申请编号**：RFC-20261109-AG06-TCC-PREFLIGHT-AUTH
- **申请性质**：**零业务接触、零网络隧道、纯本地受限产物安装与前台 TCC 授权核验**
- **当前状态**：待总控审查授权 (PENDING REVIEW AND APPROVAL)
- **解耦策略**：将 TCC 权限打通与 MUSE 30 分钟业务只读窗口严格解耦。先通过本申请确保 MacServer 本地 TCC 授权 100% 就绪，再开启业务验收窗口，杜绝在业务窗口内耗费时间排障授权。

---

## 一、本次申请操作范围与 4 项安全铁律

| 检查项 / 维度 | 申请执行范围 | 安全隔离铁律 |
| :--- | :--- | :--- |
| **业务开关状态** | `EVENTKIT_BRIDGE_PRODUCTION_AUTHORIZED=false` | **全程保持 false**，严禁开启业务开关 |
| **数据访问边界** | 仅调用 `--request-authorization` 与 `--check-authorization` | **严禁查询任何真实列表或条目内容**，严禁触发 `/reminders/lists` |
| **网络与隧道边界** | 不启动 `run-resident-tunnel.sh` | **严禁建立反向 SSH 隧道**，Seoul 18765 维持关闭 |
| **Seoul MCP 容器** | 维持基线镜像 `sha256:f3e697fe...` | **严禁部署 Seoul 候选容器**，保持生产稳定 |

---

## 二、准确交付产物规格矩阵

| 属性 | 规格值 | 验证依据 |
| :--- | :--- | :--- |
| **构建产物路径** | `integrations/apple-icloud-mcp/macserver-eventkit/.build/release/EventKitBridgeServer` | 源码通过 `scripts/build-and-sign-universal.sh` 构建 |
| **Universal SHA256** | `f78e24e533c2bf9a77161dc05eb154ce99687de9a5b881ad481bfbe2bbfb3074` | `shasum -a 256` 确定性校验 |
| **架构支持** | Mach-O Universal Binary (`x86_64` + `arm64`) | `lipo -info` 确认 |
| **最低系统要求** | macOS 14.0 (minos 14.0, sdk 14.0) | `otool -l LC_BUILD_VERSION` |
| **代码签名标识** | `com.muse.macserver-eventkit` | embedded CodeDirectory |
| **Hardened Runtime** | 激活 (`flags=0x10002(adhoc,runtime)`) | `codesign -dvvv` |
| **x86_64 切片 CDHash** | `a25782f93277e3d6f965a3fab1a72e8ea1569a34` | Intel MacServer 实际加载切片 |
| **arm64 切片 CDHash** | `f00641aa5ddebd8cb2c6aa9d7eeb9d141396a61b` | M5 Host / Apple Silicon 切片 |
| **Embedded Info.plist** | 两个切片均包含 `__TEXT,__info_plist` | 包含 `NSRemindersUsageDescription` 与 `NSRemindersFullAccessUsageDescription` |
| **多架构签名门禁** | `codesign --verify --strict --all-architectures` | ✅ **PASS (Exit code 0)** |

---

## 三、目标安装路径、原子备份与回滚方案

1. **目标安装路径**：
   - 目标路径：`/Users/shared/bin/EventKitBridgeServer`
   - 文件权限：`0755`，属主：`jin:staff`
2. **原子快照备份**：
   在部署新二进制前，执行本地备份：
   ```bash
   cp -a /Users/shared/bin/EventKitBridgeServer /Users/shared/bin/EventKitBridgeServer.bak.$(date +%s)
   ```
3. **回滚预案 (Rollback SLA < 1 分钟)**：
   若前台授权受阻或用户拒绝授权：
   - 还原旧二进制文件：
     ```bash
     cp -a /Users/shared/bin/EventKitBridgeServer.bak.<timestamp> /Users/shared/bin/EventKitBridgeServer
     ```
   - 确保 `bridge.env` 保持 `EVENTKIT_BRIDGE_PRODUCTION_AUTHORIZED=false`。
   - 重启 LaunchAgent，验证 `/health` 200 OK 及业务 403 锁定。

---

## 四、受支持的用户前台操作与核验步骤

经总控授权后，按以下 4 步执行：

### 步骤 1：部署新二进制（管理员执行）
将 Universal Binary（SHA256: `f78e24e5...`）复制并替换至 `/Users/shared/bin/EventKitBridgeServer`，核验 SHA256 一致。

### 步骤 2：用户前台触发授权（用户在 Aqua GUI 会话执行）
在 MacServer 活跃图形会话（`gui/501`）的 Terminal 窗口中运行：
```bash
/Users/shared/bin/EventKitBridgeServer --request-authorization
```
**系统响应**：
macOS Sequoia 弹出原生权限申请窗口：
> **“EventKitBridgeServer”想要访问您的提醒事项**  
> *MUSE MacServer requires read-only access to Reminders to inspect allowed reminder lists.*  
> `[不允许]` | `[允许完全访问]`

### 步骤 3：用户交互确认
用户在前台弹窗中点击 **【允许完全访问】**。
命令返回：
```
[EventKitBridge] Authorization GRANTED by user.
```
（退出码 `0`）。

### 步骤 4：授权状态确定性只读断言
执行无副作用的授权状态查询命令：
```bash
/Users/shared/bin/EventKitBridgeServer --check-authorization
```
**判定准则**：
- 预期输出：
  ```json
  {"authorization_status":"authorized","authorized":true}
  ```
- 退出码严格为 `0`。

---

## 五、完成后的状态与第二阶段准入

1. **本次申请终态**：
   - TCC 权限状态确认变为 `authorized`；
   - 业务读取开关继续保持 `false`；
   - 生产环境无对外监听、无网络隧道、无任何 Apple 数据被读取。
2. **第二阶段准入**：
   本次前置授权成功后，再由总控审批启动 MUSE 前台 30 分钟只读业务验收窗口（RFC-20261108-AG05-LIMITED-READONLY-WINDOW）。
