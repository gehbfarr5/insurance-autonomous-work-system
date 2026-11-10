# R1-01 MacServer 本地只读诊断授权申请（修订版 v3）

- **任务**：REM-R1-01 新版 iCloud 提醒事项空列表定位
- **申请方**：WorkBuddy（本专项唯一工程主执行 Agent）
- **版本**：**v3**（2026-11-10 19:50 CST）。v1 未获真实操作授权；v2 按 7 类审查意见整改；v3 在前两轮基础上完成第三轮 8 项与第四轮 3 项定点整改。**不是**新任务。
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

## 0.1 本版（v3）相对 v2 的定向改动

| # | 问题 | 本版处理 | 位置 |
| :--- | :--- | :--- | :--- |
| 1 | 关闸可以不经验证返回 0；看门狗据此写"已恢复" | 验证改为无条件，删除 `--expect` 开关；`FIRED_RESTORED` 需闸门回执 `verification=PASS` | §8、§9 |
| 2 | `finish()` 先删开闸计时、失败也写 `stop` | 关成之前不删计时、不写 `stop`；有界 2 次重试；失败保留保护 | §8 |
| 3 | 看门狗超时后仍强行并发关闸 | 三角色共用一把锁；有界等待后退出 7；按 `pid+lstart` 回收陈旧锁 | §8、§9 |
| 4 | 同时写 plist 与 `bridge.env`；`load -w` 兜底；吞 bootout 错误 | 只写权威源；配置文件单键原子写 + 0600 备份；删除 `load -w`；bootout 错误按 `launchctl print` 核实 | §5.1 |
| 5 | UNKNOWN 里残留"读 0 条后重试创建一次" | 删除；只读核对 + 升级，不重复写入 | §11 |
| 6 | 误称 `--check-authorization` 不存在；403 直接归因 TCC | 更正为三层事实（源码/产物/运行）；403 记"原因未定"再区分 | §2.3、§2.3.1、§2.3.2 |
| 7 | P5 用无令牌 curl 当 403 证据；紧急关闸自拼命令；称"权限上必须由人做"；R1/R2 混淆 | P5 改用受限客户端；紧急关闸复用同一入口；创建/删除改为明示选择；R1 不要求 MUSE 签署 | §15、§4.2、§1 |
| 8 | 缺针对性隔离验证 | 新增 4 类场景（看门狗验证失败、恢复不解除保护、互斥、跨批次假成功），编排断言 66→91 | §12 |
| 9 | **锁目录存在但 owner 未发布时被当作陈旧回收**，两个操作可同时进入修改/重载 | 改为**先写 owner 记录、再用 `ln -s` 原子发布锁名**，"有锁无主"这一状态在本实现中不可达；无 owner 的锁在 `R1_LOCK_INIT_GRACE_SECONDS`（默认 10s）内**只等不抢**；回收先 `mv` 再核对目标，抢到的是新持有者就放回、绝不删除；写入与重载前各做一次持锁断言。新增**确定性**并发场景（在"记录已写、锁名未发布"处暂停首个持有者，再启动第二个操作，断言只有一次重载、败者退出 7 且未写盘） | §8、§9、§12 |
| 10 | P5 与紧急入口没校验输出目录；父目录不存在/不可写时可能改完生产状态却写不出回执 | `r1_gate.sh` 在任何改动前校验 `--out` 所在目录（存在 + 实写探测），失败退出 **6** 并明确说明"什么都没改"；`r1_window.sh` 在武装看门狗前校验 `--work-dir`（父目录不存在即拒绝，不用 `mkdir -p` 兜底；存在则实写探测），失败退出 **17**；看门狗状态目录不可用则 **FATAL 退出 4**，不装作已武装；客户端 `--out` 目录不可用返回 **4** 并输出 `EVIDENCE_DIR_UNUSABLE`（此前与传输失败同为 3） | §9、§12、§15 |
| 11 | P5 直接关闸会覆盖"首次恢复是否成功"这一结论 | P5 第一步改为**不修改状态的认证读取**（受限客户端带令牌，`gate_http_status=403` 即首次恢复有效）；只有该读取不成立时才执行关闸，**单独记为补救操作**，并保留首次读取的原始回执与结论 | §15 |
| 12 | "归档证据无法判定已部署产物是否支持 `--check-authorization`"这句话本身是错的 | `AG06_TCC_PREFLIGHT_AUTHORIZATION_RECEIPT.json` 已记录**同一冻结哈希** `f78e24e5` 在 `gui/501` 执行该参数的输出与退出码（`notDetermined`/exit 2，`authorized`/exit 0），故"产物支持"为**已证实**；仍未证实的是"当前运行进程上下文下的状态" | §2.3.1 |

