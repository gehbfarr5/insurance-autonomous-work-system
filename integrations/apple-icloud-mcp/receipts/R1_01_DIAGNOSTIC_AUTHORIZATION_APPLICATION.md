# R1-01 MacServer 本地只读诊断授权申请（修订版 v2）

- **任务**：REM-R1-01 新版 iCloud 提醒事项空列表定位
- **申请方**：WorkBuddy（本专项唯一工程主执行 Agent）
- **版本**：v2（2026-11-10 18:20 CST）。v1 未获真实操作授权，本版按审查意见逐条修订，**不是**新任务。
- **R1 状态**：`NOT_STARTED`（离线工程闭环已完成，真实诊断零执行）
- **本申请只覆盖 R1**：MacServer 本地工程诊断。MUSE 独立验收属 **R2**，与 R1 是并列关系，**不是** R1 的前置条件或替代条件（见 §1）。

---

## 0. 一页摘要

**问题**：历史三次真实读取（B3 11-07、AG-04 11-08、AG-07 11-10）全部返回 `200 + []`。所有回执都没有记录过"该列表曾经有事项"的证据，所以"列表本来就是空"和"读取链路只会返回空"这两种情形目前无法区分。

**结论**：区分二者只需一次受控真实读取，但必须先有一个**确认存在**的合成事项。

**本申请请求批准**：一次 **45 分钟上限**的 MacServer 本地只读诊断会话，包含

1. 只读核验运行产物身份（哈希 / 签名 / cdhash / 进程）；
2. 用户在该列表创建 **1 条**合成事项；
3. WorkBuddy 用已签名产物执行 **2 批次**只读采集（同一绝对截止，累计开闸 ≤ 600 秒）；
4. 用户精准删除该 1 条；
5. WorkBuddy 执行 **1 批次**清理核验（同一脚本 `--expect absence`）；
6. 全程自动关闸并复验 403，无论成功失败。

**批准后**：WorkBuddy 在范围内自主执行，不再逐条申请。**未批准前**：不连接 MacServer、不读取凭据、不开闸、不创建任何事项。

---

## 1. 分层边界：R1 与 R2 是两件事

| 层 | 内容 | 归属 | 本申请 |
| :--- | :--- | :--- | :--- |
| **A** | 工程直连只读诊断（回环 HTTP + 本机脚本） | **R1** | ✅ 本申请唯一覆盖对象 |
| **B** | MUSE 前台触发（GUI/前端交互） | R2 | ❌ 不申请 |
| **C** | 脚本包装层 | R2 | ❌ 不申请 |
| **D** | 原生 MCP 工具调用 | R2 | ❌ 不申请 |

- R1 的通过标准由 **A 层**观测直接判定：同一列表、同一合成事项，被 MacServer 的 EventKit 正确读取。
- R2（MUSE 前台验收）由 MUSE 侧**独立签署**，工程 Agent 不代签，也不把其签署作为 R1 本地读取的前置或附加条件。
- 本申请**不**启动网关试运行、**不**建隧道、**不**改动 Seoul。

---

## 2. 设备、程序与身份核验

### 2.1 目标设备（沿用已有记录，本次不重新采集）

| 项 | 值 | 来源 |
| :--- | :--- | :--- |
| 节点别名 | `macserver-ts`（Tailscale 名） | `acceptance-request/MACSERVER_ACCEPTANCE_REQUEST.md` §2 |
| 地址 | `100.100.***.91`（完整值仅存受限本地记录） | 同上 |
| OS / 架构 | macOS 15.7.7 (24G720) / x86_64 | 同上、AG-06 回执 |
| 执行用户 | uid 501(jin), gid 20(staff) | 同上 |
| 图形会话 | `jin console`, session=Aqua | 同上 |
| LaunchAgent | `com.muse.macserver-eventkit`，`RunAtLoad` + `KeepAlive` | plist 模板 |
| 监听 | `127.0.0.1:18765`（仅回环） | 服务实现 |

> WorkBuddy 运行在另一台主机（macOS 27.0.1 / arm64），**与 MAC-1 不是同一台设备**，也不存在 18765 监听。所有 MacServer 动作都经由 §3 的接入通道在其本机执行。

### 2.2 运行产物身份（P0 实测项）

| 项 | 冻结值 |
| :--- | :--- |
| 路径 | `/Users/shared/bin/EventKitBridgeServer` |
| SHA256 | `f78e24e533c2bf9a77161dc05eb154ce99687de9a5b881ad481bfbe2bbfb3074` |
| 构建时间 | 2026-11-09T14:56:14Z |
| 签名 | adhoc + hardened runtime（`flags=0x10002`） |

P0 采集并要求**同时**满足：路径一致、SHA256 一致、`codesign --verify --strict --all-architectures` 通过、`pgrep -x` 恰好 1 个进程，且该进程的可执行文件路径与上述路径相同（`lsof -p <pid>` 取 txt 项）。任一不符 → `BLOCKED`，不开闸。

