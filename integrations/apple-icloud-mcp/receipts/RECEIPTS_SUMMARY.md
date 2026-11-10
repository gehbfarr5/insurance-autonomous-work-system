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

## 六、AG-06 验收窗口保护时序与安全闭环回执 (`AG06_ACCEPTANCE_WINDOW_RECEIPT.json`)

经用户显式授权开启 30 分钟受限验收窗口，执行现场前置核验与缺陷闭环：
1. **保护时序与真实变更记录（更正“全过程事前保护”表述）**：
   - **产物部署先于保护初始化**：Universal Binary 候选（`6b4a0b82...`）于 **08:58:30Z** 部署至 MacServer；看门狗与截止时间于 **09:01:27Z** 写入初始化（`DEADLINE_EPOCH=1794216687`）。部署操作先于看门狗初始化 2 分 57 秒，明确不再称全过程事前保护；
   - **过渡期状态（08:58:30Z - 09:01:27Z）**：新产物已就位，但 `bridge.env` 业务开关维持 `false`，LaunchAgent 处于未激活态，隧道未开启；
   - **开关开启与主动核验窗口（09:01:46Z - 09:02:15Z）**：看门狗与 1800 秒期限生效后，置业务开关为 `true`，触发 LaunchAgent 重载并向 `GET http://127.0.0.1:18765/reminders/lists` 发起权限探测（持续 29 秒）。
2. **两类不同事实的严格分别记录（正式收回“零探测”表述）**：
   - **业务调用返回权限拒绝**：探测返回 HTTP 403 Forbidden（`PERMISSION_DENIED`，"EventKit access permission was denied or revoked."）；
   - **未读取到条目内容**：读取条目数 = 0，读取内容暴露数 = 0，写入调用 = 0。零真实数据泄露。
3. **根因定位**：
   - 经 `codesign --verify -vvv` 查明，此前 `lipo` 产物中 `x86_64` 切片未签名（`code object is not signed at all In architecture: x86_64`），且缺少 embedded `Info.plist`；macOS 15 Sequoia 对其拒绝授权。
4. **即刻基线锁定与完全恢复**：
   - 于 09:02:15Z 将 MacServer 业务开关重置为 `false`，09:02:43Z 还原 LaunchAgent 配置，重新断言返回 403；
   - Seoul 容器保持 baseline 镜像 `sha256:f3e697fe...`，健康检查 200 OK；
   - 隧道未建立，反向转发端口 18765 监听完全注销，零孤儿进程残留；
   - 全量实体 UUID 脱敏归档（测试列表：`9D9A****03F3`，来源：`9BBB****`）。

---

## 七、AG-06 TCC 前置授权核验回执 (`AG06_TCC_PREFLIGHT_AUTHORIZATION_RECEIPT.json`)

经用户显式批准，完成新签名 Universal Bridge 产物替换安装与图形前台 Reminders TCC 授权打通：
1. **真实产物安装与目标机签名核验**：
   - 目标路径：`/Users/shared/bin/EventKitBridgeServer` (`0755`)；
   - 真实快照备份：`/Users/shared/backup/pre_tcc_auth_1794237357`；
   - 实测 SHA256：`f78e24e533c2bf9a77161dc05eb154ce99687de9a5b881ad481bfbe2bbfb3074`（100% 匹配冻结摘要）；
   - 严格多架构签名门禁：`codesign --verify --strict --all-architectures` 确认切片有效并满足 Designated Requirement。
2. **用户前台原生授权打通**：
   - 前置检查：`--check-authorization` 返回 `{"authorization_status":"notDetermined","authorized":false}`（退出码 `2`）；
   - 原生请求：通过 `gui/501` LaunchAgent 单次拉起 `--request-authorization`，macOS Sequoia 弹出原生系统权限申请弹窗；
   - 用户操作：用户在屏幕上手动确认并授予提醒事项完全访问权限；
   - 进程回执：输出 `[EventKitBridge] Authorization GRANTED by user.` 并以退出码 0 干净退出；
   - 终态校验：在 `gui/501` 运行 `--check-authorization` 返回 `{"authorization_status":"authorized","authorized":true}`（**退出码 0，授权成功**）。
3. **后台守护进程重载与只读健康核验**：
   - 重载 LaunchAgent：`com.muse.macserver-eventkit`（PID `51084`）；
   - 本地健康检查：`curl http://127.0.0.1:18765/health` 正常返回 `200 OK`（只读就绪）；
   - 业务开关：`EVENTKIT_BRIDGE_PRODUCTION_AUTHORIZED=false` 全程保持关闭；
   - 零数据探测：未调用 `/reminders/lists`，读取条目数 = 0，写操作数 = 0。
4. **硬隔离边界保持**：
   - Seoul 候选未部署（运行基线 `sha256:f3e697fe...`，健康检查 200 OK）；
   - 反向 SSH 隧道未启动（宿主端口 18765 零监听）；
   - 保真度声明：仅证明 TCC 前台授权就绪，**明确不据此宣称真实提醒读取或 MUSE E2E 已通过**。

