# R1-03 历史绑定 ID 精确核验（可执行方案 + 必要授权项）

- **任务**：REM-R1-01 后续，编号 **R1-03**，版本 **v2**（2026-11-10 23:55 CST）
- **申请方**：WorkBuddy（本专项唯一工程主执行 Agent）
- **前置判定**：R1 = `BLOCKED_TARGET_NOT_VISIBLE`（2026-11-10T14:45:13Z，枚举 HTTP 200、2 条、无目标）。R1 窗口已结束，不续期。
- **本文件性质**：**方案 + 已实现的离线工具**。除离线验证外**本轮不执行任何真实操作**——不部署、不重启、不开闸、不调用账户级枚举、不读取其他列表、不读取任何事项内容。
- **R2 仍不开启。**

---

## 0.0 本版（v2）相对 v1 的修订

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
| `scripts/r1_bridge_client.py`（原 645 行 v2.2.0） | **已改** | 新增子命令 `probe`（`item_url` / `classify` / `apply_phase` / `cmd_probe`）；`read_token()`、`http_get()`、`emit()`、`ensure_out_dir()`、`LOOPBACK_RE` 全部复用；版本升 **2.3.0** |
| `scripts/r1_token_extract.sh`（137 行） | **未改** | 令牌单键提取，`24/24` 已通过；`probe` 沿用同一路径，未重跑 |
| `scripts/tests/fake_bridge.py` | **已改（仅测试夹具）** | ① 新增 `allowed_ids` 控制文件，**在闸门检查之前**执行精确匹配（镜像真实顺序 `:419` → `:136`）；② 新增 `item_status` 控制文件，按 listID 注入 `status`+`code`。二者缺省不存在，行为不变 |
| `scripts/tests/test_r1_probe.py` | **新增** | 72 项断言，覆盖矩阵 13 类 + 三相转换 + canary 异常 + 边界（详见 §7.2） |
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

| # | 验证 | 结果 |
| :--- | :--- | :--- |
| 1 | `fake_bridge.py` 注入 13 种响应，逐一断言分类标签 | 见 `scripts/tests/test_r1_probe.py` |
| 2 | `404 + INTERNAL_ERROR` **不得**被判成 `NOT_RESOLVABLE` | 同上 |
| 3 | 200 分支回执不含任何事项标题/备注原文 | 同上 |
| 4 | 请求序列里没有 `/reminders/lists`；`list_enumerations_called == 0` | 同上 |
| 5 | 闭闸三态：`401` / `403 LIST_NOT_ALLOWED` / `403 PERMISSION_DENIED` 各自独立可判 | 同上 |
| 6 | `pre` → `open` → `post` 相位转换：`GATE_CLOSED_AS_EXPECTED` → 真实结果 → `GATE_RESTORED_CLOSED` | 同上 |
| 7 | canary 异常（canary 拿到 `PERMISSION_DENIED`）→ `ANOMALOUS_CANARY`，退出码 25 | 同上 |
| 8 | 令牌含引号/空白 → 硬失败 | 复用既有 `r1_token_extract` 24 例，未重跑 |

> 未做：Swift 端 404 的 HTTP 端到端测试（§4.4 登记的缺口）。本轮不新增未运行的测试。

复现命令（全离线，loopback + 假桥，无 TCC、无 Apple 数据）：

```
python3 scripts/tests/test_r1_probe.py           # 72/72
python3 scripts/tests/test_r1_bridge_client.py   # 63/63（夹具改动后的回归）
```

`test_r1_probe.py` 的诚实边界写在文件头：它证明的是**客户端的分类逻辑**与矩阵一致，以及客户端**构造不出**枚举 URL；它**不**证明 Swift 服务端真的产出这些响应——假桥是按源码分支手写的，夹具与服务的偏差在这里看不出来。

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
| **P0** | 只读核实 MacServer 现态（§8.3 四项） | `launchctl list`、`ps`、`GET /health`；不重启、不改配置、不碰 Apple 数据 | ≤ 60 s |
| **P1** | 单键开窗：`EVENTKIT_BRIDGE_PRODUCTION_AUTHORIZED` → `true`，重载一次；窗口结束**改回原值**并重载 | **只此一个键**；重载前后各记 plist sha256；含紧急关窗 | 开窗累计 ≤ 120 s（R1 为 600 s） |
| **P2** | **读取绑定目标列表**（变体 A 才需要）：可能读入该列表全部事项内容 | 仅该一条列表；客户端只落盘条数与摘要；不落盘标题/备注/URL/日期 | 1 次 |
| **P3** | 发送 ≤ 4 次 loopback 条目请求：1 次 canary + 1 次闭闸基线（pre）+ 1 次开窗探测（open）+ 1 次关窗复核（post） | 仅 `127.0.0.1`；`GET` only；**不调用 `/reminders/lists`** | ≤ 4 次条目请求 |
| **P4** | 记录进程环境中的闸门值（§4.3 手段 1） | 只输出 `EVENTKIT_BRIDGE_PRODUCTION_AUTHORIZED=` 一行；令牌键一律丢弃 | 1 次 |
| **P5** | 关窗与恢复核验：闸门键回原值 + `/health` 仍 200 + plist 与开窗前逐字节比对 | **不卸载服务、不重启系统、不动二进制**；核验口径见 §8.4 | ≤ 60 s |

**明确不在申请范围**（写了也不会做）：

- ❌ 账户级枚举 `/reminders/lists`
- ❌ 读取目标之外的任何列表（含"只读计数""只读名字"）
- ❌ 进入「最近删除」、恢复、新建、改名、移动
- ❌ 任何写入（`POST`/`PUT`/`DELETE` 一律 405，且我们不发送）
- ❌ 修改绑定、修改 TCC、替换二进制、为"让它能跑"而改源码或重新编译
- ❌ 部署、重装、卸载服务、`bootstrap`/`bootout`、pid 归零（前版误列，已删除）

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
| 1 | 本方案 | `receipts/R1_03_BOUND_ID_PRECISE_CHECK_APPLICATION.md` |
| 2 | `probe` 子命令 + 离线用例（本轮不执行真实请求） | `scripts/r1_bridge_client.py`（2.3.0）、`scripts/tests/` |
| 3 | 执行回执（批准并执行后） | `receipts/R1_03_BOUND_ID_PROBE_RESULT.json` |
| 4 | 关窗与恢复核验（执行后） | 并入回执：闸门键回原值、`/health` 200、plist 与开窗前逐字节比对 |

---

## 12. 一句话总结

用**一个只带目标 ID 的条目请求**，把"存在/不存在/身份变化"从"说不清"变成三个可区分的状态码；代价是成功分支上会读一次那条列表的内容（可换成哨兵绑定以避免，但要牺牲身份信号）；**不碰账户级枚举，也不声称底层未枚举**。执行需要 P0–P5，且恢复目标是"服务健康 + 闸门关闭"，不是卸载。本轮只交付方案与离线验证。