### 2.3 TCC 核验口径（同程序身份 + 正确会话）

已部署二进制中"闸门关闭"与"TCC 被拒"返回的都是 `403 PERMISSION_DENIED`，因此 TCC 状态不能只看状态码。本申请采用：

| 观测 | 判定 |
| :--- | :--- |
| 开闸后 `/reminders/lists` → **200** | 闸门生效且 TCC 正常 |
| 开闸后仍 **403**，且**同程序身份**已确认（路径+SHA256+cdhash+pid） | 判定 **TCC 被拒/授权失效** → 停窗，报 `BLOCKED (TCC)`，本窗口内不重开授权 |
| 开闸后 **403**，但程序身份不符或闸门值为 false | 判定 **闸门未生效 / 身份漂移** → 按 §9 恢复，报 `INTERRUPTED` |

**会话正确性核验**：`stat -f %Su /dev/console` 必须为 `jin`，且 `launchctl print gui/501` 可读；否则判定"不在正确图形会话"，只做只读采集，不做任何需要会话的判定。

**诚实说明**：v1 曾写"可执行 `EventKitBridgeServer --check-authorization` 作为 TCC 旁证"。经核对该参数在源码中**不存在**，本版删除该说法。TCC 状态以行为为主证据，以用户屏幕上的"隐私与安全性 → 提醒事项"显示为旁证；**不读取 `TCC.db`**（需完全磁盘访问，且会改变取证语义）。

### 2.4 源码版本：明确的证据边界

运行产物与源码 commit **无法严格对应**：`BUILD_METADATA.json` 只有 sha256/cdhash/时间戳，没有 source commit。

- 本次**只**证明"运行产物 = 已归档哈希"，**不**主张"运行产物 = 某个 commit"。
- 缺口已在离线提交中修复（`write_build_metadata.py` 写入 `source_provenance`），但**要等下一次经批准的重建才生效**。
- **本次不重建、不重签**：adhoc 签名的 DR 基于 cdhash，重建即改变 TCC 授权对象，会把"读取定位"变成"重新授权"，污染诊断。

---

## 3. 接入方式与脚本落地

### 3.1 精确接入方式（依据已有非敏感资产，本次不连接验证）

`acceptance-request/MACSERVER_ACCEPTANCE_REQUEST.md` §2 记录了已发生的实机只读核对：工程侧经 **Tailscale → SSH 到 `macserver-ts`，以 uid 501(jin) 执行非交互命令**，完成了 OS、架构、GUI 会话、端口占用、`launchctl list`、目录权限的核查。

因此本申请的执行通道是：**WorkBuddy → Tailscale → SSH(macserver-ts, jin) → 逐条非交互命令**。不新建隧道、不改 ACL、不启用端口转发。

> 本次**不**为"确认可达"而先连一次生产。可达性作为批准后的 P0 第一步，失败即 `BLOCKED` 退出（零变更）。

### 3.2 落地文件（仅 4 个脚本 + 1 个临时令牌文件）

目标目录：`/Users/jin/r1-harness-<UTCstamp>/`，`0700`，窗口结束后删除。

| 文件 | 用途 | SHA256 |
| :--- | :--- | :--- |
| `r1_window.sh` | 自闭合窗口编排（411 行） | `5f707c2b5491943d7fc74dce4bca3c56fec813a4678d8010d2487e0a119dfa70` |
| `r1_gate.sh` | 唯一开/关闸入口（280 行） | `9468d6accd3b2703bdec6db9a56bf45eae1020b3e8a4e93ee2820270feb9c8d8` |
| `r1_watchdog.sh` | 独立期限看门狗（130 行） | `820db76c6bcc6badf57b074bf1e4fa4c29f4edd9dfeee74eb85d9291ca66e5e0` |
| `r1_bridge_client.py` | 只读客户端（562 行） | `b257dbdf873a59e6937d0f75c8a2ea92e437131c8f0f239372202fcf3c489155` |
| `token` | 临时令牌文件，`0600`，**窗口结束即删** | 不记录（内容永不落回执） |

- **不**安装到 PATH、**不**新增 LaunchAgent、**不**改 launchd 配置、**不**新增常驻进程、**不**新增二进制、**不** pip 安装。
- 证据目录：`/Users/jin/r1-evidence/<UTCstamp>/`，`0700`，**保留**（含每批次原始回执与 plist 备份）。
- 清理责任：WorkBuddy 删除 harness 目录与 token 文件；删除失败则保留现场并如实报告，不掩盖。

### 3.3 令牌处理（默认由 WorkBuddy 完成，不需要用户输入）

用户**不需要**手工输入或粘贴令牌。批准 A3 后，WorkBuddy 在 MacServer 上以单键提取方式生成临时文件：

