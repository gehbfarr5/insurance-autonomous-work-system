# 阳光森林有界诊断与恢复说明｜2026-11-04

## 状态与范围

记录更新时间：2026-11-03 19:02 CST。此说明只覆盖既有每日任务自然运行及一次性诊断证据收集，不启动任何业务动作，不改变调度、防重状态或凭据。

### 11月3日prepare失败层级审计｜2026-11-03 19:02 CST

MUSE仅复核既有Forest对话的三段脱敏摘要，读取时间19:02:18 CST；未读raw logs或业务state、未访问设备、未运行代码/任务、未修改文件/调度。08:57助理误触、09:00调度助理和主流程均在prepare事件到达MainActivity后以`PREPARE_TIMEOUT_NO_FALLBACK`结束，未进入业务、cleanup均PASS；两段助理为`NOT_SENT`且`vueCheck`缺失，主流程无业务stage且`pendingAction`为空。

现可定位到runner Activity/就绪标记轮询超时层；assistant页面门禁未被求值，不能归因为门禁失败。module登录态门禁因无登录类事件、逐字段布尔值或采样时间，仍UNKNOWN。就绪标记未到达的具体原因以及屏幕/Keyguard/认证输入原因仍UNKNOWN。该记录是已有脱敏摘要的复核，不是对原始设备日志的重读；它缩小了失败层级，但未证明底层触发原因。逐段时序见[诊断检查点](forest-prepare-diagnostics-2026-11-03.md)及[结构化证据](remaining-work-evidence-2026-10-29.json)。

### 最新只读状态与来源复核｜2026-11-03 18:54—18:56 CST

18:47:11 MUSE在既有Forest对话中报告：唯一启用的任务仍为`Asia/Shanghai`每日09:00、下次2026-11-04 09:00；running/queued/in-flight为`0/0/false`，runner lock `FREE`、无Forest进程。live `run.py` SHA为`de9bd83cb8188151353c97d3e73071a50d2bfca8142d5a5774b00e94e3284562`，live `assistant.py` SHA为18:40集成候选`7c6400b3900a2f4426ab2c3af4e4ebddfaacf5f82c4bf233ef24dc8b1c35121c`。最近调度失败仍为11月3日09:11:17，最近成功10月31日09:15:50。该请求未重读业务结果；assistant/main阶段值沿用先前读数，其他聊天未探测。

18:48:55经唯一既有SSH别名`pixel3a-kjgx`以非root UID 10249只读复核：Pixel 3a、Android 15、Asia/Shanghai、boot completed；`ps -A`未见AutoX/AutoJs进程；已安装`com.p4.secureview` APK SHA-256 `dbada93c1d0110fe86ef1c0cad77224e81c0f5939bd9462a3c0b9d5b72c48167`，与已知v0.19工件值匹配。当前设备操作锁未读，故记`UNKNOWN`（18:22历史FREE不作为当前值）；monitor私有状态/hash、屏幕、Keyguard、device locked及前台Activity同样UNKNOWN。未用root/su，未启动/停止进程、写设备或业务状态、运行任务、改变调度/凭据/网络。本次只读预检不证明monitor在运行，也不解释11月3日prepare超时。

### MUSE部署状态与官方来源追加复核｜2026-11-03 18:54—18:56 CST

18:54:37 MUSE再次报告唯一Forest每日09:00调度、下一次11月4日09:00，running/queued/in-flight `0/0/false`、runner lock `FREE`、Forest进程未见；live `run.py`/`assistant.py`哈希保持`de9bd83c…e3284562` / `7c6400b3…c35121c`，最近调度失败及最近成功时间未变。该请求不读业务结果、不访问设备或WP1。随后Drive四项metadata-only检索和CPIC官方域三项检索均无直接规则来源；结果只记有界未命中，不推断资料不存在。具体查询见证据索引末尾新增的`rulesDriveMetadataSearch20261103_1856`与`rulesOfficialSearch20261103_1856`。

### assistant门禁诊断遥测集成｜2026-11-03 18:40 CST