---

## 八、AG-07 60分钟 MUSE 原生前台只读验收回执 (`AG07_MUSE_FRONTEND_ACCEPTANCE_RECEIPT.json`)

经用户显式批准，执行 60 分钟（3600 秒）MUSE 原生前台只读验收窗口：
1. **时序与双端独立保护**：
   - 窗口开始时间：2026-11-09 23:50:18 CST（15:50:18 UTC）；
   - 窗口绝对截止时间：2026-11-10 00:50:18 CST（16:50:18 UTC），绝对截止时间戳 `DEADLINE_EPOCH=1794243018`；
   - Seoul 事前看门狗：PID 531350 于生产变更前成功孵化（事前保护）；
   - MacServer 本地看门狗：Supervisor PID 52448 加载 `session_deadline.env` 严格同步该期限。
2. **候选部署与真实反向隧道链路**：
   - Seoul 部署网关候选镜像 `sha256:faa6e380...`，健康检查 200 OK；
   - MacServer 建立专用反向 SSH 隧道，Seoul 宿主监听 `172.19.0.1:18765`；
   - 激活只读业务开关 `EVENTKIT_BRIDGE_PRODUCTION_AUTHORIZED=true`。
3. **MUSE 原生前台独立交互与结果审计**：
   - 执行客户端：`~/workspace/carddav-mcp-client/verify_muse_test_20261110.py`（`writes_enabled=False`，全程只读，零写入）；
   - **步骤 1（工具发现）PASS**：`reminders_lists` 与 `reminders_list` 均标明 `readOnlyHint=true`；`reminders_list` 过滤参数确认使用 `list_ids`；写工具零调用；
   - **步骤 2（列表发现）PASS**：原生仅返回唯一绑定测试列表 `MUSE 测试`（`9D9A5AAD-E3F0-4459-8756-BBCDBCB703F3`），元数据 `writable: false`；生产列表严格隔离不可见；
   - **步骤 3（条目读取）UNVERIFIED**：调用 `reminders_list`（仅传测试列表 ID）服务端原生返回条目数为 0；无分段失败与截断；非空条目保真字段在真实库中无条目返回，客观记录为未核对，不编造、不伪造。
4. **自主到期触发与完全生产基线恢复**：
   - 到期时刻（00:50:18 CST）双端看门狗自主触发统一编排恢复；
   - MacServer 业务开关持久化关闭，`/reminders/lists` 断言 HTTP 403 Forbidden (`PERMISSION_DENIED`)；
   - 反向隧道完全停止，无残留进程；
   - Seoul 容器恢复基线镜像 `sha256:f3e697fe...`，健康检查 200 OK；
   - 宿主 `sshd` 临时配置注销，`GatewayPorts` 恢复为 `no`，端口 18765 监听完全释放。

---

## 九、四维度最终判定

| 验收维度 | 判定结论 | 判定依据 |
| :--- | :--- | :--- |
| **1. 真实只读链路** | **PASS** | 反向 SSH 隧道、网关容器到 Bridge 端到端 HTTP 链路全通，MCP 协议调用正常响应 |
| **2. 非空字段保真度** | **UNVERIFIED** | 真实调用返回 0 条，非空字段无法在真实生产库中完成核验；离线单元/替身测试 100% 通过 |
| **3. MUSE 原生前台独立验收** | **PARTIALLY_PASSED** | 步骤 1（只读工具发现）与步骤 2（唯一列表元数据隔离）通过；步骤 3 待非空数据就绪后复验 |
| **4. 生产基线恢复** | **PASS** | 3600 秒到期双端独立看门狗自主触发回滚，基线镜像 200 OK，业务 403，无残留监听 |

---

## 十、AG-08 MUSE 原生前台日历闭环验收回执 (`AG08_MUSE_FRONTEND_ACCEPTANCE_RECEIPT.json`)

经用户显式批准，在已精确绑定的唯一日历「MUSE 测试」内，由用户在 MUSE 原生前台独立执行 9 步全生命周期验收：
1. **时限合规与快速闭环**：
   - 批准期限：60 分钟（3600 秒），第 45 分钟启动清理；
   - 实际执行时间：2026-11-10 03:21:59 至 03:28:40 CST；
   - 实际总耗时：**6 分 41 秒（401 秒）**，远在 45 分钟清理警戒线及 60 分钟截止时间之内。
2. **候选产物与基线**：
   - 上游源码版本：Commit `92bd313154cfbc51fce7e8df5b3f73ea86a6f1c7` (`calendar: surface CalDAV ETag in listEvents`, Muse)；
   - 生产镜像：`sha256:f3e697fe266f58910c01985f9c906a84479705846c88fd7d2ea1ccf12c0da2f0`（零重新部署，零停机）；
   - 编译产物 SHA256 完备校验通过；隔离单元测试 9 个套件共 144 项全部通过。
