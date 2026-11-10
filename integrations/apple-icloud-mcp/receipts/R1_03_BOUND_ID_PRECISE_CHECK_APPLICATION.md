# R1-03 历史绑定 ID 精确核验（可执行方案 + 必要授权项）

- **任务**：REM-R1-01 后续，编号 **R1-03**，版本 **v3**（2026-11-11 CST）
- **申请方**：WorkBuddy（本专项唯一工程主执行 Agent）
- **前置判定**：R1 = `BLOCKED_TARGET_NOT_VISIBLE`（2026-11-10T14:45:13Z，枚举 HTTP 200、2 条、无目标）。R1 窗口已结束，不续期。
- **本文件性质**：**方案 + 已实现的离线工具**。除离线验证外**本轮不执行任何真实操作**——不连 MacServer、不部署、不重启、不开闸、不调用账户级枚举、不读取其他列表、不读取任何事项内容。
- **v3 的增量**：把 probe 真正接进开窗/关窗/看门狗的执行路径（§7.3），消解"禁止 bootout/bootstrap"与"改 plist 后重载"的表面冲突（§3.1），补齐申请所需的脚本/哈希/临时文件/期限/预算/恢复步骤（§7.4），并把四类失效场景的集成验证结果写清（§7.2）。
- **R2 仍不开启。**

---

## 0.0 版本修订

### v3 相对 v2（本轮）

| # | 审查意见 | 修订 |
| :--- | :--- | :--- |
| 6 | 把 probe 接进实际窗口、关闸与独立看门狗；整条路径不得调用 `/reminders/lists` | 新增 `r1_probe_window.sh`（§7.3.1）；`r1_gate.sh` / `r1_watchdog.sh` 加 `--list-id` 切到 probe 验证，并加 `--require-no-enumeration` **拒绝静默回退**到枚举模式（§7.3.2、§7.3.3） |
| 7 | 明确权威配置加载方式，消解"禁止 bootout/bootstrap"与"改 plist 后重载"的冲突 | 判定顺序写死为 **plist 优先 → config 文件次之 → 都没有则 open 拒绝**，重载方式随之二选一；§9 的排除项改为"不得用 bootout/bootstrap **做别的事**"，与单键重载不再互斥（§3.1） |
| 8 | 补针对性集成验证：正常关窗、主进程被杀、期限触发、恢复失败；记录全部请求，断言零账户级枚举 | 四类场景 + 预算触发共 6 组，39 项断言全绿；零枚举由**假桥的请求日志**逐条统计，不是自述（§7.2） |
| 9 | 补齐脚本、哈希、令牌及临时文件范围、绝对期限、开闸预算、恢复步骤 | 新增 §7.4，逐项给出脚本 sha256、临时文件清单与生命周期、`--window-seconds`/`--open-budget` 的取值与不变量、以及四条恢复路径 |
| 10 | 删除 R1-02 中工程方自行写入的"予以追认/不构成违规" | 已在 `R1_02_...md` §6.1 改为三行客观事实表，只记调用、返回、与申请文字的差异；不写判定词 |

### v2 相对 v1

| # | 审查意见 | 修订 |
| :--- | :--- | :--- |
| 1 | §8 设备归属错误 | 前版把**工程宿主**的观测当成 MacServer 现态。已改写为：历史基线取自 R1/P5 回执，**当前现态标为未核实**；删除"重新部署／服务卸载／pid 归零"三项无依据计划；恢复目标改为"**原有常驻服务健康 + 业务闸门关闭**"（§8） |
| 2 | 实现 probe 及隔离测试 | 已实现（v2.3.0），**不提供 `--allow-enumeration`**；URL 构造函数只能生成条目端点，枚举路径在结构上不可达；新增 72 项离线断言（§7.1、§7.2） |
| 3 | 开窗/关窗/恢复不得调用枚举 | 改为 `pre / open / post` 三相，全部只用同一个条目请求；闭闸验证靠**三层先后**区分 401 / 403 `LIST_NOT_ALLOWED` / 403 `PERMISSION_DENIED`（§3、§4.2） |
| 4 | 矩阵须以源码分支校验，区分源码事实与未实测行为 | 每行加**证据类别** S/T/U；新增 §4.1.1（源码事实 ≠ 冻结产物行为）与 §4.4（既有测试对照，并点名 `404` 是端到端缺口） |
| 5 | 非空事项不得自动触发后续动作 | `RESOLVED_WITH_ITEMS` 仅记录 `item_count` 后结束；回执 `follow_up.triggered` 恒为 `false`；删除"立即转入保真度比对"（§10） |

---

## 0. 三个问题的直接回答

| 你的问题 | 直接回答 |
| :--- | :--- |
| **会不会读取事项内容？** | **会——在一种分支上会。** 若目标 ID 能解析且 source 校验通过，服务端会执行 `predicateForReminders(in: [calendar])` 并把该列表的**事项（含备注、URL、日期）读进内存并回传**。这条分支在授权项里必须写明。另有两种**零内容读取**变体（§5.2、§5.3），代价是丢掉一个关键信号。 |
| **存在 / 不存在 / 权限拒绝怎么区分？** | 用**条目端点**的三个错误码区分：`404 LIST_NOT_FOUND` = ID 解析不到；`403 SOURCE_MISMATCH` = **ID 解析到了**但 source 身份不符（= 仍在、身份变了）；`403 PERMISSION_DENIED` = 卡在闸门/TCC，**这一项无法由响应自身消歧**。完整矩阵见 §4。 |
| **能不能说"服务端过滤 = 底层未枚举"？** | **不能。** 白名单只是**入口闸**，位置在 `calendar(withIdentifier:)` **之前**；一旦通过，EventKit 内部如何解析不为我们所见。本方案只主张"**请求只携带了目标 ID、服务端没有向 EventKit 索取其他列表**"，不主张"EventKit 底层没有扫过"。措辞边界见 §6.1。 |

---

## 1. 为什么这条路能给出 R1 给不出的信息

R1 用错了端点。`GET /reminders/lists` 是**账户级枚举**（`EventKitBridgeServer.swift:397-414`，该分支无任何白名单调用），它只能回答"枚举里有没有"，答不了"这个 ID 还认不认得"。

条目端点 `GET /reminders/lists/{listID}/items` 是目前**唯一**在不做账户级枚举的前提下，能判定某个绑定 ID 是否仍可解析的现有路径。它的判定链条是确定的（源码已逐行核对）：

| # | 位置 | 行为 | 失败时 |
| :--- | :--- | :--- | :--- |
| 1 | `EventKitBridgeServer.swift:368-373` | 非 GET 一律拒绝 | `405 WRITE_OPERATION_REJECTED` |
| 2 | `:375-382` | 服务端限流 | `429 RATE_LIMIT_EXCEEDED` |
| 3 | `:384-389` | 路由解析，失败回 `internalError("unknown route")` | **`404` + `INTERNAL_ERROR`**（注意：不是 `LIST_NOT_FOUND`） |
| 4 | `:418` | `authValidator.validate(requiredScope: .reminderRead)` | `401 AUTHENTICATION_FAILED` / `403 UNAUTHORIZED_SCOPE` |
| 5 | `:419` | `allowlistValidator.validate(listID:)` — **精确集合成员判定**（`AllowlistValidator.swift:38-43`） | `403 LIST_NOT_ALLOWED` |
| 6 | `ProductionEventKitStore.swift:136-146` | `isProductionActivated` + TCC 状态双 guard | `403 PERMISSION_DENIED` |
| 7 | `ProductionEventKitStore.swift:148-150` | `store.calendar(withIdentifier: listID)` | **`404 LIST_NOT_FOUND`** |
| 8 | `ProductionEventKitStore.swift:152-161` | `sourceVerifier.verify(listID:sourceID:sourceType:sourceTitle:)` | **`403 SOURCE_MISMATCH`**（绑定的 sourceID/type/title 任一不符或绑定缺失） |
| 9 | `ProductionEventKitStore.swift:162-164` | `_contentAccessCount += 1`；`predicateForReminders(in: [calendar])` | 超时 `504 TIMEOUT` |
| 10 | 回调 | 逐条映射 → `200` | — |

