# R1-01 真实诊断授权申请（MacServer 本地只读）

- **任务**：REM-R1-01 新版 iCloud 提醒事项空列表定位
- **申请方**：WorkBuddy（本专项唯一工程主执行 Agent）
- **提交时间**：2026-11-10 13:30 CST
- **当前 R1 状态**：`NOT_STARTED`（离线工作已完成，真实诊断零执行）
- **本次申请覆盖**：仅 A 层（工程 Agent 直连诊断）。不覆盖 MUSE 前台验收（B/C/D 层）、不覆盖完整网关试运行、不覆盖任何写能力扩展。

---

## 0. 一句话结论与申请意图

历史上每一次读取都返回 `200 + []`，而所有回执都没有记录过"该列表曾经有事项"的证据。因此当前无法区分两种情形：**列表本来就是空的**，还是**读取链路只会返回空**。二者用一次受控的真实读取即可判定，但真实读取必须先有一个"确认存在"的合成事项。

**本申请请求批准**：在 MAC-1 上执行一次 ≤45 分钟的只读诊断窗口，期间由用户手工创建一个合成事项、由 WorkBuddy 用现有已签名产物采集 3 次只读证据、由用户精准删除该事项、全流程自动关闸并复验 403。

---

## 1. 精确设备、程序与版本核验计划

### 1.1 目标设备

| 项 | 值 | 来源 |
| :--- | :--- | :--- |
| 别名 | MAC-1 | 本申请 |
| 设备标识 | `100.100.***.91`（完整值仅在受限本地记录） | AG-04 回执 |
| OS | macOS 15.7.7 Sequoia | AG-06 回执 |
| 架构 | x86_64（Intel） | AG-06 回执 |
| 图形会话 | `gui/501`（Aqua），用户 `jin` | AG-06 回执 |
| 服务 | LaunchAgent `com.muse.macserver-eventkit`，`RunAtLoad` + `KeepAlive` | plist 模板 |
| 监听 | `127.0.0.1:18765`，仅回环 | 服务实现 `bind(127.0.0.1)` |

> WorkBuddy 当前运行在另一台主机（macOS 27.0.1 / arm64，无 18765 监听）。**本申请不主张 WorkBuddy 与 MAC-1 为同一台设备**，所有 MAC-1 动作均需在 MAC-1 上的操作入口执行。

### 1.2 程序与产物

| 项 | 值 |
| :--- | :--- |
| 程序路径 | `/Users/shared/bin/EventKitBridgeServer` |
| 已部署 SHA256 | `f78e24e533c2bf9a77161dc05eb154ce99687de9a5b881ad481bfbe2bbfb3074` |
| 构建时间 | 2026-11-09T14:56:14Z |
| 签名 | adhoc + hardened runtime；DR = cdhash `a25782f9…`(x86_64) / `f00641aa…`(arm64) |
| 源码版本 | **未核实**（见下） |

**源码版本核验计划（本申请请求执行）**

1. 在 MAC-1 上实测 `shasum -a 256 /Users/shared/bin/EventKitBridgeServer`，与上述冻结值比对；
2. `codesign --verify --strict --all-architectures -vvv` + `codesign -dvvv --arch=x86_64` 取 cdhash、flags、min OS；
3. `otool -arch x86_64 -l` 确认 `__TEXT,__info_plist` 存在；
4. 比对 `BUILD_METADATA.json`（当前**不含** source commit，仅含哈希与时间戳）。
   → 结论口径：本次只能证明"运行产物 = 已归档的哈希"，**不能**证明"运行产物 = 某个 commit"。该缺口已由本次离线提交修复（新增 `source_provenance`），但**要等下一次经批准的重建才生效**；本次不重建。

### 1.3 TCC 与 403 的区分口径（重要，避免把两种 403 混为一谈）

已部署二进制中，"闸门关闭"与"TCC 被拒"返回的都是 HTTP 403 `PERMISSION_DENIED`。判定规则：

