# R2 执行回执（MUSE 前台只读验收）

- **回执类型**: R2_EXECUTION_RECEIPT（脱敏；**含 §8 归档关账，2026-11-11 22:4x 补记**）
- **授权**: 总控批准执行一次 R2 v2.3（基线 `6b370be`）；单窗 3600 秒硬期限；**按申请执行，含 §8.3 已记录执行偏差 D1–D6（其中 D1 令牌来源修正、D2 supervisor 运行方式与申请文字不同）；验收主路径（P3/P4）按申请完成，未触发看门狗回滚**
- **执行时间**: 2026-11-11 21:40–22:0x CST（窗开 13:40:48Z，截止 epoch 1794408048；提前完成收尾，未到期）
- **判定**: **R2 验收通过** —— 目标匹配 ✓ / 真实非空读取与字段保真 ✓ / 清理零残留 ✓ / 双端恢复 ✓；另有两项诚实记录的输入偏差说明（§3）

## 1. 逐步记录

| 步 | 时间(CST) | 动作 | 结果 |
|---|---|---|---|
| P0 | 21:20–21:39 | Seoul 现状核对（基线容器 healthy、latest=f3e697fe、网络网关 172.19.0.1、mac-operator 密钥 `/etc/ssh/seoul-keys/` 在位）；MacServer 核对（桥 pid 14249、gate=false、白名单恰 1 项、绑定 `listID:sourceID:calDAV:iCloud`）；**S0-lite 令牌提取**（见 §4 重要发现）；注入 env 构建（0600）经受限密钥直传 Seoul；compose override + 看门狗脚本 + sshd drop-in 写入（0600）；合并配置验证（3 个 MACSERVER_EVENTKIT 键 + secrets.env + 基础 env 全部生效） | 全部 PASS |
| P1 | 21:37 | 用户在 MUSE-R1-04-SYNTEST 创建恰 1 条合成事项 | 完成（§3 输入偏差说明） |
| T0 | 13:40:48Z | **双端看门狗先就绪**：Seoul prechange watchdog pid 1840282（期限 1794408048）；MacServer 隧道 supervisor pid 21389（DEADLINE_EPOCH 同值，到期即 orchestrated-stop 自动关闸） | 均确认在跑 |
| T1 | 21:41–21:48 | sshd drop-in 重载；隧道 supervisor 启动；经 3 次诊断修正（§4）后四层状态 layer2=connected / layer3=forwarding_active；Seoul 侧 `172.19.0.1:18765` + `127.0.0.1:18765` 双监听确认 | PASS |
| T2+T3 | 21:51 | 容器创建前准备+首次启动生效（同一步骤）：`compose.yaml + compose.r2.yaml up -d` → 候选镜像 `candidate-ag05-delivery-20261108` healthy；容器 env 三键确认 | PASS |
| T4 | 21:53 | **开闸**（r1_gate.sh open，互斥+0600 plist 备份+probe 验证）：前两次 FAIL（client 令牌文件空白字符拒绝，§4），换用有效令牌后第三次 **PASS**（probe=RESOLVED_WITH_ITEMS / 200 / item_count=1） | PASS |
| P3 | 21:56 | **MUSE 原生读取**（用户前台触发，零写调用）：step1 reminders_lists **仅 1 列表**（生产列表隔离不可见）；step2 reminders_list 返回 1 条，字段逐项核对（§3） | PASS |
| P4 | 22:0x | 用户精准删除（原生 App）→ MUSE 原生复读 **0 条** → 工程复核（桥直连 items）**200 + `[]`** | 零残留 ✓ |
| T4 close | 22:0x | **关闸**（r1_gate.sh close）：**PASS**（probe=GATE_RESTORED_CLOSED，pid 23354→25381） | PASS |
| P5 | 22:0x | 双端恢复核验（§5）→ 清理（§6） | 全部 PASS |
| P6 | — | 本回执 + 提交号 | — |

## 2. MUSE 发起证据（三通道分开记账）

- **(a) 前台触发**：用户在 MUSE 前台直接触发原生工具（P3 两步、P4 复读各一次）；发起入口 `https://seoul-forge-01.tail4db0d9.ts.net/mcp`（21:1x 自检实测连通）
- **(b) 包装层日志**：P3 首次 apple_login 返回 `NEEDS_APPLE_RELOGIN` → **只读通道自动恢复**后第二次 OK（与此前验收同一模式）；P4 直接触发 OK；`writes_enabled=false` 全程（自检与验收均零写调用）
- **(c) 调用/响应记录**：两步返回原文由用户粘贴回传（列表 ID、事项 ID、字段值），本回执仅记掩码/摘要
- 发起方区分：本次窗口 MUSE 经 OAuth client 发起；工程复核经**桥直连**（MacServer 本地 curl，仅条目端点）——两类请求路径天然分离，各自记账