```bash
umask 077
awk -F= '/^EVENTKIT_BRIDGE_BEARER_TOKEN=/{sub(/^EVENTKIT_BRIDGE_BEARER_TOKEN=/,""); print; exit}' \
  "$HOME/.config/muse-macserver/bridge.env" > "$HARNESS/token"
chmod 600 "$HARNESS/token"
test -s "$HARNESS/token" || { echo "TOKEN_UNAVAILABLE"; exit 2; }
```

约束：只提取**这一个键**；不打印、不进 argv、不进环境变量、不进日志或回执；窗口结束随 harness 目录删除。若该文件不存在 → `BLOCKED`，**不**尝试其他凭据来源、**不**回退到用户手工输入。

---

## 4. 操作责任划分（含 GUI 能力评估）

### 4.1 GUI 能力评估结论

- 仓库内**没有**任何 GUI 自动化资产：检索 `osascript|AppleScript|Accessibility|cliclick` 在 `integrations/apple-icloud-mcp` 下**零命中**。
- WorkBuddy 到 MacServer 的既有通道是 SSH 非交互命令，**不在 Aqua 图形会话内**；`osascript` 驱动提醒事项 App 需要 Automation（AppleEvents）、UI 脚本还需要辅助功能授权，且会在目标机弹出授权对话框——**这会改变 TCC 状态，而 TCC 状态正是本次诊断要观察的变量之一**。

### 4.2 责任划分

| 环节 | 执行者 | 依据 |
| :--- | :--- | :--- |
| 产物/进程/会话只读核验 | **WorkBuddy**（SSH） | 无需 GUI |
| 令牌准备 | **WorkBuddy**（SSH，单键提取） | §3.3 |
| 开闸 / 关闸 / 复验 403 | **WorkBuddy**（`r1_gate.sh`） | §9 |
| 两批 presence 采集 | **WorkBuddy**（`r1_window.sh`） | §8 |
| 清理核验（absence） | **WorkBuddy**（`r1_window.sh --expect absence`） | §8 |
| 证据归档、脱敏、回执 | **WorkBuddy** | §10 |
| **创建 1 条合成事项** | **用户**（MacServer 屏幕上的提醒事项 App） | 唯一的数据写入，且是无 GUI 自动化时的最小权限路径 |
| **删除该 1 条** | **用户** | 同上 |

**这一项不是"让用户排障"**：创建/删除是**唯一的数据动作**，权限上必须由人做，且只需两次点击级操作。除这两步外，诊断、核验、取证、清理确认、恢复、回执全部由 WorkBuddy 完成。

若希望完全由 WorkBuddy 代劳创建/删除，需**单独批准 A11**（GUI 自动化 + 其 TCC 影响与回滚）。默认**不**启用，因为它会引入新的 TCC 变量。

---

## 5. 变更清单（按类型分开，逐类批准）

### 5.1 文件

| 动作 | 路径 | 权限 | 说明 |
| :--- | :--- | :--- | :--- |
| 新建目录 | `/Users/jin/r1-harness-<ts>/` | 0700 | 结束后删除 |
| 新建目录 | `/Users/jin/r1-evidence/<ts>/` | 0700 | 保留 |
| 写入 | harness 下 4 个脚本 | 0700/0600 | §3.2 |
| 写入 | `token` | 0600 | 结束后删除 |
| 写入 | `~/Library/LaunchAgents/com.muse.macserver-eventkit.plist` | 保持 0644 | **仅改 1 个键的值**，改前 `cp -p` 备份到证据目录并 `chmod 600` |
| 写入 | 证据 JSON | 0644 in 0700 dir | 脱敏后 |
| 删除 | harness 目录、`token` | — | 结束即删 |

**不**触碰：二进制、plist 其他键、`bridge.env` 其他键、Seoul、隧道、容器。

> plist 的 `EnvironmentVariables` 可能含令牌，因此备份**不放在原目录**，而是放进 0700 证据目录并置 0600；回执记录备份路径与权限，不记录内容。

### 5.2 进程

| 动作 | 对象 | 影响 | 恢复 |
| :--- | :--- | :--- | :--- |
| `launchctl bootout` + `bootstrap`（或回退 `kickstart -k`） | `gui/501/com.muse.macserver-eventkit` | 服务重启 2–3 秒不可用；**同一二进制同一 cdhash，TCC 不受影响** | 关闭闸门后再重载一次，并复验 403 |

记录：目标 PID、实际可执行程序、`lstart`、配置来源（plist / config file / absent）、`process_env_observation`（**只**过滤打印这一个键的观测结果）、恢复后 PID。**不**把磁盘 plist 值当作运行进程环境。

### 5.3 部署

**无**。不安装候选产物、不替换生产文件、不改 PATH、不注册新服务、不合并 PR。

### 5.4 凭据使用

