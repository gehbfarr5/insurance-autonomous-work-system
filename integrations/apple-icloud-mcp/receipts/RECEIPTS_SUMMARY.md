# AG-02 MacServer 试运行回执汇总（B1 安装、B2 授权元数据与 B3 绑定列表只读回执）

- **归档日期**：2026-11-07
- **归档 PR**：[PR #21](https://github.com/gehbfarr5/insurance-autonomous-work-system/pull/21) (`feat/macserver-eventkit-readonly` → `reconcile/icloud-source-baseline`)
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
2. **iCloud 同步打通**：
   - 用户在系统设置中开启 Reminders 同步；
   - 验证数据库底层同步就绪（`com.apple.Dataclass.Reminders: True`）。
3. **纯元数据探测**：
   - 临时置激活开关为 `true`，通过受限本地 Bearer Token 调用 `GET /reminders/lists`；
   - **内容隔离证明**：读取条目数 = 0，读取条目计数 = 0，写入调用 = 0；
   - **列表与测试列表定位**：发现 3 个 iCloud 来源列表，锁定专用测试列表 `M****试`（脱敏标识：`9D9A****03F3`），并写入本地受限配置 `bridge.env` (`0600`)。
4. **即刻闭环与安全恢复**：
   - 探测完成后立即将激活开关恢复为 `false` 并重启守护进程；
   - 再次校验未授权拒绝机制生效（HTTP 403 `PERMISSION_DENIED`）。

---

## 三、B3 绑定测试列表只读读取回执 (`B3_TEST_LIST_READ_RECEIPT.json`)

经用户显式授权，执行针对已绑定测试列表的单次只读读取验证：
1. **前置身份与绑定核查**：
   - 严格核验目标列表 ID (`9D9A****03F3`) 与来源身份 (`iCloud / calDAV`)，确认与此前元数据 100% 一致。
2. **单列表只读执行**：
   - 临时启用激活开关，仅调用 `GET /reminders/lists/9D9A****03F3/items`；
   - 严格限制：读取其他列表数 = 0，写入调用 = 0，创建测试数据 = 0。
3. **响应结构与真实状态核验**：
   - HTTP 状态码：`200 OK`；
   - 来源校验（SourceVerifier）：`PASSED`；
   - 响应结构：有效 JSON Array；
   - 是否为空：`true`（当前该测试列表内条目数为 0）；
   - **保真度声明**：列表为空状态已如实记录；由于实际条目数为 0，**明确不据此宣称字段级内容保真通过**；
   - 脱敏声明：零条目标题、备注或对象标识向外暴露。
4. **即刻闭环与双端点 403 复验**：
   - 执行完成后立即恢复激活开关为 `false`，并重启服务；
   - 实测复验双业务端点均强制返回 `403 Forbidden` (`PERMISSION_DENIED`)：
     - `GET /reminders/lists` -> 403 `PERMISSION_DENIED`
     - `GET /reminders/lists/{bound_list_id}/items` -> 403 `PERMISSION_DENIED`

---

## 四、项目硬边界保持

- **Seoul 主机与生产网关**：保持隔离，未做任何修改。
- **PR 状态**：PR #20 与 PR #21 维持 **OPEN** 未合并。
- **M5 实验环境**：保持原状，未执行退役。
