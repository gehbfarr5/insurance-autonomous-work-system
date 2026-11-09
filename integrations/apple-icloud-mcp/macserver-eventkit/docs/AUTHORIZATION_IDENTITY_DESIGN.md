# MacServer EventKit 授权身份方案与 TCC 契约设计

- **组件**：`EventKitBridgeServer` (`macserver-eventkit`)
- **适用平台**：macOS 14.0+ / macOS 15.x Sequoia (Intel x86_64 及 Apple Silicon arm64)
- **文档版本**：v1.0 (2026-11-09)
- **安全基准**：严格遵循 macOS TCC 权限模型，严禁修改/重置/绕过 TCC 数据库，严禁复制旧授权或伪造签名身份。

---

## 一、稳定应用身份定义 (Application Identity Specification)

为确保 macOS 系统与 TCC 数据库能够稳定识别程序身份，并符合 macOS Sequoia 安全合规要求，构建产物统一采用以下身份规范：

| 属性 | 规范值 | 机制与载体 |
| :--- | :--- | :--- |
| **Bundle Identifier** | `com.muse.macserver-eventkit` | 嵌入 Mach-O 的 `__TEXT,__info_plist` 及 CodeDirectory |
| **Executable Name** | `EventKitBridgeServer` | 交付二进制名称 |
| **Display Name** | `MUSE EventKit Bridge Server` | `CFBundleDisplayName` |
| **Info.plist 载体** | Mach-O 嵌入节区 `__TEXT,__info_plist` | 通过 `-Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist` 静态固化至二进制 |
| **Reminders 用途说明** | `NSRemindersUsageDescription` & `NSRemindersFullAccessUsageDescription` | 提示用户：“MUSE MacServer requires read-only access to Reminders to inspect allowed reminder lists.” |
| **签名标识与选项** | `codesign -s - --identifier com.muse.macserver-eventkit --options runtime --force` | Ad-hoc Hardened Runtime (`0x10002`) |
| **Designated Requirement** | `# designated => cdhash H"<arm64_cdhash>" or cdhash H"<x86_64_cdhash>"` | 系统基于 Mach-O 切片 CDHash 自动生成 DR 规则 |

---

## 二、当前签名条件与重新授权机制分析

### 1. 为什么更新二进制后需要重新授权？
- **当前开发与部署环境限制**：本项目当前采用由系统本地生成的 Ad-hoc 签名（`Signature=adhoc`），未配置 Apple 官方受信任开发者组织证书（`TeamIdentifier=not set`）。
- **macOS TCC 的代码识别机制**：
  - 当二进制具备有效的 Apple Developer Team ID 时，TCC 的 Designated Requirement 规则为 `identifier "com.muse.macserver-eventkit" and anchor apple generic and certificate leaf[subject.OU] = "<TEAM_ID>"`。在此模式下，二进制重新编译更新后，由于 Team ID 不变，系统会延续既有授权，无需用户再次确认。
  - **但在 Ad-hoc 签名条件下**，系统生成的 Designated Requirement 严格绑定特定切片的 **CDHash**（即代码内容的 SHA-256 哈希值）。
  - 因此，任何导致代码或构建产物变动的操作（包括代码修改、编译选项调整、重新打包 lipo 等），均会生成全新的 CDHash。
  - 当 macOS 内核与 TCC 守护进程（`tccd`）加载该新二进制时，检测到该 CDHash 在 `TCC.db` 中无匹配条目，必然判定权限状态为初始未确定态：
    ```json
    {"authorization_status":"notDetermined","authorized":false}
    ```
    （退出码为 `2`）。

### 2. 严禁的歧途与安全红线
为维持系统安全完整性，以下行为属于绝对禁止的违规操作：
- **严禁直接修改或注入 `~/Library/Application Support/com.apple.TCC/TCC.db`**：在启用了 SIP（System Integrity Protection）的 macOS 系统上，外部直接写 TCC 数据库被内核拦截；强行篡改会损坏数据库完整性。
- **严禁使用 `tccutil reset Reminders`**：重置会导致用户合法授权记录丢失。
- **严禁从旧二进制提取伪造旧 CDHash 或旧签名**：这会导致代码签名校验失败（`CSSMERR_TP_NOT_TRUSTED` / `code has been modified`），直接被 Gatekeeper 拦截并导致 SIGKILL。