**第 7、8 两步的顺序是整个方案的支点**：解析先于校验，校验先于取内容。所以"解析得到 vs 解析不到"这件事，在**任何内容被读取之前**就已经变成一个可观测的 HTTP 状态码。

同一顺序在**两条路径**上各实现一遍且完全一致：HTTP 入口 `handleRawHttpRequest`（`:365-437`）与直调内存 seam `handle(method:path:credential:)`（`:440-475`）。因此上面的矩阵不是 HTTP 层的偶然产物，而是路由语义本身。

### 1.1 已确证的配置事实（复用 R1 产物，无需新操作）

R1 回执 `why_two_lists.behavioural_evidence` 与 `non_target_metadata.basis` 已记录：

```
allowed_list_count = 1
allowed_list_matches_target = true
binding_present_and_caldav_icloud = true
gate_source = launchd_env
```

配合 `BridgeConfig.validateForProduction()`（`:212-224`：每个白名单 ID 必须有非空绑定）可以推出：**白名单里恰好一个 ID，且它就是目标绑定 ID，且它有一条 calDAV/iCloud 绑定**。这带来两个直接后果：

1. 请求一旦越过第 5 步，**唯一可能被解析的 ID 就是目标**——这不是"我们把别的过滤掉了"，而是"请求里根本没有别的 ID"。
2. 由于绑定必然存在且 `requireExplicitBinding: true`（`main.swift:132`），第 8 步的 `SOURCE_MISMATCH` 只能来自**source 三元组实际值发生变化**，不能来自"绑定缺失"。这让 `SOURCE_MISMATCH` 成为一个强信号，而不是含糊的拒绝。

> 附带更正：`/health` 的 `store` 字段取值是 `config.useFakeStore ? "fake" : "production"`（`:284`），它区分的是 **PRODUCTION/TEST 模式**，**不是**闸门开合。现有 `r1_bridge_client.py` 的 `production_store_confirmed` 断言据此只能证明"不是 fake store"，不能被读成"闸门已开"。本方案不重复这个措辞错误。

---

## 2. 本方案要问的唯一问题

> **绑定的那个 `listID`（`9D9A****03F3`）在当前 EventKit store 里，还解析得到一个 calendar 吗？如果解析得到，它的 source 身份还是登记时的那一个吗？**

不恢复、不新建、不改绑定、不动 TCC、不做账户级枚举、不进「最近删除」。

---

## 3. 执行形态：三个阶段，4 次条目请求 + 1 次 health，一次枚举都不发

整个窗口（开窗 → 探测 → 关窗）**只用**两种 URL：`/health` 和 `/reminders/lists/{id}/items`。**没有任何阶段调用 `/reminders/lists`**，客户端也**不提供**绕过这一点的开关。

| 阶段 | 请求 | 目的 | 触达 Apple 数据 |
| :--- | :--- | :--- | :--- |
| **pre**（闸门关） | `GET /health` + `GET .../{CANARY}/items` + `GET .../{TARGET}/items` | ① 进程与 store 模式；② canary 证明白名单精确匹配；③ 目标得到 `403 PERMISSION_DENIED` = **闭闸基线成立**（见 §4.2） | 否（全部在 store 第一道 guard 之前返回） |
| **开窗** | ——（单键改值 + 重载） | 只改 `EVENTKIT_BRIDGE_PRODUCTION_AUTHORIZED` | —— |
| **open**（闸门开） | `GET .../{TARGET}/items` | 唯一一次真实探测 | **是**：第 7 步解析；若通过第 8 步则读该列表事项 |
| **关窗** | ——（改回原值 + 重载） | 恢复 | —— |
| **post**（闸门关） | `GET .../{TARGET}/items` | 必须回到 `403 PERMISSION_DENIED`，否则说明关窗没生效 | 否 |

`pre` 与 `post` 是**同一个请求、同一个判定**，一次开窗前后各跑一次，构成"窗口确实开过、也确实关回去"的闭环——**不需要枚举端点**，也不需要看任何列表清单。

`CANARY` 的价值：同一进程、同一令牌、同一时刻的对照。`TARGET` 得 `PERMISSION_DENIED` 而 `CANARY` 得 `LIST_NOT_ALLOWED`，差异只能来自白名单之后，即"目标确实在白名单里、请求确实进了 store"。

**请求预算**：3 次条目请求（pre: canary + target；open: target；post: target = 实际 4 次）+ 1 次 health。服务端与 store 共用同一个 `RequestLimiter`（`main.swift:137` 创建，`:156` 传入 store、`:167` 传入 server），每次条目请求消耗 **2 个令牌**；`rateLimitRPS=10` 下 4 次请求仍在容量内。出现 `429` 一律视为**无结论**，重试不超过 1 次。

### 3.1 权威配置源：一个键只有一处说了算，重载方式由它决定

前版存在一处表面矛盾：§9 的排除项写着"不得 `bootout`/`bootstrap`"，而 §7 又说"改 plist 后重载"。这不是两件事，是**同一个动作的两个部分**——`launchd` 不会重读已加载 job 的 `EnvironmentVariables`，改完 plist 只能靠 `bootout` + `bootstrap` 让它生效。矛盾来自前版把"禁止重装/卸载服务"和"重载配置"写成了同一条禁令。

实际规则如下，`r1_gate.sh:103-124` 按此实现，**没有任何隐式回退**：

| 情形 | 判定条件 | `source` | 生效值 | 重载方式 |
| :--- | :--- | :--- | :--- | :--- |
| plist 里有这个键且非空 | `plutil -extract ...EnvironmentVariables.EVENTKIT_BRIDGE_PRODUCTION_AUTHORIZED` 成功 | `launchd_env` | plist 的值 | `bootout` + `bootstrap`（唯一能让 plist 生效的方式） |
| plist 没有，config 文件里有 | `grep -E '^[[:space:]]*KEY[[:space:]]*='` 命中 | `config_file` | 文件的值 | `kickstart -k`（只重启进程，配置本就从文件读） |
| 两处都没有 | 以上皆否 | `absent` | —— | `open` 直接拒绝（exit 5）；`close` 只需证明端点已关 |

**优先级不是"谁更权威"，而是"程序实际读的是哪个"**：`BridgeConfig.load` 里 plist 的 `EnvironmentVariables` 覆盖 config 文件（`if mergedEnv[k] == nil || empty`），所以 plist 有值时文件里的同键**根本不参与**。`r1_probe_window.sh` 在 preflight 阶段把这一判定写进 `static_config.json` 的 `gate_source`，执行前就能看到这次会走哪条重载路径。

**边界因此收敛为**：允许 `bootout` + `bootstrap` **唯一且仅当**它的目的是让那一个键的新值生效；不允许用它来重装、换二进制、改绑定、改 label、改 `ProgramArguments`、清理环境。前者的证据是"plist 除该键外逐字节不变"（开窗前存 sha256、关窗后比对），后者的证据不存在，因此不做。

**保留原常驻服务**：整个过程不删除 plist、不 `disable` job、不换 label。窗口结束时服务仍是同一个 job、同一个 pid 族、同一个二进制，只有那个键从 `true` 回到 `false`。

---

## 4. 判定矩阵（这是本方案的核心交付物）

### 4.1 主矩阵

证据类别：**S** = 本轮读源码确认的分支；**T** = 仓库内既有测试已覆盖；**U** = 冻结产物上**尚未实测**。