| 观测 | 判定 |
| :--- | :--- |
| 开闸后 `/reminders/lists` 返回 **200** | 闸门已生效且 TCC 正常 |
| 开闸后仍 **403**，且 plist 中 `EVENTKIT_BRIDGE_PRODUCTION_AUTHORIZED=true` 已确认写入 | 判定为 **TCC 被拒 / 授权已失效** → 停止窗口，报 `BLOCKED (TCC)`，不在本窗口内重开授权 |
| 开闸后 **403**，且 plist 值仍为 false | 判定为 **闸门未生效** → 按恢复步骤回滚，报 `INTERRUPTED (gate not applied)` |
| （可选）用户在 MAC-1 图形会话执行 `EventKitBridgeServer --check-authorization` 返回 `authorized:true` | 作为 TCC 的独立旁证 |

---

## 2. 唯一已绑定专用列表的身份对应方法

公开别名：**LIST-ALPHA**（`9D9A****03F3`）。完整标识仅写入受限本地记录，不进入本申请正文、回执或提交。

对应方法（只涉及一个列表，不枚举其他列表或账户）：

1. 通过 bridge 的 `/reminders/lists` 读取元数据。该端点受 `EVENTKIT_BRIDGE_ALLOWED_LIST_IDS` 白名单约束，**只会返回已绑定的那一个列表**，不暴露其他列表。
2. 校验四元组一致：`listID` == 绑定值、`sourceType` == `calDAV`、`sourceName` == `iCloud`、`sourceID` 与绑定值一致。
3. 记录 `calendarIdentifier`（列表 ID）与 `sourceIdentifier`（账户来源 ID）的**完整值**到受限本地记录：
   `~/.config/muse-r1/identity.private.json`（`0600`，不入库、不进回执）。
4. 用户在 MAC-1 原生提醒事项 App 中只查看该一个列表的名称，确认与 LIST-ALPHA 对应；**不打开其他列表的内容**。
5. 报告中仅出现 `9D9A****03F3` 形式的掩码。

> 说明：`writable:false` 是网关代码写死的常量，不是 EventKit 属性，不作为身份或权限证据。

---

## 3. 合成事项规格（精确）

### 3.1 现状证据

**没有**任何证据表明该列表当前存在事项：B3（11-07）、AG-04（11-08）、AG-07（11-10）三次真实读取均为 0 条；所有写入路径在历史配置中均关闭（桥只读、网关拒绝写、`ALLOW_REMINDERS_WRITE_1=false`）。因此本申请按"需要创建"处理。

### 3.2 唯一一个合成事项（不批量、不追加）

| 字段 | 精确值 |
| :--- | :--- |
| 列表 | 仅 LIST-ALPHA |
| 标题 | `[MUSE-R1-SYN-20261110-01] 只读读取保真核验` |
| 备注 | `R1-01 合成事项，仅用于只读字段保真核验，验收后精准清理。MARKER=R1SYN20261110A` |
| 截止日期 | 2026-11-17 10:30（Asia/Shanghai），即 **2026-11-17T02:30:00Z**，**带时间**（非全天） |
| 优先级 | 中（Reminders UI 为"中"；EventKit `priority` 期望 `5`） |
| 完成状态 | 未完成（`isCompleted=false`） |
| URL / 重复 / 提醒 | 均不设置；若 App 自动附加默认提醒，保存后移除 |

### 3.3 期望观测（R1 判定依据）

| 断言 | 期望 |
| :--- | :--- |
| `title` | 与上表逐字一致 |
| `notes` | 与上表逐字一致（含 MARKER） |
| `dueDate` | 存在，解码为 `2026-11-17T02:30:00Z` |
| `isAllDay` | `false` |
| `priority` | `5` |
| `isCompleted` | `false` |
| `listID` | 等于绑定值 |
| `itemID` | 非空；完整值仅入受限记录 |
| `timeZone` | **允许为 null**（EventKit 对 iCloud 事项常不返回 `components.timeZone`）；若返回则应为 `Asia/Shanghai`。为 null 记录为 INFO，不判失败 |

### 3.4 创建、记录与清理的责任划分

