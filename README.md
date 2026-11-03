# 保险规划师自主工作系统

> **阳光森林最新只读快照｜2026-11-03 16:04 CST（设备读数截至15:58）:** MUSE于15:54:29回读唯一既有任务仍为`Asia/Shanghai`每日09:00、下次11月4日09:00；running/queued/in-flight为0/0/false，runner lock为FREE，无forest-agent进程。最近调度失败为11月3日09:11:17，最近成功为10月31日09:15:50，连续失败3次；本次状态请求没有重读业务结果。此前已核实的11月3日assistant/main在prepare超时、无业务阶段/回执、cleanup PASS仍有效，根因UNKNOWN。15:58:24经既有`pixel3a-kjgx`及原有`su`路径只读读到`sargo`、Android 15、boot完成、Dozing；monitor `watching`、guard清、heartbeat新鲜、requests=0，monitor/trigger/worker哈希分别为`2b611ca16f49523c74e544b96e19a7931db6af7d1ea4787ecea708b25e56241a`、`0243ee09abdbf07b162cc69c815ca69f00ad3519bda78df26d8588a5e9c0c499`、`f6fb7d23ebdb75183a62430d92aa7e161ff1ec7fc3db10f26ac857da8939000f`；monitor锁存在，blocked/stop不存在。设备操作锁和前台Activity本次为UNKNOWN；v0.19 APK pin上次直接读取于15:22，当时匹配，不声称15:58重新核验。未重跑业务、未写设备、未改state/cron/调度。官方规则仍仅有历史UI快照支持的日限额/计量单位；重置、重复周期、到账时延无官方原据。P4仍开放，S1未整体验收；P50/月度规划挂起。详情见[诊断检查点](planning/forest-prepare-diagnostics-2026-11-03.md)、[运行恢复说明](planning/forest-diagnostics-operations-2026-11-04.md)、[来源与扩展核查](planning/remaining-work-2026-10-29.md)。

> **iCloud MCP 项目归档（2026-11-02）：** 核心首尔 MCP 与现有 Agent 已进入可用阶段；Chat 和 Work Cloud 同一 Sites MCP 演示工具已分别验收，但 **ChatGPT 真实 iCloud 数据链路仍受 Site 源码工作区阻断，子项目暂缓**。完整部署、研究、验收、无效尝试及恢复条件见 [iCloud MCP 全阶段总归档](planning/icloud-mcp-master-handover-2026-11-02.md)，不要将 demo PASS 误称为生产 iCloud PASS。