## 3. 字段保真核对（12 项基线）

| 断言 | 结果 |
|---|---|
| synthetic_item_visible / unique_synthetic_item | ✓（1 条） |
| title | 观测 `MARKER：R2SYN20261111A` = 用户实际输入（**含 MARKER 串，目标匹配 ✓**） |
| notes 两行精确匹配 | ✓（`R2 fidelity line one` / `line two fidelity 校验`） |
| priority=5 / completed=false / is_all_day=false | ✓✓✓ |
| item_id 非空 / 列表归属匹配 | ✓✓ |
| due 观测 `2026-11-12T02:00:00.000Z` | = 用户实际输入（10:00 CST），精确到秒 ✓ |
| time_zone | `Asia/Shanghai` ✓ |
| 列表隔离 | ✓ reminders_lists 仅返回绑定列表；生产列表不可见 |

**诚实说明**：建议规格为"标题无前缀 + due 10:30"；用户实际输入"标题含 `MARKER：` 前缀 + due 10:00"（P3 后经用户确认）。观测值与**实际输入**逐字段一致——为**输入偏差**而非链路保真缺陷；两类偏差均如实记录，不构成验收失败，也未做任何重试/重建。

## 4. 执行中的异常与修正（如实记录；均为准备/验证层，无数据影响）

1. **隧道三连修**：(i) supervisor 首两次重连与 sshd reload 竞态（255 退出）；(ii) 定位到 sshd 对**重复 PermitListen 行相互覆盖**（`sshd -T` 实证仅一条生效）→ 改单行双条目后生效；(iii) 手动复现确认双绑定成功。supervisor 第 15 次重连成功，四层状态达标。
2. **桥令牌来源发现**（重要）：plist 的 `EVENTKIT_BRIDGE_BEARER_TOKEN`（195 字符含空格）**并非生效令牌**——运行进程 env 无该键（摘要=空串），实际生效令牌来自 plist 所引 `EVENTKIT_BRIDGE_CONFIG_FILE`（`~/.config/muse-macserver/bridge.env`，64 字符）。首次注入 env 用了 plist 令牌（若进入业务调用将 401），**在 MUSE 步骤前发现并重建注入 env + 重建容器**（首启生效），避免了一次无效验收。r1_gate probe 两次 FAIL 的根因即 client 对 plist 令牌的空白字符拒绝（冻结脚本未改动；换 bridge.env 令牌后 PASS）。
3. **无恢复路径触发**：看门狗零回滚、无重试风暴、无 UNKNOWN 写入。

## 5. 请求账（窗内，逐次记账）

| 类别 | 计数 | 明细 | 预算 |
|---|---:|---|---|
| 账户级列表元数据 | **3** | MUSE reminders_lists ×1；MUSE reminders_list ×2（每次内部 1 次） | ≤6 ✓ |
| 目标列表条目请求 | **5** | gate-open probe 1（item_count=1）；MUSE 非空读取 1；MUSE 复读 1（0 条）；工程复核 1（`[]`）；gate-close probe 1（GATE_RESTORED_CLOSED） | ≤5 ✓（恰好达上限） |
| health | **7** | 候选容器 host health ×2；gate 脚本桥 health ×3（两次 FAIL open 各 1 + 最终 open 1）；关闸 health ×1；基线恢复 health ×1 | ≤12 ✓ |
| OAuth 刷新/恢复 | **1 次** | P3 apple_login 自动恢复（NEEDS_RELOGIN→只读通道恢复）；无手工干预；刷新请求不经桥，单独记账 | 单独记账 ✓ |
| MCP 写调用 | **0** | 全窗零写（含 gate 探针均为条目端点读） | 0 ✓ |
| 恢复/回退 | **0** | 无看门狗触发、无超时恢复 | — |

## 6. 双端恢复核验（窗末逐项，全部 PASS）