| HTTP | `code` | 分类标签 | **能得出的结论** | **不能得出的结论** | 证据 |
| :--- | :--- | :--- | :--- | :--- | :--- |
| 200 | —（数组，长度 0） | `RESOLVED_IDENTITY_MATCH_EMPTY` | ID 解析成功；source 三元组与绑定一致；当前谓词查询返回 0 条 | ≠「列表为空」（见 §6.4）；≠「用户看得到」；≠「同步正常」 | S + T（`testRealHttpContentQuerySucceedsForLegitimateICloudList`）+ U |
| 200 | —（数组，长度 >0） | `RESOLVED_WITH_ITEMS` | 同上且非空 → **直接推翻"空列表"这一前提** | 不推翻"枚举里看不到"：两者可同时为真 | S + T（同上）+ U |
| 404 | `LIST_NOT_FOUND` | `NOT_RESOLVABLE` | `calendar(withIdentifier:)` 返回 nil → 该 ID 在**本机当前 EventKit store** 中不可解析 | ≠「已删除」；≠「账户里没有」；≠「不可恢复」；可能只是未同步落地 | S，**无 HTTP 端到端测试**（仅有 store 级与映射级单测，见 §4.5）+ U |
| 403 | `SOURCE_MISMATCH` | `RESOLVED_SOURCE_IDENTITY_CHANGED` | **ID 解析到了**；`sourceID`/`sourceType`/`sourceTitle` 三者至少一项与登记值不同 → 这是 R1 留下的"身份变化"假设的**直接证据** | ≠「内容完好」；≠「用户看得到」；不指出是哪一项变了（错误体已脱敏） | S + T（`testSourceRejectionMatrixZeroContentAccess`）+ U |
| 403 | `SOURCE_NOT_ALLOWED` | `ANOMALOUS_REACHED_UNEXPECTED_BRANCH` | 按源码此分支在 `requireExplicitBinding: true` 下**不可达**（`SourceVerifier.swift:70-80`）；但既有测试只断言"二者之一"，**没有把这一项钉死** | 出现即为配置/构建异常信号，**不得**当作任何列表结论；停止并报告 | S（推断）+ T（未钉死）+ U |
| 403 | `PERMISSION_DENIED` | `BLOCKED_PERMISSION_OR_GATE` | 请求已过第 4、5 步，被第 6 步拦下 | **不能**区分"闸门关闭"与"TCC 未授权/被撤销"——本方案唯一的不可消歧点，处理见 §4.3 | S + T（仅在枚举路径上：`HttpIntegrationTests:1175-1178`）+ U（条目路径） |
| 403 | `LIST_NOT_ALLOWED` | `BLOCKED_NOT_ON_ALLOWLIST` | 该 ID 不在**当前部署**的白名单里 → 配置未指向它 | ≠「列表不存在」。此项**必须**先修配置，否则任何存在性结论都无效 | S + T（`testRealHttpNonAllowlistedListRejected`，断言 222 行） |
| 401 | `AUTHENTICATION_FAILED` | `BLOCKED_AUTH` | 令牌无效（含引号/空白/权限问题） | 与列表状态无关 | S + T（`testRealHttpMissingAuthHeaderReturns401`、`testRealHttpInvalidBearerTokenReturns401`） |
| 429 | `RATE_LIMIT_EXCEEDED` | `BLOCKED_RATE_LIMIT` | 限流 | 与列表状态无关；不得重试超过 1 次 | S + T |
| 503 | `CONCURRENCY_LIMIT_EXCEEDED` / `STORE_RESOURCE_LIMIT_EXCEEDED` | `BLOCKED_BUSY` | 并发/预算闸 | 与列表状态无关 | S |
| 504 | `TIMEOUT` | `BLOCKED_TIMEOUT` | 回调查询超时（`callbackTimeoutSeconds`） | 解析是否成功**未知**；不得推断 | S + T |
| 404 | `INTERNAL_ERROR` | `ERROR_ROUTE` | 路由未匹配（`BridgeRoute.parse` 返回 nil） | **最容易误判的一项**：同为 404，但**与列表无关**。任何 404 必须同时看 `code` | S（`:384-389`） |
| — | 连接失败 | `ERROR_BRIDGE_UNREACHABLE` | 进程未运行/端口不通 | 与列表状态无关 | S（`http_get` 返回 0） |

**硬规则：只读状态码不读 `code` 会误判。** `404` 有两种含义，必须以 `code` 区分。

### 4.1.1 源码事实 ≠ 冻结产物的运行行为

矩阵全部来自**当前仓库源码**。冻结产物 `f78e24e5…3074` 是否由这份源码逐行构建，本轮**没有复核**；该二进制在条目端点上的实际状态码分布，除 R1 那次 `exit 20`（根本没发条目请求）外**没有任何实测**。因此：

- 矩阵可作为**判定口径**，不可作为"该二进制已验证如此"的断言；
- 执行时若出现矩阵里没有的组合，按 `ERROR_UNRECOGNISED_*` 记录并停止，**不向矩阵折中**；
- 回执里每条结论都带 `evidence_class: S|T|U`。

### 4.2 闭闸基线：三种拒绝必须分清

闭闸时的验证不能用枚举端点（`/reminders/lists` 会把闸门关闭与 TCC 拒绝混成同一个 403），只能**用同一个条目请求**，靠三层的**先后顺序**把它们分开：

```
① 认证 :418  →  ② 白名单 :419  →  ③ store 第一道 guard :136
   401            403 LIST_NOT_ALLOWED      403 PERMISSION_DENIED
```

三者互斥、可分辨、且都不接触 Apple 数据（②在 store 之前返回，③在解析之前返回）。

| 观测 | 含义 | 处理 |
| :--- | :--- | :--- |
| `401 AUTHENTICATION_FAILED` / `403 UNAUTHORIZED_SCOPE` | **认证失败**：连白名单都没到 | 先查令牌本身（引号、空白、0600），本次窗口不成立 |
| `403 LIST_NOT_ALLOWED` | **白名单拒绝**：认证过了，配置没指向这个 ID | 停止，先修配置；本次开窗无意义 |
| `403 PERMISSION_DENIED` | **权限拒绝**：认证、白名单都过了，卡在 store 第一道 guard | 这正是闭闸基线（闸门关 + 配置对），可以开窗 |
| `404` / `403 SOURCE_MISMATCH` / `200` | 已经越过闸门 | 说明窗口实际已经开着；`pre` 阶段出现即为异常，先查上一轮是否关闸 |

`CANARY`（必然不在白名单的合成 ID）用于同一时刻的对照：它应当**只**得到 `403 LIST_NOT_ALLOWED`。若 `CANARY` 也得到 `PERMISSION_DENIED`，说明白名单未生效，闭闸基线不成立。

这条基线还把"闸门关闭时 `PERMISSION_DENIED` 长什么样"钉成已知量，是 §4.3 消歧的前提。

### 4.3 唯一不可消歧点：`403 PERMISSION_DENIED`

`ProductionEventKitStore.swift:136-146` 两道 guard 抛出的是**同一个** `permissionDenied`，错误体也完全相同。因此**响应本身无法区分**：

- (a) `EVENTKIT_BRIDGE_PRODUCTION_AUTHORIZED` 未生效（闸门仍关 / 未重载）
- (b) TCC 未授权或被撤销

消歧手段（都不读取 Apple 数据）：

| # | 手段 | 能证明什么 | 局限 |
| :--- | :--- | :--- | :--- |
| 1 | `ps eww -p <pid>` 过滤后只取 `EVENTKIT_BRIDGE_PRODUCTION_AUTHORIZED=` 一行 | 该进程**实际环境**里闸门值 | 必须严格脱敏：只输出这一个键，令牌键一律丢弃；输出保存在证据目录且不含令牌 |
| 2 | 服务 stdout 启动两行：`Allowlisted List IDs: N` / `Registered Source Bindings: M`（`main.swift:124-125`） | N=1、M=1 → 白名单与绑定各恰好一条（不含 ID 本身） | 只证明配置规模，不证明闸门 |
| 3 | `ss`/`launchctl print` 取 pid 与加载状态 | 进程就是新加载的那个 | 不证明环境变量 |

**若 (1) 显示闸门为 true 而仍得 `PERMISSION_DENIED`**：结论写作 `BLOCKED_PERMISSION_DENIED_GATE_OPEN`，即"闸门已开，剩余原因为 TCC/授权或 store 未注入；未进一步区分"。**不得**写成"TCC 已被撤销"。

若 (1) 显示闸门为 false：结论写作 `BLOCKED_GATE_NOT_EFFECTIVE`，重载未生效，本次窗口作废。