| 项 | 内容 |
| :--- | :--- |
| 读取 | `~/.config/muse-macserver/bridge.env` 中 **1 个键**（bearer token） |
| 落盘 | 1 个 0600 临时文件，窗口结束删除 |
| 出现位置 | 仅 HTTP `Authorization` 头 |
| 禁止 | argv / 环境变量 / 日志 / 回执 / 屏幕输出 / 版本库 |

> 只有在**明确批准 A3** 时才读取。脚本**不会**因为检测到 `BRIDGE_ENV_FILE` 存在就自动读取；没有 `--token-file` 直接拒绝运行。

### 5.5 真实数据操作

| 动作 | 数量 | 执行者 | 范围 |
| :--- | :--- | :--- | :--- |
| 创建提醒事项 | **1 条** | 用户 | 仅 LIST-ALPHA |
| 读取 | 3 批次只读 GET | WorkBuddy | 仅 LIST-ALPHA |
| 删除 | **1 条** | 用户 | 仅该条，按完整标题精准删除 |

不枚举其他列表/账户/日历；**不**做范围删除；**不**批量创建。

---

## 6. 唯一列表与唯一合成事项

公开别名 **LIST-ALPHA**（`9D9A****03F3`）。完整标识只进受限本地记录 `~/.config/muse-r1/identity.private.json`（0600），不进申请、回执或提交。

身份对应（只涉及一个列表）：

1. `GET /reminders/lists` 受 `EVENTKIT_BRIDGE_ALLOWED_LIST_IDS` 白名单约束，只返回已绑定的那一个列表；
2. 四元组一致：`listID` = 绑定值、`sourceType` = `calDAV`、`sourceName` = `iCloud`、`sourceID` = 绑定值；
3. 记录 `calendarIdentifier` / `sourceIdentifier` 完整值到受限记录；
4. 报告中只出现掩码。

> `writable:false` 是网关代码常量，不作为身份或权限证据。

**合成事项（仅 1 条）**

| 字段 | 精确值 |
| :--- | :--- |
| 标题 | `[MUSE-R1-SYN-20261110-01] 只读读取保真核验` |
| 备注 | `R1-01 合成事项，仅用于只读字段保真核验，验收后精准清理。MARKER=R1SYN20261110A` |
| 截止 | 2026-11-17 10:30 Asia/Shanghai = `2026-11-17T02:30:00Z`，**带时间** |
| 优先级 | 中（EventKit `priority` = 5） |
| 完成 | 未完成（`isCompleted=false`） |
| URL/重复/提醒 | 不设置；App 自动附加的默认提醒，保存后移除 |

**判定断言**（全部必须成立）：`title` 逐字、`notes` 逐字（含 MARKER）、`dueDate` 解码等于上述时刻、`isAllDay=false`、`priority=5`、`isCompleted=false`、`listID` = 绑定值、`itemID` 非空、**唯一匹配 1 条**。

`timeZone` 允许为 `null`：EventKit 对 iCloud 事项常不返回 `components.timeZone`，记为 INFO，不判失败；若返回则应为 `Asia/Shanghai`。**不**把 `timeZone=null` 写成普遍规律，只记录本次观测。

日期判定先核实编码契约再实现：Swift `JSONEncoder` 默认 `.deferredToDate`，日期以 **Cocoa 参考纪元秒**（2001-01-01）编码；客户端先检测该契约再解码，检测不到则以 `UNSUPPORTED_DATE_ENCODING` 退出，不猜。

---

## 7. 对照矩阵（同一账户 / 同一列表 / 同一事项 / 相近时间）

| 通道 | 说明 | 强制 | 缺口处理 |
| :--- | :--- | :--- | :--- |
| **C1 原生 App** | 用户在 MacServer 屏幕上目视计数 | 是 | 用户口述 + 可选截图 |
| **C2 云端观察** | iCloud 网页版 | 否 | 不可用即记 `CLOUD_OBSERVATION_UNAVAILABLE`，不影响 A 层结论 |
| **C3 EventKit** | `GET /reminders/lists/{LIST-ALPHA}/items` | 是 | 脚本回执 |

| C1 | C3 | 结论 |
| :--- | :--- | :--- |
| 1 条 | 1 条且字段全对 | **R1 PASS** |
| 1 条 | 1 条但字段不符 | `FAIL (field fidelity)`，定位映射/序列化 |
| 1 条 | 0 条 | 排除"列表为空"；剩同步、身份漂移、查询层 |
| 0 条 | 0 条 | 创建未落到该列表或未同步 |
| — | 403/超时/5xx | `BLOCKED`，按 §2.3 区分闸门与 TCC |

---

## 8. 时限、期限保护与恢复（本版唯一的时限口径）

v1 同时出现"每次 ≤2 分钟""累计 ≤10 分钟""`--deadline 600`"三种口径，互相冲突。**本版以本节为唯一来源**，其他章节不再出现时限数字。

