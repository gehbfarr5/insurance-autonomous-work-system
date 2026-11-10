# R1-03 历史绑定 ID 精确核验（可执行方案 + 必要授权项）

- **任务**：REM-R1-01 后续，编号 **R1-03**，版本 **v1**（2026-11-10 23:35 CST）
- **申请方**：WorkBuddy（本专项唯一工程主执行 Agent）
- **前置判定**：R1 = `BLOCKED_TARGET_NOT_VISIBLE`（2026-11-10T14:45:13Z，枚举 HTTP 200、2 条、无目标）。R1 窗口已结束，不续期。
- **本文件性质**：**方案**。除离线验证外**本轮不执行任何真实操作**——不部署、不重启、不开闸、不调用账户级枚举、不读取其他列表、不读取任何事项内容。
- **R2 仍不开启。**

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

## 3. 执行形态（一次请求，最多三次）

| 序号 | 请求 | 目的 | 是否触达 Apple 数据 |
| :--- | :--- | :--- | :--- |
| **T0-1** | `GET /health`（无令牌） | 进程活着、`store` 字段非 fake、`generation` 单调 | 否 |
| **T0-2** | `GET /reminders/lists/{CANARY}/items`，`CANARY` = 一个**必然不在白名单**的合成串 | 证明白名单精确匹配、且该请求**在到达 store 之前**被拒 | 否（第 5 步即返回） |
| **T1** | `GET /reminders/lists/{TARGET}/items` | 唯一一次真实探测 | **是**（第 7 步解析；若通过第 8 步则读内容） |

`T0-2` 的价值在于给出**同一进程、同一令牌、同一时刻**的对照：若 `TARGET` 得到的是 `PERMISSION_DENIED` 而 `CANARY` 得到 `LIST_NOT_ALLOWED`，两者的差异只可能来自第 5 步之后的路径——也就是"目标 ID 确实在白名单里、请求确实进了 store"。

`T0-2` 在**闸门关闭**时也能跑（第 5 步先于第 6 步），因此它可以在开闸之前完成，用来先验证"这次部署的配置是否真的指向目标"。若 `T0-2` 需要重跑以确认 `TARGET` 是否在白名单，则用 `TARGET` 本身发一次、预期 `403`（`LIST_NOT_ALLOWED` 或 `PERMISSION_DENIED`）——见 §4.2 的 T0 基线。

**请求预算**：≤ 3 次条目端点请求 + 1 次 health。服务端与 store 共用同一个 `RequestLimiter` 实例（`main.swift:137` 创建，`:156` 传入 store、`:167` 传入 server），因此每次条目请求消耗 **2 个令牌**；`rateLimitRPS` 为 10 时 3 次请求无风险。出现 `429` 一律视为**无结论**，等待后重试不超过 1 次。

---

## 4. 判定矩阵（这是本方案的核心交付物）

### 4.1 主矩阵