### 4.4 既有测试能证明到哪一步（以及 404 这一格是缺口）

| 矩阵行 | 仓库内既有覆盖 | 覆盖层级 |
| :--- | :--- | :--- |
| 401 | `testRealHttpMissingAuthHeaderReturns401`、`testRealHttpInvalidBearerTokenReturns401` | HTTP 端到端 |
| 403 `LIST_NOT_ALLOWED` | `testRealHttpNonAllowlistedListRejected`（`:211`，断言在 `:222`） | HTTP 端到端 |
| 403 `SOURCE_MISMATCH` / `SOURCE_NOT_ALLOWED` | `testSourceRejectionMatrixZeroContentAccess`（`:254`）；同时断言 `contentAccessCount == 0`（`:283-286`） | HTTP 端到端，**但两个码"二者之一"，未区分** |
| 200（含非空） | `testRealHttpContentQuerySucceedsForLegitimateICloudList`（`:192`） | HTTP 端到端 |
| 403 `PERMISSION_DENIED` | `HttpIntegrationTests:1175-1178` | 只覆盖**枚举路径**，未覆盖条目路径 |
| 404 `LIST_NOT_FOUND` | `ErrorHandlingTests:70`（映射=404）、`:84-90`（store 抛该错） | **仅单元级；条目端点的 HTTP 端到端没有测试** |
| 405 / 429 / 504 | 有 | HTTP 端到端 |

两条必须写明的后果：

1. **`NOT_RESOLVABLE` 这一格是整个矩阵里唯一没有端到端测试的判定**。它的成立依赖"`:148` 抛错 → `httpStatus=404` → `errorBody.code=LIST_NOT_FOUND`"三段拼起来，三段各自有证据，但拼装没人测过。执行时若真的拿到 404，回执必须标 `evidence_class: S`，不得写成"已验证"。
2. `SOURCE_NOT_ALLOWED` 在源码上不可达这一条是**推断**，既有测试允许"二者之一"，所以它仍是推断。若真观测到它，按异常处理，不当作列表结论。

> 本轮**不补** Swift 测试：新增未运行的测试比没有测试更糟。该缺口登记在案，是否补、何时补，等你定。

---

## 5. 会不会读取事项内容——三种变体，请择一

### 5.1 变体 A：用真实绑定（推荐）

请求照 §3 发。若目标解析成功且 source 匹配 → 服务端读入该列表全部事项并回传 → 客户端**只落盘条数与摘要**，标题/备注/URL/日期一律不写盘、不打印。

- **得到**：完整三态（404 / `SOURCE_MISMATCH` / 200）
- **代价**：成功分支上确实读了该列表的事项内容（**仅这一条列表**）
- **为什么可接受**：目标列表是专用测试列表；读取范围就是它自己；证据只留计数与摘要；链路上只有 loopback

### 5.2 变体 C：哨兵绑定（零内容读取，但要改一个配置键）

把 `EVENTKIT_BRIDGE_BINDINGS` 里目标的 `sourceID` 换成一个**必然不匹配**的哨兵值（`validateForProduction` 只要求非空，能通过）。于是第 8 步**必定**失败：

- 404 → 解析不到
- `403 SOURCE_MISMATCH` → 解析到了（且**内容一次都没读**，因为 `_contentAccessCount += 1` 在第 8 步之后）
- `PERMISSION_DENIED` → 闸门/TCC

- **得到**：解析/不解析的二态判定，零内容读取
- **代价**：① 必须改一个配置键并在之后恢复；② **丢掉"身份是否变化"这个信号**——哨兵绑定下所有成功解析都会变成 `SOURCE_MISMATCH`，无法与真实的身份变化区分
- **"零内容读取"这句有测试支撑**：`testSourceRejectionMatrixZeroContentAccess`（`HttpIntegrationTests:254`）对四个 source 不符的列表逐一断言 `contentAccessCount == 0`（`:283-286`），即校验失败时确实一次都没进入取内容分支

### 5.3 变体 B：新增只读端点（最干净，但要改代码 + 部署）

新增 `GET /reminders/lists/{listID}/binding`：只做第 7、8 步，返回 `{resolved, source_matches, source_type_allowed}`，**永不调用** `predicateForReminders`。这样即使成功也不读内容，且三态全保留。

- **代价**：改源码 + 新增端点 + 重跑测试 + 重新部署；本次明确不允许部署，故只能作为 R1-04 的候选

> 我的建议：**变体 A**。它用现有二进制、现有端点、最少环节拿到最完整的三态；内容暴露被限定在一条你指定的测试列表上，且不落盘。若你要求"任何情况下都不读事项内容"，则选 **C**，我接受丢掉身份变化信号。

---

## 6. 措辞边界（写进回执的硬约束）

### 6.1 不能说"服务端过滤 = 底层未枚举"

白名单是**入参闸**，位置在 `calendar(withIdentifier:)` **之前**。它保证的是"**请求里没有第二个 ID、服务端没有向 EventKit 索取其他列表**"。EventKit 内部是否扫描、缓存、索引了账户内其他日历，**本方案不观测、不主张、不否认**。

正确写法：
> 本次仅对绑定 ID 发起了一次条目请求；未调用账户级枚举端点；服务端未向 EventKit 请求其他列表的元数据或内容。

错误写法（禁止出现）：
> 底层未枚举账户 / EventKit 只看到了目标列表 / 服务端已隔离其他列表。

### 6.2 `404 LIST_NOT_FOUND` ≠ 列表已删除

它只说明 `calendar(withIdentifier:)` 在当前 store 返回 nil。未排除：同步未落地、账户未登录、EventKit 缓存重建中、列表在别的设备/账户但本机无副本。

### 6.3 `403 SOURCE_MISMATCH` 不指明变了哪一项

错误体已脱敏（不含 ID、不含 source），所以只能说"三元组至少一项不符"，不能说是账户重登、改名还是类型变化。

### 6.4 `200` + 0 条 ≠ 列表为空

`predicateForReminders(in: [calendar])` 以该 calendar 自身限定（`ProductionEventKitStore.swift:164`），但：
- `calendar(withIdentifier:)` **不校验 entity type**——若该 ID 落在非提醒事项的日历上，谓词同样返回 0 条；
- 已完成/已删除的过滤行为由 EventKit 决定，本方案未观测。

所以 200+0 的准确表述是"**该 ID 解析成功、source 匹配、当前谓词查询返回 0 条**"。

### 6.5 不预设结果

不因预期"应该找不到"就把 404 写成"确认已删除"，也不因预期"应该在"就把 `SOURCE_MISMATCH` 写成"链路故障"。判定词只描述观测。

---

## 7. 复用与改动清单

