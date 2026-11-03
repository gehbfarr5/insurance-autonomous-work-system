# 11月2日准备阻断修复与单次补跑记录｜2026-11-02

## 2026-11-04 02:15—02:17 CST：修复路径比较与当前门禁

MUSE 02:15:02只读状态显示无活动/排队/在途Forest任务、runner lock `FREE`，既有09:00 Asia/Shanghai自然schedule待触发。Pixel在设备时钟02:17:22经现有alias以非root核对身份、启动和APK pin；已安装APK匹配v0.19。窄进程过滤无匹配，精确已记录设备操作锁marker缺失，但整体设备锁、monitor状态/hash及屏幕/Keyguard/Activity仍UNKNOWN。

修复方案取舍：直接绕过Activity/ready-marker/auth/method-pin门禁或加重试，会改变失败主路径且现有证据未解释底因，拒绝；复用已有field-presence与固定Activity类别离线候选，并等自然运行同轮证据，再按可观察失败修主路径，当前选择此方案。两份collector在MUSE所查workspace位置缺失，但本地private review包中的精确hash均已核对，manifest 14/14、11/11；其静态`su -c`路径与当前非root约束冲突，不能运行或用猜测路径替代。只在未来确认既有非root证据导出及runner/pin兼容后，才重新评估集成。保留09:00自然轮，不部署、不重放、不读取raw logs。证据键：`museReadonlyStatus20261104_021502`、`pixelReadonlyPreflight20261104_0217`、`pixelProcessFilter20261104_0217`、`pixelDeviceLockMarkerRead20261104_0217`、`localCollectorPackageReview20261104_0217`、`acceptanceGateStatus20261104_0217`。

## 2026-11-04 01:42—01:47 CST：再核运行状态；设备级修复门禁仍关闭

MUSE 01:42:49只读确认Forest当前无活动/排队/在途任务、runner lock `FREE`、无Forest进程，既有每日09:00 Asia/Shanghai schedule下次11月4日09:00，live runner/assistant hashes及最近运行记录未变。其后Pixel既有alias以非root仅确认UID 10249、Pixel 3a、Android 15和boot完成（设备时间01:44:06）；设备操作锁、monitor状态/hash及UI状态仍UNKNOWN。没有新证据可支持修改认证或就绪门禁。

决策保持：不绕过Activity/ready-marker门禁、不添加认证重试、不部署候选；保留自然09:00运行，结束后先读同轮脱敏MUSE结果。01:46:58 CPIC官方域定向搜索未找到直接规则原据，不能据此认定原据不存在。无root/`su`、业务state/raw logs读取、任务/代码执行、设备/调度/部署改动。证据键：`museReadonlyStatus20261104_014249`、`pixelReadonlyPreflight20261104_0144`、`officialWebsiteRuleSearch20261104_0146`。

## 2026-11-04 00:47—00:49 CST：复核当前门禁；不具备设备集成条件

00:47:37 CST MUSE只读回报Forest无活动任务、唯一Asia/Shanghai每日09:00 schedule下次11月4日09:00、running/queued/in-flight `0/0/false`、runner lock `FREE`、无Forest进程；live `run.py` / `assistant.py`哈希仍为`de9bd83cb8188151353c97d3e73071a50d2bfca8142d5a5774b00e94e3284562` / `7c6400b3900a2f4426ab2c3af4e4ebddfaacf5f82c4bf233ef24dc8b1c35121c`。最近调度失败11月3日09:11:17，最近成功10月31日09:15:50。

随后通过既有Pixel别名以非root完成限定身份/APK读取：Pixel 3a、Android 15、boot完成，SecureView APK SHA-256 `dbada93c1d0110fe86ef1c0cad77224e81c0f5939bd9462a3c0b9d5b72c48167`匹配v0.19 pin；本地时钟不晚于00:49:31，精确命令时间未捕获。该读取没有提供设备操作锁、monitor状态/hash、屏幕/Keyguard或前台Activity；它们继续UNKNOWN。未用root/su、运行代码/任务、读业务state/raw logs、安装/部署、写设备或更改schedule。

修复取舍维持既定结论：直接绕过Activity/就绪标记门禁或加认证重试会掩盖未明根因并改变生产路径；采用保留所有门禁、等待自然运行并先回收同轮脱敏证据的路径。现有候选仅离线审查，特权导出路径不可复用，未安装。11月3日三段仍只定位到prepare等待阶段，底因未知；本轮无新证据支持修改主路径。下一证据点为既有11月4日09:00自然运行，完成后先读同轮MUSE结果、stages、assistant状态和cleanup。P4开放，S1未验收。证据键：`museReadonlyStatus20261104_004737`、`pixelReadonlyPreflight20261104_0049`。

## 离线候选完整性复核｜2026-11-03 23:43—23:45 CST

11月4日逐字段和固定Activity类别两份候选的哈希清单分别14/14、11/11匹配；既有离线合成测试最终记录PASS；collector/joiner首次断言因期望结果漏列新增`fieldShapeStatus`而失败，修正断言后复跑PASS（无候选运行时异常）；本轮未重跑，亦不证明Android/AutoX兼容。导出器静态使用`su -c`，当前约束下不可用；Pixel操作锁与live monitor状态/hash仍UNKNOWN，候选未安装/重启。复用严格门禁与白名单投影、采用证据后修复、拒绝绕过；维持自然调度。详见[诊断检查点](forest-prepare-diagnostics-2026-11-03.md)及结构化键`offlineCandidateIntegrityReview20261103_234515`。

## 2026-11-03 23:38—23:42 CST：刷新并发状态并完成有界Pixel只读预检

23:38:55在既有Forest MUSE线程只读确认任务不活动，唯一Asia/Shanghai每日09:00 schedule下次11月4日09:00；running/queued/in-flight `0/0/false`、MUSE runner lock `FREE`、无Forest进程。live `run.py` / `assistant.py` SHA-256为`de9bd83cb8188151353c97d3e73071a50d2bfca8142d5a5774b00e94e3284562` / `7c6400b3900a2f4426ab2c3af4e4ebddfaacf5f82c4bf233ef24dc8b1c35121c`；最新调度失败仍为11月3日09:11:17，最近成功10月31日09:15:50。该读数仅覆盖scheduler/deployment元数据，不代表Pixel操作锁。

在该新鲜MUSE无在途读数后，经既有`pixel3a-kjgx`别名、非root UID 10249完成只读系统身份与APK核对（本机时钟括定于23:38:55—23:42:02）：Pixel 3a、Android 15、boot完成，SecureView已安装APK SHA-256 `dbada93c1d0110fe86ef1c0cad77224e81c0f5939bd9462a3c0b9d5b72c48167`，匹配已知v0.19 pin。设备操作锁、monitor私有状态/hash及屏幕/Keyguard/前台Activity仍UNKNOWN，没有精确、已验证的非root读取方法。未用root/su、未启动或停止应用、安装/部署、执行任务/业务代码、读取业务状态/日志、写设备或改变网络/凭据/调度。