| 约束 | 值 | 强制点 | 触发后果 |
| :--- | :--- | :--- | :--- |
| **会话绝对截止** | `T0 + 2700s`（45 分钟） | 看门狗 `--deadline-epoch`，T0 为 P0 开始时刻 | 看门狗关闸、写 `FIRED_RESTORED`，窗口退出码 **16** |
| **单次调用开闸预算** | ≤ **300s** | `--open-budget 300`（按 `gate_open_since` 累计） | 看门狗关闸、`WATCHDOG_REASON=open_budget`，退出码 **16** |
| **两次调用合计开闸** | ≤ **600s** | 由"每次 ≤300"在构造上保证 | 同上 |
| **单批采集超时** | ≤ **120s** | 客户端 `--timeout 120` | 该批 `ERROR`，窗口退出码 **15** |

两次调用的 `--window-seconds` 必须按 **同一绝对截止** 计算：

```bash
REMAIN=$(( T0 + 2700 - $(date +%s) ))   # 第一次与第二次都用这个值
```

因此第二次调用**不会**获得新的 45 分钟。

**期限保护在任何开闸变更之前就位**（顺序硬编码在 `r1_window.sh` 中，不依赖注释）：

1. 前置校验（哈希/签名/health=production/初始 403/唯一目标/白名单绑定/唯一进程）→ 任一失败零变更退出；
2. **启动独立看门狗**（`nohup` + `disown`；macOS 无 `setsid`），校验其 pid 存活且 `WATCHDOG_DEADLINE_EPOCH` 与计划一致；
3. 才允许开闸。

看门狗独立性：不是窗口脚本的子 shell，主脚本崩溃、`SIGKILL`、读取阻塞、中途失败都不影响它按绝对期限关闸。关闸动作与人工关闸**是同一个脚本**（`r1_gate.sh close`），因此自动恢复与人工恢复的行为完全一致。

**恢复失败**：`r1_gate.sh` 返回非 0 → 窗口写 `WINDOW_RESULT: RESTORE_FAILED`、退出码 **13**、`window_summary.json` 里 `restore_verified=FAILED`，**不**输出任何成功字样，保留现场。

---

## 9. 失败传播与安全约束（脚本内已强制，不靠人工记得）

| 约束 | 实现 |
| :--- | :--- |
| 每条命令检查返回值 | `set -uo pipefail`；每次 `gate`/`capture` 都取 `$?` 并分支；开闸失败 → `OPEN_FAILED` + 退出 11/13 |
| 三类判定**不合并** | `capture_completed` / `field_assertions` / `restore_verified` 三个独立字段写入 `window_summary.json`；"采集完成"永不蕴含"恢复成功" |
| 开闸前强制四项 | 初始 `/reminders/lists` 必须 403；唯一目标（白名单恰好等于该列表）；预期程序（SHA256+签名+唯一进程）；calDAV/iCloud 绑定存在 |
| 入口固定回环 | 客户端 `LOOPBACK_RE` 拒绝非 `127.0.0.1/localhost/[::1]`；`ProxyHandler({})` 使 `http_proxy` 无法改道；`_RefuseRedirect` 使 3xx 不被跟随（避免把令牌送到别处） |
| 不自动读凭据 | 无 `--token-file` 直接拒绝；不因 `BRIDGE_ENV_FILE` 存在而读取 |
| 凭据不入日志/argv | 令牌只从 0600 文件读；`ps` 只过滤打印一个键；回执只存状态码与布尔 |
| 受限目录 | harness/证据目录 0700；plist 备份 0600；token 0600 |
| 失败留证据 | 闸门操作失败也写回执（`verification=FAIL` + `failure_stage` + `disk_written_before_failure`）；窗口任何退出路径都写 `window_summary.json` |
| 截断不算成功 | 越过绝对期限或看门狗已触发 → 停止采集，退出 **16**，不回退为"成功" |

---

## 10. 证据与判定规则

1. **唯一目录**：每次调用生成 `window-<UTCstamp>-<label>/`，已存在则拒绝；批次目录 `batch-<n>-<label>/` 已存在则退出 5。**首次非空证据不可被覆盖**。
2. **原始保留**：每批 `capture.json` 保留原始 `body_digest` 与计数；**所有批次**都保留，失败批次也保留。
3. **健康检查**：必须报 `store=production`；`Fake` 存储不得作为 R1 证据。
4. **清理断言与读取保真断言分开**：`--expect presence` 判字段保真，`--expect absence` 判清理生效，同一脚本、同一窗口约束。
5. **脱敏**：UUID 掩码为 `9D9A****03F3` 形式，标题/备注只存 SHA256 前 12 位；完整标识仅进 0600 受限文件。
6. **判定三态**：`PASS` / `FAIL` / `BLOCKED`，由 §11 的断言直接给出，不写"可能同步延迟"这类不可判定文本。

---

## 11. UNKNOWN 规则