| HTTP | `code` | 分类标签 | **能得出的结论** | **不能得出的结论** |
| :--- | :--- | :--- | :--- | :--- |
| 200 | —（数组，长度 0） | `RESOLVED_IDENTITY_MATCH_EMPTY` | ID 解析成功；source 三元组与绑定一致；当前谓词查询返回 0 条 | ≠「列表为空」（见 §6.4）；≠「用户看得到」；≠「同步正常」 |
| 200 | —（数组，长度 >0） | `RESOLVED_WITH_ITEMS` | 同上且非空 → **直接推翻"空列表"这一前提** | 不推翻"枚举里看不到"：两者可同时为真 |
| 404 | `LIST_NOT_FOUND` | `NOT_RESOLVABLE` | `calendar(withIdentifier:)` 返回 nil → 该 ID 在**本机当前 EventKit store** 中不可解析 | ≠「已删除」；≠「账户里没有」；≠「不可恢复」；可能只是未同步落地 |
| 403 | `SOURCE_MISMATCH` | `RESOLVED_SOURCE_IDENTITY_CHANGED` | **ID 解析到了**；`sourceID`/`sourceType`/`sourceTitle` 三者至少一项与登记值不同 → 这是 R1 留下的"身份变化"假设的**直接证据** | ≠「内容完好」；≠「用户看得到」；不指出是哪一项变了（错误体已脱敏） |
| 403 | `SOURCE_NOT_ALLOWED` | `ANOMALOUS_REACHED_UNEXPECTED_BRANCH` | 按源码此分支在 `requireExplicitBinding: true` 下**不可达**（`SourceVerifier.swift:70-80`） | 出现即为配置/构建异常信号，**不得**当作任何列表结论；停止并报告 |
| 403 | `PERMISSION_DENIED` | `BLOCKED_PERMISSION_OR_GATE` | 请求已过第 4、5 步，被第 6 步拦下 | **不能**区分"闸门关闭"与"TCC 未授权/被撤销"——本方案唯一的不可消歧点，处理见 §4.3 |
| 403 | `LIST_NOT_ALLOWED` | `BLOCKED_NOT_ON_ALLOWLIST` | 该 ID 不在此次部署的白名单里 → 配置未指向它 | ≠「列表不存在」。此项**必须**先修配置，否则任何存在性结论都无效 |
| 401 | `AUTHENTICATION_FAILED` | `BLOCKED_AUTH` | 令牌无效（含引号/空白/权限问题） | 与列表状态无关 |
| 429 | `RATE_LIMIT_EXCEEDED` | `BLOCKED_RATE_LIMIT` | 限流 | 与列表状态无关；不得重试超过 1 次 |
| 503 | `CONCURRENCY_LIMIT_EXCEEDED` / `STORE_RESOURCE_LIMIT_EXCEEDED` | `BLOCKED_BUSY` | 并发/预算闸 | 与列表状态无关 |
| 504 | `TIMEOUT` | `BLOCKED_TIMEOUT` | 回调查询超时（`callbackTimeoutSeconds`） | 解析是否成功**未知**；不得推断 |
| 404 | `INTERNAL_ERROR` | `ERROR_ROUTE` | 路由未匹配（`BridgeRoute.parse` 返回 nil） | **最容易误判的一项**：同为 404，但**与列表无关**。任何 404 必须同时看 `code` |
| — | 连接失败 | `ERROR_BRIDGE_UNREACHABLE` | 进程未运行/端口不通 | 与列表状态无关 |

**硬规则：只读状态码不读 `code` 会误判。** `404` 有两种含义，必须以 `code` 区分。

### 4.2 T0 基线（闸门关闭时即可完成，零 Apple 数据）

| 观测 | 结论 |
| :--- | :--- |
| `TARGET` → `403 PERMISSION_DENIED` | 目标 ID **在白名单内**（已过第 5 步）。基线成立，可进入 T1 |
| `TARGET` → `403 LIST_NOT_ALLOWED` | 目标 ID **不在白名单内** → 配置未指向目标，**停止**，先修配置；本次开闸无意义 |
| `CANARY` → `403 LIST_NOT_ALLOWED` | 白名单为精确匹配（`AllowlistValidator.swift:38-43` 仅做集合成员判定） |
| `CANARY` → 任何其他码 | 异常信号，停止并报告 |

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
| `scripts/r1_bridge_client.py`（645 行，v2.2.0） | **改** | 新增子命令 `probe`；`read_token()`、`http_get()`、`emit()`、`ensure_out_dir()`、`LOOPBACK_RE` 全部复用。版本升 **2.3.0** |
| `scripts/r1_token_extract.sh`（137 行） | **不改** | 令牌单键提取，`24/24` 已通过；`probe` 沿用同一路径 |
| `scripts/tests/fake_bridge.py`（201 行） | **小改** | 现条目端点恒回 `200`（`:170-172`）；需加一个"按 listID 注入 `status`+`code`"的测试控制文件（约 15 行，仅测试用） |
| `scripts/tests/test_r1_bridge_client.py`（389 行） | **改** | 追加 `probe` 用例；既有 63 例不动 |
| `macserver-eventkit` 源码 / 二进制 | **不改** | 变体 A/C 均不需要改代码；变体 B 才需要（本轮不做） |
| R1 回执 `static_config` 四行 | **复用** | 作为"白名单恰含目标"的依据，不重复取证 |
| `com.muse.macserver-eventkit.plist.template` | **复用** | 单键开闸即改 `EVENTKIT_BRIDGE_PRODUCTION_AUTHORIZED`（`:385`） |

### 7.1 `probe` 子命令规格