> 第四轮（#9–#12）只改这四类，不重复客户端 53 项与其他无关已通过测试，也不新增通用交接报告。

---

## 1. 分层边界：R1 与 R2 是两件事

| 层 | 内容 | 归属 | 本申请 |
| :--- | :--- | :--- | :--- |
| **A** | 工程直连只读诊断（回环 HTTP + 本机脚本） | **R1** | ✅ 本申请唯一覆盖对象 |
| **B** | MUSE 前台触发（GUI/前端交互） | R2 | ❌ 不申请 |
| **C** | 脚本包装层 | R2 | ❌ 不申请 |
| **D** | 原生 MCP 工具调用 | R2 | ❌ 不申请 |

- R1 的通过标准由 **A 层**观测直接判定：同一列表、同一合成事项，被 MacServer 的 EventKit 正确读取。
- **R1 的通过不要求 MUSE 签署。** R2（MUSE 前台验收）由 MUSE 侧独立签署，工程 Agent 不代签；R2 **必须在 R1 通过之后另行授权**，不得把 MUSE 签署当作 R1 本地读取的前置条件或替代条件。
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
| 开闸后 `/reminders/lists` → **200** | 闸门生效且 EventKit 权限可用 |
| 开闸后仍 **403**，且**同程序身份**已确认（路径+SHA256+cdhash+pid） | 记为 **`403 原因未定（权限/闸门原因未定）`**，不直接归因 TCC；此时按 §2.3.2 的只读探针再区分，仍不能区分则停窗报 `BLOCKED (403 原因未定)` |
| 开闸后 **403**，但程序身份不符或闸门值仍为 false | 判定 **闸门未生效 / 身份漂移** → 按 §9 恢复，报 `INTERRUPTED` |

**会话正确性核验**：`stat -f %Su /dev/console` 必须为 `jin`，且 `launchctl print gui/501` 可读；否则判定"不在正确图形会话"，只做只读采集，不做任何需要会话的判定。

### 2.3.1 `--check-authorization` 的三层事实（v2 与 v3 早期稿的错误已更正）

v2 曾写"该参数在源码中不存在"，**这是错的**——我当时的检索目录写错，实际存在。v3 早期稿又写了第二个错误：称"已部署产物是否支持该参数无法从归档证据判定"。这句也**不成立**，归档证据里已经有答案。三层分开陈述，不得混用：

| 层次 | 事实 | 状态 |
| :--- | :--- | :--- |
| **源码支持** | `Sources/EventKitBridgeServerExec/main.swift:27` 起实现 `--check-authorization`：输出 `{"authorization_status":…,"authorized":…}`，退出码 0=authorized / 2=notDetermined / 3=denied\|restricted\|writeOnly / 1=unsupported | **已核实**（本仓源码） |
| **已部署产物支持** | `AG06_TCC_PREFLIGHT_AUTHORIZATION_RECEIPT.json` 记录了 `target_installation.sha256 = f78e24e533c2bf9a77161dc05eb154ce99687de9a5b881ad481bfbe2bbfb3074`（与冻结值一致）的产物在 `gui/501 (Aqua)` 会话执行该参数的实际输出：`{"authorization_status":"notDetermined","authorized":false}` → **exit 2**，随后 `{"authorization_status":"authorized","authorized":true}` → **exit 0**。参数被识别、JSON 形状与退出码契约均与源码一致 | **已证实**（归档证据，非推断） |
| **本次运行状态** | 该参数报告的是**执行它的那个进程上下文**的 TCC 状态。SSH 执行与 LaunchAgent 执行可能被归属到不同的 responsible process；且上述两次执行发生在**当日更早的会话**，不能外推为"现在仍是 authorized" | **必须重新测量**：P0 在 Aqua 会话内执行并记录执行上下文（会话、父进程、退出码、JSON） |