| 环节 | 执行者 | 入口 | 说明 |
| :--- | :--- | :--- | :--- |
| 创建（1 次） | **用户**（MAC-1 图形会话） | 原生提醒事项 App | 桥是只读的，且当前无 GUI 自动化授权；这是最小权限路径。WorkBuddy 提供逐字段核对清单，并在创建后立即用只读读取确认 |
| 对象 ID 记录 | **WorkBuddy** | 取证脚本输出 | 完整 `itemID` 仅写受限本地记录；回执中仅掩码 |
| 读取取证 | **WorkBuddy** | `r1_window.sh` + `r1_capture_readonly.py` | 只读 GET，单列表，3 次 |
| 清理（1 次） | **用户** | 原生提醒事项 App，按完整标题精准删除 | 只删该一条，不做范围删除 |
| 清理核验 | **WorkBuddy** | 第 3 次取证 | 断言返回 0 条，且无 `[MUSE-R1-SYN-` 前缀残留 |

> 备选（**不推荐**，需额外授权）：由 WorkBuddy 用 `osascript` 驱动 App 完成创建/删除。这需要新增"自动化/辅助功能"TCC 授权，且会在受限窗口内引入新的 GUI 依赖，故本次不申请。

---

## 4. 对照矩阵（同一账户 / 同一列表 / 同一事项 / 相近时间）

| 通道 | 说明 | 强制 | 证据缺口处理 |
| :--- | :--- | :--- | :--- |
| **C1 原生 App** | MAC-1 上提醒事项 App 打开 LIST-ALPHA，人为目视计数 | 是 | 由用户口述 + 截图（可选），WorkBuddy 不代替 |
| **C2 云端观察** | iCloud.com 网页版提醒事项 | 否 | 若不可用/未登录，记录 `CLOUD_OBSERVATION_UNAVAILABLE` 作为证据缺口，不影响 A 层结论 |
| **C3 EventKit** | bridge `GET /reminders/lists/{id}/items` | 是 | 由取证脚本输出 JSON 回执 |

判读表：

| C1 | C3 | 结论 |
| :--- | :--- | :--- |
| 显示 1 条 | 读到 1 条且字段全对 | **R1 PASS** |
| 显示 1 条 | 读到 1 条但字段不符 | `FAIL (field fidelity)`，定位映射层 |
| 显示 1 条 | 读到 0 条 | 排除 H1（列表非空）；剩 H2 同步、H4 身份漂移、H5 EventKit 查询层 |
| 显示 0 条 | 读到 0 条 | 创建/保存未落到该列表或未同步 → 检查是否存到本地"提醒事项"默认列表（H4/H2） |
| — | 403 / 超时 / 5xx | `BLOCKED`，按 §1.3 区分闸门与 TCC |

---

## 5. 需要的运行时动作、影响、时限与恢复

| 动作 | 必要性 | 影响面 | 时限 | 恢复 |
| :--- | :--- | :--- | :--- | :--- |
| 打开原生提醒事项 App | C1 通道 + 唯一创建入口 | 仅 GUI，不写文件 | 窗口内 | 关闭 App |
| 编辑 LaunchAgent plist 的 `EVENTKIT_BRIDGE_PRODUCTION_AUTHORIZED` | 业务端点在闸门关闭时一律 403，不开闸无法读取 | 该 plist 单个键；执行前 `cp -p` 备份到同目录 `*.r1-backup-<epoch>` | 每次 ≤2 分钟 | 脚本 `EXIT` trap 恢复为 `false` → `kickstart -k` → 复验 403 |
| `launchctl kickstart -k gui/501/com.muse.macserver-eventkit` | 配置仅在进程启动时读取，改值必须重启才生效 | 服务重启约 2–3 秒不可用；**同一二进制、同一 cdhash，TCC 授权不受影响** | 每次约 3 秒 | 同上 |
| 安装候选产物 / 重建 / 重新签名 | **不申请** | — | — | — |
| 反向 SSH 隧道 / Seoul 网关 / 容器 | **不申请**（A 层仅用回环） | — | — | — |
| 网络、防火墙、sshd、Tailscale 策略 | **不申请** | — | — | — |