| 产物 | 处置 | 说明 |
| :--- | :--- | :--- |
| `scripts/r1_bridge_client.py`（原 645 行 v2.2.0） | **已改** | 新增子命令 `probe`（`item_url` / `classify` / `apply_phase` / `cmd_probe`）；`--expect` 支持逗号分隔的**分类集合**（开窗需要接受 6 种"越过 guard"的标签）；`read_token()`、`http_get()`、`emit()`、`ensure_out_dir()`、`LOOPBACK_RE` 全部复用；版本升 **2.3.0** |
| `scripts/r1_gate.sh`（原 610 行） | **已改** | 加 `--list-id` / `--canary-id` / `--require-no-enumeration`；验证分 `probe` / `legacy_enumeration` 两种模式，无隐式回退；回执加 7 个 probe 字段（§7.3.2） |
| `scripts/r1_watchdog.sh`（原 178 行） | **已改** | 加同样三个参数并**转发给 `r1_gate.sh close`**；主进程已死时的关窗也不枚举（§7.3.3） |
| `scripts/r1_probe_window.sh` | **新增（364 行）** | R1-03 专用窗口：preflight → 静态核查 → pre → arm watchdog → open → close → disarm → summary（§7.3.1） |
| `scripts/r1_token_extract.sh`（137 行） | **未改** | 令牌单键提取，`24/24` 已通过；`probe` 沿用同一路径，未重跑 |
| `scripts/tests/fake_bridge.py` | **已改（仅测试夹具）** | ① 新增 `allowed_ids` 控制文件，**在闸门检查之前**执行精确匹配（镜像真实顺序 `:419` → `:136`）；② 新增 `item_status` 控制文件，按 listID 注入 `status`+`code`；③ 新增 `--request-log`，逐条记录 `{status}\t{command}\t{path}`；④ `items` 控制文件非对象时显式 500，避免夹具错误伪装成"桥不可达"。缺省时行为不变 |
| `scripts/tests/test_r1_probe.py` | **新增** | 72 项断言，覆盖矩阵 13 类 + 三相转换 + canary 异常 + 边界（§7.2.1） |
| `scripts/tests/test_r1_probe_window.sh` | **新增（324 行）** | 39 项断言，四类失效场景 + 零枚举统计（§7.2.2） |
| `scripts/tests/test_r1_bridge_client.py`（389 行） | **未改** | 夹具改了，回归一次：**63/63 仍通过** |
| `macserver-eventkit` 源码 / 二进制 | **不改** | 变体 A/C 均不需要改代码；变体 B 才需要（本轮不做） |
| R1 回执 `static_config` 四行 | **复用** | 作为"白名单恰含目标"的依据，不重复取证 |
| `com.muse.macserver-eventkit.plist.template` | **复用** | 单键开闸即改 `EVENTKIT_BRIDGE_PRODUCTION_AUTHORIZED`（`:385`） |

### 7.1 `probe` 子命令规格（已实现）

```
probe --endpoint http://127.0.0.1:18765 \
      --token-file <path> \
      --list-id <TARGET_ID> \
      --phase {pre|open|post} \
      --expect <classification> \
      --out <path> \
      [--canary-id R1-CANARY-00000000-0000-0000-0000-000000000000]
```

- **只可能发两种 URL**：`/health` 与 `/reminders/lists/{id}/items`。URL 由单一构造函数生成并做结构断言（路径必须是 5 段、第 1/2/4 段分别是 `reminders`/`lists`/`items`），**构造不出枚举 URL**。
- **不提供 `--allow-enumeration`**（前版列过，已删除）。枚举入口在 `probe` 这条路径上不存在，不是"默认关闭"，而是"没有"。
- **`--phase`** 决定同一次请求的解释：
  - `pre`：`403 PERMISSION_DENIED` → `GATE_CLOSED_AS_EXPECTED`（闭闸基线成立）；若出现 `404`/`403 SOURCE_MISMATCH`/`200` → `GATE_ALREADY_OPEN`（窗口本来就开着，先查上一轮）。
  - `open`：按 §4.1 原样分类。
  - `post`：`403 PERMISSION_DENIED` → `GATE_RESTORED_CLOSED`；其他 → `GATE_STILL_OPEN`。
- **默认只落盘计数与摘要**：200 时只写 `item_count` 与 `body_digest`；标题/备注/URL/日期不落盘、不打印。
- 回执 `boundary` 固定写入，且 `list_enumerations_called` 是**实测值**（统计本次实际发出的请求），不是常量：
  ```json
  {
    "http_methods": ["GET"],
    "list_enumerations_called": 0,
    "item_endpoint_calls": 2,
    "list_ids_in_request_masked": ["<target>", "<canary>"],
    "lists_other_than_target_touched": 0,
    "item_content_persisted": false,
    "non_target_metadata_persisted": false,
    "writes_attempted": 0,
    "token_persisted": false
  }
  ```
- `--expect` 与实际分类不符 → 退出码 `24`；canary 异常 → `25`；store 非 production → `20`；传输失败 → `3`。
- 分类词表固定（§4.1 的 13 个 + 3 个阶段标签），**不允许自由文本分类**。
- `follow_up.triggered` 恒为 `false`（§10）。

### 7.2 本轮已做的离线验证（不触网、不碰 Apple 数据）

#### 7.2.1 客户端单元层（`test_r1_probe.py`，72 项）

| # | 验证 | 结果 |
| :--- | :--- | :--- |
| 1 | `fake_bridge.py` 注入 13 种响应，逐一断言分类标签 | PASS |
| 2 | `404 + INTERNAL_ERROR` **不得**被判成 `NOT_RESOLVABLE` | PASS |
| 3 | 200 分支回执不含任何事项标题/备注原文 | PASS |
| 4 | 请求序列里没有 `/reminders/lists`；`list_enumerations_called == 0` | PASS |
| 5 | 闭闸三态：`401` / `403 LIST_NOT_ALLOWED` / `403 PERMISSION_DENIED` 各自独立可判 | PASS |
| 6 | `pre` → `open` → `post` 相位转换 | PASS |
| 7 | canary 异常（canary 拿到 `PERMISSION_DENIED`）→ `ANOMALOUS_CANARY`，退出码 25 | PASS |
| 8 | 敌意 listID（`..`、`reminders/lists`、`a/b/items`、空串）一律被 URL 结构断言拦下 | PASS |
| 9 | `probe --help` 里不存在 `--allow-enumeration` | PASS |

#### 7.2.2 窗口集成层（`test_r1_probe_window.sh`，39 项）

这一层验的不是分类逻辑，而是**接进实际执行路径后是否还成立**：开窗、关窗、看门狗三条路径都改成了 probe 验证，任何一条偷偷回退到枚举，下面的断言就会红。

| 场景 | 触发方式 | 关键断言 | 结果 |
| :--- | :--- | :--- | :--- |
| **1. 正常关窗** | 完整跑 `r1_probe_window.sh --confirm` | 退出 0；盘上 `gate_value=false`；`window_outcome=COMPLETED`；`open_probe_classification=RESOLVED_IDENTITY_MATCH_EMPTY`；`restore_probe_classification=GATE_RESTORED_CLOSED`；`watchdog=DISARMED_BY_MAIN`；`gate_open.json` 的 `verification_mode=probe`；`probe_pre` 的 canary 得 `LIST_NOT_ALLOWED` | PASS |
| **2. 主进程被杀** | 闸门开了 `true` 之后 `kill -9` 窗口进程 | 看门狗进 `FIRED_RESTORED`；盘上回到 `false`；看门狗那次 `gate_close_*_attempt1.json` 的 `verification_mode=probe`（**恢复路径也不枚举**） | PASS |
| **3a. 绝对期限** | 直接 arm 一个 `now+2s` 的看门狗 | `FIRED_RESTORED`、`WATCHDOG_REASON=deadline`、闸门回 `false` | PASS |
| **3b. 开闸预算** | `gate_open_since` 回拨 100 s，预算 5 s | `FIRED_RESTORED`、`WATCHDOG_REASON=open_budget`、闸门回 `false` | PASS |
| **4. 恢复失败** | `STUB_LAUNCHCTL_FAIL=1` 让重载失败 | `FIRED_RESTORE_FAILED`（**不软化成成功**）；看门狗退出码 6；扫遍 `gate_close_*_attempt*.json` 无一条 `verification=="PASS"` | PASS |
| **零枚举（贯穿 1–4）** | 假桥 `--request-log` 逐条记录 | 每个场景 `enumeration_calls == 0`；`other_calls == 0`（除 `/health` 与 `/reminders/lists/{id}/items` 外无任何路径）；场景 1 的 `item_calls == 4` 与 §3 预算逐次对上 | PASS |

**零枚举的证据口径**：不是"脚本里没写"，而是假桥对**每一个被应答的请求**写一行 `{status}\t{command}\t{path}`，测试用 `awk -F'\t'` 统计——`$3=="/reminders/lists"` 的条数、条目路径正则的条数、其余路径的条数。三项一起看，才能既证明"没枚举"，也证明"没走别的路"。

#### 7.2.3 回归与既有路径

| 项 | 命令 | 结果 |
| :--- | :--- | :--- |
| 既有客户端用例（夹具改动后） | `python3 scripts/tests/test_r1_bridge_client.py` | **63/63** |
| R1 回放路径未被破坏（`legacy_enumeration` 冒烟） | `r1_gate.sh open`（不带 `--list-id`） | rc=0、`verification=PASS`、`verification_mode=legacy_enumeration`、`gate_classification=GATE_AS_EXPECTED` |