因此：P0 会执行一次 `--check-authorization` 并记录其 JSON 与退出码，同时记录执行上下文（会话、父进程）；只有在 Aqua 会话内取得的、**本次窗口内**的结果才用于 TCC 判定。历史归档结论只用于证明"产物认得这个参数"，不得用来替代本次测量。

### 2.3.2 403 归因规则

"闸门关闭"和"权限被拒"都返回 403 `PERMISSION_DENIED`，单看状态码无法区分。规则：

1. 先确认闸门**按行为**已开（`gate_open.json` 的 `verification=PASS`，即 200）——若已 200，则不需要归因；
2. 若开闸操作本身验证失败（仍 403），先查 `r1_gate.sh` 的回执：`gate_source_detected`、`verification`、`gate_http_status`；
3. 只有在**闸门已按行为开启**且仍 403 时，才可能涉及权限；此时用 §2.3.1 的探针在 Aqua 会话内取值；
4. 任一步不能给出确定结论 → 回执写 **`403 原因未定`**，不写"TCC 失效"。

**不读取 `TCC.db`**（需完全磁盘访问，且会改变取证语义）。

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
| `r1_window.sh` | 自闭合窗口编排（480 行） | `b728467aabbccb603007aca49b1acdb0afffd8483836ce061548b28b3dfdac55` |
| `r1_gate.sh` | 唯一开/关闸入口（610 行） | `7e3d006310202613b21cb5675ccf1f14af8df7d8b59b2d96e317782585568da1` |
| `r1_watchdog.sh` | 独立期限看门狗（178 行） | `eb1336480e3b83d89df12921a669e165c0e76cbf994893f7c9f20f748b309d43` |
| `r1_bridge_client.py` | 只读客户端（611 行） | `a95ae5704d612f7d49d74e5d27f6e5834b82e137cb44f5aecf72f8bb08478cc6` |
| `token` | 临时令牌文件，`0600`，**所有恢复结束且看门狗退出确认后**才删 | 不记录（内容永不落回执） |

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

**这是本申请明确提出的一个选择，不是"权限上只能由人做"**：创建/删除提醒事项在技术上可以由 GUI 自动化完成（A11），但那样需要在目标机新增 Automation / 辅助功能授权，会在诊断窗口内引入一个新的 TCC 变量。因此本申请**推荐**由用户在屏幕上点两次；如果统筹更希望全程无人值守，可批准 A11，改由 WorkBuddy 驱动 `osascript`，两种方式都行，取决于取舍。

除创建/删除这一项外，诊断、核验、取证、清理确认、恢复、回执全部由 WorkBuddy 完成，用户不需要排障、不需要输入或粘贴任何令牌。

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
| 删除 | harness 目录、`token` | — | **所有恢复结束且看门狗退出已确认之后**才删（见 §15 P5 步骤 3） |

**不**触碰：二进制、plist 其他键、`bridge.env` 其他键、Seoul、隧道、容器。

**清理时序的理由**：看门狗按期限关闸时要用 `token`（`r1_gate.sh close --token-file`）。若先删令牌，期限保护会在最需要它的时刻失效；若先删脚本，则连关闸入口都没有了。因此删除顺序固定为"确认无遗留看门狗 → 确认无存活锁持有者 → 删令牌与脚本"。

> plist 的 `EnvironmentVariables` 可能含令牌，因此备份**不放在原目录**，而是放进 0700 证据目录并置 0600；回执记录备份路径与权限，不记录内容。

**只改实际权威的那一个源（v3 变更）**

`BridgeConfig.load()` 中环境变量优先，所以当 plist 定义了这个键时，改 `bridge.env` 是无效写入，只会让两个文件悄悄不一致。因此：

| 情形 | 行为 |
| :--- | :--- |
| plist 定义了该键 | 只改 plist；**不**写 `bridge.env`（验收断言：`bridge.env` 前后字节一致） |
| 只有 `bridge.env` 定义该键 | 只改 `bridge.env`；见下方"配置文件的写入契约" |
| 两者都没有 | `open` 直接拒绝（exit 5），**不**凭空创建一个键；`close` 只做只读验证 |

**配置文件的写入契约**（仅在 `bridge.env` 为权威源时生效）：