**窗口总时长**：45 分钟申请上限；预计实际占用 12–18 分钟（创建 3 分、取证 2 分钟 + 60 秒间隔、清理 3 分、恢复验证 3 分）。**累计开闸时长预计 < 4 分钟**，分两段（每段一个取证批次）。

---

## 6. 硬边界（本申请明确不做）

- 不修改 Seoul 任何状态：镜像、环境变量、容器、权限位、令牌仓库。
- 不建立完整网关试运行，不启隧道，不动端口转发。
- 不读取、导出、刷新、创建、替换任何凭据；**不打开** `bridge.env`（除非走 §7.2 备选并获单独批准）。
- 不枚举其他列表、其他账户、其他日历内容。
- 不做全盘扫描、不做未知设备端口探测、不退役任何实验资源。
- 不做生产文件替换，不合并任何 PR。
- 不把 MUSE 前台验收由工程 Agent 代签。

---

## 7. 执行时序与精确命令

### 7.1 令牌处理（二选一，默认 A）

**A（默认，推荐）**：由用户在 MAC-1 的操作会话中把令牌注入环境变量，WorkBuddy 只读取环境变量，全程不落盘、不回显、不写回执。

```bash
# 由用户在自己的 MAC-1 会话中执行一次（不要在共享日志中回显）
read -r -s -p "bridge token: " EVENTKIT_BRIDGE_TOKEN; export EVENTKIT_BRIDGE_TOKEN
```

**B（备选，需单独批准）**：允许 WorkBuddy 在 MAC-1 上从 `~/.config/muse-macserver/bridge.env` 单行读取该令牌到进程变量（`awk` 取 `EVENTKIT_BRIDGE_BEARER_TOKEN` 一行），不打印、不复制、不入库。

> 两种方式下，脚本都只在构造 `Authorization: Bearer` 头时使用该值。

### 7.2 阶段 P0：前置核验（闸门保持关闭，零变更）

```bash
cd <repo>/integrations/apple-icloud-mcp/macserver-eventkit

# 干跑：只打印计划与前置校验结果，不做任何变更
scripts/r1_window.sh \
  --list-id "$R1_LIST_ID" \
  --expect-title '[MUSE-R1-SYN-20261110-01] 只读读取保真核验' \
  --expect-notes 'R1-01 合成事项，仅用于只读字段保真核验，验收后精准清理。MARKER=R1SYN20261110A' \
  --out-dir "$HOME/r1-evidence"

# 干跑应输出：sha256 匹配冻结值、signature VALID、gate at start: false
# 若 signature INVALID 或 sha256 不匹配 → 立即停止，报 BLOCKED，不要开闸
```

同时记录基线：`curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:18765/health`（期望 200，`/health` 不受闸门约束）。

### 7.3 阶段 P1：创建合成事项（用户）

用户在 MAC-1 图形会话打开提醒事项 App → 选择 LIST-ALPHA → 按 §3.2 逐字段创建 → 保存后目视确认列表内为 1 条，且标题无多余空格。

### 7.4 阶段 P2：第一批取证（开闸 → 读 2 次 → 自动关闸）

```bash
scripts/r1_window.sh --confirm \
  --list-id "$R1_LIST_ID" \
  --expect-title '[MUSE-R1-SYN-20261110-01] 只读读取保真核验' \
  --expect-notes 'R1-01 合成事项，仅用于只读字段保真核验，验收后精准清理。MARKER=R1SYN20261110A' \
  --out-dir "$HOME/r1-evidence" \
  --passes 2 --interval 60 --deadline 600
```

期望终态：`WINDOW_RESULT: CAPTURE_OK_GATE_CLOSED_VERIFIED`，且 `r1_pass_1.json`、`r1_pass_2.json` 落盘。

### 7.5 阶段 P3：清理（用户）+ 第三批取证

用户按完整标题精准删除该 1 条 → 目视列表为空 → 运行：

