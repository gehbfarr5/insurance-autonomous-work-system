# 11月2日准备阻断修复与单次补跑记录｜2026-11-02

## 当前结论

- 11月2日自然轮在准备阶段阻断，五项均未进入业务。此前v0.18补跑仍以`PREPARE_TIMEOUT_NO_FALLBACK`结束、`NOT_SENT`、无stage/receipt，cleanup PASS。
- 用户随后明确授权：门禁全过后安装自制v0.19并从原入口补跑一次。MUSE于11:13:41完成即时门禁；只备份并替换本次范围的runner和模块APK，未改assistant.py、tasks.py、cron、调度或清除状态。安装后runner候选哈希、APK候选哈希和versionName 0.19.0均读回一致。
- 原入口仅运行一次，没有第二轮或重放。旧bundle准备超时已消除，但新暴露两个独立停止点：助理段准备成功并到达BridgeWebActivity，随后调用入口未唯一匹配，结果`REVIEW / ONCLICKAPP_OR_MENU_NOT_UNIQUE_NO_CALL / NOT_SENT`；主流程在登录态检查处`BLOCKED / PREPARE_LOGIN_STATE_MISSING`。两段均无业务回执，cleanup PASS，五项均未完成/未执行。
- 最终结束时runner.lock与设备操作锁均FREE，无相关进程。state主文件、cron定义和调度定义未变；assistant.json当日`lastError`随本次运行更新，`phase/questionStatus/startedAt`未变、没有`sentAt`。每日Asia/Shanghai 09:00调度未改，下一次为11月3日09:00。
- 本次结论是**v0.19安装与读回PASS、旧准备超时修复链路得到有限验证；每日业务执行仍未通过**。P4/S1不代表整体验收完成。跨日验证按用户要求等到真实次日；P50/月度规划继续挂起。

## 修复与运行证据

本机离线候选以当前运行bundle及首页模块结构为依据，复用应用原有弹窗关闭回调；未知弹窗保持阻断、不用坐标点击。APK按既有项目签名构建。包内哈希清单通过；MUSE从精确live runner源生成隔离候选，并验证三个v0.19标记、旧标记清零、仅预期改动及语法。模块补丁的本机v0.18 staging dry-run三文件通过；MUSE工作区没有模块源码树，因此不声称MUSE独立复核了该源码树。

签名证据保持边界：本机既有离线记录报告v2/v3签名验证通过；MUSE本地缺少对应验证工具，该环境内记UNKNOWN。安装后的证书身份与v0.18一致且设备读回APK哈希与候选一致；这不把MUSE端的独立v2/v3验证状态改写成PASS。

最终脱敏包：`sunshine-forest-20261102-v019-final-desensitized.zip`，SHA-256 `2e2abb95d64ced6fc4d16887fd7d8cc1ca3d03286c08e8600472c95ab3486579`。本机重算外层哈希一致，ZIP内5个成员的逐文件SHA-256均已核对。脱敏证据留在Git忽略的私有目录；公开仓库不含原日志、截图、客户/账号资料、凭据或网络端点。

安装与运行关键哈希（用于版本追溯）：

- v4交付ZIP：`0177f6ad3de5a4618c1e83b8fb7ca23bd963ac37793ab997dfb25ac3c7978c75`
- 安装后runner：`de9bd83cb8188151353c97d3e73071a50d2bfca8142d5a5774b00e94e3284562`（与隔离候选一致）
- 安装后v0.19模块APK：`dbada93c1d0110fe86ef1c0cad77224e81c0f5939bd9462a3c0b9d5b72c48167`（与设备读回一致）
- 补跑证据ZIP：`2e2abb95d64ced6fc4d16887fd7d8cc1ca3d03286c08e8600472c95ab3486579`

## 分项结果与边界

| 成果 | 结果 | 证据含义 |
| --- | --- | --- |
| v0.19 runner与APK有限替换 | PASS | 已备份，替换后哈希/版本读回一致 |
| 助理准备链路 | 部分通过 | bundle超时消除并到达BridgeWebActivity；调用入口不唯一，未调用、未提问、NOT_SENT |
| 主流程准备 | BLOCKED | 登录态缺失；无待决动作、无业务阶段、无回执 |
| 五项每日业务 | NOT_EXECUTED / NOT_COMPLETED | 签到、时光轴、客温客价、助理业务提交及一键领取均未完成；余额/待领未刷新 |
| 清理与调度 | PASS / 未变 | 两段cleanup PASS，锁释放；09:00每日调度定义未改 |
| 状态文件 | 有限变化 | state主文件与cron未变；assistant.json仅当日lastError更新，未清理INTENT/NOT_SENT |
| 长期/跨日稳定性 | 未验证 | 等真实次日核对；不以单次准备通过代替长期验收 |

