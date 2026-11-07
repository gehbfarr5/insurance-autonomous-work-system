# AG-02 MacServer 试运行回执汇总（B1 安装回执与 B2 授权及元数据回执）

- **归档日期**：2026-11-07
- **归档 PR**：[PR #21](https://github.com/gehbfarr5/insurance-autonomous-work-system/pull/21) (`feat/macserver-eventkit-readonly` → `reconcile/icloud-source-baseline`)
- **归档 Commit 基线**：`97571d45e48b92608af122a628d74d3a744b82ec`
- **目标宿主**：Intel MacServer (`macserver-ts` / `100.100.172.91`, macOS 15.7.7 x86_64, `gui/501`)

---

## 一、B1 安装与服务生命周期回执 (`B1_INSTALL_RECEIPT.json`)

经用户显式授权，已在 Intel MacServer 上执行全新原子化安装：
1. **环境核验**：确认无既有冲突服务、端口 18765 干净可用、GUI 会话活跃。
2. **凭据部署**：生成 32 字节安全 Token，落地于 `~/.config/muse-macserver/bridge.env`（权限 `0600`，父目录 `0700`）。
3. **二进制与配置**：部署 `/Users/shared/bin/EventKitBridgeServer` (`0755`) 与 `~/Library/LaunchAgents/com.muse.macserver-eventkit.plist` (`0644`)。
4. **服务生命周期验证**：
   - `gui/501/com.muse.macserver-eventkit` 注册并正常运行 (`state = running`)；
   - `GET /health` 返回 `200 OK`（只读模式）；
   - `verify.sh --mode=unauthorized-check` 返回 `403 Forbidden` (`PERMISSION_DENIED`)；
   - 验证服务注销停止、端口释放及重新启动完全正常。

---

## 二、B2 TCC 授权与只读元数据回执 (`B2_TCC_AND_METADATA_RECEIPT.json`)

经用户显式授权，在 MacServer 图形会话完成 TCC 权限打通与只读元数据探测：
1. **TCC 系统授权**：
   - 在 `gui/501` 环境触发原生授权请求，用户在系统弹窗中点击允许；
   - 验证 Reminders 权限状态已就绪（`authorized: true`）。
2. **纯元数据探测**：
   - 临时置激活开关为 `true`，通过受限本地 Bearer Token 调用 `GET /reminders/lists`；
   - **内容隔离证明**：读取条目数 = 0，读取条目计数 = 0，写入调用 = 0；
   - **元数据发现（脱敏）**：发现 1 个列表（来源：`本地` / `local`，标题：`提****项`，标识：`3C8C****0D15`）；
   - **iCloud 来源**：发现 0 个 iCloud 同步源（确认系统设置中 Apple 账户的 Reminders 同步开关未开启）。
3. **即刻闭环与安全恢复**：
   - 遵循指令，因未发现可用 iCloud 源，立即关闭激活开关（`PRODUCTION_AUTHORIZED=false`）并重启服务；
   - 再次校验未授权拒绝机制生效（HTTP 403 `PERMISSION_DENIED`）。

---

## 三、状态更新：由“准入前零安装”转为“已受管安装、已授权、受限关闭”

- **过时状态纠正**：此前文档记录的“MacServer 零文件安装、零服务启动、零 TCC 授权”属于 AG-02 安装准入前的安全承诺。现已完成经过授权的全新安装与 TCC 授权流程。
- **最新准确状态**：
  - **安装状态**：已安装为受管 LaunchAgent (`gui/501/com.muse.macserver-eventkit`)，受限配置位于 `~/.config/muse-macserver/`。
  - **TCC 状态**：Reminders 授权已由用户确认赋予。
  - **Bridge 激活状态**：**关闭** (`PRODUCTION_AUTHORIZED=false`)，当前对外强制返回 403 `PERMISSION_DENIED`。
  - **硬边界维持**：真实 Apple 提醒条目内容读取 = 0，写入 = 0，生产修改 = 0，凭据轮换 = 0，Seoul 网关保持隔离，PR #20 与 PR #21 维持 OPEN 未合并。