```bash
scripts/r1_window.sh --confirm \
  --list-id "$R1_LIST_ID" \
  --expect-title '[MUSE-R1-SYN-20261110-01] 只读读取保真核验' \
  --expect-notes 'R1-01 合成事项，仅用于只读字段保真核验，验收后精准清理。MARKER=R1SYN20261110A' \
  --out-dir "$HOME/r1-evidence" \
  --passes 1 --deadline 300
```

期望：`EMPTY_ARRAY_CONFIRMED_BY_BRIDGE`（证明清理生效，且再次确认链路可读）。

### 7.6 阶段 P4：恢复复验（脚本已自动完成，此处为独立复核）

```bash
plutil -extract EnvironmentVariables.EVENTKIT_BRIDGE_PRODUCTION_AUTHORIZED raw \
  "$HOME/Library/LaunchAgents/com.muse.macserver-eventkit.plist"     # 期望 false
curl -s -o /dev/null -w '%{http_code}\n' \
  -H "Authorization: Bearer $EVENTKIT_BRIDGE_TOKEN" \
  http://127.0.0.1:18765/reminders/lists                             # 期望 403
curl -s http://127.0.0.1:18765/health                                # 期望 200
pgrep -fl EventKitBridgeServer                                       # 期望仅 1 个守护进程
```

---

## 8. 期限保护与恢复失败的处理

1. **期限**：每次脚本运行内置 `--deadline`（绝对秒数），到点即关闸退出（exit 4，回执标记 `partial`）。
2. **自愈**：关闸逻辑挂在 `EXIT` trap 上，正常结束、异常退出、`Ctrl-C`、`SIGTERM` 均会触发。
3. **复验**：关闸后脚本**必须**重新断言 `/reminders/lists` 返回 403 才输出成功；否则输出 `CAPTURE_OK_GATE_CLOSE_FAILED`（exit 3）。
4. **失败处理**：出现 exit 3 时，WorkBuddy 立即停止一切后续步骤，报告实际状态与已执行步骤，**不重试**、不手工"补清理"冒充自动恢复，交由统筹决定。
5. **最坏情况**（进程被强杀导致 trap 未执行）：以备份 plist 回滚：
   ```bash
   cp -p "$HOME/Library/LaunchAgents/com.muse.macserver-eventkit.plist.r1-backup-<epoch>" \
         "$HOME/Library/LaunchAgents/com.muse.macserver-eventkit.plist"
   launchctl kickstart -k gui/501/com.muse.macserver-eventkit
   ```
   并在回执中如实记录"由人工回滚，非自动恢复"。

---

## 9. UNKNOWN 处理规则

本窗口内 WorkBuddy 不通过 bridge 发起任何写操作（bridge 本身只读，写动词返回 405）。唯一写动作是用户在 App 内的创建/删除，因此：

1. 若用户创建后**无法确认是否保存成功**：不重复创建；先做一次只读读取，若返回 0 条则判定未保存，由用户重试一次；若返回 ≥1 条则以实际观测为准。
2. 若删除后**无法确认是否删除**：不重复删除；以第 3 次取证结果为准；若仍返回该事项，停止并升级统筹，不做范围删除。
3. 若出现重复事项（同标题 ≥2 条）：**不自动删除**，保留现场，报告并等待指令。
4. 任何"写入已发送但结果未知"的情形，禁止自动重试、禁止切换后端、禁止扩大读取范围。

---

## 10. 请求批准的范围（逐条）

批准以下 9 项即视为授予本窗口内完整自主执行权，WorkBuddy 可在范围内完成诊断、常规修复与验证，不再逐条申请：