- 路径：`~/.config/muse-macserver/bridge.env`（唯一，不含其他路径）
- 范围：**仅** `EVENTKIT_BRIDGE_PRODUCTION_AUTHORIZED` 一行；脚本对该键做单行替换，键不存在则报错停止（不追加）
- 备份：写前 `cp -p` 到 `<out>.config-backup`，`chmod 600`（该文件含令牌，不得 0644）
- 原子性：同目录临时文件 + `os.replace`，并保持原文件 mode；读取方（含下一个进程）不会看到半写状态
- 恢复：把备份 `cp -p` 回原位后按 §9 重新关闸并验证；备份路径写在回执的 `config_backup` 字段（权限记为 `config_backup_mode=0600`）；plist 情形对应 `plist_backup`

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
2. **准备并校验受限输出目录**（`--work-dir` 必须存在或父目录存在、0700、实写探测通过；运行目录与 `state/` 同规则）→ 不通过即退出 **17**，此时尚未武装看门狗、尚未碰生产状态；
3. **启动独立看门狗**（`nohup` + `disown`；macOS 无 `setsid`），校验其 pid 存活且 `WATCHDOG_DEADLINE_EPOCH` 与计划一致（看门狗自身也会先验证状态目录可写，不可写则 FATAL 退出 4）；
4. 才允许开闸。

看门狗独立性：不是窗口脚本的子 shell，主脚本崩溃、`SIGKILL`、读取阻塞、中途失败都不影响它按绝对期限关闸。关闸动作与人工关闸**是同一个脚本**（`r1_gate.sh close`），因此自动恢复与人工恢复的行为完全一致。

**恢复的语义（v3 收紧）**

1. **验证不是可选项**：`r1_gate.sh` 不再有"跳过验证直接返回 0"的路径。open 与 close 都必须在重载后重新读 `/health` 与业务端点，只有观测到的行为与目标状态一致才返回 0。调用者不需要（也不能）用参数决定是否验证。
2. **有界重试**：窗口自身最多 2 次 `close`，看门狗最多 3 次（每次换一个回执文件名，全部保留）。不做无限重试，不在失败后继续加码。
3. **失败不解除保护**：窗口在 close 未通过验证时**不**删 `gate_open_since`、**不**写 `stop` 文件，看门狗保持武装，期限路径仍是最后一道关闸；窗口自身以退出码 **13** 结束并写 `RESTORE_FAILED`。
4. **只在真正关成之后才收工**：确认 `verification=PASS` 后才停掉开闸计时并写 `stop`。
5. **互斥（v3 第四轮重做）**：窗口、看门狗、紧急关闸共用同一把锁（`$R1_LOCK_DIR/gate.lock`）。实现要点：
   - 锁是**符号链接**，目标指向先写好、再发布的 owner 记录（`LOCK_PID` + `LOCK_LSTART`）；`ln -s` 在名字已存在时失败，因此"发布"是单步原子操作。**"有锁无主"这个中间状态在本实现中不可达**，旧版 `mkdir` 后才写 `owner.env` 的窗口已消失。
   - **无 owner 记录的锁不立即判陈旧**：只有存在时间超过 `R1_LOCK_INIT_GRACE_SECONDS`（默认 10s）才按陈旧回收；在此期间只等待、绝不抢占。这条规则同时覆盖"旧版残留的锁目录"。
   - **回收不得误删新持有者**：先 `mv` 到唯一名，再 `readlink` 核对是否仍是我们判定时看到的那一代；若不同（说明期间有新的持有者发布），放回原处并继续等待，**绝不删除**；放不回去时保留为证据并放弃本次回收。
   - **持锁断言**：写权威源之前、重载之前各校验一次"名字仍指向自己"，不成立即退出 **7** 并写 `failure_stage=lock_lost` 回执，**不写盘、不重载**。
   - 锁被占用时**有界等待**（默认 20s，重试操作 15s，按真实秒计），超时失败退出 **7** 并写 `failure_stage=lock` 回执；**绝不**在超时后强行并发写配置或重载。持有者进程已死或 pid 被复用时，锁按 `pid + lstart` 判定为陈旧并回收。