1. 创建结果不确定（用户无法确认是否保存）：**不重复创建**；先做一次只读读取——返回 0 条判"未保存"，由用户重试**一次**；≥1 条以实观测为准。
2. 删除结果不确定：**不重复删除**；以清理核验批次为准；仍存在则停止并升级统筹，**不**做范围删除。
3. 出现重复事项（同标题 ≥2 条）：**不自动删除**，保留现场，报告待指令（`exit 21`）。
4. 任何"写入已发送、结果未知"：禁止自动重试、禁止切换后端、禁止扩大读取范围；只按批准范围只读核对，仍不能确定则保留现场升级。
5. **不得**用"读取 0 条"证明此前写入未发生；空数组只证明"此刻读不到"，不证明"当时没写"。

---

## 12. 隔离验证结果（本轮离线证据，均为可复跑命令）

| 命令 | 结果 | 覆盖 |
| :--- | :--- | :--- |
| `python3 scripts/tests/test_r1_bridge_client.py` | **53/53 通过** | 空列表 / 非空保真 / 重复事项 / 错误日期 / priority 0 / isCompleted / 空 itemID / fake store / 多列表 / 清理未生效 / 证据目录占用 / 令牌权限 / 全目录令牌扫描 / 不可达 / 非回环拒绝 / **3xx 拒绝** / **代理改道拒绝** |
| `bash scripts/tests/test_r1_window.sh` | **66/66 通过** | 前置拒绝 / 干跑零变更 / happy path / 字段不符 / 空列表 / 取证传输失败 / **加载失败** / **恢复失败** / **绝对期限触发** / **累计开闸预算触发** / **主进程 SIGKILL** / **plist 权威源 bootout+bootstrap** / **备份 0600** / **清理核验（absence）** |
| `python3 scripts/write_build_metadata.py --self-test` | **7/7 通过** | 溯源字段完整性、脏树标记、二进制变更检测 |
| `swift test --disable-sandbox`（此前已跑，未改动 Swift 源码） | 91/91 通过 | 桥实现与协议 |

隔离性：上述测试只使用回环 `fake_bridge.py`，**不**实例化真实 `EKEventStore`、**不**触发 TCC、**不**访问 Apple 账户、**不**注册 launchd 作业（`launchctl`/`codesign`/`pgrep`/`ps` 全部为桩）。

---

## 13. 已知限制（不隐瞒）

1. **launchd 加载语义无法在本机实测**：WorkBuddy 宿主环境 `launchctl bootstrap` 任意 LaunchAgent 返回 `Bootstrap failed: 5: Input/output error`。因此"改 plist 后如何被加载"只能依据源码优先级（`BridgeConfig.load` 中环境变量优先）+ 官方语义推断。脚本因此采用**来源检测 + 双路径**（`launchd_env` → `bootout`+`bootstrap`；否则 `kickstart -k`），并**以行为验证**（200/403 + PID 变化 + 该一个键的进程环境观测）为唯一判定，不以"磁盘值为 true"归因。两种路径都失败 → 退出 4 + 失败回执，窗口中止。
2. **产物与 commit 无法严格对应**（§2.4），本次不重建。
3. **历史回执存在脱敏违规**：`AG07_MUSE_FRONTEND_ACCEPTANCE_RECEIPT.json` 含列表完整 UUID 与完整标题。本申请**不擅自改写历史回执**；如需修订请单独批准（§14 A12）。
4. **Seoul 网关测试环境缺口**：本工作树缺未跟踪的 `node_modules`，`npm test` 49/50，`protocol.test.ts` 报 `ERR_MODULE_NOT_FOUND '@modelcontextprotocol/sdk'`。网关代码未被本次修改，属环境问题，如实记录不掩盖。

---

## 14. 请求批准的范围（逐条勾选，最小授权）

- [ ] **A1 只读身份核验**：在 MacServer 执行 `shasum -a 256`、`codesign -dvvv --verify`、`pgrep`、`ps -o lstart`、`lsof -p`、`launchctl print gui/501/...`，输出写入证据目录。
- [ ] **A2 只读端点调用**：仅 `127.0.0.1:18765` 的 `/health`、`/reminders/lists`、`/reminders/lists/{LIST-ALPHA}/items`，仅 GET，仅单个列表。
- [ ] **A3 令牌使用**：按 §3.3 从 `bridge.env` 单键提取到 0600 临时文件，窗口结束删除。
- [ ] **A4 闸门开合**：临时将 `EVENTKIT_BRIDGE_PRODUCTION_AUTHORIZED` 置 `true`，按 §8 的时限与预算重载服务，结束必须恢复 `false` 并复验 403。
- [ ] **A5 合成事项**：由用户创建 1 条（§6），事后再精准删除该 1 条。
- [ ] **A6 本地取证写入**：`/Users/jin/r1-harness-<ts>/`、`/Users/jin/r1-evidence/<ts>/`、`~/.config/muse-r1/identity.private.json`（0600）。
- [ ] **A7 目视核对**：用户在该列表内目视计数并口述，WorkBuddy 记录（C1 通道）。
- [ ] **A8 云端旁证**：允许记录 iCloud 网页是否可用；不可用即记缺口，不尝试登录。
- [ ] **A9 脚本落地**：向 harness 目录写入 §3.2 四个脚本（哈希如上），窗口结束删除。
- [ ] **A10 脱敏提交**：把结论作为新回执提交到 `feat/r1-01-readonly-diagnostic-harness`；**不合并 PR**，不动 PR #19–#23。
- [ ] **A11（默认不启用，需单独批准）**：GUI 自动化（`osascript` 驱动提醒事项 App）替代用户创建/删除；含其新增 TCC 影响与回滚方案。
- [ ] **A12（可选，需单独批准）**：修订历史回执中的未脱敏标识（AG-07）。