```
probe --endpoint http://127.0.0.1:18765 \
      --token-file <path> \
      --list-id <TARGET_ID> \
      --canary-id R1-CANARY-00000000-0000-0000-0000-000000000000 \
      --expect <classification> \
      --out <path>
```

- **只发 §3 的三个请求**；不调用 `/reminders/lists`（除非显式 `--allow-enumeration`，且该开关**默认关闭**并在回执里留痕）
- **默认 `--persist-items=count-only`**：200 时只写 `item_count` 与整体 `body_digest`；标题/备注/URL/日期不落盘、不打印
- 回执 `boundary` 固定写入：
  ```json
  {
    "http_methods": ["GET"],
    "list_enumerations_called": 0,
    "item_endpoints_called": 2,
    "list_ids_in_request": ["<target>", "<canary>"],
    "lists_other_than_target_touched": 0,
    "item_content_persisted": false,
    "non_target_metadata_persisted": false,
    "writes_attempted": 0,
    "token_persisted": false
  }
  ```
- `--expect` 与实际分类不符 → 退出码非 0，与现有 `gate` 子命令同构
- 分类词表固定为 §4.1 的 12 个标签，**不允许自由文本分类**

### 7.2 本轮可做的离线验证（不需要你批准任何真实操作）

| # | 验证 | 覆盖 |
| :--- | :--- | :--- |
| 1 | `fake_bridge.py` 注入 `200/[]`、`200/[n]`、`404 LIST_NOT_FOUND`、`403 SOURCE_MISMATCH`、`403 SOURCE_NOT_ALLOWED`、`403 PERMISSION_DENIED`、`403 LIST_NOT_ALLOWED`、`401`、`429`、`503`、`504`、`404 INTERNAL_ERROR` | 12 个分类标签全部命中，逐一断言 |
| 2 | 断言 `404 + INTERNAL_ERROR` **不得**被判成 `NOT_RESOLVABLE` | 第 4.1 末条硬规则 |
| 3 | 断言 200 分支回执中不含任何事项标题/备注原文 | 落盘边界 |
| 4 | 断言请求序列里没有 `/reminders/lists` | "不调用账户级枚举" |
| 5 | 断言 `TARGET` 得 `PERMISSION_DENIED` 而 `CANARY` 得 `LIST_NOT_ALLOWED` 时，回执给出 `BASELINE_ALLOWLIST_MEMBERSHIP_CONFIRMED` | §4.2 |
| 6 | 令牌含引号/空白 → 硬失败（复用现有 `r1_token_extract` 24 例） | 已有 |

> 可选加做（离线、无 TCC）：在 `Tests/EventKitBridgeTests/HttpIntegrationTests.swift` 里用 `FakeEventKitStore` 断言真实的 404/403 分支——`allowlist={不存在的 ID}` 应得 `404 LIST_NOT_FOUND`，`allowlist={wrong-source 列表}` 应得 `403 SOURCE_MISMATCH`。这能证明**服务端真实分支**与矩阵一致，而不只是假桥一致。若编译或运行超过 10 分钟则跳过，并在回执里写明"未做"。

---

## 8. 执行前置条件（说明为什么本轮不可能执行）

| 前置 | 现状（已核实） | 结论 |
| :--- | :--- | :--- |
| 只读桥已安装 | `/Users/shared/bin/` 不存在；`launchctl list` 无 `com.muse.macserver-eventkit` | **未安装**，执行必须先部署 |
| plist 已加载 | 仅存一份模板副本（含 `TARGET_ICLOUD_LIST_UUID` 占位符），`~/Library/LaunchAgents` 无对应项 | **未加载**，执行必须先落地并 `bootstrap` |
| 闸门 | 模板值 `false` | 执行必须单键开闸 |
| 令牌 | R1 结束后已按约定删除 | 执行必须重新生成并单键落盘（0600） |

**四项都必须动到系统状态。**因此本文件的定位是"方案 + 授权项"，不是执行记录。**本轮不部署、不重启、不开闸。**

---

## 9. 需要你批准的授权项（执行时最小集合）