`legacy_enumeration` 的存在只有一个理由：让 R1 的窗口能被原样回放。**R1-03 的任何调用都带 `--list-id`**，并且 `--require-no-enumeration` 在没有 `--list-id` 时直接 exit 2——回退是"被拒绝"，不是"默认"。

> 未做：Swift 端 `404` 的 HTTP 端到端测试（§4.4 登记的缺口）。本轮不新增未运行的测试。

复现命令（全离线，loopback + 假桥，无 TCC、无 Apple 数据）：

```
python3 scripts/tests/test_r1_probe.py           # 72/72
python3 scripts/tests/test_r1_bridge_client.py   # 63/63（夹具改动后的回归）
bash    scripts/tests/test_r1_probe_window.sh    # 39/39
```

`test_r1_probe.py` 的诚实边界写在文件头：它证明的是**客户端的分类逻辑**与矩阵一致，以及客户端**构造不出**枚举 URL；它**不**证明 Swift 服务端真的产出这些响应——假桥是按源码分支手写的，夹具与服务的偏差在这里看不出来。`test_r1_probe_window.sh` 的边界同理：它证明**编排逻辑**正确（谁在什么时候发什么、失败是否被正确命名为失败），不证明 MacServer 上的 `launchd`/`codesign` 真的如桩所模拟的那样回应。

### 7.3 接线：probe 如何进入开窗、关闸与看门狗

前版只有"客户端能分类"和"gate 能带参数"两件事，中间的执行编排是空的。v3 补上这一段，由三个脚本分担，职责不重叠。

#### 7.3.1 `r1_probe_window.sh`（新增，364 行）——唯一的窗口入口

```
r1_probe_window.sh --list-id ID --token-file F --plist P --work-dir D
                   [--config-file C] [--canary-id CID]
                   [--endpoint http://127.0.0.1:18765]
                   [--window-seconds 300] [--open-budget 120]
                   [--label r103] [--confirm]
```

执行顺序（**顺序本身就是安全属性，不能重排**）：

1. **preflight**：`python3` / 三个脚本存在 → plist 存在 → 令牌文件存在且 `0600` → 二进制 sha256 == `FROZEN_SHA256` → `codesign --verify --strict` 通过 → `--open-budget < --window-seconds`。任一失败 `exit 10`，**什么都没改**。
2. **静态配置核查**（只读文件）：算出 `gate_source`、`gate_value`、`mode`、`allowed_list_count`、`allowed_list_matches_target`、`binding_present_and_caldav_icloud`，写 `static_config.json`。以下任一成立即拒绝：闸门已经是 `true`（窗口本来就开着）、`mode != PRODUCTION`、白名单不是恰好这一个 ID、该 ID 没有 calDAV/iCloud 绑定。
3. **`pre` 相位**：`probe --phase pre --expect GATE_CLOSED_AS_EXPECTED`，带 canary。拿不到闭闸基线就 `exit 10` 并且**不开窗**。
4. **先 arm 看门狗，再开闸**：`nohup ... &` + `disown`，然后校验 `watchdog.pid` 里的进程确实活着、`watchdog_meta.env` 里的 deadline 与预期一致。**看门狗没起来就不开闸**——这是"先有兜底再有动作"的顺序。
5. **`open`**：`r1_gate.sh open --list-id ... --require-no-enumeration`。开窗失败 → 尝试关回去，`exit 11`；开成功但回执里没有 `probe_classification` → 关回去，`exit 12`。
6. **`close`**：同一个 gate、同一个 probe 相位 `post`，期望 `GATE_RESTORED_CLOSED`。失败 → `exit 13`，并保留整个 `RUN_DIR`。
7. **disarm**：写 `stop`，等 `DISARMED_BY_MAIN`。若看门狗在 disarm 之前已经 fire（`FIRED_*`），即使恢复成功也记 `TRUNCATED` 并 `exit 16`——**被截断的窗口不报成功**。
8. 写 `summary.json`（`window_outcome` / `absolute_deadline_epoch` / `open_budget_seconds` / 两个分类 / `watchdog_state` / `follow_up.triggered=false`）。

`--confirm` 之前的一切都是只读的：没有 `--confirm` 时脚本在完成 pre 相位后打印 `DRY RUN` 并 `exit 0`，**不碰闸门**。

`.r1-write-probe.$$` 是一个 0 字节的写权限探针，创建后立即删除；`RUN_DIR` 用 `mkdir -m 700` 建，且**拒绝复用已存在的目录**（两次窗口不共享一棵证据树）。

#### 7.3.2 `r1_gate.sh`（610 → 674 行）——唯一改闸门的地方

新增两个开关：`--list-id` 与 `--require-no-enumeration`。验证模式二选一，无隐式回退：

```bash
if [ -n "$LIST_ID" ]; then VERIFY_MODE="probe"
elif [ "$NO_ENUM" -eq 1 ]; then echo "PRECONDITION: --require-no-enumeration needs --list-id" >&2; exit 2
else VERIFY_MODE="legacy_enumeration"; fi
```

期望值按模式推导，不用调用方声明：

| 操作 | 期望分类 |
| :--- | :--- |
| `close` | `GATE_RESTORED_CLOSED`（单个） |
| `open` | 6 个"越过 guard"的标签任一：`NOT_RESOLVABLE`、`RESOLVED_SOURCE_IDENTITY_CHANGED`、`RESOLVED_IDENTITY_MATCH_EMPTY`、`RESOLVED_WITH_ITEMS`、`ANOMALOUS_SOURCE_NOT_ALLOWED`、`BLOCKED_TIMEOUT` |

`open` 接受集合而不是单一值，是因为**开窗成功只意味着"请求越过了 guard"**，越过后具体是 404 还是 200 属于探测结论，不属于开窗成败。但**观测到的那个标签仍原样写进回执**（`probe_classification`），异常标签（如 `ANOMALOUS_SOURCE_NOT_ALLOWED`）不会被"平均掉"。

回执新增字段：`verification_mode`、`probe_phase`、`probe_classification`、`probe_http_status`、`probe_error_code`、`probe_item_count`、`probe_enumeration_calls`；`evidence_files` 按模式指向 `.probe.json` 或 `.gate.json`。`verification_basis` 一字未改，仍是"http behaviour after reload + process identity; never the file value"。

#### 7.3.3 `r1_watchdog.sh`（178 → 196 行）——独立进程的兜底

看门狗在**独立进程**里跑，所以它必须自己带全参数，不能依赖窗口进程还活着。新增 `--list-id` / `--canary-id` / `--require-no-enumeration`，并把它们**转发给 `r1_gate.sh close`**：

```bash
CLOSE_ARGS=(--plist ... --config-file ... --token-file ... --endpoint ...
            --purpose "watchdog:$reason" --lock-wait 15 --out "$receipt")
[ -n "$LIST_ID" ] && CLOSE_ARGS+=(--list-id "$LIST_ID")
[ "$NO_ENUM" -eq 1 ] && CLOSE_ARGS+=(--require-no-enumeration)
```

这条改动是整个 v3 里最要紧的一处：**主进程被杀之后的那次关窗，是最容易被写成"顺手枚举一下确认关掉了"的地方**。现在它走同一个 probe，`--require-no-enumeration` 在参数缺失时直接拒跑，而不是悄悄回退。

#### 7.3.4 结构性保证，而非流程约束

上面三条路径都不枚举，靠的不是"我们都记得加参数"，而是三件事：

1. `item_url()` 是唯一 URL 构造器，做 5 段路径结构断言（`segments[1]=="reminders"`、`[2]=="lists"`、`[4]=="items"`），不符就 `AssertionError`——**枚举 URL 在这条路径上构造不出来**。
2. `probe` 子命令**没有** `--allow-enumeration`（前版列过，已删除）。不是默认关闭，是不存在。
3. `--require-no-enumeration` 把"忘了传 `--list-id`"从"静默枚举"变成"exit 2"。