**明确不在本批准内**：重建/重签二进制、Seoul 任何变更、隧道/ACL/端口转发、写能力扩展、PR 合并、`TCC.db` 读取、范围删除、批量创建。

---

## 15. 执行时序（P0–P5，一次批准即可执行）

```bash
# ---------- 变量（在 WorkBuddy 侧设置，含完整标识但不落库）
TS=$(date -u +%Y%m%dT%H%M%SZ)
T0=$(date +%s)
HARNESS=/Users/jin/r1-harness-$TS
EVID=/Users/jin/r1-evidence/$TS
LIST_ID='<完整列表 UUID，仅本地填写>'
TOKEN_TITLE='[MUSE-R1-SYN-20261110-01] 只读读取保真核验'
TOKEN_NOTES='R1-01 合成事项，仅用于只读字段保真核验，验收后精准清理。MARKER=R1SYN20261110A'
```

**P0 只读前置（零变更）**

```bash
ssh macserver-ts "mkdir -p $HARNESS $EVID && chmod 700 $HARNESS $EVID"
scp integrations/apple-icloud-mcp/macserver-eventkit/scripts/r1_window.sh \
    integrations/apple-icloud-mcp/macserver-eventkit/scripts/r1_gate.sh \
    integrations/apple-icloud-mcp/macserver-eventkit/scripts/r1_watchdog.sh \
    integrations/apple-icloud-mcp/macserver-eventkit/scripts/r1_bridge_client.py \
    macserver-ts:$HARNESS/
ssh macserver-ts "cd $HARNESS && shasum -a 256 r1_window.sh r1_gate.sh r1_watchdog.sh r1_bridge_client.py && chmod 700 *.sh *.py"
# 逐个比对 §3.2 的哈希；不一致即停止，报 BLOCKED

# 令牌准备（A3；用户不参与输入）
ssh macserver-ts "umask 077; awk -F= '/^EVENTKIT_BRIDGE_BEARER_TOKEN=/{sub(/^EVENTKIT_BRIDGE_BEARER_TOKEN=/,\"\"); print; exit}' \
  ~/.config/muse-macserver/bridge.env > $HARNESS/token && chmod 600 $HARNESS/token && test -s $HARNESS/token" \
  || { echo "TOKEN_UNAVAILABLE - BLOCKED"; }

# 干跑：只读前置 + 计划打印，不产生任何变更
ssh macserver-ts "$HARNESS/r1_window.sh --list-id $LIST_ID \
  --expect-title '$TOKEN_TITLE' --expect-notes '$TOKEN_NOTES' \
  --expect-due-utc 2026-11-17T02:30:00Z \
  --token-file $HARNESS/token --plist ~/Library/LaunchAgents/com.muse.macserver-eventkit.plist \
  --config-file ~/.config/muse-macserver/bridge.env \
  --work-dir $EVID --label p0"
```

干跑应输出：SHA256 匹配、`signature VALID`、`health: production store confirmed`、`gate: closed (403) confirmed`、`static: gate_source=...`、`process: pid=... lstart=...`，然后 `DRY RUN`。

**P1 用户创建 1 条合成事项**（§6 逐字段）

**P2 第 1 次采集（2 批）**

```bash
ssh macserver-ts "$HARNESS/r1_window.sh --confirm \
  --list-id $LIST_ID --expect-title '$TOKEN_TITLE' --expect-notes '$TOKEN_NOTES' \
  --expect-due-utc 2026-11-17T02:30:00Z --expect presence \
  --token-file $HARNESS/token --plist ~/Library/LaunchAgents/com.muse.macserver-eventkit.plist \
  --config-file ~/.config/muse-macserver/bridge.env \
  --work-dir $EVID --label pass --passes 2 --interval 60 \
  --window-seconds $(( T0 + 2700 - $(date +%s) )) --open-budget 300"
```

**P3 用户精准删除该 1 条**

**P4 第 2 次采集（清理核验，1 批）**

