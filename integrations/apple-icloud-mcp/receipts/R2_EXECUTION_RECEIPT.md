# R2 执行回执（MUSE 前台只读验收）

- **回执类型**: R2_EXECUTION_RECEIPT（脱敏）
- **授权**: 总控批准执行一次 R2 v2.3（基线 `6b370be`）；单窗 3600 秒硬期限；**全程按申请执行，正常路径完成，未触发看门狗回滚**
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