## 只读根因细化｜2026-11-02 11:26

MUSE 对脱敏结果和现有适配源码做了只读核查，没有访问设备、改代码、写状态或触发业务：

- 助理结果记录 `onClickAppMatches=false`，目标菜单项 `aiAlert2026` 恰好一项，因此菜单唯一性本身满足。结果没有保存 `vue` 布尔值或当前方法源码；源码把 Vue/方法缺失与方法体不匹配固定版本 `NAV_PIN` 合并为同一失败原因 `ONCLICKAPP_OR_MENU_NOT_UNIQUE_NO_CALL`。当前只能判定该门禁未通过，不能区分实际 Vue 对象/方法缺失、未就绪或方法体不同。不能仅为通过而移除或放宽固定方法指纹。
- 主流程 `PREPARE_LOGIN_STATE_MISSING` 是 `user`、`empNoAES`、`operateFlag` 三项的合并门禁。现有结果没有逐项字段存在性或采样时点，三项均为 UNKNOWN；不能据此断言用户已退出登录，也不能确定是登录态缺失还是页面状态尚未就绪。
- 只读核对的 MUSE `assistant.py` live 哈希为 `a3a7de236f8a3e3a4a29f73c55fce4161919d117e727ed550e46490c24260229`，与安装前一致；`run.py` live 哈希为 v0.19 的 `de9bd83cb8188151353c97d3e73071a50d2bfca8142d5a5774b00e94e3284562`。本机旧导出 `run.py` 是 v0.17，不能用来解释当前 v0.19 运行行为。
- v0.19 APK 内 `forest-prepare.js` 为1493字节，本机独立解出的 SHA-256 `d787363212189e495ce752b089195aad1505cd328e892cc85cd4a8e33bb29d08` 与候选 JS 一致；MUSE工作区没有该 JS 的独立源码副本。当前仍缺实际 `vue` 值、方法存在性/方法体指纹的脱敏诊断，以及三个登录字段各自的布尔快照和采样时点。
- 两段仍只有准备阶段记录、无业务阶段/回执/部分动作，cleanup PASS。后续先改进离线诊断记录，使各门禁分项可观测但不记录字段值；继续 fail-closed，不放宽方法 pin。任何新的安装或实机运行都需要新的明确授权。

### 手势认证器关联排查｜2026-11-02