```bash
ssh macserver-ts "$HARNESS/r1_window.sh --confirm \
  --list-id $LIST_ID --expect-title '$TOKEN_TITLE' --expect-notes '$TOKEN_NOTES' \
  --expect-due-utc 2026-11-17T02:30:00Z --expect absence \
  --token-file $HARNESS/token --plist ~/Library/LaunchAgents/com.muse.macserver-eventkit.plist \
  --config-file ~/.config/muse-macserver/bridge.env \
  --work-dir $EVID --label cleanup --passes 1 \
  --window-seconds $(( T0 + 2700 - $(date +%s) )) --open-budget 300"
```

**P5 独立复核 + 清理 harness**

```bash
ssh macserver-ts "plutil -extract EnvironmentVariables.EVENTKIT_BRIDGE_PRODUCTION_AUTHORIZED raw \
  ~/Library/LaunchAgents/com.muse.macserver-eventkit.plist; \
  curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:18765/reminders/lists; \
  curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:18765/health; \
  pgrep -fl EventKitBridgeServer"
# 期望：false / 403 / 200 / 恰好 1 个进程
ssh macserver-ts "rm -rf $HARNESS"   # 删除脚本与 token；保留 $EVID
```

**紧急关闸（已授权，无需再申请）**——任何人可随时执行：

```bash
ssh macserver-ts "launchctl bootout gui/501/com.muse.macserver-eventkit 2>/dev/null; \
  plutil -replace EnvironmentVariables.EVENTKIT_BRIDGE_PRODUCTION_AUTHORIZED -string false \
    ~/Library/LaunchAgents/com.muse.macserver-eventkit.plist 2>/dev/null || true; \
  launchctl bootstrap gui/501 ~/Library/LaunchAgents/com.muse.macserver-eventkit.plist; \
  sleep 3; curl -s -o /dev/null -w 'lists=%{http_code}\n' http://127.0.0.1:18765/reminders/lists"
# 期望 lists=403。若配置源是 bridge.env 则改该文件的同一键；两种来源都用 r1_gate.sh close 更稳妥。
```

---

## 16. 判定口径

| 判定 | 断言 |
| :--- | :--- |
| **R1 PASS** | `batch-1`/`batch-2` 中 `classification=NON_EMPTY_FIDELITY_PASS`，且 9 项字段断言全 PASS，且 `restore_verified=VERIFIED`，且记录 SHA256、签名、cdhash、观测时刻、列表身份对应 |
| **R1 FAIL（可判定）** | 同一窗口 C1 显示 ≥1 条而 C3 返回 0 条，且已排除闸门与 TCC → 输出已排除项与未排除项，不写"可能延迟" |
| **R1 BLOCKED（TCC）** | 开闸后仍 403，且同程序身份已确认 |
| **R1 BLOCKED（前置）** | 哈希不符、签名无效、health 非 production、初始非 403、白名单/绑定不符、多进程、python3 缺失、token 不可得 |
| **R1 INTERRUPTED** | 期限或预算触发（退出 16）、恢复失败（13）、取证未完成（15） |
| **不构成 PASS** | 空数组、Mock/Fake、无程序身份与哈希、B/C/D 层调用、MUSE 未独立签署、被截断的窗口 |

> **离线完成 ≠ R1 完成。** R1 通过后才提交 R2 的方案与申请；R2 由 MUSE 侧独立签署。

---

## 附录 A：本轮离线产物清单

| 文件 | 作用 |
| :--- | :--- |
| `macserver-eventkit/scripts/r1_window.sh` | 自闭合窗口：前置门禁 → 武装看门狗 → 开闸 → 采集 → 关闸 → 三独立判定；支持 `--expect absence` |
| `macserver-eventkit/scripts/r1_gate.sh` | 唯一开/关闸入口：来源检测、0600 备份、双路径重载、行为验证、失败也写回执 |
| `macserver-eventkit/scripts/r1_watchdog.sh` | 独立期限看门狗：绝对截止 + 累计开闸预算 + 归属元数据 |
| `macserver-eventkit/scripts/r1_bridge_client.py` | 只读客户端：固定回环、空代理、拒绝 3xx、令牌仅从 0600 文件、批次不可覆盖 |
| `macserver-eventkit/scripts/write_build_metadata.py` | 构建溯源写入与校验（补 source commit 缺口） |
| `macserver-eventkit/scripts/tests/fake_bridge.py` | 回环假桥：按真实优先级（plist > config > control）读闸门，支持 302/延迟/500 |
| `macserver-eventkit/scripts/tests/test_r1_bridge_client.py` | 53 项断言 |
| `macserver-eventkit/scripts/tests/test_r1_window.sh` | 66 项断言（含加载失败、恢复失败、期限、预算、SIGKILL、launchd 分支、清理核验） |
| `receipts/R1_01_OFFLINE_DIAGNOSIS_RECEIPT.json` | 离线定位回执（事实/假设/排除项） |