---

## 三、用户需要完成的最小前台操作 (Minimal Foreground User Actions)

在正式验收窗口开启期间，当新构建的 Universal Binary 部署至 MacServer 后，系统处于受支持的合法前台用户授权流程：

### 流程说明
1. **前置条件**：
   - 部署最新的 Universal Binary 至 `/Users/shared/bin/EventKitBridgeServer`。
   - 用户处于活跃的 MacServer 本地图形会话中（`gui/501`）。
2. **最小操作执行**：
   用户只需在本地终端（或通过前台交互提示）执行单条命令：
   ```bash
   /Users/shared/bin/EventKitBridgeServer --request-authorization
   ```
3. **系统行为响应**：
   - 二进制通过 embedded `Info.plist` 向系统发起 `EKEventStore.requestFullAccessToReminders`。
   - macOS Sequoia 原生弹出标准权限弹窗：
     > **“EventKitBridgeServer”想要访问您的提醒事项**  
     > *MUSE MacServer requires read-only access to Reminders to inspect allowed reminder lists.*  
     > `[不允许]` | `[允许完全访问]`
4. **用户交互**：
   - 用户点击 **`[允许完全访问]`**（或在 macOS 系统设置 -> 隐私与安全性 -> 提醒事项中勾选允许）。
5. **授权就绪校验**：
   - 执行快速只读状态核验：
     ```bash
     /Users/shared/bin/EventKitBridgeServer --check-authorization
     ```
   - 预期输出：
     ```json
     {"authorization_status":"authorized","authorized":true}
     ```
     （退出码 `0`）。
   - 此时 LaunchAgent 启动即可正常访问受限提醒事项元数据。

---

## 四、已证明缺陷与尚待真实环境验证行为的清晰界定

必须对技术认知保持严谨与客观，清晰区分**已知确定事实**与**现场待验证事实**：

| 分类 | 现象 / 机制 | 状态与证据 |
| :--- | :--- | :--- |
| **已证明的实际缺陷 1** | **Universal 产物 x86_64 切片签名缺失**：此前交付的二进制（`6b4a0b82...`）经 `lipo` 合并后未对 Universal 产物进行整包重签名，导致 `codesign --verify -vvv` 报错 `code object is not signed at all In architecture: x86_64`。 | ✅ **已证明并彻底修复**。全新构建流水线在 `lipo` 后执行签名，并通过 `codesign --verify --strict --all-architectures` 严格卡门禁。 |
| **已证明的实际缺陷 2** | **Mach-O 缺少 embedded `__info_plist`**：此前编译未链接 Info.plist，缺少 Reminders 用途说明。在 macOS Sequoia 上，无用途说明的二进制发起 TCC 请求会被系统立即静默拒绝。 | ✅ **已证明并彻底修复**。编译流水线使用 `-Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist` 将合规 Plist 固化在两个切片中。 |
| **尚待真实环境验证 1** | **macOS Sequoia GUI 弹窗交互响应**：在具备完整签名与 embedded Plist 后，在 MacServer `gui/501` 会话中执行 `--request-authorization` 时，macOS Sequoia 弹窗是否能够按预期即时呈现并在用户点击后平滑写入 TCC 授权。 | ⏳ **待真实环境验证**（需在批准的 30 分钟窗口内由用户在前台观察并确认）。 |
| **尚待真实环境验证 2** | **LaunchAgent 无头守护进程的权限继承**：通过前台 `--request-authorization` 获得授权后，由 launchd 以同一 UID（501）启动的后台守护进程能否稳定读取 Reminders 元数据而不受会话属性变动干扰。 | ⏳ **待真实环境验证**（此前 AG-02 在相同 launchd 模式下曾验证成功，新候选待窗口内复验）。 |