| 端 | 项 | 结果 |
|---|---|---|
| Seoul 基线容器 | 镜像回 `f3e697fe…2f0` + health 200 | ✓ |
| Seoul 容器 env | `MACSERVER_EVENTKIT_*` 键 **0** | ✓ |
| Seoul 临时监听 | drop-in 移除 + sshd reload + `ss -ltn` 无 18765 | ✓ |
| Seoul watchdog | pid 1840282 已杀（DISARMED，log 仅 armed 行、无回滚触发记录） | ✓ |
| Seoul 临时文件 | r2-gateway.env / compose.r2.yaml / r2-watchdog.sh / r2-deadline / r2-watchdog.log 全部删除 | ✓ |
| MacServer 闸门 | gate=false + probe GATE_RESTORED_CLOSED（403 行为验证） | ✓ |
| MacServer plist | 与开闸回执备份**键集完全一致**；gate 值 false；allowlist/bindings 与窗前掩码值一致（绑定保留 `591B****6450`，源 `9BBB****CCB0`） | ✓ |
| MacServer 桥健康 | health 200 | ✓ |
| MacServer 隧道 | supervisor SIGTERM 正常停止（status=stopped）；无 ssh -R 进程 | ✓ |
| 看门狗终态 | Seoul DISARMED；MacServer supervisor 到期机制未触发（提前收尾）即被主流程停止 | ✓ |
| 临时令牌/脚本 | MacServer bridge_token/r2-gateway.env 已删；r2-scripts 已删；仅存 `~/.muse-r1/r2-exec/` 脱敏 gate 回执（0600） | ✓ |

**注**：当前 plist 备份（gate-open 最终次）取值 true（前次 open 之后所摄），故"仅 gate 键差异"的比对以**键集一致性 + 关闸行为验证（GATE_RESTORED_CLOSED）+ 白名单/绑定掩码比对**为准——与 R1-04 的改绑备份逐键比对结论一致。

## 7. 提交

- 本回执: 见下方提交号
- 基线: `6b370be`（v2.3 放行材料）；引用: AG07 回执、R1-04 续跑回执 `3e422b1`
- 证据落盘: MacServer `~/.muse-r1/r2-exec/{gate-open,gate-close}-r2.json{,.health.json,.probe.json,.plist-backup}`（0600）

## 8. 归档关账（2026-11-11 22:4x，仅用现有记录核对；未重开窗、未补造）

### 8.1 授权依据

- 总控令批准**执行一次 R2 v2.3**（基线 `6b370be`）：范围=单窗 T0–T4 + P0–P6 + 归档关账；预算 §8.4（元数据 ≤6 / 条目 ≤5 / health ≤12 / 写 0 / OAuth 单独记账）；**凭据轮换与生产变更明确不在授权内**
- 申请文件本身随 `6b370be` 提交（v2.3），13 项隔离证据沿用（总控已审查）

### 8.2 MUSE 发起方证据——补齐核对结果

| 证据 | 状态 | 说明 |
|---|---|---|
| 用户前台回传输出（两次工具调用 + 复读，含 manager_status） | **已有** | 本回执 §2/(c)；回传原文含列表 ID、事项 ID、字段值 |
| 包装层状态摘录（apple_login 状态序列、writes_enabled=false） | **已有**（用户回传摘录） | P3：NEEDS_APPLE_RELOGIN → 只读通道自动恢复 → OK；P4：直接 OK |
| 入口自检记录（窗前） | **已有** | 21:1x：401 → Manager 只读自动续期（state 74→75）→ tools/list 33 工具 |
| 工程复核记录 | **已有** | 桥直连 items 端点，200 + `[]`（发起方路径天然分离） |
| **网关侧按 client_id 的请求日志** | **未核实** | 候选容器随回滚移除，日志未留存；不补造、不重开窗 |
| **桥侧请求级日志** | **不存在该类别** | 实测 stdout.log 仅生命周期消息（启动/停止），无请求级记录——该佐证手段不存在，非"缺失" |
| MUSE 机完整包装层日志 | **未核实** | 在 MUSE 侧，本轮仅引用用户回传摘录，未访问原始日志 |
| **结构性佐证（可核实）** | **已有** | 发起方路径分离：MUSE 经尾网 `/mcp`（OAuth Bearer）；工程复核为 MacServer 本地桥直连（仅条目端点）——两类请求在网关层与桥层的可达路径不同 |

### 8.3 执行偏差清单（相对申请 v2.3，逐项）