6. **最坏情况**：若 2/3 次都失败，看门狗写 `FIRED_RESTORE_FAILED` 并以 6 退出，现场（含每次失败回执）保留，交由人工按 §15 的紧急关闸执行同一入口，而不是手工拼命令。

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
| 验证不可跳过 | `open`/`close` 一律在重载后按行为验证；无"跳过验证返回 0"的分支，也没有控制它的参数 |
| 恢复有界 | 窗口 2 次、看门狗 3 次；每次都落独立回执；失败即退出 13/6，不无限重试 |
| 失败不解除保护 | close 未验证通过时不删 `gate_open_since`、不写 `stop`；看门狗继续武装到期限 |
| 恢复互斥 | 三角色共用 `gate.lock`；原子发布 + 无主宽限 + 核对式回收；写盘前/重载前持锁断言；有界等待后失败退出 **7**，不强行并发 |
| 输出目录先于状态变更 | `r1_gate.sh` 在任何改动前校验 `--out` 目录（存在 + 实写探测），失败退出 **6** 并声明"什么都没改"；`r1_window.sh` 校验 `--work-dir`（父目录不存在即拒绝，不用 `mkdir -p` 兜底），失败退出 **17**；看门狗状态目录不可用则 FATAL 退出 **4**；客户端输出目录不可用返回 **4** + `EVIDENCE_DIR_UNUSABLE` |
| 失败回执口径一致 | 失败回执的 `disk_written_before_failure` 由实际是否写盘决定（不再用"阶段名"推断），`lock_lost`/`lock` 两类失败都如实写 `false` |
| 只改权威源 | 按 `BridgeConfig.load` 的优先级只写一处；plist 权威时 `bridge.env` 字节不变（有断言） |
| 不吞主路径错误 | `bootout` 失败时先查 `launchctl print`：确实未加载才继续，否则按 reload 失败退出 4 并写回执；已删除 `load -w` 兜底 |
| 一个坏批次否决整体 | 采集结论按"每个计划批次都产生观测且都符合期望"聚合；任一批次传输失败或出现重复事项，整体不得为成功 |

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

**一条总规则：结果不确定时只做只读核对，不重复写入；无法确定就保留现场并升级统筹。**

1. 创建结果不确定（用户无法确认是否保存）：**不重复创建**。只做只读读取并如实记录观测；无论读到 0 条还是 ≥1 条，**都不触发第二次创建**。读到 0 条时结论是"此刻读不到"，不是"没保存"，因此不能作为再写一次的理由；由统筹决定是否另行授权一次新的创建。
2. 删除结果不确定：**不重复删除**；以清理核验批次为准；仍存在则停止并升级统筹，**不**做范围删除。
3. 出现重复事项（同标题 ≥2 条）：**不自动删除**，保留现场，报告待指令（`exit 21`）。
4. 任何"写入已发送、结果未知"：禁止自动重试、禁止切换后端、禁止扩大读取范围；只按批准范围只读核对，仍不能确定则保留现场升级。
5. **不得**用"读取 0 条"证明此前写入未发生；空数组只证明"此刻读不到"，不证明"当时没写"。

---

## 12. 隔离验证结果（本轮离线证据，均为可复跑命令）

| 命令 | 结果 | 覆盖 |
| :--- | :--- | :--- |
| `python3 scripts/tests/test_r1_bridge_client.py` | **53/53 通过**（本轮改动后回归，未新增条目） | 空列表 / 非空保真 / 重复事项 / 错误日期 / priority 0 / isCompleted / 空 itemID / fake store / 多列表 / 清理未生效 / 证据目录占用 / 令牌权限 / 全目录令牌扫描 / 不可达 / 非回环拒绝 / **3xx 拒绝** / **代理改道拒绝** |
| `bash scripts/tests/test_r1_window.sh` | **125/125 通过** | 上述 91 项全部保留，新增：<br>**[19]** 无 owner 的锁在宽限期内**不被回收**（且无重载、配置字节不变、回执 `failure_stage=lock` + `disk_written_before_failure=false`），把同一把锁 mtime 改老后才回收并留痕<br>**[20] 确定性并发**：首个持有者在"owner 记录已写、锁名未发布"处暂停（测试注入点，生产无该变量即失效），此时断言"锁名不存在、owner 记录已在盘"；第二个操作持锁期间首个恢复运行 → 首个退出 **7**、全流程**只有一次重载**、败者未写盘、结束后无锁残留、互斥仍可复用<br>**[21]** 证据目录不可用：`--work-dir` 父目录不存在（不 invent 目录树）/ 不可写 → **17**；`gate --out` 目录不存在 / 不可写 → **6**；客户端 → **4** + `EVIDENCE_DIR_UNUSABLE`（与传输失败可区分）；看门狗状态目录不可建 → **FATAL/4**；以上均断言"生产配置与 launchctl 日志零变化" |
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

