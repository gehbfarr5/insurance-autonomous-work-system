# AG-02 / AG-04 试运行与恢复回执汇总

- **归档日期**：2026-11-08
- **归档 PR**：[PR #21](https://github.com/gehbfarr5/insurance-autonomous-work-system/pull/21) & [PR #22](https://github.com/gehbfarr5/insurance-autonomous-work-system/pull/22)
- **目标宿主**：Intel MacServer (`100.100.172.91`, macOS 15.7.7) & Seoul MCP (`100.82.240.43`, Ubuntu 24.04)

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

## 四、AG-04 生产只读试运行与基线恢复回执 (`AG04_TRIAL_AND_RECOVERY_RECEIPT.json`)

经用户显式变更授权，执行 AG-04 限时受控只读生产试运行与独立恢复：
1. **真实链路技术验证 (`REAL_LINK_READONLY: PASS`)**：
   - 验证 MUSE 客户端脚本 → Seoul MCP → 受限反向 SSH 隧道 → MacServer EventKit → iCloud 真实只读测试列表全链路；
   - 发现并定位 1 条核准测试列表（脱敏标识：`9D9A****03F3`，名称：`M****试`，`writable: false`）；
   - 读取该测试列表条目返回 0 条（干净的空列表）；
   - 写入防护：`writes_enabled=False` 全程保持，零写入、零写探针。
2. **MUSE 独立验收状态判定 (`MUSE_INDEPENDENT_ACCEPTANCE: PENDING_MUSE_UI_EVIDENCE`)**：
   - 本次执行由客户端 Python 脚本发起，缺乏 MUSE 原生 UI 对话交互证据；
   - 依据交付规范，严格判定真实链路通过、MUSE 独立 UI 验收证据待补。
3. **网络与临时变更审计**：
   - 记录因 Tailscale ACL 策略采用 MacServer → Seoul 反向 SSH 隧道；
   - 临时宿主配置（`GatewayPorts clientspecified`）与公钥限制已在验收完成后 100% 还原；
   - 端口 18765 监听完全注销，临时密钥已销毁。
4. **确定性基线恢复**：
   - Seoul 容器恢复至基线镜像 `sha256:f3e697fe266f58910c01985f9c906a84479705846c88fd7d2ea1ccf12c0da2f0`；
   - 健康检查通过（200 OK）；MacServer 业务锁定恢复（403 PERMISSION_DENIED）；
   - OAuth Token 仓库完好保留，Contacts/Calendar 权限与基线一致。

---

## 五、AG-05 隔离集成、编排恢复与安全边界回执

1. **隔离集成回执 (`AG05_ISOLATED_INTEGRATION_RECEIPT.json`)**：
   - 验证 Fake Store 隔离环境只读契约、空列表处理及 schema 对应（`session_id` / `list_ids`）。
   - 证明 Universal Binary（x86_64 + arm64）离线启动与回环安全性。
2. **编排恢复 13 项演练回执 (`AG05_ORCHESTRATED_RECOVERY_RECEIPT.json`)**：
   - 全部 13 项恢复场景 100% 通过：
     - 本地业务权限持久化关闭与 403 断言；
     - 本地绝对期限崩溃韧性与看门狗自动恢复；
     - 跨机断网 UNKNOWN 故障聚合与非零退出保证；
     - 任务进程清理零附带损伤；
     - 并发恢复互斥与失败传播；
     - SSH 配置恢复保真度（新增删除、既有保留、自定义路径）；
     - 未配置安全屏障与容器停止失败安全屏障；
     - 进程精确归属与本地恢复状态持久化追溯。
3. **安全边界负向验证回执 (`AG05_SAFETY_BOUNDARY_RECEIPT.json`)**：
   - 全部 5 项负向安全测试 100% 通过：
     - `authorized_keys` 备份失败在任何生产变更前阻断部署；
     - 目标授权路径无法确定时拒绝部署，坚决不猜测当前用户 `~/.ssh/authorized_keys`；
     - Docker inspect 失败／空状态／unknown 严格阻止配置覆盖与基线启动；
     - PID 文件指向同名无关进程：核验启动身份与配置目录，零附带损伤；
     - `watchdog.pid` 指向无关进程或期限不一致：拒绝复用，防止生命周期混乱。
4. **最终交付全流程验收回执 (`AG05_FINAL_DELIVERY_ACCEPTANCE_RECEIPT.json`)**：
   - 从干净检出验证 3 条最终生命周期路径 100% 通过：
     - **最终启动**：无期限隔离启动进入正常监督循环，4 层健康状态 `HEALTH: OK`，反向端口转发就绪；
     - **到期关闭**：受限启动建立看门狗，4 秒绝对期限到期后自动将 `bridge.env` 业务开关置为 `false`，业务端点断言 HTTP `403`，Supervisor 干净退出；
     - **人工停止**：运行中调用 `tunnel-ctl.sh stop`，Supervisor、SSH 子进程与看门狗全部终止，`tunnel.lock` 锁目录与 `tunnel.pid` 彻底删除，零残留进程与文件。

---

## 六、项目硬边界保持

- **PR 状态**：PR #20、PR #21、PR #22 与 PR #23 严格维持 **OPEN** 未合并。
- **只读边界**：生产试运行已彻底关闭，禁止私自重启隧道或开启 Bridge。
- **受限备份**：生产快照留在本地宿主机，禁止上传或提交至公开仓库。