**有界集成结果：PASS（只验证源码替换与运行元数据）；同轮运行及业务结果：PENDING。** 18:36:23 MUSE只读预检确认唯一启用的Forest schedule仍为Asia/Shanghai每日09:00、下次11月4日09:00；running/queued/in-flight `0/0/false`、runner lock `FREE`、Forest进程未见。live与原始备份哈希均为`a3a7de236f8a3e3a4a29f73c55fce4161919d117e727ed550e46490c24260229`，私有候选哈希为`7c6400b3900a2f4426ab2c3af4e4ebddfaacf5f82c4bf233ef24dc8b1c35121c`。设备操作锁本次未读，18:22:27既有别名读数为FREE；本次集成未访问设备。

静态消费者审计覆盖MUSE现存代码树：未发现该assistant结果记录的读取器、schema/validator或精确键集合约束；已知报告按字段选择读取且曾容忍缺字段。既有写入器本来就产生不同形状的记录。证据对已检查代码树为中等，对未来工具或外部解析器为UNKNOWN，因此不能声称普遍兼容。

写前复核时间18:40:26，原子替换18:40:41，写后复核18:40:48。目标为云端Forest runner的`assistant.py`，不是设备/APK/module。仅在结果对象中增加五个脱敏诊断字段：Vue存在布尔值、`onClickApp`存在布尔值、目标项数量、固定`forest-20261104-0900` runGroup、门禁专属采样时间；不可用来源时按候选约定保留UNKNOWN/null。原方法源码固定pin、目标项必须恰好一个、失败在调用前停止以及原页面方法调用均未改变；没有加入新的放行条件，也不保存方法源码、菜单文本、客户数据或凭据。

替换采用同目录临时文件加rename。先从原备份建立并验证独立部署侧回滚副本，原备份未动；live SHA-256现与候选一致`7c6400b3900a2f4426ab2c3af4e4ebddfaacf5f82c4bf233ef24dc8b1c35121c`，两份原始备份均与基线一致。写后唯一schedule/下次触发不变，running/queued/in-flight仍`0/0/false`、runner lock `FREE`、无Forest进程且无临时文件遗留；无需回滚。没有运行解释器、语法检查、业务脚本、任务或设备，也没有改变state/dedupe/history/cron/schedule/credentials/network/module/APK/WP1。细节见证据索引`assistantGateIntegration20261103`。

### MUSE只读状态复核｜2026-11-03 18:15:56 CST

既有森林对话确认：Forest部署范围内没有观测到活跃任务，唯一启用任务为`Asia/Shanghai`每日09:00，下次触发2026-11-04 09:00；running/queued/in-flight为`0/0/false`，runner lock `FREE`，无forest-agent进程。其他聊天未探测，不能据此断言全局MUSE空闲。live `run.py`哈希为`de9bd83cb8188151353c97d3e73071a50d2bfca8142d5a5774b00e94e3284562`，`assistant.py`哈希为`a3a7de236f8a3e3a4a29f73c55fce4161919d117e727ed550e46490c24260229`。最近调度失败11月3日09:11:17，最近成功10月31日09:15:50；业务段状态沿用早先读取，没有本次重读。设备操作锁在这次MUSE查询中未读取。

### Pixel非root只读预检｜2026-11-03 18:22:27 CST

通过唯一既有`pixel3a-kjgx`配置，以非root远端用户读取：Pixel 3a、Android 15、`Asia/Shanghai`、boot completed；设备操作锁`FREE`，AutoX相关进程未见。已安装SecureView APK的SHA-256为`dbada93c1d0110fe86ef1c0cad77224e81c0f5939bd9462a3c0b9d5b72c48167`，与已知v0.19工件值一致，但运行时版本属性未读到。屏幕状态、Keyguard showing、device locked和前台Activity均UNKNOWN；monitor状态/hash因私有应用目录对非root不可读而UNKNOWN。该读数不证明monitor在运行，也不回溯11月3日prepare结果。本次未用root/su、未写设备/业务state、未启动或停止进程、未运行任务、未改调度或凭据。