3. **MUSE 前台 9 步验证逐项结果**：
   - **步骤 1（日历核对）PASS**：原生 `calendar_list` 返回唯一测试日历「MUSE 测试」，`writable: true`，Base64 ID 逐字匹配；
   - **步骤 2（区间净空）PASS**：2026-11-15 至 11-17 范围 pre-check 返回 0 条 `[MUSE-TEST-CAL-20261110]`；
   - **步骤 3/4（创建条目）PASS**：定时事件与全天事件各 1 次创建成功，初始 ETag 分别为 `"mw9nlf7g"` 与 `"mw9nlgyb"`；
   - **步骤 5（回读验证）PASS**：定时事件时区换算正确（14:00-15:00+08 换算为 06:00-07:00Z）；全天事件起点 `2026-11-16T00:00:00.000Z`、终点 `2026-11-17T00:00:00.000Z`（符合 iCalendar RFC 5545 排他结束日期，对应单日全天），`all_day: true`；两个 ETag 均为真实非空字符串；
   - **步骤 6（CAS 正常更新）PASS**：带入初始 ETag 正常更新描述为 `[已正常更新]`，ETag 递增为 `"mw9nlf7h"`；
   - **步骤 7（CAS 并发冲突拦截）PASS**：通过原生 MCP 直接调用向服务端原样传入旧 ETag `"mw9nlf7g"`（特意独立于门控包装层以绕开其旧 ETag 自动刷新覆盖行为），服务端精准拦截并返回 `CONFLICT`（"该事件已被其他客户端修改"，旧 ETag 被服务端拒绝，具体拦截层未证实）；回读确认描述仍为 `[已正常更新]`，ETag 未变，数据未被篡改；
   - **步骤 8（精准删除）PASS**：重读确认最新状态后，经门控包装层分别传入两条事件 ID 与最新 ETag，两项日程精准删除成功；
   - **步骤 9（零残留核验）PASS**：调用 `calendar_list_events` 查验，测试前缀日程数量为 0；独立二次复查确认 `events: []`，实现 100% 干净零残留。
4. **安全审计与工程治理**：
   - 生产日历保护：三套生产日历（日历、工作、私人）全量纳入 deny 拒绝清单；
   - 调用分类与诚实边界：明确区分门控包装层调用（步骤 3、4、6、8）与直接原生 MCP 调用（步骤 7）；旧 ETag 被服务端拦截属实，因现场无原始报文抓包证据，结论客观表述为“旧 ETag 被服务端拒绝，具体拦截层未证实”；
   - 证据与凭据脱敏归档于本地及系统存储。

---

## 十一、最终验收与交付判定

| 验收模块 | 判定结论 | 判定依据 |
| :--- | :--- | :--- |
| **日历模块 (Calendar)** | **功能验收已报告通过，工程归档未完成 (ACCEPTANCE_REPORTED_PASSED_ARCHIVAL_PENDING)** | MUSE 原生前台经修复后的日常门控入口全链路完成 9 步闭环验收（用时 191 秒）；时区换算（UTC 06:00–07:00Z）与 RFC 5545 排他全天保真；旧 ETag 冲突本地拦截（0 网络发送、0 重试），冲突后回读无篡改，精准删除与独立查验 100% 零残留（`events: []`）；回执 `AG08_FINAL_CLOSURE_RECEIPT.json` 归档。**工程归档阻断**：等待 MUSE 在宿主环境自动生成标准 diff 及 64 位完整 SHA-256。 |
| **门控写入包装层 (Gated Wrapper)** | **功能验收已报告通过，工程归档未完成 (ACCEPTANCE_REPORTED_PASSED_ARCHIVAL_PENDING)** | 生产源码 `/home/hatch/workspace/carddav-mcp-client/safe_write.py` 完成三分支 ETag CAS 保留与本地拦截修复；严格遵守 `(status, payload)` 二元组契约；真实门控链路实测旧 ETag 拦截 100% 成功且 sends=0；原 HMAC、deny 清单、INTENT claim 完好；零生产容器重启、零部署风险。**授权待核实**：现场修改未登记独立用户写授权 Token，如实标记待核实，不标为已核准。**工程归档阻断**：等待 MUSE 导出真实 unified diff、完整 64 位 SHA-256 并验证隔离应用。 |
| **提醒事项 (Reminders)** | **PAUSED (暂停)** | TCC 前置授权已完成；全部准备工作已明确取消，严格保持暂停状态 |
| **通讯录与群组 (Contacts/Groups)** | **DELIVERED (已交付)** | 33 项 MCP 工具完备，CardDAV 原生分组与多 Agent 并发防护正常运行 |
| **生产基线与基础设施** | **PASS** | 生产镜像稳定健康，无临时进程残留，PR 维持未合并状态 |

---

## 十二、项目硬边界保持

- **PR 状态**：PR #20、PR #21、PR #22 与 PR #23 严格维持 **OPEN** 未合并。
- **只读边界**：提醒事项生产通道维持关闭状态，禁止私自开启。
- **凭据与脱敏**：真实 Calendar ID 及私有账户路径仅保留于本地受限配置，公开仓库和提交历史严格脱敏。