- [ ] **A1 只读身份核验**：在 MacServer 执行 `shasum -a 256`、`codesign -dvvv --verify`、`pgrep`、`ps -o lstart`、`lsof -p`、`launchctl print gui/501/...`，并在 Aqua 会话内执行一次 `EventKitBridgeServer --check-authorization`（只读、不触发授权弹窗），输出写入证据目录。该参数**在源码与已部署产物中都已确认存在**（后者由 `AG06_TCC_PREFLIGHT_AUTHORIZATION_RECEIPT.json` 记录同一冻结哈希 `f78e24e5` 的实际输出与退出码证实，见 §2.3.1）；这次执行要取得的是**本窗口、本会话上下文**的状态，不是"参数是否存在"。
- [ ] **A2 只读端点调用**：仅 `127.0.0.1:18765` 的 `/health`、`/reminders/lists`、`/reminders/lists/{LIST-ALPHA}/items`，仅 GET，仅单个列表。
- [ ] **A3 令牌使用**：按 §3.3 从 `bridge.env` 单键提取到 0600 临时文件；**所有恢复操作结束且看门狗退出已确认后**删除（§15 P5 步骤 3）。
- [ ] **A4 闸门开合**：临时将 `EVENTKIT_BRIDGE_PRODUCTION_AUTHORIZED` 置 `true`，按 §8 的时限与预算重载服务；开合**只能**经 `r1_gate.sh` 这一入口（共用互斥锁、按行为验证、失败留证），结束必须恢复 `false` 并复验 403；紧急关闸同样走该入口。
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
# 受限目录先建好并验证可写：r1_gate.sh 会拒绝不存在的输出目录（退出 6），
# r1_window.sh 会拒绝不可用的 --work-dir（退出 17）。不做 mkdir -p 兜底猜测。
ssh macserver-ts "umask 077; mkdir -p $HARNESS $EVID $EVID/p5 $EVID/emergency \
  && chmod 700 $HARNESS $EVID $EVID/p5 $EVID/emergency \
  && for d in $HARNESS $EVID $EVID/p5 $EVID/emergency; do \
       ( : > \$d/.probe ) 2>/dev/null && rm -f \$d/.probe || { echo \"EVIDENCE_DIR_UNUSABLE \$d\"; exit 6; }; \
     done && echo DIRS_OK"
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

**P5 独立复核（先只读，再决定是否需要补救）**

复核必须带有效认证。无令牌的 `curl` 打 `/reminders/lists` 得到的是 **401**（认证失败），不是 403（闸门关闭），拿它当"已关闸"的证据是错的。

**第一步不修改任何状态**：只用受限客户端带令牌读一次业务端点。首次自动关闸是否真的有效，就由这一次读取判定。只有它不成立时才做第二步，并把第二步**单独记为补救操作**，不覆盖第一步的结论。

```bash
# 1a) 只读复核（不写盘、不重载、不取互斥锁）
ssh macserver-ts "python3 $HARNESS/r1_bridge_client.py gate \
  --endpoint http://127.0.0.1:18765 --token-file $HARNESS/token \
  --expect 403 --out $EVID/p5/gate_recheck_readonly.json; echo \"readonly_exit=\$?\""
ssh macserver-ts "python3 -c \"import json;d=json.load(open('$EVID/p5/gate_recheck_readonly.json'));print(d['http_status'], d['classification'])\""
```

- `http_status=403` 且 `readonly_exit=0` → 首次恢复**已被独立读取证实**，记 `FIRST_RESTORE_VERIFIED_BY_READONLY_RECHECK`。**到此结束，不再执行任何关闸**（多关一次会在证据里制造第二个"关闸成功"，反而模糊首次结论）。
- `http_status=200` 或读取不可达 → 记为 `FIRST_RECHECK_NOT_CLOSED`，保留该回执原文，然后进入 1b。

```bash
# 1b) 仅在首次复核不成立时执行：补救关闸（同一入口、同一互斥、同一验证）
ssh macserver-ts "$HARNESS/r1_gate.sh close \
  --plist ~/Library/LaunchAgents/com.muse.macserver-eventkit.plist \
  --config-file ~/.config/muse-macserver/bridge.env \
  --token-file $HARNESS/token --purpose 'p5-remedial-close' \
  --out $EVID/p5/gate_close_remedial.json; echo \"remedial_exit=\$?\""
```