### live assistant gate静态核对｜2026-11-03 18:24:13 CST

当前assistant.py原字节SHA-256为`a3a7de236f8a3e3a4a29f73c55fce4161919d117e727ed550e46490c24260229`，与预期完全匹配。调用门禁要求root元素可达Vue对象、`onClickApp`存在且源码匹配固定pin、过滤后目标项恰好一个；三个条件同时满足才先记录阶段标记再调用。失败在调用前停止。live记录保留method-match布尔值及仅含code/name的过滤列表；Vue存在性、单独的method存在性、单独数量、门禁专属采样时间/run group未写入记录，只有一般保存时间及成功阶段标记。module源码在本地适配副本中MISSING；安装module版本/hash在不访问设备时UNKNOWN。这个静态审查不能证明历史运行到达门禁，11月3日prepare超时根因仍UNKNOWN。结构化事实见证据索引的`assistantGateStaticAudit20261103`。

以上18:24记录为集成前快照；新增诊断字段已按上方18:40记录集成到云端assistant脚本，设备侧APK/module与monitor未改。

### 官方来源补查｜2026-11-03

追加的Drive定向metadata检索对森林规则与五项扩展词组均无命中，未读取文件内容；精确查询和边界见证据索引。CPIC官方历史页面提到E锦囊/保险超市产品页迭代及销售支持用途，但未提供当前激活流程、本人资格或森林奖励周期；因此五项扩展分类仍全部“仍待核实”。[E锦囊历史方案公告](https://www.cpic.com.cn/c/2018-11-02/1562542.shtml) · [太保2017投资者日材料](https://www.cpic.com.cn/upload/resources/file/2017/12/22/47047.pdf)。

### 私有离线Activity类别候选复核｜2026-11-03 18:08 CST

针对11月4日review-only窗口，在私有副本中增加前台Activity固定类别枚举与v3/v4侧车兼容投影。选择固定类别而非原始类名，避免持久化运行时Activity字符串；复用现有monitor/trigger/worker控制流、固定窗口日志投影和runGroup/时间关联工具。候选SHA-256为`1310672261f2851465c756287e9d60882526f8f25a14fcc9585043a2f02944b1`，11文件SHA清单为`2802b8c406d420e916835efc471f4b0905e9ffa86c0ca5525953b9e360a08fe4`，逐文件11/11匹配。五项离线合成脚本均PASS（Node 26.0.0、Python 3.14.7）；未安装、部署、连接设备或验证AutoX/Android运行兼容。候选不更改GestureActivity精确门禁、assistant固定方法pin、认证输入、调度或业务状态；API读取异常仍fail-loud。prepare逐字段登录态及assistant Vue/方法pin/菜单观察器仍未集成live runner；本候选不构成完整单轮诊断，也不定位11月3日超时根因。候选更新/重启可能影响进程内触发状态，继续受备份、MUSE无并发、设备操作锁确认及可回滚门禁约束。详见证据索引中的`activityClassObserverReview20261103`。

### MUSE只读状态复核｜2026-11-03 18:08 CST

约18:05 WP11对话已结束生成；随后只读打开既有森林线程。当前AX树显示发送框、未见生成中控件，但线程没有本轮新的scheduler/task/queue/in-flight/runner-lock/部署哈希读回；可见的16:23调度读数已过时。因此并发与Pixel设备门禁仍UNKNOWN，本轮未连接Pixel。不得将历史16:23的FREE锁读数或本机没有SSH进程当作当前设备授权。结构化记录见`remaining-work-evidence-2026-10-29.json`的`museUiSnapshot20261103`。

### 前一轮MUSE界面只读可用性复核｜2026-11-03 17:57 CST

约17:50及17:54 CUA读取MUSE应用可访问性树，当前对话两次均显示Assistant正在输入，界面含停止生成控件。未切换到森林对话、未发送消息或中断生成；也未读取Forest scheduler/task/queue/runner lock/deployed hash。该UI证据只说明MUSE前台仍有生成状态，不足以判断Forest后台并发或设备锁。浏览器清单为空、Work设置禁用浏览器控制。17:55本机进程盘点未发现SSH客户端或匹配`pixel3a-kjgx`的会话；本轮未连接Pixel，此检查不代表设备端状态。当前并发和设备访问门禁保持UNKNOWN；当时等待该MUSE工作自然结束后，通过既有森林线程重取新鲜状态。结构化证据见`remaining-work-evidence-2026-10-29.json`的`museUiSnapshot20261103`。

### 访问门禁历史记录｜2026-11-03 16:14 CST

CUA inventory returned “Mac is locked”; MUSE UI was not read at that time. The following 16:23 MUSE-only readback supersedes this unknown queue status. No Pixel connection followed. Private CUA error record: `muse-access-gate-20261103-1614.json`, SHA-256 `80b65bfcb899569a4f5d0169e66effff268ba659427a4ce59538d01325c4595a`.

### 最新MUSE只读回读｜2026-11-03 16:23 CST

MUSE confirmed the single enabled Asia/Shanghai 09:00 schedule, next trigger Nov 4, running/queued/in-flight `0/0/false`, runner lock `FREE`, no `forest-agent` process, latest scheduler failure Nov 3 09:11:17, last success Oct 31 09:15:50, and three consecutive failures. The query was accidentally truncated to keywords; MUSE stated this read was read-only and did not access Pixel, read business state, or change anything. The assistant/main status remains carried forward from earlier and was not reread. Pixel device state, device-operation lock, and foreground Activity remain UNKNOWN. Private sanitized readback `muse-access-readback-20261103-1623.json`, SHA-256 `984471e93c15f10ba975dd1c1ac93862192274b0111456591c576e5ec4dda3b9`; it is not a raw UI export.

### Runner static read｜2026-11-03 16:33 CST

MUSE recomputed the current live `run.py` hash and confirmed it matches the recorded deployment hash. Static flow: `Device.prepare()` polls resumed Activity with a 70-second deadline and 1-second interval; `Device.event()` writes prepare events; `Device.cleanup()` is called from `main()` and handles marker cleanup, app stop, and owner-checked lock release, with a failure branch on exception. MUSE attributed scheduler-level `FAILED` to the worker reporting unfinished work, consistent with the incomplete assistant/main segments. The 09:06:17–09:11:17 interval remains UNKNOWN because neither runner code nor scheduler metadata has a sub-step breakdown; this read also does not identify the specific prepare-timeout trigger. MUSE reported a private export of the exact live runner is available, but did not export or attach it. Private sanitized readback SHA-256: `fb4493eaf0f6161709225cb75940fecb5a3182806cc639e8829ffbd8d18605a0`.

### 最新只读复核｜2026-11-03 15:54—15:58 CST

- MUSE 15:54:29确认唯一既有每日09:00 CST任务，下次11月4日09:00；running/queued/in-flight为0/0/false，runner lock FREE，无forest-agent进程。最近调度失败11月3日09:11:17，最近成功10月31日09:15:50，连续失败3次。
- 在上述无并发readback之后，经唯一允许的`pixel3a-kjgx`别名及既有`su`路径于15:58:24只读回读：Android 15、boot完成、Dozing；monitor `watching`、guard清、heartbeat新鲜、requests=0；monitor lock存在，blocked/stop不存在。monitor/trigger/worker哈希分别为`2b611ca16f49523c74e544b96e19a7931db6af7d1ea4787ecea708b25e56241a`、`0243ee09abdbf07b162cc69c815ca69f00ad3519bda78df26d8588a5e9c0c499`、`f6fb7d23ebdb75183a62430d92aa7e161ff1ec7fc3db10f26ac857da8939000f`。
- 设备操作锁和前台Activity本次为UNKNOWN；v0.19 APK pin只在15:22最后直接核验并匹配。没有业务重跑、设备写入或state/cron/调度变更。后续窗口开始前仍须即时复核MUSE并发及设备锁；不因本次readback跳过门禁。
- 本次状态抄录存于仓库外受限私有文件`status-readback-20261103-1554-1558.json`，SHA-256 `58d9f090792927caa636cb4d59bfa37ccc8401cf53dc3bafad9f59ce9164bfaf`。它是脱敏操作员抄录，不是MUSE原始导出或Pixel stdout；UNKNOWN项和APK哈希的15:22读取时点均保留。
- 11月4日只读review包`auth-trigger-diagnostics-20261104-review-only`的SHA256SUMS于16:10 CST复算14/14匹配，随后原生命令`shasum -a 256 -c SHA256SUMS.txt`也返回14/14 OK；其monitor候选哈希与15:58 live读数一致。仓库外私有校验记录`review-package-integrity-20261103.json` SHA-256 `89721b3f7b1b5761b1fd672dc994364a889a6b8854169568e2fa5ecb2a5c5e1a`。清单完整性不代表窗口期Keyguard API/sidecar/MUSE对账已实机验收；只用此包中的collector说明，不应用窗口已过期的11月3日v3部署包。

- **前一时点记录（15:37，已由上方15:54状态读回更新）：** MUSE 14:09 CST 快照报告既有 `Asia/Shanghai 09:00` 任务下一次为 11 月 4 日 09:00，且当时 running/queued/in-flight 均为 0。15:37 CUA 应用清单确认 MUSE 进程运行，但未读回任务状态。不要把旧快照或应用进程状态当成当前任务 readback。
- Pixel 15:22 CST 通过现有 `pixel3a-kjgx` 别名及其既有 `su` 路径只读复核：`sargo`、Android 15、启动完成；monitor 状态 `watching`、guard 未阻断、心跳新鲜、`requests=0`；设备操作锁、`blocked` 与 `stop` 标记不存在，monitor 自身锁存在。Forest 未在前台，设备 Dozing。
- 已部署的 monitor-only 候选 SHA-256 为 `2b611ca16f49523c74e544b96e19a7931db6af7d1ea4787ecea708b25e56241a`；其触发器与 worker 哈希仍为 `0243ee09abdbf07b162cc69c815ca69f00ad3519bda78df26d8588a5e9c0c499` 与 `f6fb7d23ebdb75183a62430d92aa7e161ff1ec7fc3db10f26ac857da8939000f`。已安装 v0.19 SecureView APK 哈希 `dbada93c1d0110fe86ef1c0cad77224e81c0f5939bd9462a3c0b9d5b72c48167` 与 runner pin 一致。
- 输入审计仍为 12 行，最后修改时间 2026-10-31 09:06:46 CST；现有状态记录为 `page_left`，本轮没有认证输入。固定窗口 sidecar 尚未出现，窗口为 2026-11-04 08:55–09:55 CST。登录字段逐项诊断仍不可用，因为 prepare observer 未部署。

完整只读 readback 及 MUSE 状态限制见[诊断检查点](forest-prepare-diagnostics-2026-11-03.md)。恢复基线哈希、设备备份位置、候选及离线验证材料见本机私有审阅包。

## 自然运行顺序

### 当前MUSE访问门禁｜2026-11-03 17:00 CST

CUA库存只确认MUSE应用进程运行，未提供Forest任务/调度读回；浏览器控制不可用。最近并发读数仍为16:23，已过时，当前为UNKNOWN。未连接Pixel；不将16:23的0/0/false和runner lock FREE用作当前门禁。

### Pixel SSH连接只读复核｜2026-11-03 17:03 CST

本机只读确认既有SSH别名已配置、ControlMaster未启用、无对应控制socket或带别名的SSH进程；本轮未建立Pixel连接。该项不是设备锁/monitor/hash读数，仍须先满足MUSE并发门禁。

### 当前MUSE访问门禁｜截至2026-11-03 17:25 CST

更新的CUA inventory确认Muse应用进程运行，但浏览器清单为空，系统提示Work设置已禁用浏览器控制；本机可用工具名中没有MUSE/Pixel专用connector。没有从MUSE读取Forest scheduler、队列、in-flight或runner lock。遵守此前避免触碰无关WP1上下文的边界，未打开Muse界面。本轮未连接Pixel；16:23 MUSE读数继续视为过时，当前并发UNKNOWN。

### Review-only采集字段审计与修正｜2026-11-03 17:12 CST

静态核对本机私有review包的README、monitor、collector、joiner及observer候选，未读取原始设备日志，也未连接Pixel。实际字段边界如下：

- 已安装monitor在固定窗口内采集屏幕亮灭、Keyguard读取状态及两个布尔值、目标应用/手势Activity匹配、guard/account门禁、延迟复核门禁、episode接受、worker请求及worker返回状态/原因。它只能说明目标应用/手势Activity是否匹配，无法识别其他前台Activity；account只保留匹配布尔值，不导出原始Activity名或标记值。
- MUSE脱敏分段负责提供assistant/main区间、阶段、回执与cleanup。joiner的`auth.dispatch=DISPATCHED`代表monitor请求了认证worker；`auth.return=RETURNED`代表worker调用返回，不证明实际手势已输入、应用接受输入或服务端认证成功。
- `forest-prepare-loginstate-observer.js`与`assistant-gate-observer-expression.js`均未部署/集成。三项登录字段的存在性及采样时间、助理Vue/方法固定pin/菜单数量快照，除非MUSE在精确分段内提供匹配时间戳，否则都必须保持UNKNOWN。
- 发现collector先前忽略monitor写失败`.failure`标记，可能把不完整sidecar误报为完整关联。现已在本机私有collector加入标记计数：保留已有脱敏样本，同时将`correlationStatus`降为`PARTIAL_UNKNOWN`；若没有sidecar则monitor来源仍为UNAVAILABLE。对应合成采集器检查通过，包清单已重算并复核14/14。该修正只影响本机导出器，不改设备代码、monitor、APK、runner、调度或业务state。

### Review-only采集包完整性复核｜2026-11-03 17:12 CST

修正后的私有review包SHA256SUMS已按14个成员重算并逐项核验通过。synthetic collector test覆盖固定分段关联、脱敏和`.failure`标记的`PARTIAL_UNKNOWN`路径；这不验证窗口期设备API、sidecar生成、MUSE导出兼容或业务结果。collector覆盖边界与字段解释见私有包README；下一轮窗口后仍须先确认MUSE无在途任务，再使用本机修正后的collector。

### 官方应用规则快照复核｜2026-11-03 17:22 CST

按公开证据索引E07定位到的私有`rules.json`为8079字节，SHA-256与索引完全匹配。原页面规则弹层支持历史日上限及按次/人/单计量；明细的周选项只是1–7、8–14、15–21、22日至月底的显示区间，月末说明仅涉及行为积分统计与人管结算。内容不证明阳光森林每日重置时点、任务重复周期、奖励异步入账时延或当前规则。CPIC官方域对4条精确规则字符串/计量组合查询未命中；结论维持“本次有界检索未命中”，完整时点原据继续待恢复。

### 前次访问门禁｜2026-11-03 16:52 CST

本轮CUA库存只确认MUSE进程运行，未提供Forest任务/调度读回；浏览器控制不可用。16:23的MUSE状态读数仍是最近一次Forest并发证据，当前并发状态UNKNOWN。未连接Pixel。不得使用旧的0/0/false与runner lock FREE读数作为当前设备门禁；先获取新鲜MUSE状态，确认目标任务结束、没有其他任务在途，再通过既有别名读设备锁和哈希。既有别名在本机配置中存在，但本轮未建立SSH连接。16:33静态源码读回只解释prepare轮询控制流，尚未定位触发超时的具体分支，也未导出完整live runner。后续步骤和窗口限制仍按本节 runbook 执行。

1. **先确认 MUSE 并发，再接触 Pixel。** 通过已有 MUSE 运行入口只读确认当前日程、运行/排队/在途任务及目标自然运行。只有确认没有其他设备任务占用、且目标任务身份明确后，才通过现有 Pixel 别名复读 monitor、设备操作锁及部署哈希。若 MUSE 当前任务或队列不可读/UNKNOWN，跳过 Pixel 连接和所有设备诊断；记录 UNKNOWN，等待可验证无并发后再继续。不手动启动、取消或改动原任务，不连接备用 SSH 路线。
2. **只允许既有自然调度发生。** 不点击入口，不重放、不补跑、不登录，不清理 `state`、防重记录、attempt 或 audit 文件。已有授权只覆盖原每日范围，不因诊断窗口扩大业务权限。
3. **窗口结束且确认无在途任务后只读采集。** 取得 MUSE 已脱敏的 `assistant` 与 `main` 两段唯一、非重叠起止时间，并确认任务已结束、没有其他设备任务运行，再通过本机私有 collector 从同一 Pixel 别名读取 sidecar 与 epoch 时间日志。若任务结束或设备独占状态无法确认，先不连接 Pixel、不采集；继续标记 UNKNOWN。使用本机私有包`auth-trigger-diagnostics-20261104-review-only/README.txt`中的输入契约；先在包目录执行`shasum -a 256 -c SHA256SUMS.txt`，14个成员均须为OK。该包要求仅输入脱敏的唯一assistant/main区间，collector命令为：

   ```sh
   python3 collect-run-diagnostics.py --segments <sanitized-segments.json> --output <private-result.json>
   ```

   在该私有包目录内运行。输入与输出均留在本机私有目录，不上传MUSE原始结果或Pixel日志。不要使用固定窗口已过期的`auth-trigger-diagnostics-keyguard-v3-bounded`部署包；也不要执行私有归档`delivery-package-v4/INSTRUCTIONS.txt`中的2026-11-02单次补跑指令，该次已按授权完成。当前只允许自然调度与此处说明的只读采集。
4. **缺失继续记 UNKNOWN。** 没有 sidecar、日志 marker 不在唯一分段内、MUSE 分段缺失/重叠、来源不可用时，不合成事件、不从空结果推出“未触发”，也不重试生产动作。`NOT_SENT`、`SENT`、`UNKNOWN`、页面完成和奖励确认分别保留。

## 异常停止与回滚

- 若哈希不符、stop/blocked 标记出现、monitor 状态异常、设备操作锁被占用或 MUSE 报告有并发运行：停止诊断动作；先读清在途状态，不启动另一个流程、不删锁或状态。当前只读检查不授权解除并发锁。
- 若安全原因要求停止 monitor，先复读操作锁及是否存在 `input_requested` 在途阶段；确认没有在途认证后才可用原有 `stop` 标记使其自行退出，并读回停止状态。不要 `kill` AutoX，也不要在窗口内以清锁方式恢复。
- 如需回滚已部署 observer，使用已验证的设备备份 `/data/user/0/org.autojs.autoxjs.v7/files/pixel-auth/monitor.js.rollback-20261103-1500`，其基线 SHA-256 为 `238d86a8ec06c5a92579ea54377956f282cbed824c32b2c56823a2924cb906fd`。操作前复读设备操作锁与当前候选哈希；恢复后必须复核 live 文件哈希，并通过既有 AutoX 启动方式确认 `watching`、新鲜 heartbeat、guard 清。若启动入口或 readback 不能确认，停在文件已回滚状态，不尝试任何业务动作。
- monitor 的 `requests` 是进程内计数，重启会归零。记录每次重启前后真实读数，不回填历史累计，不改写原始运行结果。
- v0.19 工件保持 pin；prepare observer 不部署。不得降低固定方法指纹、手势页/本人匹配或登录态门禁。

## 交接判据

运行证据由 MUSE 自然任务原始记录与本机脱敏导出组成，两者来源和时间分开标注。诊断阶段只有在实际环境/工件版本复核完成，且同轮日志把故障定位到明确阶段（或严格证明观测仍 UNKNOWN）、没有误触发业务时才算通过。一次自然运行或一次健康 readback 不代表日常业务成功、S1 完成或长期稳定。