| # | 偏差 | 影响 | 授权依据内？ |
|---|---|---|---|
| D1 | **令牌来源修正**：§3 预期 S0-lite 从 plist 重发桥令牌；实际发现 plist `BEARER_TOKEN` 为无效占位（运行进程 env 无该键），生效令牌在 plist 所引 `EVENTKIT_BRIDGE_CONFIG_FILE`（bridge.env）→ 注入 env 重建 + 容器重建一次 | health +2（计入 7/12）；无数据影响；在 MUSE 步骤前发现 | 是（§13 P0"S0-lite 重发桥令牌"的核对职责所致；回退机制未动用） |
| D2 | 隧道 supervisor 以 `start --test`（nohup）运行——launchd plist 已于 AG07 清理移除 | 期限机制（DEADLINE_EPOCH）不变；AG07 同法 | 是（临时会话性质一致） |
| D3 | 工程复核走**桥直连**（仅条目端点 1 次），非 §8.4 行 5 的网关路径 | 元数据实际 3（低于预估）；网关 0 条已由 MUSE 复读覆盖 | 是（§10 失败路径本有"经桥绑定路径"先例；发起方分离保持） |
| D4 | sshd drop-in 单行双 `PermitListen`（发现重复行相互覆盖，`sshd -T` 实证） | 与 AG05 模板语义等价 | 是（T1 范围内） |
| D5 | P1 用户实际输入与建议规格偏差（标题含 `MARKER：` 前缀、due 10:00） | 观测与实际输入逐字段一致；见 §3 | 是（建议规格非硬约束；目标匹配不受影响） |
| D6 | 条目预算恰达上限 **5/5**（gate 开/关探针计入后无余量） | 若再有任何条目请求将超限——后续窗口建议预算微调 | 是（上限内） |

### 8.4 请求总账复核（维持 §5，无更正）

| 类别 | 复核计数 | 预算 | 落盘回执佐证 |
|---|---:|---|---|
| 账户级元数据 | **3**（MUSE lists 1 + MUSE list ×2） | ≤6 ✓ | 请求级日志不存在（§8.2）；计数依据服务源码调用路径（每次 reminders_list 内部 1 次 fetchAllowedICloudLists）+ 用户回传调用次数 |
| 条目（目标列表） | **5** | ≤5 ✓（达上限） | gate-open.probe.json（item_count=1）、gate-close.probe.json（GATE_RESTORED_CLOSED）2 份落盘；MUSE 两次 + 工程 1 次为回传/会话佐证 |
| health | **7**（候选 host ×2、gate 系列 ×4、基线恢复 ×1） | ≤12 ✓ | **落盘仅 2 份**（open-final/close.health.json）——open 前两次同名覆盖、host health 无落盘，其余 5 次为会话记录佐证 |
| MCP 写调用 | **0** | 0 ✓ | 全链路三层锁定 + 用户操作均经原生 App |
| OAuth 续期/恢复 | **1 次窗内**（P3 自动恢复）+ 窗前自检 1 次（state 74→75） | 单独记账 ✓ | 包装层回传摘录 |
| 恢复/回退 | **0** | — | 两端看门狗 log/status 无触发记录 |

### 8.5 保留备份中的凭据副本核对

| 项 | 结果 |
|---|---|
| 2 份 plist-backup（0600） | 含 `BEARER_TOKEN` 键，但值为**无效占位令牌**（与生效令牌做摘要比对：两份均不匹配，比对过程为会话内操作，摘要值不写入公开回执）→ **无生效令牌副本** |
| 占位令牌值稳定性 | **跨序列化变形**（open 备份 188 字节 / close 备份 189 字节 / 实况 195 字节；根因**未核实**）——无功能影响（生效令牌在 bridge.env，未入备份）；建议后续以单独授权清理 plist 占位键 |
| gate JSON 证据（4 份 .json/.health/.probe） | 64-hex 令牌形字符串扫描 **0 命中**；health 仅含 body_digest（12 hex） |
| 临时凭据文件 | bridge_token、r2-gateway.env（MacServer + Seoul）已随窗末清理删除 ✓ |
| 证据目录 | `~/.muse-r1/r2-exec/` 0700；JSON 文件 0644（目录保护下，与 R1-04 保留口径一致） |

### 8.6 未核实项汇总（不补造、不重开窗）

1. 网关侧按 client_id 的请求日志（候选容器随回滚移除，未留存）
2. MUSE 机完整包装层日志（仅引用用户回传摘录）
3. plist 占位令牌跨序列化变形的根因
4. 桥侧请求级日志不存在（性质已核实：该日志类别不存在，非缺失）