| 编号 | 授权内容 | 边界 | 预算 |
| :--- | :--- | :--- | :--- |
| **P1** | 部署只读桥：复制已冻结二进制 `f78e24e5…3074` 到 `/Users/shared/bin/`，落地 plist（单键 `ALLOWED_LIST_IDS`=目标、单绑定、`PRODUCTION_AUTHORIZED=false`），`launchctl bootstrap` | **不替换二进制、不重新编译、不改任何代码**；plist 落地前后各记 sha256 | ≤ 120 s |
| **P2** | 单键开闸：`EVENTKIT_BRIDGE_PRODUCTION_AUTHORIZED` → `true`，重载一次 | 只此一个键；含紧急关闸（`false` + 重载）；关闸预算计入 | 开闸累计 ≤ 120 s（R1 为 600 s） |
| **P3** | **读取绑定目标列表**（变体 A 才需要）：可能读入该列表全部事项内容 | 仅该一条列表；客户端只落盘条数与摘要；不落盘标题/备注/URL/日期 | 1 次 |
| **P4** | 发送 ≤ 3 次 loopback 条目请求：1 次 canary（到达 store 前即被拒）+ 1 次 T0 基线 + 1 次 T1 探测 | 仅 `127.0.0.1`；`GET` only；不做账户级枚举 | ≤ 3 次条目请求 |
| **P5** | 关闸 + 卸载 + 删除令牌与临时脚本 | 恢复后 plist 与开闸前逐字节比对；`launchctl list` 无残留；pid 归零 | ≤ 60 s |
| **P6** | 记录进程环境中的闸门值（§4.3 手段 1） | 只输出 `EVENTKIT_BRIDGE_PRODUCTION_AUTHORIZED=` 一行；令牌键一律丢弃 | 1 次 |

**明确不在申请范围**（写了也不会做）：

- ❌ 账户级枚举 `/reminders/lists`
- ❌ 读取目标之外的任何列表（含"只读计数""只读名字"）
- ❌ 进入「最近删除」、恢复、新建、改名、移动
- ❌ 任何写入（`POST`/`PUT`/`DELETE` 一律 405，且我们不发送）
- ❌ 修改绑定、修改 TCC、重装系统组件、替换二进制
- ❌ 为"让它能跑"而改源码或重新编译

---

## 10. 判定 → 下一步（都不自动触发）

| 探测结果 | 结论 | 下一步选项 |
| :--- | :--- | :--- |
| `NOT_RESOLVABLE`（404） | 该 ID 在本机 EventKit 已不可解析 | ① 与 R1-02 的 App 层观察交叉；② 讨论"重建同名列表 + 重新绑定"（需另立对象/风险/回退）；③ 保持 BLOCKED |
| `RESOLVED_SOURCE_IDENTITY_CHANGED`（403） | **ID 还在，身份变了** —— R1 的"账户/身份变化"假设得到直接支持 | ① 定位是哪一项变化（需另一份最小授权，可能涉及 source 枚举）；② 讨论重新登记绑定 |
| `RESOLVED_IDENTITY_MATCH_EMPTY`（200/0） | ID 还在、身份未变、当前查询 0 条 —— 与"枚举看不到"并存 | ① 记录矛盾点；② 重新审视 R1 的枚举结论（可能是枚举侧的可见性问题，而非数据问题） |
| `RESOLVED_WITH_ITEMS`（200/n>0） | 同上且非空 → **推翻"空列表"前提** | ① 立即转入保真度比对（原 R1 目标）；② 重新定义问题 |
| `BLOCKED_*` | 无结论 | 修前置后重来；不消耗判定 |

---

## 11. 交付物

| # | 产物 | 位置 |
| :--- | :--- | :--- |
| 1 | 本方案 | `receipts/R1_03_BOUND_ID_PRECISE_CHECK_APPLICATION.md` |
| 2 | `probe` 子命令 + 离线用例（本轮不执行真实请求） | `scripts/r1_bridge_client.py`（2.3.0）、`scripts/tests/` |
| 3 | 执行回执（批准并执行后） | `receipts/R1_03_BOUND_ID_PROBE_RESULT.json` |
| 4 | 恢复与零残留（执行后） | 并入回执，plist sha256 前后比对 + `launchctl` 空载 + pid 归零 |

---

## 12. 一句话总结

用**一个只带目标 ID 的条目请求**，把"存在/不存在/身份变化"从"说不清"变成三个可区分的状态码；代价是成功分支上会读一次那条列表的内容（可换成哨兵绑定以避免，但要牺牲身份信号）；**不碰账户级枚举，也不声称底层未枚举**。执行需要 P1–P6，本轮只交付方案与离线验证。