> **阳光森林前一接续状态｜2026-11-03 15:43 CST：** MUSE 14:09 CST快照当时报告既有Asia/Shanghai每日09:00、下一次11月4日且无运行/排队/在途任务；15:37 CUA仅确认MUSE应用进程运行，未打开其界面，当前运行/排队/在途状态仍UNKNOWN。15:22是最近一次Pixel只读读数：经既有`pixel3a-kjgx`别名及原有`su`路径读到设备`sargo`/Android 15/boot完成、Dozing、Forest未在前台；monitor `watching`、guard清、heartbeat新鲜、requests=0，设备操作锁及stop/blocked标记不存在，monitor自身锁存在。live monitor SHA-256 `2b611ca1…`、trigger/worker未变，v0.19 SecureView APK SHA-256 `dbada93c…`仍匹配runner精确pin。输入审计12条、最后写于10月31日；`page_left`记录新鲜度未在该读数建立；固定窗口sidecar缺失属预期。因未能确认MUSE无并发，本轮未重连Pixel；prepare/login字段observer仍离线。静态源码核对显示公开策略仅含离线签到/领取，10月26日旧本地执行器不等于MUSE最近报告的live `run.py`；五项实现与回执边界见[本地证据核查](planning/local-evidence-audit-2026-10-29.md#日常五项实现与部署来源边界2026-11-03-1543-cst)。不重跑/改业务state、cron或调度。详见[诊断检查点](planning/forest-prepare-diagnostics-2026-11-03.md)、[运行恢复说明](planning/forest-diagnostics-operations-2026-11-04.md)和[新会话交接](planning/p4-next-session-handoff.md)。P4仍开放，S1未结项，P50/月度规划挂起。

> **阳光森林 11月3日自然运行与五段对照｜2026-11-03：** 09:00调度的助理与主流程均在prepare超时，五项未进入业务、cleanup报告PASS；另有08:57误触助理同样超时。MUSE只读对照还覆盖11月2日11:14手动v0.19两段：只有手动助理到达BridgeWeb并完成prepare，其余四段止于MainActivity；五段均无认证入口调用证据。MUSE报告五段共用同一live v0.19 runner/模块哈希，版本差异不足以解释结果；启动/设备/应用上下文差异仍未知。`user`/`empNoAES`/`operateFlag`、`gesturePage`/`accountMatch`历史分项均缺失，不支持归因为密码/手势脚本故障。脱敏ZIP已下载；本机重算外层SHA-256 `56e7280e…`及7个内部文件哈希全部通过。原始结果/prepare文件未包含，源文件完整SHA-256由MUSE提供、无法在本机对原字节重算。五段细节和哈希见[修复与补跑记录](planning/forest-prepare-repair-2026-11-02.md)。不连接Pixel、不重跑、不改state/cron/调度；每日任务仍按既有定义，P50/月度规划挂起。

> **此前v0.19登录派发源码核验｜2026-11-02：** MUSE只读取得安装后live v0.19 runner最小脱敏片段（live SHA-256 `de9bd83c…`；本机摘录SHA-256 `8cf4de84…`），确认启动顺序为写命令/使能标记→wake key→force-stop→启动；最多70秒轮询resumed Activity，只有精确`GestureActivity`出现才单次调用本地认证入口，没有解锁Keyguard步骤。因此11月2日已知入口未被调用，该次失败不支持归咎密码/手势输入动作；Keyguard、页面路由及登录字段状态仍未知。详细历史见[修复与补跑记录](planning/forest-prepare-repair-2026-11-02.md)。

> **Keyguard根因观测候选｜2026-11-02 21:52：** 离线审查发现既有诊断候选只记录屏幕亮灭，无法区分Keyguard是否显示/系统是否仍要求认证。已准备review-only v2，在同一监控采样点只读采集`isKeyguardLocked()`与`isDeviceLocked()`布尔值，API失败显式记录`READ_FAILED`，不改变现有派发门禁或`monitor-status.json`；脱敏采集器改用schema v2并拒绝旧版/不一致字段。Node语法、七个门禁及单次派发行为对比、采集器schema/敏感样例/上限验证、Python语法均通过。候选未部署，Android/AutoX实机兼容仍待验证；Pixel安装或监控重启需单独授权。两API语义见[Android KeyguardManager官方文档](https://developer.android.com/reference/android/app/KeyguardManager#isKeyguardLocked())和[Context.KEYGUARD_SERVICE](https://developer.android.com/reference/android/content/Context#KEYGUARD_SERVICE)。

> **离线诊断候选更新｜2026-11-02：** 森林登录态被动等待候选最多重采样8秒，只记录三个字段各自的存在性布尔值、采样时间和等待时长；保持原有状态门禁，不触发认证或业务动作。触发监控候选与部署源码完成8场景行为对比；助理入口候选保持固定方法指纹和唯一菜单门禁。三项候选的集成、合成验证及只读采集器端到端检查已完成，私有审阅包含回滚说明并已核验；均未部署。安装后live v0.19 runner的静态解析/Activity门禁已由脱敏源码片段确认；AutoX运行时兼容及诊断候选上线仍待验证，sidecar替换/重启另需授权。

> **助理入口诊断候选｜2026-11-02：** 另一项本地候选把 Vue 是否存在、`onClickApp` 方法是否存在、固定方法指纹是否匹配、目标菜单是否恰好一项分别写入脱敏结果，并记录采样时间；所有原有门禁仍需通过才可调用，不放宽指纹、不提前调用。合成检查及Python语法检查通过，未部署。当前已形成触发监控、森林登录态、助理入口三项离线诊断候选；森林准备字段已有静态透传证据，live runner门禁结构现已确认，但AutoX运行时兼容仍待补核；三项候选维持本机，不安装。

> **版本对齐更正｜2026-11-02：** 本机哈希复核发现最初森林登录态候选误沿用了v0.18 staging的促销模块索引2559；该候选未安装。现已从SHA-256与v0.19 APK内脚本一致的源码（`d7873632…`）重建，使用模块索引2561，并在合成测试中固定此索引后复测通过。live runner相关门禁结构已只读导出；候选依旧未安装，AutoX兼容仍未验收。

> **静态竞态依据｜2026-11-02：** 匹配v0.19适配器锁定的当前runtime bundle中，`__r(584).default`静态初始化含空的`user:{}`对象；这让“登录态检查过早”成为合理可能，但不能证明11月2日当时字段实际状态或认证器为何未派发。

> **解析兼容与只读采集复核｜2026-11-02：** 本机v0.17 runner导出与脱敏v0.19 fixture的透传检查已完成，且21:37取得安装后live v0.19 runner门禁/解析片段，确认其Activity、marker和状态分支结构；AutoX对扩展输出的运行时兼容仍未核实。触发候选的worker原因码使用固定白名单，未知值归为OTHER；原因码覆盖、敏感样例和生产者到采集器端到端合成检查通过。约18:30经现有SSH只读确认Pixel 3a / Android 15、AutoX主/脚本进程运行、monitor为watching、guardBlocked=false、requests=6；采集器返回NO_DIAGNOSTIC_FILE，部署版监控哈希与本机源码一致。未部署候选的elapsedMs已修正为监控进程启动后的单调时长，离线断言和集成检查通过；设备与调度未变。

> **当时的执行模式记录｜2026-10-30：** 本机主导开发、验证与证据判定；组件回执及成功空采集已在本机隔离接入，9项集成/29项回归/3组真实子进程恢复通过；MUSE有限安装证据已核对（16项），状态树43→43不变；本地认证已支持本人手势页自动输入；冷启动、再次重开、与显式入口重叠三项实机验证通过，每次仅输入一次；单实例锁/心跳正常，原凭据未改；刷新读数和组件基线仍待补证，真实业务正例未验收。MUSE保留既有每日执行及必要云端取证。需求目标不变，未迁移运行器/改调度。跨日已到自然次日，先读已有结果，不补跑；P50/月度规划继续挂起。[新方案与接续顺序](planning/execution-mode-2026-10-30.md)为当前入口，以下10月29日状态保留为历史。

> **本次会话收尾核对｜2026-10-30：** 唯一定时已启用，每日北京时间09:00，下一次10月31日09:00；本日双段已退出、锁空闲。自然主流程PASS、AI SENT/REVIEW，两段cleanup PASS；调度层failed单列，未配置失败重试。两份脱敏包11项哈希通过；本机只读组件实测返回RECORDS_NOT_UNIQUE并完成清理，未重放业务。客温客价独立回执、AI完成/奖励等仍缺。[当前恢复入口](planning/execution-mode-2026-10-30.md)以文末本次会话收尾为准。

> **后续修复与更正｜2026-10-30：** 已补取同轮signPhase回执，确认签到+0.5，主流程SKIP仅防重复；更正前份导出遗漏导致的解读。记录组件挂载时序已实机定位并修复，本机基线读取通过，MUSE有限安装及离线复测证据已核对；56项state和cron不变，今日AI SENT不重发。下一自然轮继续验收回答/奖励，传输根因尚不能凭诊断改动称已解决。详见[当前报告末节](planning/execution-mode-2026-10-30.md)。

> **其余项目推进｜2026-10-29：** 已恢复6份真实静态源码字节与指纹、完成五项扩展证据重核，广度根树已在原环境只读通过（120组件、无截断），三个新包29项清单独立核对；回执和组件provides候选已完成离线修正/反例验证，尚缺生产采集器与正例，未部署。跨日/月度规划/P50保持原暂停。以[最新推进与缺口](planning/remaining-work-2026-10-29.md)为当前入口，不以旧版“云端源码未取得”等叙述覆盖当前事实。

> **接续更新｜2026-10-29（恢复补核）：** 新增4项真实进程中断/重启恢复测试，与16项策略合计20项PASS；实际assistant.main的隔离SIGTERM/重启也通过，未重跑业务。八个MUSE调查包已核对；根入口/客户映射已读，修正根树探针因截断明确REVIEW，清理与本轮完整状态对账通过，AI/成功空列表回执仍待核实。用户要求跨日验证等待自然次日；月度规划/P50继续挂起。见[回执与恢复补核](planning/receipt-recovery-2026-10-29.md)。
**Autonomous Insurance Work System**

> 让 AI 主动发现值得做的工作，在明确授权下组织执行、验证成果和持续改进；同时与保险规划师共同探索客户经营方法和专业成长。

## 项目总览

项目覆盖客户经营、公司信息与机会、内部事务、自主运行与改进四个领域。长期目标是让 AI 在授权内主动发现、组织、执行和核验工作，并与用户共同改进经营方法；近期先从繁琐内部事务建立可靠减负能力。

阅读顺序：本页 → [整体审阅与内容地图](planning/project-review-2026-10-24.md) → [总体框架](docs/02-project-framework-v0.2.md) → [已确认决定](docs/03-confirmed-decisions.md) → [缺失与待验证内容](docs/04-open-questions.md)。需要落实时再进入 P4 交接和工作包。

## 当前状态｜2026-11-03

**P1—P3已完成，P4进行中，S1未整体验收。每日五项范围不变。10月31日记录确认签到SIGNED +0.5、时光轴VIEWED 6055ms、一键领取+6.5；智能助理SENT但答案与奖励未确认，客温客价无独立收据。11月1—3日五项均未执行/完成。11月3日MUSE只读对照覆盖三段当日运行和两段11月2日手动运行：五段模块门禁均报告为同一v0.19工件，只有11月2日手动助理段到达BridgeWeb；11月3日误触及调度轮都在MainActivity准备超时。脱敏ZIP外层和7个内部成员哈希已在本机验证；原始result/prepare文件未包含，源文件完整哈希由MUSE提供但无法本机对原字节复算。失败根因仍UNKNOWN，不归咎认证输入脚本。五段无业务动作，脱敏记录报告cleanup PASS；历史登录布尔值缺失。每日Asia/Shanghai 09:00定义未改；MUSE 14:09快照曾报告下一次为11月4日09:00，但当前调度未复读、状态仍UNKNOWN；不连接Pixel、不重跑、不改state/cron。P50/月度规划继续挂起，AI奖励、客温客价独立回执、完整恢复及扩展验收仍待补。**

**[本地成果与证据核查](planning/local-evidence-audit-2026-10-29.md)** · [成果哈希索引](planning/evidence-index-2026-10-29.json) · [五项扩展与规则来源核查](planning/remaining-work-2026-10-29.md) · [可公开策略、日志与离线运行说明](src/forest_policy/README.md) · [进度核对](planning/progress-reconciliation-2026-10-29.md)。五项扩展的流程/本人资格/奖励周期仍按证据分类；完整官方时点原依据尚未恢复。P50/月度规划继续挂起，保留原月初计划和2U＝2800目标。

S1 首个试点域是 **C：公司要求完成的细碎重复内部事务**；每日互动为首项切入。C 包含互动、培训、答题、特定活动、客户筛选报送、月度收入计划等，不限定为两个 APP 板块，也不表示所有任务同批实施。

已确认优先研究完全云端化，以日常只用 iPhone 为目标；条件不满足再评估 Pixel 独立执行。Android 注入是用户确认的必要技术前提；早期“具体方案未选”已由P4的Pixel注入/CDP有限实现推进；云端Android替代仍未完成兼容验收。旧项目经验不替代当前实现的证据。

## 阅读入口

| 用途 | 权威入口 |
| --- | --- |
| 当前阶段与下一步 | [P0—P4 路线图](planning/roadmap.md) |
| iCloud MCP 多 Agent 接入（2026-11-01） | **[已接入 Agent 与验收台账](planning/icloud-mcp-agent-connection-status-2026-11-01.md)** · [持续跟踪 Issue #6](https://github.com/gehbfarr5/insurance-autonomous-work-system/issues/6) |
| 新会话启动 | **[P4 交接 Prompt](planning/p4-next-session-handoff.md)** · [P4 Issue](https://github.com/gehbfarr5/insurance-autonomous-work-system/issues/3) |
| P3 已确认框架与递延项 | **[P3 结项与 P4 接续](planning/p3-framework-and-p4-transition.md)** |
| 项目目标与整体关系 | [愿景](docs/00-project-vision.md) · [原则](docs/01-philosophy-and-principles.md) · [总体框架 v0.2](docs/02-project-framework-v0.2.md) |
| 正式决定与当前缺口 | [D-001—D-030 决策日志](docs/03-confirmed-decisions.md) · [开放问题](docs/04-open-questions.md) |
| 人机职责、授权及验证 | [治理原则](docs/05-autonomy-governance.md) |
| P1 业务事实基线 | [四领域地图](planning/p1-business-map.md)，下接各领域事实记录 |
| P2 评估与试点选择 | [候选评估结项](planning/p2-s1-candidate-assessment.md) |
| 阶段完成与结构整理核对 | [P1—P3 同步与结构整理记录](planning/p1-p3-sync-and-structure-review.md) |
| 历史访谈与旧会话入口 | [资料索引](planning/phase-2-business-requirements.md) · [BR 历史归档](planning/archive/2026-10-business-interview-history.md) |

## 阶段与范围

- **P0—P4 是工作阶段：** 框架整理 → 业务调查 → 试点选择 → 方案框架 → 分批设计、实施与验证。P4 不必是最终阶段，不预设 P5 或固定终点。
- **S1—S3 是候选能力路线：** 可靠执行与减负 → 跨领域协同 → 深入经营协作与持续进化。进入 P4 不等于 S1 已实现。
- 四领域保留：A 客户经营、B 公司信息与机会、C 内部事务、D 自主运行与改进。P2 的四类候选与四领域不是同一套分类；没有决定四类候选同时实施。

## 已确认的协作方式

AI 主动提出月度经营计划，双方确认方向；在既定方向与授权内自主组织周度和日常行动，必要时提出月中策略复评。重要客户关系、面对面交流和重大业务判断由用户主导。

未来助手按约定周期主动处理获准任务，根据页面反馈行动；新任务符合既有规则即可自主处理，边界不明再交接。状态不明先核查，只在确认未成功且安全时重试；紧急异常及时通知，非紧急集中交接，正常完成不逐项打扰。

长期成效仍从经营成果、人工减负、客户关系服务质量、个人专业成长四维评价。操作、页面完成、有效结果、实际价值分别核实。

## 信息与授权边界

用户已确认当前项目讨论范围适用公司允许，所需资料可以交云端工具处理。具体访问、动作范围及实施授权在对应工作包行动前明确，进入 P4 不自动授权购买、部署、账号操作、对外联系或修改生产数据。

公开仓库只保存脱敏规划与方法；不得提交真实客户资料、公司内部原始材料、群消息原文、二维码、凭据、令牌或私人录音。示例须明确标为虚构。

## 文档维护

当前状态在本页和路线图维护；正式决定在决策日志；阶段成果在各阶段结项文件；历史记录保留其当时语境。旧文件路径继续有效，旧 Prompt 明示为历史入口，不作为待执行任务。结构整理不改变原有事实、分析状态或已确认结论。