- [ ] **A1** 在 MAC-1 执行 §1.2 的只读产物核验（shasum / codesign / otool），并记录输出到回执。
- [ ] **A2** 在 MAC-1 以只读方式调用 `127.0.0.1:18765` 的 `/health`、`/reminders/lists`、`/reminders/lists/{LIST-ALPHA}/items` 三个端点，单列表、仅 GET。
- [ ] **A3** 使用 §7.1-A 方式获得令牌（用户在会话中注入环境变量）；若需改用 §7.1-B（读 `bridge.env` 单行），单独批准。
- [ ] **A4** 临时把 `EVENTKIT_BRIDGE_PRODUCTION_AUTHORIZED` 置为 `true` 并 `kickstart -k` 重启该 LaunchAgent，累计开闸 ≤ 10 分钟，结束后必须恢复 `false` 并复验 403。
- [ ] **A5** 由用户在 MAC-1 原生提醒事项 App 创建 1 条合成事项（§3.2），事后再精准删除该 1 条。
- [ ] **A6** 在 MAC-1 本地写入取证产物：`~/r1-evidence/*.json` 与受限身份记录 `~/.config/muse-r1/identity.private.json`（0600）。
- [ ] **A7** 在 MAC-1 图形会话打开提醒事项 App 做目视核对（C1 通道），由用户口述结果，WorkBuddy 记录。
- [ ] **A8** 允许 WorkBuddy 记录 C2（iCloud 网页）是否可用；不可用即记录证据缺口，不尝试登录或绕行。
- [ ] **A9** 允许把脱敏后的结论作为新回执提交到隔离分支 `feat/r1-01-readonly-diagnostic-harness`（不合并 PR、不改动 PR #19–#23）。

**未包含在本批准内的动作**（仍需单独申请）：重建/重签二进制、新增 TCC 授权、GUI 自动化（osascript）、Seoul 任何变更、隧道、任何写能力扩展、PR 合并、历史回执改写（含 AG-07 未脱敏 UUID 的修订）。

---

## 11. 判定口径（PASS / FAIL / BLOCKED 的具体断言）

| 判定 | 具体断言 |
| :--- | :--- |
| **R1 PASS** | `r1_pass_1.json` 或 `r1_pass_2.json` 中 `classification == NON_EMPTY_SYNTHETIC_ITEM_PRESENT`，且 `title_exact_match` / `notes_exact_match` / `priority_match` / `completion_state_match` / `due_date_present` / `list_id_attribution_match` 全部 PASS，并记录二进制 SHA256、签名核验结果、观测时间、列表身份对应结果 |
| **R1 FAIL（可判定）** | 同一窗口内 C1 显示 ≥1 条、C3 返回 0 条，且已排除闸门与 TCC（§1.3）→ 输出已排除项（H1、H3）与未排除项（H2/H4/H5），不得只写"可能同步延迟" |
| **R1 BLOCKED（TCC）** | 开闸后 `/reminders/lists` 仍 403 且 plist 已确认为 true |
| **R1 BLOCKED（前置）** | 二进制 SHA256 不匹配、签名 INVALID、python3 缺失、plist 不可写 |
| **R1 INTERRUPTED** | 窗口被 deadline 或外部中断终止，且恢复复验未完成 |
| **不构成 PASS 的情形** | 空数组、Mock/Fake 结果、工程直连但未记录程序版本与哈希、B/C/D 层调用、MUSE 未独立签署 |

> **本次离线工作完成 ≠ R1 完成。** R1 通过前不启动完整网关验收；R1 通过后再提交 R2 的具体方案与授权申请。

---

## 附：本窗口使用的离线产物（已在隔离分支提交）

| 文件 | 作用 |
| :--- | :--- |
| `macserver-eventkit/scripts/r1_capture_readonly.py` | 只读取证，输出可归档的分类回执（空/非空/错误严格区分；不回写标题、备注、对象 ID） |
| `macserver-eventkit/scripts/tests/r1_capture_test.mjs` | 离线差分测试，用网关 Fake Bridge 覆盖 5 种情形，25/25 通过 |
| `macserver-eventkit/scripts/r1_window.sh` | 自闭合开闸窗口：干跑默认、哈希与签名门禁、`EXIT` trap 关闸、关闸后复验 403 |
| `macserver-eventkit/scripts/write_build_metadata.py` | 构建溯源写入与校验（修复 BUILD_METADATA 缺 source commit 的缺口） |