canary 只在 `pre` 跑一次：白名单的主张在那里建立；开窗与关窗都不触碰白名单，重复发只是多两次请求。watchdog 也不带 `--canary-id`——它只负责关回去。

### 7.4 申请所需的执行要素（脚本、哈希、临时文件、期限、预算、恢复）

#### 7.4.1 脚本清单与哈希

以下 sha256 对应本申请提交时的内容，执行前应逐个比对；任一不符即中止（`r1_probe_window.sh` 的 preflight 只硬校验**二进制**，脚本自身的哈希比对是执行前的独立动作）。

| 脚本 | 行数 | sha256 | 本轮 |
| :--- | ---: | :--- | :--- |
| `scripts/r1_bridge_client.py` | 966 | `daa0de1921169cfdab087a7c659df3a67c09debbd373ace4dc5f527060ac591a` | 改（2.3.0） |
| `scripts/r1_gate.sh` | 674 | `57e70235ddf4fe89d66e6fed118a931ac6628b2bf2d4068c246bc683392ea677` | 改 |
| `scripts/r1_watchdog.sh` | 196 | `90d9ceb6e033f48ea1fad67e3caa5d2d5b3fd4924ae3d6535d7e25d4cb2f0a79` | 改 |
| `scripts/r1_probe_window.sh` | 364 | `bcd642d0dd0c961b9e10303258e132c4aa218089b40f5bd12be145f383fa8a5e` | **新增** |
| `scripts/r1_token_extract.sh` | 137 | `bec944107a19394754f1aef561a4e397f3e798260cb1bd59990f3466bc96e4a0` | 未改 |
| `scripts/tests/fake_bridge.py` | 254 | `09bd2416e8b3f6cdef7829c9315242fa5b5e0c10db7c36b9dbdf348aa8247869` | 改（仅夹具） |
| `scripts/tests/test_r1_probe.py` | 363 | `a892cb1163dbbd9f068411e52961ae4d405cab1b0bfd94434e275e7cc9a7684a` | 新增（v2 已提交） |
| `scripts/tests/test_r1_probe_window.sh` | 324 | `00c690e22037d398f2ac6c6dc7328029464b14b62ba174063f11880e63f44fcc` | **新增** |

被校验的二进制：`/Users/shared/bin/EventKitBridgeServer`，sha256 固定 `f78e24e533c2bf9a77161dc05eb154ce99687de9a5b881ad481bfbe2bbfb3074`。**不替换**，只校验。

#### 7.4.2 令牌与临时文件范围

| 对象 | 路径 | 权限 | 生命周期 |
| :--- | :--- | :--- | :--- |
| 桥令牌 | `--token-file` 指向的文件 | **必须 `0600`**，否则 preflight 拒绝 | 执行结束时删除；窗口脚本只读取，不复制、不落盘明文、不写入任何回执 |
| 窗口证据树 | `--work-dir` 下 `window-<label>-<UTC>/` | `0700`，拒绝复用已存在目录 | 保留作为回执；含 `probe_*.json`、`gate_*.json`、`summary.json`、`static_config.json`、`state/` |
| 看门狗状态 | `<RUN_DIR>/state/` | `0700` | `watchdog.pid`、`watchdog_meta.env`、`watchdog_status.env`、`gate_open_since`、`stop`、`gate_close_*.log` |
| plist / config 备份 | `r1_gate.sh` 自动生成，路径写入回执的 `plist_backup` / `config_backup` | `0600` | 关窗成功后保留至人工确认，用于逐字节比对 |
| 写权限探针 | `<work-dir>/.r1-write-probe.$$`、`<out_dir>/.r1-gate-probe.$$` | —— | 0 字节，创建后立即删除，仅用于证明"失败时能留下回执" |
| 锁 | `r1_gate.sh` 的互斥文件 | —— | 进程退出即释放；`--lock-wait` 有界（窗口 20 s / 关窗 15 s），**忙等视为失败**，不并发写 |

**不产生**的东西：事项内容、事项标题/备注/URL/日期、非目标列表元数据、令牌明文、任何`.env`导出。

#### 7.4.3 绝对期限与开闸预算

两个量是**不同维度**的，缺一不可：

| 量 | 参数 | 默认 | 含义 | 触发后 |
| :--- | :--- | ---: | :--- | :--- |
| **绝对期限** | `--window-seconds` | 300 s | 从 arm 那一刻起算的**墙钟**上限，写入 `watchdog_meta.env` 的 `WATCHDOG_DEADLINE_EPOCH` | `WATCHDOG_REASON=deadline` → 关窗 |
| **开闸预算** | `--open-budget` | 120 s | 闸门处于 `true` 的**累计**时长上限，按 `gate_open_since` 计算 | `WATCHDOG_REASON=open_budget` → 关窗 |

不变量：`--open-budget < --window-seconds`，否则参数阶段就 `exit 2`（预算是期限的子集，反过来说明参数写错了）。R1 实测开窗约 8 s，120 s 是 15 倍余量。

看门狗**每 2 s 轮询一次**（`--poll 2`），两个条件任一满足即 fire，且 **fire 是单向的**：进入 `FIRED_*` 后不再接受 disarm。

#### 7.4.4 恢复步骤（四条路径，全部以"观测到的行为"为准）

| 触发者 | 命令 | 判成功的唯一条件 | 失败时的状态 |
| :--- | :--- | :--- | :--- |
| 窗口正常结束 | `r1_gate.sh close --list-id ... --require-no-enumeration` | 回执 `probe_classification == GATE_RESTORED_CLOSED` 且 rc=0 | `exit 13`，`RUN_DIR` 保留 |
| 窗口异常退出（信号） | 同上（`trap INT TERM` → `restore`） | 同上 | `exit 13` |
| 主进程被杀 | **看门狗**独立发起同一个 `close` | 同上，且 `WATCHDOG_STATE=FIRED_RESTORED` | `FIRED_RESTORE_FAILED`，退出码 6 |
| 人工紧急关窗 | 手敲 `r1_gate.sh close --plist P --token-file T --out O`（可加 `--list-id`） | 回执 `verification == PASS` | rc≠0，看回执里的 `failure_stage` |

**恢复失败时不做的事**：不重试到"看起来成功"（`R1_RESTORE_ATTEMPTS` 默认 2，用完即报失败）、不手工改 plist 掩盖、不卸载服务、不删证据。恢复失败是一次需要人介入的状态，脚本的职责是**如实命名它**并保住现场。

**恢复目标**（§8.4）：原有常驻服务健康 + 业务闸门关闭 + plist 除该键外逐字节一致 + `/health` 仍 200。不包含"卸载""pid 归零"。

---

## 8. 设备归属与现态（更正前版错误）

### 8.1 前版错在哪

前版 §8 把**工程宿主上的观测**当成了 MacServer 的现态，据此写了"只读桥未安装 → 执行必须先部署、先 `bootstrap`、结束要卸载、pid 归零"。这个推断不成立：

- 观测发生在**工程宿主**（本会话工作目录所在机器）。MacServer 是另一台机器（`100.100.172.91`），本会话**没有连接过它**。
- 工程宿主上没有 `/Users/shared/bin/`、`launchctl list` 无该 label，只能说明**这台机器**没有安装痕迹，**不能**外推到 MacServer。
- 因此"重新部署 / 服务卸载 / PID 归零"三条计划**没有依据**，已删除。

### 8.2 历史基线（有回执支撑）

MacServer 侧最后一次有证据的状态来自 R1 / P5 回执：

| 项 | 回执记录的状态 |
| :--- | :--- |
| 常驻服务 | 单进程在跑（R1 期间 pid 33771），业务闸门**关闭** |
| plist | 与开闸前**逐字节一致**（唯一差异是第 28 行 `false→true→false`） |
| 看门狗 | `DISARMED_BY_MAIN` |
| 令牌与 4 个脚本 | 确认后已删除 |
| 开闸实测时长 | 约 8 s（预算 600 s） |