两条结论分开写进汇报：`first_recheck`（原始回执路径 + http_status）与 `remediation`（`remedial_exit` + 回执路径）。**补救成功不等于首次恢复成功**，二者不得合并成一句"已关闸"。

```bash
# 2) 进程与磁盘值（只作为补充，不作为运行状态判据）
ssh macserver-ts "pgrep -fl EventKitBridgeServer; \
  plutil -extract EnvironmentVariables.EVENTKIT_BRIDGE_PRODUCTION_AUTHORIZED raw \
    ~/Library/LaunchAgents/com.muse.macserver-eventkit.plist 2>/dev/null || echo 'key: not in plist'"

# 3) 清理 harness —— 必须晚于"所有恢复操作结束 + 看门狗退出已确认"
#    理由：看门狗关闸时要用 $HARNESS/token；先删令牌会让期限保护在最需要它的时刻失效。
# 3a) 看门狗是否真的退出（按 state 目录里的 pid + lstart 归属判定，不看 plist）
ssh macserver-ts "python3 - '$EVID' <<'PY'
import glob, os, subprocess, sys
alive = []
for meta in glob.glob(os.path.join(sys.argv[1], '*', 'state', 'watchdog_meta.env')):
    kv = dict(l.split('=', 1) for l in open(meta, encoding='utf-8').read().splitlines() if '=' in l)
    pid = kv.get('WATCHDOG_PID', '')
    want = kv.get('WATCHDOG_LSTART', '').strip('\"')
    now = subprocess.run(['ps', '-p', pid, '-o', 'lstart='],
                         capture_output=True, text=True).stdout.strip() if pid else ''
    if now and (not want or now == want):
        alive.append(pid + ' ' + meta)
print('WATCHDOG_STILL_RUNNING ' + '; '.join(alive) if alive else 'WATCHDOG_CLEAR')
sys.exit(9 if alive else 0)
PY"
# 3b) 互斥锁是否还有存活持有者（只有"锁名存在且 owner 存活"才算占用）
ssh macserver-ts 'L=$HOME/.muse-r1/gate.lock; if [ -e "$L" ] || [ -L "$L" ]; then \
  echo "LOCK_ARTIFACT_PRESENT: $(readlink "$L" 2>/dev/null || echo legacy-dir)"; else echo LOCK_CLEAR; fi'
# 3c) 3a 输出 WATCHDOG_CLEAR 且 3b 为 LOCK_CLEAR（或无存活持有者）时，才删令牌与脚本
ssh macserver-ts "test -f $HARNESS/token && rm -f $HARNESS/token; rm -rf $HARNESS"
```

若 3a 报 `WATCHDOG_STILL_RUNNING`：**不要**删令牌与脚本，等它按期限关闸退出（有界等待）后再复核一次；确认退出后才执行 3c。删除失败则保留现场并如实报告，不掩盖。

注：P5 全部走受限客户端与 `r1_gate.sh`，不使用 `curl`、不手工拼 `plutil`/`launchctl`。

**紧急关闸（已授权，无需再申请）**——复用与自动恢复**完全相同**的唯一入口，不另写一条会吞错的临时命令：

```bash
# 任何人在任何时刻，一条命令，走同一个互斥锁与同一套验证
ssh macserver-ts "$HARNESS/r1_gate.sh close \
  --plist ~/Library/LaunchAgents/com.muse.macserver-eventkit.plist \
  --config-file ~/.config/muse-macserver/bridge.env \
  --token-file $HARNESS/token --purpose 'emergency-close' \
  --out $EVID/emergency/close.json; echo \"exit=\$?\""
# 退出码 0 表示"已按行为验证为 403"；非 0 表示没有恢复成功，需按 §9 保留现场并上报
# 退出码 6 表示 --out 目录不可用（不存在/不可写）——此时脚本什么都没改；先建好 $EVID/emergency 再重试
```

若 harness 已被删除（窗口已收尾），用仓库内同一脚本的副本执行同一命令；**不要**临时拼 `plutil` + `launchctl`（那会绕过互斥与验证，并且在 bootout 失败时静默继续）。

---