继续保留11月4日既有自然运行，运行后先从MUSE取同轮脱敏prepare/结果/stages/助手派发/cleanup证据；不重放、不放宽门禁、不安装过期候选。日常五项回执与扩展分类维持既有状态；P4开放、S1未验收。证据键：`museReadonlyStatus20261103_233855`、`pixelReadonlyPreflight20261103_2342`。

## 最新只读状态复核｜2026-11-03 22:51—22:57 CST

Pixel 22:51:04经既有别名以UID 10249非root只读确认Pixel 3a/Android 15/boot完成、SecureView APK SHA匹配v0.19 pin。设备操作锁、monitor私有状态/hash、Keyguard和前台Activity仍UNKNOWN；没有使用root/su。MUSE 22:56:37在既有Forest线程确认无活动/排队/在途任务、runner lock FREE、无Forest进程；唯一Asia/Shanghai每日09:00任务下次11月4日，live哈希及最近调度结果不变。没有读业务状态、重试、源码执行、设备写入、部署或调度变化。11月3日prepare失败仍定位于Activity/标记等待超时层，底因UNKNOWN；不放宽门禁或重放，等待11月4日自然运行。证据键：`museReadonlyStatus20261103_225637`、`pixelReadonlyPreflight20261103_225104`。

## 最新只读状态复核｜2026-11-03 22:37—22:43 CST

MUSE 22:37:51确认Forest当时无活动/排队/在途任务，唯一Asia/Shanghai每日09:00任务下次11月4日09:00、runner lock FREE、无Forest进程，live哈希未变。22:43:04经既有Pixel别名以非root UID 10249只读确认Pixel 3a/Android 15/boot完成、SecureView APK SHA匹配v0.19 pin。设备操作锁、monitor私有状态/hash、Keyguard和前台Activity仍UNKNOWN；没有重用旧`su`读取路径，也没有写入、重试或部署。11月3日prepare失败层仍为Activity/标记等待超时，底因UNKNOWN。此记录不延伸11月2日已授权的一次补跑范围；等待11月4日既有自然运行。证据键：`museReadonlyStatus20261103_223751`、`pixelReadonlyPreflight20261103_224304`。

## 最新只读状态复核｜2026-11-03 21:45—21:47 CST

MUSE 21:45:36确认当时Forest无运行/排队/在途任务，唯一09:00 Asia/Shanghai任务下次11月4日09:00、runner lock FREE、进程未见，live runner/assistant哈希未变。约21:46 Pixel既有别名非root只读确认Android 15、boot完成、AutoX/AutoJS未见、v0.19 APK匹配；设备操作锁/monitor/Keyguard/Activity仍UNKNOWN。无root/su、写入或部署。11月3日prepare失败原因仍止于Activity/就绪标记轮询层，底层原因UNKNOWN；不重放，等待11月4日自然运行。


## 最新只读续记｜2026-11-03 21:30—21:35 CST

21:30:20 MUSE在既有Forest线程确认当时无运行/排队/在途任务，唯一每日Asia/Shanghai 09:00任务下次11月4日09:00，runner lock FREE，无Forest进程；live run.py/assistant.py哈希与既有值匹配。最近调度失败仍为11月3日09:11:17，最近成功为10月31日09:15:50。没有重读业务结果或原始日志。

约21:31本机经既有Pixel别名以非root只读确认Pixel 3a/Android 15/boot完成、无AutoX/AutoJS进程、SecureView APK hash匹配v0.19。设备操作锁、monitor状态/hash和屏幕/Keyguard/Activity仍UNKNOWN；没有root/su、安装、部署或写入。11月3日旧观察窗口过期，不部署该候选。11月3日prepare失败仍定位在Activity/就绪标记轮询层，标记未到达的底层原因UNKNOWN；11月4日自然结果待观察。P4开放、S1未验收。

## 当前只读续记｜2026-11-03 18:54—18:56 CST

MUSE 18:47:11确认Forest唯一每日Asia/Shanghai 09:00任务下次11月4日，running/queued/in-flight `0/0/false`、runner lock FREE、未见Forest进程；`assistant.py`为18:40集成版哈希。最近调度失败仍是11月3日09:11:17，最近成功10月31日09:15:50；本次没有重读业务阶段。18:48:55 Pixel经既有非root SSH别名只读确认Android 15、boot完成、AutoX进程未见，SecureView APK SHA与v0.19工件一致。设备操作锁、monitor私有状态/hash、显示/Keyguard/前台Activity均UNKNOWN；未用root/su、未写设备或运行任务。11月3日prepare超时根因仍UNKNOWN，不归因于输入或Keyguard；11月4日自然观察待完成。

18:54:37 MUSE只读刷新确认schedule、空闲状态、runner lock、live哈希及最近调度记录均与18:47一致；未读业务结果。18:55—18:56追加的官方规则来源检索均无直接命中；只记本次未找到，原始依据仍待恢复。Pixel值沿用18:48:55，设备操作锁仍UNKNOWN。prepare超时根因继续UNKNOWN。

## 2026-11-03 16:04 最新只读续记

MUSE 15:54:29回读既有每日09:00、下次11月4日09:00，running/queued/in-flight 0/0/false，runner lock FREE；最近失败11月3日09:11:17，前次成功10月31日09:15:50，连续失败3次。Pixel于15:58:24经既有别名只读回读monitor `watching`、guard清、requests=0，monitor锁在、blocked/stop不存在；设备操作锁与前台Activity UNKNOWN，APK pin最后于15:22直接确认匹配。没有设备写入或业务重跑。11月3日prepare超时根因仍UNKNOWN；下一步遵照[运行恢复说明](forest-diagnostics-operations-2026-11-04.md)等待既有自然窗口并只读收集，不能把本次健康监控读数当作故障定位结果。

## 2026-11-03 当前接续补记

15:22经现有Pixel别名及既有`su`路径只读确认，monitor-only诊断候选仍健康，SecureView v0.19 APK仍匹配runner pin；本次没有重跑、重启、写设备或改状态。15:37 CUA仅确认MUSE应用进程运行；当前任务/队列无可用只读连接器，且未打开界面。为避免并发，15:37未重连Pixel，15:22读数不是当前preflight。MUSE 14:09快照只证明当时队列为空；当前并发与调度仍UNKNOWN。11月4日自然窗口操作与停止/回滚说明见[有界诊断运行手册](forest-diagnostics-operations-2026-11-04.md)。