本机只读源码核对显示，通用一次性输入器只在 `target=true`、`gesturePage=true`、`accountMatch=true` 时认定手势页；触发器需观察到登录页，且同一页面 episode 只触发一次。[attempt.js](../tools/pixel-auth/attempt.js#L7) [trigger.js](../tools/pixel-auth/trigger.js#L4) 若页面/本人匹配条件不成立，它会在最多4秒观察后以 `EXPECTED_LOGIN_PAGE_NOT_VISIBLE` 阻断，不输入；输入前还会重新确认页面与屏幕。输入函数返回后需观察已知登录后 Activity 稳定1.5秒才报 `page_left`，该结果仍不代表森林内部数据已就绪。现有通用代码在调用前持久化 `INPUT_INTENT_PERSISTED`，但未单独写一条“输入调用已返回”的关联事件；设备私有 UI 适配器不在本机源码树中。

对11:14:53—11:17:57补跑的只读证据：

- MUSE 记录里只有助理段 `control` 区的本地无障碍认证路径标记，无精确时间；没有 `target`、`gesturePage`、`accountMatch`、attempt结果、输入调用或 `page_left` 回执。该标记只能说明存在认证路径信息，不能证明本轮触发或输入。
- 主流程只记录 11:17:26 `.MainActivity`，随后在11:17:57写出 `PREPARE_LOGIN_STATE_MISSING`；`user`、`empNoAES`、`operateFlag`各自状态及检查的精确时点均缺失，检查只知发生在上述区间内。
- **logcat汇总更正（约19:00重新读取Pixel系统缓冲）：** 新读到的`epoch`日志覆盖11:14:50.663—11:17:59.686，共693条系统记录，完整覆盖11:14:53开始的补跑及11:17:57失败记录。目标应用首次出现于11:15:29.825；此前目标包提及数为0。ActivityTaskManager记录`SplashActivity`→`MainActivity`→`BridgeWebActivity`→`MainActivity`→`SplashActivity`→`MainActivity`，全部693条均未提到`GestureActivity`。这次更完整缓冲取代此前“起始前7秒缺失”的限制；仍不能排除没有Activity切换记录的短暂UI覆盖层。更正此前“11:14—11:19只有一条11:14:34 ActivityThread记录”的不完整摘要：它不是当前系统logcat完整统计。MUSE既有工作区没有本轮认证监控日志或认证器版本哈希。

对已从 Pixel 安装版 APK 提取的 `forest-prepare.js` 再做静态核对：文件1493字节，SHA-256 `d787363212189e495ce752b089195aad1505cd328e892cc85cd4a8e33bb29d08`。`step()` 只在启动时读取一次 `__r(584).default.user`；若 `user` 不存在、`empNoAES` 为空或 `operateFlag` 未定义，立即输出 `BLOCKED / LOGIN_STATE_MISSING` 并返回。该登录态门禁没有等待/重试；后续最多8次等待只用于促销弹窗关闭及 `HOME_NOT_READY`。这确定了直接阻断的代码路径是单次登录态快照，但没有逐项诊断信息，无法判断具体缺项。

**结论：** 直接阻断是森林内部三项登录态字段的合并门禁未通过；源码显示它只采样一次、不等待字段就绪。更新后的完整logcat显示runner唤醒并启动APP后没有进入`GestureActivity`；监控请求未增、输入审计无记录，确认已知认证工作器没有被派发。因此没有证据表明密码/手势输入器执行错误；仍缺screen/page/account/guard/episode逐项历史值，以及live v0.19 runner是否执行了本机fixture所示的冷启动命令。不要据此修改凭据、强制登出或重跑生产业务。

### Pixel AutoX 输入审计补核｜2026-11-02 17:12

在此前 MUSE 运行记录/ logcat 核查之外，本机经既有 SSH 别名只读读取 Pixel 上 AutoX 私有记录。设备读数确认为 Pixel 3a、Android 15/API 35。已部署 `auth-worker.js` 与本机受控副本哈希一致（SHA-256 `f6fb7d23ebdb75183a62430d92aa7e161ff1ec7fc3db10f26ac857da8939000f`）。

- 输入审计共12条，首末记录分别为10月30日09:19:39.994和10月31日09:06:46.162；11月2日补跑窗口11:14:53—11:17:57没有该工作器的输入审计记录。
- 结果文件共18条，时间范围10月30日08:17:52至10月31日09:06:49；补跑窗口内没有结果文件。历史结果中17条为应用就绪条件仍不满足，1条为请求无效或过期。
- 工作器的 `input-audit.jsonl` 记录在调用 `gesture.apply` 的紧前位置。因此，**推断**该工作器在本次补跑窗口没有进入手势输入调用。这比此前“输入是否发生未知”更具体，但不是对所有可能认证路径的证明。
- 17:12:43的当前监控快照为 `watching`、守护未被阻断，心跳新鲜；这是当前状态，不能还原11:14—11:17每个监控门禁的历史值。

**更新后的归因边界：** 主流程直接停在森林内部一次性登录态快照门禁，已知代码在 `user`、`empNoAES`、`operateFlag` 任一条件不满足时立即 `LOGIN_STATE_MISSING`。现有证据强烈支持已知 AutoX 工作器本轮未调用手势输入，但具体未调用原因仍未知：历史页面/目标/本人匹配、屏幕、阻断标记和 episode 条件未保存；也不能排除其他认证路径或输入后应用状态尚未就绪。故不能把根因定为密码/手势脚本错误，也不修改凭据或重跑生产动作。

### 部署版监控与派发计数补核｜2026-11-02 17:20

再次从 Pixel 只读读取安装源码哈希，`monitor.js`、`trigger.js`、`auth-worker.js`、`attempt.js` 均与本机受控副本完全一致；其中监控脚本 SHA-256 为 `238d86a8ec06c5a92579ea54377956f282cbed824c32b2c56823a2924cb906fd`。因此下面的门禁顺序可以对应本次运行环境，而不只是未验证的本机候选。

- 17:20:18监控快照为 `watching`、`guardBlocked=false`、`requests=6`、心跳时间新鲜。监控状态所引用的进程当时已运行 `3-05:32:23`，约从10月30日11:47:55持续至本次补核；进程跨越11月2日补跑窗口。
- 已只读聚合18条结果记录：11条标记 `automatic`、1条 `explicit`、另6条是旧记录且无 `source` 字段。当前监控进程启动后恰有6条 `automatic` 结果，末条为10月31日09:06:49；这与进程内 `requests=6` 相符。
- 安装版监控源码在调用 `worker.run()` 之前先递增 `requests` 并写 `input_requested` 心跳。进程未重启、17:20快照仍为6，且没有11月2日结果或输入审计；因此有强证据表明本监控进程在11月2日窗口没有派发工作器请求，故更没有进入其手势输入调用。它不是“工作器接到请求后输入失败”的证据。
- 已知派发前门禁依次涉及屏幕开启、目标应用/手势页匹配、阻断标记未设置、本人标记匹配、短暂等待后的页面复核以及 episode 是否已重新武装。历史快照没有保留这些分项值，故不能区分具体哪一道门禁未通过。单次 11:17:26 的前台 Activity 采样为 `.MainActivity`，与当时未处于手势页相符，但不足以证明整个窗口内手势页从未出现。

**更新后的诊断：** 本次更具体的故障层是“登录页自动触发监控没有派发工作器”，不是输入坐标/手势执行结果错误。森林应用内部一次性 `LOGIN_STATE_MISSING` 是随后独立观察到的直接停止点；它可能由登录提示未出现/未被触发器识别或应用内部状态未就绪造成。要确认是哪一个门禁，必须让未来运行记录每个无敏感值的判定布尔值；11月2日的历史缺失无法追补。当前不改密码、不放宽触发条件、不重放业务。

**下一步：** 先取得与当前 v0.19 配套的 runner、设备私有适配器和输出解析契约，离线增加同一运行关联的脱敏阶段/布尔诊断；继续 fail-closed，不记录手势坐标、字段值、账号或页面正文，不部署候选。待下一自然轮后只读查看诊断结果，不把跨日结果作为本次会话收尾前置条件。

### 本机触发门禁诊断候选｜2026-11-02

基于已与Pixel安装版哈希匹配的 `monitor.js` 建立了本机私有候选：保留原有筛选、episode、输入及锁逻辑，另写独立的有界诊断事件文件；只记阶段码、屏幕/页面/本人匹配/guard/复核/episode布尔值及脱敏工作器结果，不记标记文本、账号、包/Activity名称、页面内容、手势坐标或凭据。原 `monitor-status.json` 字段保持不变，诊断事件最多保留128条并记录淘汰数量。源码留在本机受控私有目录，不同步到公开仓库，因为候选沿用设备专属配置标识。

离线检查：候选 `node --check` 通过；模拟7类触发门禁、单次派发、原状态JSON结构、脱敏载荷和128条上限的 Node harness PASS。没有写入Pixel、没有重启监控、没有触发输入或业务动作；Android AutoX 运行时兼容性和设备安装仍未验证。启用前需备份并复核设备状态，再观察自然触发，不主动重放业务。

**下一优先项：** 离线对齐森林准备源码和认证适配器，并补同一运行关联的时间戳/阶段码及布尔观测：显式区分“未检测到手势页”“未调用输入”“输入调用已返回但未离页”“已离页但应用登录态未就绪”，只记字段存在性、页面/账号匹配布尔值和采样时点，不记手势坐标、字段值、账号或页面正文。当前缺 live runner/私有适配器及输出解析契约；补齐前不改事件格式或运行副本。先做离线兼容性与脱敏检查；设备安装/实机验证另行授权。

## 接续动作

1. 本机先完善可离线验证的诊断，使助理 Vue/方法存在性/方法指纹、手势认证阶段与三个登录字段的布尔存在性和采样时点分别可见；不写入字段值、不放宽固定方法 pin，保留v0.18与v0.19备份，不改每日调度。
2. 跨日验证等到真实次日后读取自然运行结果；未有充分离线依据前不重复运行业务、不清state、不重放。将`NOT_SENT`、页面完成、业务提交、奖励确认、重复检查和长期运行分开记录。
3. 继续补AI结构化答案/奖励回执、客温客价独立收据、真实成功空列表、五项扩展的完整流程与周期、官方时点原始依据和完整设备恢复证据。用户可独立完成的项目不因暂时打不开页面判为现实阻碍。
4. P50和月度规划保持挂起（目标2U＝2800）；不部署定时、不新增持续运行任务。

## 本机离线诊断候选更新｜2026-11-02

为减少下次自然运行的证据盲区，并处理森林启动时登录字段可能晚于首屏加载的竞态，在Pixel安装版 `forest-prepare.js` 同源副本上建立私有候选，未修改已安装APK：

- 登录态条件不满足时只被动重采样最多8秒，不输入认证、不重放命令、不触发业务；就绪后最多沿既有路径派发一次，超时保持 `BLOCKED / LOGIN_STATE_MISSING`。
- 终态增加字段存在性布尔值、采样序号、时间及等待时长；不写字段值、账号、页面正文、凭据或手势坐标。
- 保持原 `BLOCKED/NAVIGATED` 状态词；等待期间不发送新的中间状态，降低未知v0.19解析器的兼容风险。
- 合成验证覆盖启动即就绪、延迟就绪、持续缺失、各字段分别缺失、权限拒绝、字段脱敏及单次路由约束，通过；Pixel触发监控候选也完成与部署源码的8场景行为对比。离线测试不代表设备兼容或生产验收。
- 对助理分支另有私有 `assistant.py` 候选，将Vue存在性、onClickApp函数存在性、原固定方法pin匹配和目标菜单数量分别记录为布尔值/计数并标时；不记录方法源码、菜单内容或页面正文。固定方法pin和唯一菜单门禁均保持，只有全部通过才会进入原调用。页面检查脚本合成场景及Python语法检查通过；未调用方法、未发送问题。

候选与测试留在Git忽略的私有目录，不公开源码或设备专属标识。当前本机MUSE run.py导出为v0.17（SHA-256 93151ce3…），与设备live v0.19哈希de9bd83c…不同；live解析器源码仍未取得。18:10 Pixel只读采集器返回NO_DIAGNOSTIC_FILE，状态字段为guardBlocked=false、requests=6；本轮连接确认Pixel 3a / Android 15。手势触发候选独立写入只读sidecar，不依赖MUSE runner输出解析；但替换monitor.js需单独授权，且需先备份、校验哈希并准备回滚。森林登录态与助理入口候选新增runner结果字段，须在live v0.19解析和AutoX兼容确认后再安排。Mac界面仍锁定、浏览器禁用，本轮未发送MUSE命令、未安装候选、未重启监控、未改变调度/state、未重跑业务；历史11月2日具体未通过门禁无法追补。

### Pixel 当前守护只读复核｜2026-11-02 17:37

通过既有SSH别名只读核对：设备为Pixel 3a / Android 15/API 35，AutoX应用进程与脚本进程均在；监控状态`watching`、guard未阻断、`requests=6`。输入审计仍为12条，文件更新时间为10月31日09:06:46。此快照说明监控此刻存活、已知工作器此后没有新输入审计；它不能补回11月2日当时未记录的门禁分项，也不代表手机登录或森林任务成功。

### 森林准备候选版本索引更正｜2026-11-02

二次逐文件哈希审查发现，最初的本机登录态候选曾从v0.18 staging资产拷贝，促销关闭模块索引为2559；v0.19安装包内同源脚本SHA-256为`d787363212189e495ce752b089195aad1505cd328e892cc85cd4a8e33bb29d08`，实际索引为2561。最初候选从未安装，因此未影响设备。现已从该精确v0.19资产重建被动等待候选，测试只提供2561并通过；若回退到2559，合成成功路径失败。设备端AutoX运行时和live runner解析兼容仍未验证。

与v0.19适配器指纹匹配的runtime bundle SHA-256为`ade689b53535d322de7c4d83d055f35be8de98f39f2886040d495f03d71b2c6f`；从该bundle静态提取的模块584导出`default.user`初始为空对象，且该初始化定义未包含`empNoAES`或`operateFlag`。因此登录字段异步填充前被单次快照读为空在技术上成立；这只是静态机制证据，不能回溯11月2日真实字段状态，也不能解释认证触发器未派发的具体门禁。

### 离线解析兼容与只读采集器｜2026-11-02

本机契约复核了已有MUSE v0.17脱敏run.py及脱敏v0.19 fixture：二者均对P4ForestAuto:后的完整JSON执行JSON解码，将完整对象赋给Device.preparation，并将其直接附加到最终结果；没有对白名单字段做裁剪。v0.18→v0.19补丁脚本仅有三项固定版本/错误码/资产名替换。新的本机契约测试覆盖嵌套loginState诊断字段透传，通过。

证据边界：v0.17源码SHA-256为93151ce3…；v0.19 fixture SHA-256为5028250d…，属于脱敏测试夹具且明确不可部署。live v0.19原文件未导出到本机；本结论仅确认现有源码/fixture的结构化透传路径，live精确解析和Pixel AutoX执行兼容仍待验证。

触发候选的workerReason已通过静态枚举白名单加固，未知原因归为OTHER；覆盖与敏感样例反例检查通过。只读Pixel采集器对未知字段、原因码及超过128条事件fail-closed；合成测试和monitor sidecar生产者→采集器端到端检查通过。18:10 Pixel实时只读结果为Pixel 3a / Android 15、guardBlocked=false、requests=6、NO_DIAGNOSTIC_FILE；说明候选未安装。未对设备作写入或重启。

### Pixel当前触发监控与候选复核｜2026-11-02 18:30左右

通过既有SSH别名再次只读核对：设备为Pixel 3a / Android 15，AutoX主进程和脚本进程均在运行；`monitor-status.json`为`watching`、`guardBlocked=false`、`requests=6`。部署版`monitor.js`、`trigger.js`、`auth-worker.js`、`attempt.js`哈希分别与本机受控副本一致（`238d86a8…`、`0243ee09…`、`f6fb7d23…`、`b4cb1ed5…`）。只读采集器返回`NO_DIAGNOSTIC_FILE`，确认触发诊断候选尚未部署。未写设备、重启监控、输入手势或触发业务。

这次快照证明监控当前存活，不能还原11月2日历史窗口的屏幕/应用/手势页/本人/guard/episode分项值。对原运行的归因仍是“监控在派发前未调用手势工作器”，没有证据表明输入器接到请求后输入失败；具体未通过哪一道派发门禁仍未知。

审查未部署的监控候选时发现`elapsedMs`原先记为设备累计运行时长，现已修正为相对本监控进程启动的单调时长。本机`node --check`及诊断集成测试通过，新增700毫秒断言；审阅包已按新文件更新并重算哈希，旧包保留为本地历史副本。Pixel上仍未安装候选，明日自然运行仍需观察到真实门禁事件后才能判定具体上游条件。

### 登录态来源与手势输入归因补核｜2026-11-02

对与v0.19适配器指纹匹配的runtime bundle（SHA-256 `ade689b53535d322de7c4d83d055f35be8de98f39f2886040d495f03d71b2c6f`）作定向静态追踪：模块584创建的全局`user`初始为空对象；模块862、885、963在登录响应分支将`loginEmp`赋给全局对象；模块1887、1894有退出/清理时重置为空的路径；模块2269只在已有用户对象上更新密码字段。对该bundle的直接赋值、字段赋值及常见合并形态检索，没有发现从本地存储直接恢复到该全局`user`对象的路径。

这使“准备检查时尚未完成一次登录响应，故全局登录对象仍为空”成为与代码相符的解释，但不证明11月2日实际缺失了哪一个字段，也不能排除原生桥接或运行态未覆盖的路径。结合本轮requests未增加、没有输入审计，现有证据仍指向：已知监控没有派发认证工作器，因此不能把失败归因于密码输入/手势动作本身；认证触发器上游为何未派发仍待分项观测。下一步优先用有界诊断sidecar取得具体屏幕/页面/本人/guard/episode门禁布尔值，再将其与森林三字段采样时点对齐。候选安装和监控重启仍待本次明确授权；不因此补跑业务。

### 恢复本轮后Pixel只读复核｜2026-11-02 18:46 CST

通过既有SSH别名只读复核：Pixel 3a / Android 15 / API 35；现有监控PID仍存活，`monitor.js` SHA-256仍为`238d86a8ec06c5a92579ea54377956f282cbed8242c2b56823a2924cb906fd`；状态为`watching`、`guardBlocked=false`、`requests=6`且心跳新鲜。严格只读采集器仍返回`NO_DIAGNOSTIC_FILE`，确认触发诊断sidecar尚未安装。本次未写设备、未重启、未触发认证或业务；该快照确认当前基线，不能追溯11月2日哪一道派发门禁未通过。

### 手势页Activity匹配目标清单复核｜2026-11-02

为核实触发器的精确Activity匹配目标是否已从当前安装包移除，通过既有SSH只读读取设备安装APK到本机受控私有目录，并核对设备端/本机副本SHA-256相同。离线清单解析确认当前安装包声明了监控器匹配的手势页Activity；此前10月30日三项Pixel验证记录也观察到相同Activity，且设备报告该应用上次更新为10月22日。因此“匹配的Activity类已从当前安装包消失”不符合现有证据。APK仅留在Git忽略私有目录，没有上传。

这仍不能证明11月2日窗口实际到达该Activity。当前重新读取的完整系统缓冲覆盖补跑开始至失败记录，未出现该Activity；但预检查的屏幕/目标页/本人标记/guard/复核/episode历史布尔值没有保存，且系统Activity日志不能排除没有Activity切换的短暂UI覆盖层。精确派发门禁仍未知，不据此修改识别逻辑或重放业务。

### 补跑唤醒与认证触发链根因细化｜2026-11-02 19:00

对当前Pixel系统缓冲和本机runner来源作关联核对：11:15:29.703系统记录设备从`Dozing`唤醒，原因`WAKE_REASON_WAKE_KEY`、细节`android.policy:KEY`；目标应用首次出现于11:15:29.825，Splash于11:15:30.334启动。此前0条目标应用记录。Android官方定义`KEYCODE_WAKEUP=224`，可唤醒设备；`WAKE_REASON_WAKE_KEY`是非电源键的唤醒键事件；Dozing状态下`PowerManager.isInteractive()`为false。[KeyEvent官方文档](https://developer.android.com/reference/android/view/KeyEvent#KEYCODE_WAKEUP) [AOSP唤醒原因定义](https://android.googlesource.com/platform/frameworks/base/+/ee50d90e9d41c877bed65fdfd39240c8693f57b4/core/java/android/os/PowerManager.java#616) [PowerManager.isInteractive](https://developer.android.com/reference/android/os/PowerManager#isInteractive())

本机MUSE v0.17脱敏源码（SHA-256 `93151ce3…`）及v0.19脱敏fixture（SHA-256 `5028250d…`）都含启动顺序`input keyevent 224; am force-stop; monkey launch`，并各含两处force-stop。Android官方将224定义为唤醒键；该命令与系统唤醒时间及随后Splash启动高度吻合，强烈支持runner发出唤醒键后启动了APP。因精确live v0.19 `run.py`尚未导出，这条关联仍标记为高置信推断，不声称已直接核验live命令。脱敏fixture及原始日志仅保留在本机私有目录，不进入公开仓库。

已部署`monitor.js`哈希与本机受控源码一致；它只在`device.isScreenOn()`、目标包和精确`GestureActivity`同时满足时派发，源码没有唤醒调用。当前Pixel缓冲完整覆盖补跑窗口却没有`GestureActivity`，监控计数未增且没有认证输入审计。因此**直接故障不是手势输入器输入错误：输入器没有收到请求**。最有力的运行时解释是runner唤醒并冷启动APP后，APP只到Splash/Main/BridgeWeb，没有进入应用手势页，监控页门禁未通过；无法由现有数据区分当时的screenOn、本人标记、guard或episode值。

另一个与`LOGIN_STATE_MISSING`相符的机制是冷启动后内存登录对象为空：精确bundle的模块584以`user={}`初始化，已发现的`loginEmp`赋值在登录响应分支；runner来源及v0.19 fixture的启动/清理命令含`am force-stop`。因此force-stop可能清空应用进程内用户对象，而本轮没有新的登录响应填充它。由于live v0.19 runner源码及运行时三个字段快照均缺失，这仍是根因链中的高置信假设，不能说已证明force-stop就是唯一原因。

**收尾诊断状态：** 11月2日无派发、无输入、登录态一次性检查失败已由日志、哈希匹配源码和运行记录交叉确认；最可能的链路是runner冷启动后未出现应用手势页，且内存登录态未重新填充。剩余未知是live v0.19确切启动命令及唤醒后Keyguard/三个登录字段状态。无需为了证明旧输入器而重放业务。后续若继续取得live源码，先只读核实`force-stop`；若要在自然运行中定位当前门禁，再使用已准备sidecar（安装/重启仍需单独授权）。

### runner派发门禁与Pixel登录入口基线复核｜2026-11-02 19:10

重新盘点本机私有 MUSE 导出：其中脱敏 `run.py` SHA-256 为 `93151ce3…`、文件时间为10:14:55，来源清单对应安装前 v0.17（原始文件哈希 `061f1878…`）；不是11:13后安装的 v0.19 live runner。v0.18红acted候选与v0.19 fixture均为301行，逐行差异只有三个模块版本/文件标记。v0.19转换脚本锁定安装前 live v0.18 runner 哈希`d63fbabe…`并仅做这三个替换；补跑证据记录安装后读取哈希`de9bd83c…`与候选相同。精确的安装后源文件仍未保存在本机，不能把脱敏fixture冒充live源码。

不过，锁定版本的脱敏runner fixture把登录入口门禁写得很明确：准备时执行`input keyevent 224; am force-stop; monkey -p …`，随后最长70秒轮询前台Activity；只有匹配精确`GestureActivity`且此前尚未尝试时，才调用一次`auth_start()`，而`auth_start()`调用Pixel本地`~/bin/pixel-auth-start`。v0.17源码、v0.18红acted候选、v0.19 fixture三者的这段控制流相同；v0.19补丁自身也只改版本标记。因而11月2日完整系统日志里的Splash/Main/BridgeWeb序列、无`GestureActivity`，再结合requests不增和无输入审计，强烈支持runner没有越过手势页门禁、密码/手势入口脚本未被调用。准确live文件缺失使这仍是受哈希链与夹具支持的控制流结论，而非直接读回live v0.19源码。

只读SSH还确认Pixel上的`pixel-auth-start`当前哈希`8f228b7e…`、设备文件时间10月30日13:22，与本机已验证的10月30日组件生命周期修复版本哈希一致；它不是11月2日新改的脚本。该入口采用锁、在途检查和已有成功状态合并，历史测试覆盖并发去重；11月2日窗口没有它被调用的证据。本轮没有读取或输出私有手势配置，也没有触发输入。

**原因边界更新：** 现已将“为什么没有自动输入”收敛到前置条件：预期手势Activity未出现/未被runner的精确Activity门禁观察到，故认证入口没有触发；不能归因于入口脚本输入错误。至于为什么应用启动后没有手势页，唤醒但未解锁、应用路由或内存登录态未就绪都仍需区分。当前Termux用户上下文的只读`dumpsys window policy`返回`Can't find service: window`，没有取得Keyguard快照；它不代表当时状态。后续优先取得安装后的精确runner源或一次有界运行时门禁快照，再决定是否修改唤醒/解锁/页面就绪主路径；不重放业务，不改密码或手势，不放宽Activity匹配条件。

### 安装版 APK 清单与 DEX 载荷核查｜2026-11-02 19:26 CST

对本机从 Pixel 只读取得的科技个险 18.5 安装包副本作定向静态核验（SHA-256 `169e727670d045afcf34e31a84547144fc091f9eff8e1792abd0897453b746e7`）：AndroidManifest 声明 `com.cpic.kjgxplus.nativePlug.login.GestureActivity`，但 Application 指向 `com.secneo.apkwrapper.AW`。普通 `classes.dex` 的结构头仅含7个类定义，全部属于 `com.secneo.apkwrapper`；`GestureActivity` 不在标准 type/class-definition 表，也不属于可由 JADX/apkanalyzer 直接反编译的类。该名称的字符串出现在 DEX 声明数据区之外的尾部载荷；APK同时包含 `libDexHelper.so` 与包装器资源。包装器 `AW.onCreate()` 会委托到真实 Application 并调用 native bootstrap。这说明“反编译器找不到该类”来自受保护包装/载荷结构，不能作为 Activity 已从 APK 移除的证据；其实现细节仍无法从普通 DEX 静态读取。

清单中的 `GestureActivity` 条目没有 `showWhenLocked` 或 `turnScreenOn` 属性。由于页面实现位于受保护载荷，静态检查无法判断运行时代码是否设置相同窗口行为，故不能据此认定 Keyguard 导致页面未出现。Pixel 当前只读回报仍为 Pixel 3a / Android 15 / API 35，`pixel-auth-start` SHA-256 `8f228b7ef49e36cc384880de9d6d753d1bec9486827d1a67e331297e16bb1eb4`、mtime 10月30日13:22，与此前已核验基线一致；目标应用当前已停止。这些当前快照不回溯11月2日运行状态。

**归因更新：** 11月2日的已证直接停止点仍是森林登录态单次门禁未通过；runner等待的手势 Activity 没有出现在完整补跑窗口的系统 Activity 记录中，requests 未增加，且没有已知认证工作器输入审计。因此此次失败发生在密码/手势脚本被派发之前，现有证据不支持把该脚本判为本次故障原因。为什么应用冷启动后没有进入该 Activity，仍受保护代码、缺少历史 Keyguard/屏幕/路由分项快照及未取得安装后 live v0.19 `run.py` 限制，当前不能定为“解锁手势脚本故障”或“Keyguard故障”。本次只读静态核查，没有启动应用、触发输入、安装候选或重跑业务。