## 16. 判定口径

| 判定 | 断言 |
| :--- | :--- |
| **R1 PASS** | `batch-1`/`batch-2` 中 `classification=NON_EMPTY_FIDELITY_PASS`，且 9 项字段断言全 PASS，且 `restore_verified=VERIFIED`，且记录 SHA256、签名、cdhash、观测时刻、列表身份对应 |
| **R1 FAIL（可判定）** | 同一窗口 C1 显示 ≥1 条而 C3 返回 0 条，且已排除闸门与 TCC → 输出已排除项与未排除项，不写"可能延迟" |
| **R1 BLOCKED（403 原因未定）** | 开闸后仍 403 且同程序身份已确认 → 先按 §2.3.2 在 Aqua 会话内用 `--check-authorization` 区分；能区分就写具体原因（权限未授权 / 闸门未生效），不能区分就写 **`403 原因未定`**。**不得**仅凭 403 写"TCC 失效"，也**不得**用历史归档里的 `authorized` 结论替代本次测量 |
| **R1 BLOCKED（前置）** | 哈希不符、签名无效、health 非 production、初始非 403、白名单/绑定不符、多进程、python3 缺失、token 不可得、受限输出目录不可用（退出 6/17） |
| **R1 INTERRUPTED** | 期限或预算触发（退出 16）、恢复失败（13）、取证未完成（15）、互斥不可得或丢失（7） |
| **不构成 PASS** | 空数组、Mock/Fake、无程序身份与哈希、B/C/D 层调用、被截断的窗口、用历史（非本次窗口）TCC 结论替代测量、以补救关闸冒充首次恢复 |

> **离线完成 ≠ R1 完成。** R1 通过后才提交 R2 的方案与申请；R2 由 MUSE 侧独立签署。**R1 的通过不要求 MUSE 签署**，也不得把 MUSE 签署当作 R1 的前置条件。

---

## 附录 A：本轮离线产物清单

| 文件 | 作用 |
| :--- | :--- |
| `macserver-eventkit/scripts/r1_window.sh` | 自闭合窗口：前置门禁 → **校验并实写探测受限输出目录** → 武装看门狗 → 开闸 → 采集 → 关闸 → 三独立判定；采集结论按全部计划批次聚合；关闸有界重试、失败不解除保护；支持 `--expect absence` |
| `macserver-eventkit/scripts/r1_gate.sh` | 唯一开/关闸入口：**输出目录前置校验** + **符号链接原子互斥（无主宽限、核对式回收、写前/重载前持锁断言）** + 来源检测 + 0600 备份 + 双路径重载（不吞 bootout 错误）+ **强制**行为验证；失败也写回执（`disk_written_before_failure` 由实际写盘决定） |
| `macserver-eventkit/scripts/r1_watchdog.sh` | 独立期限看门狗：绝对截止 + 累计开闸预算；**状态目录不可用即 FATAL 退出 4**，不装作已武装；只有闸门自证 `verification=PASS` 才写 `FIRED_RESTORED`，否则有界重试后 `FIRED_RESTORE_FAILED` 并以 6 退出 |
| `macserver-eventkit/scripts/r1_bridge_client.py` | 只读客户端：固定回环、空代理、拒绝 3xx、令牌仅从 0600 文件、批次不可覆盖、**输出目录不可用返回 4 且与传输失败可区分**、回执原子落盘 |
| `macserver-eventkit/scripts/write_build_metadata.py` | 构建溯源写入与校验（补 source commit 缺口） |
| `macserver-eventkit/scripts/tests/fake_bridge.py` | 回环假桥：按真实优先级（plist > config > control）读闸门，支持 302/延迟/500/逐次响应序列（`items_seq`） |
| `macserver-eventkit/scripts/tests/test_r1_bridge_client.py` | 53 项断言 |
| `macserver-eventkit/scripts/tests/test_r1_window.sh` | 125 项断言（含加载失败、恢复失败且保护未解除、期限、预算、SIGKILL、launchd 分支、清理核验、看门狗验证失败、互斥与陈旧锁、**无主锁宽限期**、**确定性并发（暂停在发布前）**、**证据目录不可用四类**、跨批次假成功） |
| `receipts/R1_01_OFFLINE_DIAGNOSIS_RECEIPT.json` | 离线定位回执（事实/假设/排除项） |