15:43静态核对还发现本机公开策略及10月26日旧执行器不是MUSE最近报告的live实现；hash/来源限制与逐项任务证据见[本地证据核查](local-evidence-audit-2026-10-29.md#日常五项实现与部署来源边界2026-11-03-1543-cst)。未修改旧本地runner，不用它替代当前MUSE代码，也未做设备访问或业务重放。

## 当前结论

- 11月2日自然轮在准备阶段阻断，五项均未进入业务。此前v0.18补跑仍以`PREPARE_TIMEOUT_NO_FALLBACK`结束、`NOT_SENT`、无stage/receipt，cleanup PASS。
- 用户随后明确授权：门禁全过后安装自制v0.19并从原入口补跑一次。MUSE于11:13:41完成即时门禁；只备份并替换本次范围的runner和模块APK，未改assistant.py、tasks.py、cron、调度或清除状态。安装后runner候选哈希、APK候选哈希和versionName 0.19.0均读回一致。
- 原入口仅运行一次，没有第二轮或重放。旧bundle准备超时已消除，但新暴露两个独立停止点：助理段准备成功并到达BridgeWebActivity，随后调用入口未唯一匹配，结果`REVIEW / ONCLICKAPP_OR_MENU_NOT_UNIQUE_NO_CALL / NOT_SENT`；主流程在登录态检查处`BLOCKED / PREPARE_LOGIN_STATE_MISSING`。两段均无业务回执，cleanup PASS，五项均未完成/未执行。
- 21:37 MUSE只读导出了安装后 live v0.19 `run.py` 最小脱敏片段，重算 SHA-256 `de9bd83cb8188151353c97d3e73071a50d2bfca8142d5a5774b00e94e3284562`，与11:13安装读回候选一致；来源不是v0.17副本或fixture。片段证实先写命令/使能标记，再发wake key、force-stop、启动应用；随后每秒检查resumed Activity、最长70秒，当Activity字符串包含`GestureActivity`且本轮尚未尝试时单次调用Pixel本地认证入口。11月2日窗口没有该Activity，故入口脚本未被派发；根因进一步收敛到Activity派发门禁，仍不能由历史证据确定未出现手势页的物理/应用原因。19:22本机取得的完整live runner原字节再次确认这是字符串包含判断，不是整串相等。
- 最终结束时runner.lock与设备操作锁均FREE，无相关进程。state主文件、cron定义和调度定义未变；assistant.json当日`lastError`随本次运行更新，`phase/questionStatus/startedAt`未变、没有`sentAt`。每日Asia/Shanghai 09:00调度未改，下一次为11月3日09:00。
- 本次结论是**v0.19安装与读回PASS、旧准备超时修复链路得到有限验证；每日业务执行仍未通过**。P4/S1不代表整体验收完成。跨日验证按用户要求等到真实次日；P50/月度规划继续挂起。

## 修复与运行证据

本机离线候选以当前运行bundle及首页模块结构为依据，复用应用原有弹窗关闭回调；未知弹窗保持阻断、不用坐标点击。APK按既有项目签名构建。包内哈希清单通过；MUSE从精确live runner源生成隔离候选，并验证三个v0.19标记、旧标记清零、仅预期改动及语法。模块补丁的本机v0.18 staging dry-run三文件通过；MUSE工作区没有模块源码树，因此不声称MUSE独立复核了该源码树。

签名证据保持边界：本机既有离线记录报告v2/v3签名验证通过；MUSE本地缺少对应验证工具，该环境内记UNKNOWN。安装后的证书身份与v0.18一致且设备读回APK哈希与候选一致；这不把MUSE端的独立v2/v3验证状态改写成PASS。

最终脱敏包：`sunshine-forest-20261102-v019-final-desensitized.zip`，SHA-256 `2e2abb95d64ced6fc4d16887fd7d8cc1ca3d03286c08e8600472c95ab3486579`。本机重算外层哈希一致，ZIP内5个成员的逐文件SHA-256均已核对。脱敏证据留在仓库外的本机私有目录；公开仓库不含原日志、截图、客户/账号资料、凭据或网络端点。

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

**结论（21:37更新）：** 直接阻断是森林内部三项登录态字段的合并门禁未通过；源码显示它只采样一次、不等待字段就绪。更新后的完整logcat显示runner唤醒并启动APP后没有进入`GestureActivity`；监控请求未增、输入审计无记录。随后取得并核对安装后live v0.19 runner原始源码片段（SHA-256 `de9bd83c…`），确认runner在resumed Activity字符串包含`GestureActivity`且尚未尝试时才调用认证入口；因此本次认证入口未派发，没有证据表明密码/手势输入器执行错误。仍缺screen/page/account/guard/episode逐项历史值，以及Keyguard和未出现手势页的底层原因。不要据此修改凭据、强制登出或重跑生产业务。11月3日取得的完整live runner字节确认此门禁是字符串包含条件。

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

截至18:10，本机MUSE run.py导出为v0.17（SHA-256 93151ce3…），与设备live v0.19哈希de9bd83c…不同；当时尚未取得live解析器源码。21:37补取的安装后live片段现已确认Activity门禁、nonce标记解码与分支处理；完整源码仍保存在MUSE侧，本机只留最小脱敏摘录。候选与测试留在仓库外本机私有目录，不公开源码或设备专属标识。18:10 Pixel只读采集器返回NO_DIAGNOSTIC_FILE，状态字段为guardBlocked=false、requests=6；本轮连接确认Pixel 3a / Android 15。手势触发候选独立写入只读sidecar，不依赖MUSE runner输出解析；但替换monitor.js需单独授权，且需先备份、校验哈希并准备回滚。森林登录态与助理入口候选新增runner结果字段，虽已核对live解析结构，AutoX对扩展结果的运行时兼容仍未验证。Mac界面仍锁定、浏览器禁用时未发送MUSE命令、未安装候选、未重启监控、未改变调度/state、未重跑业务；历史11月2日具体未通过门禁无法追补。

### Pixel 当前守护只读复核｜2026-11-02 17:37

通过既有SSH别名只读核对：设备为Pixel 3a / Android 15/API 35，AutoX应用进程与脚本进程均在；监控状态`watching`、guard未阻断、`requests=6`。输入审计仍为12条，文件更新时间为10月31日09:06:46。此快照说明监控此刻存活、已知工作器此后没有新输入审计；它不能补回11月2日当时未记录的门禁分项，也不代表手机登录或森林任务成功。

### 森林准备候选版本索引更正｜2026-11-02

二次逐文件哈希审查发现，最初的本机登录态候选曾从v0.18 staging资产拷贝，促销关闭模块索引为2559；v0.19安装包内同源脚本SHA-256为`d787363212189e495ce752b089195aad1505cd328e892cc85cd4a8e33bb29d08`，实际索引为2561。最初候选从未安装，因此未影响设备。现已从该精确v0.19资产重建被动等待候选，测试只提供2561并通过；若回退到2559，合成成功路径失败。该段记录时设备端AutoX运行时和live runner解析兼容仍未验证；21:37补取后live runner解析路径已静态核实，Pixel端运行兼容仍待实机验证。

与v0.19适配器指纹匹配的runtime bundle SHA-256为`ade689b53535d322de7c4d83d055f35be8de98f39f2886040d495f03d71b2c6f`；从该bundle静态提取的模块584导出`default.user`初始为空对象，且该初始化定义未包含`empNoAES`或`operateFlag`。因此登录字段异步填充前被单次快照读为空在技术上成立；这只是静态机制证据，不能回溯11月2日真实字段状态，也不能解释认证触发器未派发的具体门禁。

### 离线解析兼容与只读采集器｜2026-11-02

本机契约复核了已有MUSE v0.17脱敏run.py及脱敏v0.19 fixture：二者均对P4ForestAuto:后的完整JSON执行JSON解码，将完整对象赋给Device.preparation，并将其直接附加到最终结果；没有对白名单字段做裁剪。v0.18→v0.19补丁脚本仅有三项固定版本/错误码/资产名替换。新的本机契约测试覆盖嵌套loginState诊断字段透传，通过。

截至18:10的证据边界：v0.17源码SHA-256为93151ce3…；v0.19 fixture SHA-256为5028250d…，属于脱敏测试夹具且明确不可部署。21:37取得的live v0.19最小脱敏片段随后确认：runner从日志提取`P4ForestAuto:`后的JSON，按nonce匹配，将完整解析对象赋给`self.preparation`，并区分`BLOCKED`、`NAVIGATED`与70秒超时；因此live解析控制流已静态核实。尚未通过Pixel AutoX实机确认扩展诊断字段能由应用端输出并被整链采集器兼容。

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

为核实触发器的精确Activity匹配目标是否已从当前安装包移除，通过既有SSH只读读取设备安装APK到本机受控私有目录，并核对设备端/本机副本SHA-256相同。离线清单解析确认当前安装包声明了监控器匹配的手势页Activity；此前10月30日三项Pixel验证记录也观察到相同Activity，且设备报告该应用上次更新为10月22日。因此“匹配的Activity类已从当前安装包消失”不符合现有证据。APK仅留在仓库外本机私有目录，没有上传。

这仍不能证明11月2日窗口实际到达该Activity。当前重新读取的完整系统缓冲覆盖补跑开始至失败记录，未出现该Activity；但预检查的屏幕/目标页/本人标记/guard/复核/episode历史布尔值没有保存，且系统Activity日志不能排除没有Activity切换的短暂UI覆盖层。精确派发门禁仍未知，不据此修改识别逻辑或重放业务。

### 补跑唤醒与认证触发链根因细化｜2026-11-02 19:00

对当前Pixel系统缓冲和本机runner来源作关联核对：11:15:29.703系统记录设备从`Dozing`唤醒，原因`WAKE_REASON_WAKE_KEY`、细节`android.policy:KEY`；目标应用首次出现于11:15:29.825，Splash于11:15:30.334启动。此前0条目标应用记录。Android官方定义`KEYCODE_WAKEUP=224`，可唤醒设备；`WAKE_REASON_WAKE_KEY`是非电源键的唤醒键事件；Dozing状态下`PowerManager.isInteractive()`为false。[KeyEvent官方文档](https://developer.android.com/reference/android/view/KeyEvent#KEYCODE_WAKEUP) [AOSP唤醒原因定义](https://android.googlesource.com/platform/frameworks/base/+/ee50d90e9d41c877bed65fdfd39240c8693f57b4/core/java/android/os/PowerManager.java#616) [PowerManager.isInteractive](https://developer.android.com/reference/android/os/PowerManager#isInteractive())

本机MUSE v0.17脱敏源码（SHA-256 `93151ce3…`）及v0.19脱敏fixture（SHA-256 `5028250d…`）都含启动顺序`input keyevent 224; am force-stop; monkey launch`，并各含两处force-stop。Android官方将224定义为唤醒键；该命令与系统唤醒时间及随后Splash启动高度吻合，强烈支持runner发出唤醒键后启动了APP。因精确live v0.19 `run.py`尚未导出，这条关联仍标记为高置信推断，不声称已直接核验live命令。脱敏fixture及原始日志仅保留在本机私有目录，不进入公开仓库。

已部署`monitor.js`哈希与本机受控源码一致；它只在`device.isScreenOn()`、目标包和精确`GestureActivity`同时满足时派发，源码没有唤醒调用。当前Pixel缓冲完整覆盖补跑窗口却没有`GestureActivity`，监控计数未增且没有认证输入审计。因此**直接故障不是手势输入器输入错误：输入器没有收到请求**。最有力的运行时解释是runner唤醒并冷启动APP后，APP只到Splash/Main/BridgeWeb，没有进入应用手势页，监控页门禁未通过；无法由现有数据区分当时的screenOn、本人标记、guard或episode值。

另一个与`LOGIN_STATE_MISSING`相符的机制是冷启动后内存登录对象为空：精确bundle的模块584以`user={}`初始化，已发现的`loginEmp`赋值在登录响应分支；截至19:00取得的v0.17源码及v0.19 fixture含`am force-stop`。21:37取得的live v0.19源码片段确认运行前确有该force-stop，因此它可能清空应用进程内用户对象，而本轮没有新的登录响应填充它。仍没有11月2日三个字段的运行时快照，不能证明force-stop就是唯一原因。

**收尾诊断状态（21:37）：** 11月2日无派发、无输入、登录态一次性检查失败已由日志、哈希匹配源码和运行记录交叉确认；live v0.19片段确认runner先wake key、再force-stop并启动，runner源码的Activity字符串包含`GestureActivity`且本轮尚未尝试时才调用认证入口。故认证器脚本并非本次已证故障点。剩余未知是唤醒后Keyguard、页面路由和三个登录字段当时状态，无法把“Keyguard挡住”或“登录响应未就绪”定为根因。无需为了证明旧输入器而重放业务。后续如要定位当前门禁，先取得有界脱敏观测；安装sidecar/重启监控仍需单独授权。

### runner派发门禁与Pixel登录入口基线复核｜2026-11-02 19:10

重新盘点本机私有 MUSE 导出：其中脱敏 `run.py` SHA-256 为 `93151ce3…`、文件时间为10:14:55，来源清单对应安装前 v0.17（原始文件哈希 `061f1878…`）；不是11:13后安装的 v0.19 live runner。v0.18红acted候选与v0.19 fixture均为301行，逐行差异只有三个模块版本/文件标记。v0.19转换脚本锁定安装前 live v0.18 runner 哈希`d63fbabe…`并仅做这三个替换；补跑证据记录安装后读取哈希`de9bd83c…`与候选相同。精确的安装后源文件仍未保存在本机，不能把脱敏fixture冒充live源码。

不过，锁定版本的脱敏runner fixture把登录入口门禁写得很明确：准备时执行`input keyevent 224; am force-stop; monkey -p …`，随后最长70秒轮询前台Activity；当Activity字符串包含`GestureActivity`且此前尚未尝试时，才调用一次`auth_start()`。19:22取得的精确live runner后续确认其实际条件是字符串包含判断，而不是整串相等；`auth_start()`调用Pixel本地认证入口。v0.17源码、v0.18脱敏候选、v0.19 fixture描述的这段触发意图相同；v0.19补丁自身也只改版本标记。因而11月2日完整系统日志里的Splash/Main/BridgeWeb序列、无`GestureActivity`，再结合requests不增和无输入审计，强烈支持runner没有越过手势页门禁、密码/手势入口脚本未被调用。该段是11月2日历史结论；当前live runner哈希匹配与本机旧副本差异见[本地核查](local-evidence-audit-2026-10-29.md#精确live-runner源码及本地旧副本对照2026-11-03-1922-cst)。

只读SSH还确认Pixel上的`pixel-auth-start`当前哈希`8f228b7e…`、设备文件时间10月30日13:22，与本机已验证的10月30日组件生命周期修复版本哈希一致；它不是11月2日新改的脚本。该入口采用锁、在途检查和已有成功状态合并，历史测试覆盖并发去重；11月2日窗口没有它被调用的证据。本轮没有读取或输出私有手势配置，也没有触发输入。

**原因边界更新：** 现已将“为什么没有自动输入”收敛到前置条件：预期手势Activity未出现/未被runner源码中的字符串包含条件观察到，故认证入口没有触发；不能归因于入口脚本输入错误。至于为什么应用启动后没有手势页，唤醒但未解锁、应用路由或内存登录态未就绪都仍需区分。当前Termux用户上下文的只读`dumpsys window policy`返回`Can't find service: window`，没有取得Keyguard快照；它不代表当时状态。后续优先取得安装后的精确runner源或一次有界运行时门禁快照，再决定是否修改唤醒/解锁/页面就绪主路径；不重放业务，不改密码或手势，不放宽Activity匹配条件。

### 安装版 APK 清单与 DEX 载荷核查｜2026-11-02 19:26 CST

对本机从 Pixel 只读取得的科技个险 18.5 安装包副本作定向静态核验（SHA-256 `169e727670d045afcf34e31a84547144fc091f9eff8e1792abd0897453b746e7`）：AndroidManifest 声明 `com.cpic.kjgxplus.nativePlug.login.GestureActivity`，但 Application 指向 `com.secneo.apkwrapper.AW`。普通 `classes.dex` 的结构头仅含7个类定义，全部属于 `com.secneo.apkwrapper`；`GestureActivity` 不在标准 type/class-definition 表，也不属于可由 JADX/apkanalyzer 直接反编译的类。该名称的字符串出现在 DEX 声明数据区之外的尾部载荷；APK同时包含 `libDexHelper.so` 与包装器资源。包装器 `AW.onCreate()` 会委托到真实 Application 并调用 native bootstrap。这说明“反编译器找不到该类”来自受保护包装/载荷结构，不能作为 Activity 已从 APK 移除的证据；其实现细节仍无法从普通 DEX 静态读取。

清单中的 `GestureActivity` 条目没有 `showWhenLocked` 或 `turnScreenOn` 属性。由于页面实现位于受保护载荷，静态检查无法判断运行时代码是否设置相同窗口行为，故不能据此认定 Keyguard 导致页面未出现。Pixel 当前只读回报仍为 Pixel 3a / Android 15 / API 35，`pixel-auth-start` SHA-256 `8f228b7ef49e36cc384880de9d6d753d1bec9486827d1a67e331297e16bb1eb4`、mtime 10月30日13:22，与此前已核验基线一致；目标应用当前已停止。这些当前快照不回溯11月2日运行状态。

**归因更新（截至19:26）：** 11月2日的已证直接停止点仍是森林登录态单次门禁未通过；runner等待的手势 Activity 没有出现在完整补跑窗口的系统 Activity 记录中，requests 未增加，且没有已知认证工作器输入审计。因此此次失败发生在密码/手势脚本被派发之前，现有证据不支持把该脚本判为本次故障原因。该时点尚未取得安装后 live runner片段。21:37补取后已直接核实其门禁调用顺序，但仍缺历史Keyguard/屏幕/路由及登录字段分项快照，不能定为“解锁手势脚本故障”或“Keyguard故障”。该时点的检查未启动应用、未触发输入、未安装候选或重跑业务。

### 既有自动输入实机正例回查｜2026-11-02

为区分“输入器能否在登录页出现时自动处理”与“11月2日为何没触发”，回查了本机受控结果和已公开的工具验收记录。私有 `authorized-login-retry-result.json`（SHA-256 `15d86cae5021edd7a9e30279abc75dd0bdcdd6ba6aeeba587d8a4d9cebabe9a7`）记录 10月30日08:06:26观察到登录成功；`existingCredentialMatched=true`、`credentialChanged=false`、`businessDispatched=false`。此外，[登录工具验收记录](../tools/pixel-auth/README.md)记载09:19—09:20实机验证冷启动、再次重开、自动检测与显式入口重叠三种情形，均只输入一次并稳定进入登录后主页；其中冷启动与再次重开由自动检测触发，重叠场景同时包含自动检测和显式入口，用于验证共享锁只输入一次。以上证明10月30日当时部署版本在精确本人手势页条件下具备自动处理能力，但不证明任意密码弹窗/任意页面都能触发。

与11月2日对照：11月2日完整系统Activity记录没有出现目标手势页，监控请求数未增，认证工作器没有派发证据；因此10月30日正例不能替代11月2日的触发链，也不能把11月2日结果归为输入器回归。当前Pixel入口哈希仍匹配10月30日已核验版本。准确结论是：**自动输入在既有三种实机路径上验证通过；11月2日故障发生在认证派发之前；冷启动后为何未进入手势页仍未定因。**

### UsageStats 独立交叉核验｜2026-11-02 19:34

再次通过既有SSH别名只读查询 Pixel `dumpsys usagestats`，设备端过滤后仅保留11月2日11:14—11:17屏幕交互事件和目标包Activity类型/类别。记录显示11:15:29 `SCREEN_INTERACTIVE`，随后11:15:31恢复Splash、11:15:32恢复Main、11:15:41恢复BridgeWeb；11:17:25再次恢复Splash、11:17:26恢复Main，11:17:50 Main停止。筛选窗口中的目标Activity序列仍没有 `GestureActivity`。这与logcat保留的启动路径独立吻合，并确认屏幕在该时段已进入交互态；**交互态不等于Keyguard已隐藏**。

筛选窗口没有保留 `KEYGUARD_SHOWN` / `KEYGUARD_HIDDEN` UsageStats 事件。此缺席不是解锁证明，不能据此排除Keyguard。故能进一步确认的是“屏幕交互后应用恢复到Main/Bridge，仍未到认证页”；不能确认当时是否已解锁，也不能将Keyguard定为原因。仅将过滤摘要保存在仓库外本机私有目录，不导出其他应用UsageStats记录。

### 安装后 live v0.19 runner 源码门禁核验｜2026-11-02 21:37

按用户此前授权，对MUSE「阳光森林每日执行部署」旁聊发起只读补取：不访问Pixel、不运行代码或业务、不改live文件/state/cron/调度。MUSE确认本次片段直接取自安装后live `run.py` 原始字节；本轮SHA-256为`de9bd83cb8188151353c97d3e73071a50d2bfca8142d5a5774b00e94e3284562`，与11:13安装时读回的隔离候选完全一致，并由源码的0.19.0版本门禁交叉核对。它不是安装前v0.17脱敏副本，也不是v0.19 fixture。

脱敏摘录保存在本机仓库外的本机私有目录，文件名`sunshine-forest-20261102-v019-runner-prepare-snippets.txt`，SHA-256 `8cf4de8422a7203eae33308ed31c2aa15591ec22fb5816e87de4148c45cdc910`，5918字节；未将该文件或完整源码上传公开仓库。摘录保留的live源码控制流确认：

- runner先写本轮命令和使能标记，再发`KEYCODE_WAKEUP`（224），随后force-stop并启动目标应用；该启动段没有解锁/隐藏Keyguard步骤。
- runner每秒读取该应用当前resumed Activity，最长等待70秒；Activity字符串包含`GestureActivity`且本轮尚未尝试时，才单次调用`pixel-auth-start`，超时90秒，无重试/猜测。若始终只观察到Main/Bridge等页面，密码/手势入口不会被调用。
- 11月2日完整系统日志/UsageStats未见`GestureActivity`，监控派发计数未增、AutoX输入审计无本轮记录；这与live runner门禁相互印证，确认本次密码/手势入口未收到调用。10月30日入口自动检测正例仍有效，但不替代此次触发链。
- 森林模块另在一次登录态快照中检查`user`、`empNoAES`、`operateFlag`；三项任一不满足即终局`LOGIN_STATE_MISSING`，没有等待登录响应的分支。历史结果没有三项逐项布尔值，也没有Keyguard状态，故不能判定当时是锁屏、登录响应未到、路由或其他应用态问题。

**更新后的归因：** 已证直接原因是runner的Activity字符串包含条件未满足，认证入口因此未派发；没有证据指向密码/手势输入动作错误。唤醒键只证明发起唤醒，不能证明设备已解锁；“Keyguard挡住登录页”仍是待证假设。下一步先只读核实后续运行所需的screen/Keyguard/resumed-Activity/派发阶段快照，再决定是否需要改runner唤醒与登录就绪主路径。现有部署和每日调度保持不变，不为诊断重放业务；任何新安装或监控重启仍需相应授权。

### Keyguard只读观测候选v2｜2026-11-02 21:52

离线复核发现此前sidecar候选只记录`screenOn`，不足以判断“设备仍锁定”这一假设。比较了两条可观测路径：独立shell快照的改动少，但既有`dumpsys window policy`在Termux上下文不可用，也不能与监控每次派发门禁时间对齐；在现有monitor循环中只读采集Android系统Keyguard状态，可将数据与同一时间的屏幕/前台Activity/账号标记/guard/episode门禁对应。选择第二条，仅作为未部署诊断候选。

Android官方API语义不同：`KeyguardManager.isKeyguardLocked()`报告锁屏界面逻辑上是否显示；屏幕熄灭时也可能为true，而且不能单独证明需要认证。`isDeviceLocked()`则报告当前用户的应用是否仍需要锁屏认证。[isKeyguardLocked官方文档](https://developer.android.com/reference/android/app/KeyguardManager#isKeyguardLocked()) [isDeviceLocked官方文档](https://developer.android.com/reference/android/app/KeyguardManager#isDeviceLocked()) `Context.KEYGUARD_SERVICE`提供该管理器。[Context API](https://developer.android.com/reference/android/content/Context#KEYGUARD_SERVICE)

候选v2在既有监控采样点采集`keyguardShowing`、`deviceLocked`及固定`keyguardReadStatus`（`OK`、`SERVICE_MISSING`或`READ_FAILED`）；没有系统解锁、Keyguard dismiss、点击、输入、业务或状态清理动作。既有screen/app/GestureActivity/account/guard/recheck/episode派发门禁、调用顺序及`monitor-status.json`保持不变。v2使用新文件名和schema，避免旧v1侧车被误当成新格式；采集器只接受固定字段、固定状态码、最多128条记录并fail-closed，不输出marker值或原始异常。

离线检查：`node --check`、Node门禁集成（七类阻断、单次派发、基线状态模式不变、Keyguard读取失败时明确报状态且原门禁仍按原样运行、脱敏与128事件上限）通过；Python采集器合成校验与语法通过，包含v1拒绝、Keyguard状态一致性、未知字段/原因码和敏感样例反例。首次Node集成测试发现测试夹具重复定义`getSystemService`导致window stub覆盖keyguard stub；修正mock后所有检查重跑通过，此为测试夹具问题，不是候选设备运行失败。

review-only归档`auth-diagnostic-review-only-keyguard-v2.zip` SHA-256 `07008d505a301bcc5f044c69bb43abadfde33444df6ca3e50ea96778e6c838f9`，ZIP完整性及内部清单核对通过；其中候选`monitor-diagnostics-candidate.js` SHA-256 `c34801dcf6d06d3a48395e0ec927c83fd31e9c26a4595218f3357f7e2ca1d1bb`，只读采集器SHA-256 `acb97ff752a4b5c066ea47292ea1141632191f25a54ccf0f7a7b670e90f5d8e1`。包仅含候选、严格只读采集器、测试和说明，保存在仓库外本机私有目录。**尚未在Android/AutoX实机运行，未安装到Pixel，未重启monitor或触发应用/业务。** 现有MUSE只读导出记录每日任务`Asia/Shanghai 09:00`、下一次`2026-11-03 09:00 CST`、导出时`running_runs=0`；不改该任务。部署前需单独设备写操作授权、备份、核对实时monitor哈希并准备回滚；授权后只用于下一次自然运行取证，不重放11月2日业务。

21:54经既有SSH别名再次只读复核当前设备为Pixel 3a / Android 15；当前`monitor.js` SHA-256仍为基线`238d86a8ec06c5a92579ea54377956f282cbed824c32b2c56823a2924cb906fd`，状态`watching`、`guardBlocked=false`、`requests=6`；设备上不存在v2诊断文件。此快照只确认当前候选仍未部署且monitor当前健康，不回溯11月2日Keyguard/登录态，也不证明下一轮结果。

### 部署入口只读复核｜2026-11-02 21:57

经既有SSH别名只读核对，Pixel的`pixel-auth-monitor-start` SHA-256为`6dd8179d89ccc76b6d6e5b2ab87b554df51764b01c186658444183a56c206c3f`，与本机受控副本一致；入口返回`MONITOR_LOCK_AND_HEARTBEAT_CONFIRMED`。该入口用于健康确认或启动，不会在监控已健康时自动重启；其启动路径会读取并恢复AutoX Activity原组件状态。当前确认了受控入口和健康基线，但尚未执行候选安装/重启，也未实测回退过程。

若后续获准部署，须先备份并核对live `monitor.js`，通过现有`stop`标记等待旧监控释放锁，再替换为Keyguard候选、移除停止标记并调用既有启动入口；启动后核对候选哈希、watching状态及新鲜心跳。任何哈希或健康检查失败都恢复原文件并停止。此流程仍需在设备写入前完成明确的回退门禁；不启动应用登录、不输入手势、不触发业务、不改state/cron/09:00调度。

### 有界候选更正｜2026-11-02 22:06

部署前复核发现上版v2候选不应安装：持续相同门禁下可能每5秒重写整份sidecar，且诊断写失败会抛出主循环，存在影响原监控的风险。v2此前未部署。现改为一次性v3候选，仅在下一自然任务窗口`2026-11-03 08:55–09:55 Asia/Shanghai`采集；Pixel时区/时钟于22:01只读核对为`Asia/Shanghai`，与Mac时钟相符。相同样本最多每30秒记录一次；写失败写固定failure标记并发Android错误日志，禁用后续诊断写入但保持原监控继续。原有触发/工作器门禁及`monitor-status.json`字段由本机合成测试与旧版逐场景比较覆盖。

v3私有review-only包SHA-256为`edb4e0425f6379fac41e53d45a781e028ca9597a6df8734ed9691bb5778ccc26`；候选monitor SHA-256为`40f1fd5ea62e726f351e3e0f3203e07777c9a34ce1b56898e1615344c76e17a7`，严格只读采集器SHA-256为`2f2e50fc869c4ee8ed3bb88ff1b649323bec671f0f3426cfee8e78bdb68565da`。Node语法及门禁集成、Python语法/采集器检查、远端收集shell选择逻辑测试、ZIP完整性及包内清单哈希均通过。诊断写失败时固定标记/Android日志为尽力报告；若无sidecar/标记，仍只能判为无诊断证据。v3仍未在Android/AutoX实机验证，未安装到Pixel；针对旧v2哈希的部署授权不得用于v3。部署v3需以新哈希重新明确授权，并先备份、核对、恢复路径；不补跑业务或改调度/state。

22:10再次只读核对Pixel：live monitor仍为原基线哈希`238d86a8…`，启动器哈希`6dd8179d…`，状态`watching`、`guardBlocked=false`、`requests=6`、心跳2秒、文件锁有效；无stop标记或设备操作锁。当前前台是Android Launcher而非目标应用手势页。v3未安装；本轮未写设备或触发认证派发。

### 登录态字段证据补核｜2026-11-02 22:20

确认现有Keyguard监控v3只能回答设备锁屏、目标应用/手势页和认证派发层状态，不能看到森林模块内部`user`、`empNoAES`、`operateFlag`各自是否存在。live v0.19 runner解析`P4ForestAuto:` JSON后直接保存完整对象`self.preparation=item`，无字段白名单丢弃扩展内容的分支；该最小脱敏片段哈希已在上文记录。

为避免把已有带8秒等待的修复候选误当成纯观察，另从与安装APK内一致的`forest-prepare.js`（SHA-256 `d787363212189e495ce752b089195aad1505cd328e892cc85cd4a8e33bb29d08`）建立一个本地只读字段观察草案，草案只输出三个布尔值和采样时间，不输出字段值、不加等待/重试、不改原促销或路由动作。草案SHA-256 `6923c360bbeb41468594e60e6e002f1bd7f8b65968adc85f0debdc2cd6f86bb3`；Node语法及与原版逐场景的分支、属性读取顺序和动作调用对照测试通过。它尚未整合进签名APK、未装机、未实跑。若Keyguard v3自然运行仍留下`LOGIN_STATE_MISSING`的具体字段不明，完整根因验收还需对该观察草案做APK级审查、集成与单独授权；当前v3部署授权不覆盖APK替换。

### 2026-11-03 五段运行只读对照｜MUSE脱敏包已下载并校验

本机 `.private` 归档未找到11月3日原始结果包；MUSE在既有「阳光森林每日执行部署」旁聊只读取出脱敏证据包，覆盖11月2日手动两段、11月3日08:57误触助理及09:00调度两段。MUSE声明未重新运行任何代码/任务、未访问设备、未写state/cron/调度。包名`sunshine-forest-five-segments-20261102-1103-desensitized-evidence.zip`，下载到本机`Downloads`；外层SHA-256 `56e7280ee48f41cbad2d74e10d4a61c3d051a2e7831074d35a9e1de18e2cbe02`，7,844字节、8成员。本机重算外层哈希完全一致；`SHA256SUMS.txt`列出的7个成员逐项重算全部通过，五个JSON均可解析。包不含完整源码、原始日志、截图、绝对路径、端点、设备用户信息、凭据、账号、客户内容、余额或奖励标识。原始`operation-owner.json`虽存在，但因含owner token而不导出、不提供哈希；因此运行归属文件内容未独立核验。

| 运行段 | 时间（Asia/Shanghai） | prepare事件（摘要） | 终态与阶段 | marker / cleanup |
| --- | --- | --- | --- | --- |
| 11-03误触助理 | 08:57:05→08:59:01 | 模块08:57:15；SplashActivity 08:57:37；MainActivity 08:57:51 | REVIEW / `PREPARE_TIMEOUT_NO_FALLBACK`；stages `[]` | 70秒截止无marker；cleanup PASS |
| 11-03调度助理 | 09:01:55→09:03:53 | 模块09:02:04；MainActivity 09:02:26 | REVIEW / `PREPARE_TIMEOUT_NO_FALLBACK`；stages `[]` | 无marker；cleanup PASS |
| 11-03调度主流程 | 09:04:16→09:06:17 | 模块09:04:26；MainActivity 09:04:47 | BLOCKED / `PREPARE_TIMEOUT_NO_FALLBACK`；结果无`stages`键 | 无marker；cleanup PASS |
| 11-02手动助理 | 11:14:53→11:16:27 | 模块11:15:05；MainActivity 11:15:31；BridgeWebActivity 11:15:40 | REVIEW / `ONCLICKAPP_OR_MENU_NOT_UNIQUE_NO_CALL`；`prepare_done` | NAVIGATED由prepare_done与代码路径推得，prepare-events本身无marker字段；cleanup PASS |
| 11-02手动主流程 | 11:16:47→11:17:57 | 模块11:16:59；MainActivity 11:17:26 | BLOCKED / `PREPARE_LOGIN_STATE_MISSING`；结果无`stages`键 | JS marker为`BLOCKED / LOGIN_STATE_MISSING`（runner加`PREPARE_`前缀）；cleanup PASS |

**本轮核对结论与证据边界：** 五段模块事件值均为v0.19工件哈希，版本门禁均通过。MUSE在脱敏包内提供的live文件重算值为：`run.py` `de9bd83cb8188151353c97d3e73071a50d2bfca8142d5a5774b00e94e3284562`、`assistant.py` `a3a7de236f8a3e3a4a29f73c55fce4161919d117e727ed550e46490c24260229`、v0.19工件`dbada93c1d0110fe86ef1c0cad77224e81c0f5939bd9462a3c0b9d5b72c48167`；调度定义`22658ddb697d94846e6b2f3c45339675acc4d353903626723dfa91d34fc0f7df`未变，下次仍报为11月4日09:00。MUSE ZIP外层和全部包内成员哈希在本机已验证；其中每段所列原始`result.json`和`prepare-events.json`不在ZIP内，故其完整SHA-256是MUSE提供的源文件指纹，本机无法对源文件字节重算。`operation-owner.json`因owner token扣留且未哈希。此前聊天摘要只显示结果哈希前16位，现以包内全长源指纹补齐。

| 运行段 | 原始`result.json` SHA-256（MUSE计算） | 原始`prepare-events.json` SHA-256（MUSE计算） |
| --- | --- | --- |
| 11-02手动助理 | `5bd900bf14bcd1c4aff401625584eb48a1d977e5f41721798b829aee9160d7da` | `465e0309c2f539d0f7a964434b97d1221fcb1da248b1ea21a42c164b7e330f38` |
| 11-02手动主流程 | `781c9953c2cd95156cacd08aee96906a9f2160e77d8552f74726a6736a2c26ee` | `0b294363a86a3b2aa743b8c8e02e5ea2f54509add1de56d88c96a7fefea037c3` |
| 11-03误触助理 | `dd1427dda04e225028f913f35dd787fa799b70ad3bf63f2a5fd0081c452700ae` | `562dcc515572986f6fe1500dbe6f96da288f432e5d82b2c49b5dfc488a0706e3` |
| 11-03调度助理 | `e44f5815ef7d77dbdcc00ef99c0b4118da49db8d13716d0a7fd0590e499dfbee` | `7c5ea5c493e5cc6361a9a5b7f6f28cd0ceb18bcd3d2517f8801c4f913999dd73` |
| 11-03调度主流程 | `beda704f11ab50e1e7434c18522a0290a2bf12726273d608c3871aa005ccafca` | `2cb2b8e5182f7cdf8e8944b4432cb923cd79f143b4718e9980acc329cade6177` |

脱敏包成员哈希清单也已在本机复核：`README.txt` `2673bbcb1246dd370aa8b712de85e7bab91c261ca951c2171252fa60645f2f12`；`segments/01-manual-assistant-1102.json` `7e27be8c3599faa0197c7580d2deb95181ef2dda5adb65891e14f3e9e5d68395`；`segments/02-manual-main-1102.json` `d6be87ed526769c2072c75c45e54dcb94c0e03042ac5bb4609a131a889ac769a`；`segments/03-accidental-assistant-1103.json` `fe2c6ec2cf89cd5e7b0dd406c0900b09f42e07be2175cd15f8af7127634a89dd`；`segments/04-scheduled-assistant-1103.json` `1a35bfb4bb0da9e459075a175384536ae1934a7f00eac2411d2d956528df0479`；`segments/05-scheduled-main-1103.json` `81bc6203034846f4adc2c722977b757f0905a01b7f6b87ada241be2a88ee04a4`；`state-snapshot.json` `4300b5947568e8b5e6180131f4ed32f1e25f69bfff627b40de01a48270119865`。

- 只有11月2日手动助理段到达BridgeWeb并完成prepare；其余四段止于MainActivity（11月3日误触还经过Splash）。因此同版号/工件版本并不能解释运行差异；本次对照仍不能区分启动模式、设备/应用状态或其他运行上下文原因，不把相关性写成根因。
- 五段prepare-events均无`login`类事件，没有实际`auth_start()`调用的留存证据。11月2日助理`control.login`只是路径标记，不能作为调用回执；11月3日两段未到手势页，登录入口脚本不在已观测执行路径内，现有材料不支持将今日prepare超时归因于密码/手势输入器。
- `vueCheck`仅在11月2日手动助理结果中存在：`onClickAppMatches=false`、目标菜单数量1；其他助理段均止于prepare，缺`vueCheck`。五段均缺`user`、`empNoAES`、`operateFlag`各自存在性布尔值与精确采样时间；`gesturePage`、`accountMatch`也缺失。11月3日与11月2日手动运行差异的原因和Pixel实时状态均为UNKNOWN。
- ZIP内五段结果均报告cleanup PASS；state快照的pending为空、防重历史11条（末条10月31日），assistant.json 11月2/3均为`INTENT / NOT_SENT`、无`sentAt`。11月3日`startedAt`为08:57误触段的时间，不是09:01调度助理段。包内JSON成员哈希已核；未包含源结果文件及operation-owner内容，故这些摘要字段虽有脱敏包承载，源文件身份仍仅由MUSE所列SHA-256锚定。

截至2026-11-03 15:40 CST，11月3日每日五项仍全部未执行/未完成，余额与待领未刷新；不把签到记为SKIP或奖励记为已确认。脱敏包已校验，README、路线图、进度、工作包、交接与开放问题已更新；文档和并发门禁已同步至[main提交 e3fffe7](https://github.com/gehbfarr5/insurance-autonomous-work-system/commit/e3fffe7)，Issue #3已追加[并发门禁说明](https://github.com/gehbfarr5/insurance-autonomous-work-system/issues/3#issuecomment-6598123313)。本次未连接Pixel、未重跑、未改state/cron/调度。P50/月度规划继续挂起。