### 8.3 当前现态：**未核实**

本会话**没有**对 MacServer 做任何观测。上表是历史基线，**不是现态**。执行前必须先做一次只读核实（见 §9 的 P0），核实项只有四项：服务是否在跑、plist 的闸门键当前值、`/health` 是否 200、以及进程数与 pid。核实只用 `launchctl`/`ps`/`/health`，不碰任何 Apple 数据、不重启、不改配置。

### 8.4 恢复目标（更正后）

> **原有常驻服务保持健康，业务闸门回到关闭。**

不再包含"卸载服务""pid 归零"。开窗前后必须是同一个服务、同一个 plist（除闸门键一个值），窗口结束时该键回到原值、`/health` 仍 200。

**本轮不部署、不重启、不开闸、不连 MacServer。**

---

## 9. 需要你批准的授权项（执行时最小集合）

| 编号 | 授权内容 | 边界 | 预算 |
| :--- | :--- | :--- | :--- |
| **P0** | 只读核实 MacServer 现态（§8.3 四项）：服务在不在跑、plist 闸门键当前值、`/health` 是否 200、pid | 只用 `launchctl list`、`ps eww`（仅过滤闸门键一行）、`GET /health`、`plutil -extract`；不重启、不改配置、不碰 Apple 数据 | ≤ 60 s |
| **P1** | 单键开窗：`EVENTKIT_BRIDGE_PRODUCTION_AUTHORIZED` → `true`，按 §3.1 判定重载一次（`gate_source=launchd_env` 时 `bootout`+`bootstrap`；`config_file` 时 `kickstart -k`）；窗口结束**改回原值**并同样重载 | **只此一个键**；重载前后各记 plist sha256；`bootout`/`bootstrap` 仅用于让该键生效，**不换二进制、不改 label、不改 `ProgramArguments`、不 `disable` job**；含紧急关窗 | `--open-budget` **120 s**（R1 为 600 s）；开窗实测预期 < 15 s |
| **P2** | **读取绑定目标列表**（变体 A 才需要）：可能读入该列表全部事项内容 | 仅该一条列表；回执只落 `item_count` 与 `body_digest`；不落盘标题/备注/URL/日期 | 1 次 |
| **P3** | 发送 4 次 loopback 条目请求 + health：pre（canary 1 + target 1）→ open（target 1）→ post（target 1） | 仅 `127.0.0.1:18765`；`GET` only；**不调用 `/reminders/lists`**（URL 构造器在结构上拒绝，`--require-no-enumeration` 在参数层拒绝） | 4 次条目请求，硬上限 |
| **P4** | 记录进程环境中的闸门值（§4.3 手段 1） | 只输出 `EVENTKIT_BRIDGE_PRODUCTION_AUTHORIZED=` 一行；令牌键一律丢弃 | 1 次 |
| **P5** | 关窗与恢复核验：闸门键回原值 + `/health` 仍 200 + plist 与开窗前逐字节比对 + probe 得 `GATE_RESTORED_CLOSED` | **不卸载服务、不重启系统、不动二进制**；四条恢复路径见 §7.4.4 | ≤ 60 s |
| **P6** | 运行 `r1_probe_window.sh`（含内嵌看门狗） | `--window-seconds` **300 s**（绝对期限）、`--open-budget` **120 s**、`--confirm` 才真正开闸；不给 `--confirm` 时只跑到 pre 相位 | 一次窗口 |

**总时限**：从 `--confirm` 到脚本退出，硬上限 300 s；超时由看门狗强制关窗并记 `FIRED_RESTORED`（`TRUNCATED`，不报成功）。

**明确不在申请范围**（写了也不会做）：

- ❌ 账户级枚举 `/reminders/lists`
- ❌ 读取目标之外的任何列表（含"只读计数""只读名字"）
- ❌ 进入「最近删除」、恢复、新建、改名、移动
- ❌ 任何写入（`POST`/`PUT`/`DELETE` 一律 405，且我们不发送）
- ❌ 修改绑定、修改 TCC、替换二进制、为"让它能跑"而改源码或重新编译
- ❌ 部署、重装、卸载服务、`disable` job、pid 归零（前版误列，已删除）
- ❌ 用 `bootout`/`bootstrap` 做上一条之外的任何事（**该命令本身在 P1 的单键重载里是允许的**，见 §3.1）

---

## 10. 判定 → 下一步（都不自动触发）

| 探测结果 | 结论 | 下一步选项 |
| :--- | :--- | :--- |
| `NOT_RESOLVABLE`（404） | 该 ID 在本机 EventKit 已不可解析 | ① 与 R1-02 的 App 层观察交叉；② 讨论"重建同名列表 + 重新绑定"（需另立对象/风险/回退）；③ 保持 BLOCKED |
| `RESOLVED_SOURCE_IDENTITY_CHANGED`（403） | **ID 还在，身份变了** —— R1 的"账户/身份变化"假设得到直接支持 | ① 定位是哪一项变化（需另一份最小授权，可能涉及 source 枚举）；② 讨论重新登记绑定 |
| `RESOLVED_IDENTITY_MATCH_EMPTY`（200/0） | ID 还在、身份未变、当前查询 0 条 —— 与"枚举看不到"并存 | ① 记录矛盾点；② 重新审视 R1 的枚举结论（可能是枚举侧的可见性问题，而非数据问题） |
| `RESOLVED_WITH_ITEMS`（200/n>0） | 同上且非空 → **推翻"空列表"前提** | ① 仅记录 `item_count`，**到此为止**；② 是否继续由你另行决定 |
| `BLOCKED_*` | 无结论 | 修前置后重来；不消耗判定 |

> **非空事项不自动触发任何后续动作。** 命中 `RESOLVED_WITH_ITEMS` 时，本次执行**到此结束**：不再读第二遍、不读字段内容、不写入任何对象、不进入保真度验收、不改变 R2 状态。回执里 `follow_up.triggered` 恒为 `false`。要不要接着做保真比对（那是另一件事、另一份申请），由你决定，不由探测结果触发。

---

## 11. 交付物

| # | 产物 | 位置 |
| :--- | :--- | :--- |
| 1 | 本方案（v3） | `receipts/R1_03_BOUND_ID_PRECISE_CHECK_APPLICATION.md` |
| 2 | `probe` 子命令 + 离线用例（本轮不执行真实请求） | `scripts/r1_bridge_client.py`（2.3.0）、`scripts/tests/test_r1_probe.py` |
| 3 | 窗口编排 + 接入 gate / watchdog | `scripts/r1_probe_window.sh`、`scripts/r1_gate.sh`、`scripts/r1_watchdog.sh` |
| 4 | 窗口集成用例（四类失效场景 + 零枚举） | `scripts/tests/test_r1_probe_window.sh` |
| 5 | 脚本哈希清单 | 本文件 §7.4.1 |
| 6 | 执行回执（批准并执行后） | `receipts/R1_03_BOUND_ID_PROBE_RESULT.json` |
| 7 | 窗口汇总（执行后） | `<work-dir>/window-<label>-<UTC>/summary.json` + `probe_pre.json` / `gate_open.json` / `gate_close_*.json` |
| 8 | 关窗与恢复核验（执行后） | 并入回执：闸门键回原值、`/health` 200、plist 与开窗前逐字节比对、`probe_classification=GATE_RESTORED_CLOSED` |

---

## 12. 一句话总结

用**一个只带目标 ID 的条目请求**，把"存在/不存在/身份变化"从"说不清"变成三个可区分的状态码；代价是成功分支上会读一次那条列表的内容（可换成哨兵绑定以避免，但要牺牲身份信号）；**不碰账户级枚举，也不声称底层未枚举**。v3 把这条路径真正接进了开窗、关闸与看门狗——三条路径共用同一个 probe，`--require-no-enumeration` 让"忘了带参数"变成拒绝而不是回退；四类失效场景已离线验证（39 项断言，零枚举由请求日志逐条统计）。执行需要 P0–P6，恢复目标是"服务健康 + 闸门关闭"，不是卸载。本轮只交付方案、代码与离线验证。
