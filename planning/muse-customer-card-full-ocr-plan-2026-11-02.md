# 家庭卡 OCR → MUSE → iCloud 联系人：2026-11-02 修订实施基线

状态：本文是 2026-11-02 的历史实施基线；当前代码与运行状态以以下 2026-11-03 对账为准。

## 2026-11-03 当前状态对账

本节只更新执行证据，不改变下方已确认的业务规则。

GitHub 阶段与 release gate 跟踪：[Family Card OCR v1.0 Stable issue #18](https://github.com/gehbfarr5/insurance-autonomous-work-system/issues/18)。

- **WP8-B / WP9：** MUSE 历史阶段报告称首尔 OCR 路径、Token 管理、合成查重/联系人创建、回读、幂等及清理通过。本轮未重新执行这些阶段。
- **WP10：** MUSE 报告首张真实卡 OCR 成功，但自动解析为 `REVIEW_REQUIRED`；用户随后确认手工草稿并创建、回读一条真实联系人。这证明存在人工流程，不证明自动表格解析通过。
- **WP11：** 0.7.0–0.11.0 isolated replay 均为 `REVIEW_REQUIRED`。0.11.0 exact commit `180f6333046b830010d60338edb580b23c03927c` 的本地与 MUSE offline tests 均为 127/127；同一 89-block WP10 structured result 仍回放为 `REVIEW_REQUIRED`，原因码为 `table_layout_uncertain`、`main_customer_identity_unclear`、`mobile_missing`、`address_conflict`、`address_uncertain`，草稿映射被拒。MUSE 的 WP11-H same-input diagnosis 进一步确认姓名、手机号、显式生日及其他电话没有候选通过既有几何唯一性门禁；性别没有纯标签或可判定勾选信号。地址与身份证的既有诊断见 WP11-G/WP11-F；本次未读 reference，身份证精确匹配仍未知。现有证据不支持放宽字段几何门禁，未改解析器。详细脱敏结果见 [WP11-H 字段诊断](wp11h-field-diagnostic-20261103.md)。输入、payload、worktree 和生产源码状态未变。
- **MUSE source/deployment provenance：** WP11-O 只读静态审计为 `PARTIAL`。MUSE 报告的 0.5.0 package checkout 位于分支 `codex/wp7-muse-baidu-token-query-adapter-20261102`、提交 `8336008d080387ab709d1e0ab9381683b1138e0f`、工作树干净；active runtime binding 仍 UNKNOWN。active MUSE 包版本/hash/release digest、MUSE client/tool-server provenance、Seoul 部署版本/hash 和 OCR route 均 UNKNOWN。静态检查的 Seoul adapter、parser、duplicate、create、readback 文件均为 PRESENT_UNBOUND；字段级 review UI 和代码强制的创建前确认在被检查 source 中未找到，但不能据此断言 active runtime 缺少这些功能。日志隐私、查重 fail-closed、create retry/server idempotency、回滚等生产行为也未证实。审计读取 package metadata 3 次、Git provenance 12 次、source files 21 个、deployment metadata 2 次、process metadata 1 次；凭据、日志、生产执行、OCR、联系人、部署和导出为 0。机器结果见 [WP11-O](wp11o-muse-production-provenance-result-20261103.json)；此前 WP11-K 中对未跟踪 workspace 副本的发现也不代表部署行为，详见 [WP11-K](../integrations/muse-customer-card-ocr/TEST_REPORT.md#wp11-k-muse-package-and-deployment-provenance-clarification)。
- **操作员复核 UI：** 未跟踪 MUSE workspace 副本中没有字段级复核 UI，也没有把人工修改送入确认的代码路径；由于这些文件未映射到 active runtime，当前生产 UI 能力 UNKNOWN。
- **控制风险：** workspace 副本的静态代码显示姓名/手机号查重、一次 create 重试、逐字段 readback 等行为，但其来源和版本不绑定当前部署，不能当作 live runtime 事实。之前的客户端与工具 schema 审计中，`tools/list` 字段来自当时可见元数据，但无 outputSchema 或部署版本；服务端幂等、空字段语义、当前重试与回读行为均 UNKNOWN。候选本地代码要求 `READY`/`MANUALLY_REVIEWED` 与 `USER_CONFIRMED`，创建错误不重试，并以保护 journal 阻止盲目重开；这些仍是未部署候选证据。
- **验收门禁：** 30 卡集合少于 30、授权未确认、参考标注不完整；当前不得宣布 `v1.0 Stable`。本工作未部署候选；active runtime version/hash UNKNOWN。
- **WP11-I/J 恢复候选：** MUSE 只读 `tools/list` 确认 `contacts_delete.expected_etag` 为 optional，但 `contacts_read` 未声明 output schema，客户端没有 ETag/version 暴露路径，无法将删除条件绑定到新鲜读取；稳定 create ID、服务端幂等与部署 MCP provenance 仍 UNKNOWN。MUSE 报告 package source checkout 为 0.5.0 / commit `8336008d080387ab709d1e0ab9381683b1138e0f`；active runtime 未绑定此源码，实际版本 UNKNOWN，本工作未执行生产变更。未发布的本地 0.12.0 候选在受保护待处理账本保存“已知创建但尚未完成回读”的 opaque contact ID，并提供要求精确 operation ID 与重新确认草稿的 `--resume-pending` 只读回读路径；恢复中不会创建或删除。局部合成回归 18/18、完整本地离线套件 133/133 通过（Python 3.14.7 / Pillow 12.2.0）；MUSE 对精确提交 `ad13570da5794077ace40893d660c5e92b8ee5e0` 的独立离线复测也为 133/133（Python 3.12.3 / Pillow 10.2.0），使用新 detached worktree/venv。因目标对象初始不可用，MUSE 仅从授权目标分支 fetch 一次，验证 SHA 后停止网络；OCR、百度、登录、contacts、生产执行和部署均为 0。MUSE 随后在精确分支提交 `e9814eaee6b16d677ab06f0857fa2a5bd1f6a586` 上使用同一授权 WP10 结果回放，仍为 `REVIEW_REQUIRED`，仅身份证字段存在；未读 reference，身份证正确性未知，字段自动提取验收 FAIL。旧待处理记录缺 ID 时仍转人工核对。条件删除/回滚未实现或执行。当前候选状态为 `VALIDATION_PENDING`；不得部署或称为 `v1.0 Stable`。

### 接续实施顺序

1. **已完成：** 导入四文件 source-only 快照并核对哈希/公开仓库敏感信息；原始 MUSE 源码仍无可验证 Git provenance，快照不得当作生产 source of truth。
2. **已实现，尚未生产验收：** 两个 OCR 入口在本地候选中复用 Seoul response adapter，保留 `location`、`probability`、`chars`，对缺失/损坏响应 fail-closed；不增加第二套 OCR 模型。
3. **已完成 WP11-B 至 WP11-H 隔离验证：** 0.11.0 本地与 MUSE 离线套件 127/127；同一 WP10 结果仍 `REVIEW_REQUIRED`。姓名、手机号、生日、其他电话没有候选通过几何唯一性门禁；性别缺少独立可判定的勾选信号。地址字段没有提取，草稿映射被拒。不得放宽并列/重叠门槛、扩大任意跨行搜索、凭 ID 校验单独选值或推断空白框性别。
4. **已完成：** 读取同一 MUSE 旁聊中的 WP11-G 诊断及补充分类，没有重试、换数据或运行 OCR。确认救援已触发；输入中存在两个不同且都通过地址内容检查的候选，其中一个的列几何近似并列，不能安全归属到其他字段。保留 `REVIEW_REQUIRED` 是当前证据支持的结果，WP11-G 没有安全解析器改动。
5. **静态工作流快照审阅已完成，生产验收未完成：** MUSE 报告中审阅的 workflow/client 文件是未跟踪 workspace 副本，缺少部署来源绑定；其字段复核、`REVIEW_REQUIRED` 绕过、重试和 readback 结论不代表已验证 live runtime。当前 live UI/代码行为仍 UNKNOWN。
6. **生产接入前：** 取得可验证的 active runtime source-to-deployment provenance，确认 MUSE client/tool server ref/hash、Seoul 部署 hash、live `contacts_search/create/read` schema 及版本、服务端幂等、空字段语义，以及字段级修订/确认 UI。现有 MUSE workspace 文件与 public snapshot 不能作为部署 source of truth；不得覆盖未知来源。
7. **端到端安全验收：** 以隔离环境证明不确定结果不可绕过复核、查重失败不会变成空结果、写入前要求用户明确确认、写入不自动重试、回读逐字段一致、待处理写入可人工对账；所有成功/失败路径的值不得进入普通日志。
8. **数据验收继续门禁：** 30 卡集合少于 30、授权未确认、参考标注不完整；不得访问或处理新样本。现有标准库聚合器与输入模板（`integrations/muse-customer-card-ocr/src/muse_customer_card_ocr/acceptance_metrics.py`、`planning/wp11-30-card-acceptance-input-template-20261103.json`）只接收脱敏布尔值/枚举并输出汇总，要求至少 30 个预先确定的有效样本，逐项报告分母、失败原因和人工复核需求。MUSE 通过桌面旁聊在精确提交 `376e0d251db3d93e111c973b9f0957c52a356e96` 的隔离 worktree/venv 中独立运行完整离线套件 143/143 PASS，空模板 CLI 预期 `BLOCKED`；没有读取 30 卡库存、图片或 reference，也没有 OCR/联系人操作，详见[脱敏结果](wp11-30-card-muse-result-20261103.json)。MUSE 直接 MCP connector 不可用，但桌面旁聊可用于受控隔离复验。真实数据阶段仍未授权；准备的[可复制隔离测试任务](wp11-30-card-acceptance-task-20261103.md)要求在用户明确授权、集合不少于 30 张且参考标注完整前停止，不得读取库存。未来结果格式见[机器可读模板](wp11-30-card-muse-result-template-20261103.json)。不得把合成/离线测试当成准确率证据；聚合器不执行联系人操作，重复漏判、创建确认、覆盖/删除、回读及生产验收仍需独立验证。
9. **部署及回滚最后执行：** 仅在生产源 provenance、MUSE schema/UI、真实数据门槛和隔离端到端验收通过后，建立固定版本 pin，做生产部署与回滚演练，并核对生产版本/提交/哈希。MUSE 报告的 source checkout 为 0.5.0，但 active runtime version 未知；如 30 卡门槛未满足，最多报告 `VALIDATION_PENDING`，不得称为 `v1.0 Stable`。

**Reuse / adapt / avoid：** reuse 首尔 OCR、Baidu block schema、`OcrBlock` 几何解析器、本仓库 atomic-JSON journal、现有 confirmed-draft 校验和逐字段 readback verifier；adapt 四个 source-only runtime caller、严格查重与 create gate，以及 journal 对已知待回读 contact ID 的临时保存/恢复读取；avoid改走 MUSE 直连百度、添加第二套图像模型、发送未经 server/schema 确认的幂等字段，或在无法将 delete token 绑定到 fresh read 时实现删除回滚。当前分支修复不包含生产部署。

### WP11-L 多样性门禁补充（2026-11-03）

- 缺口：schema 1.0 只要求 30 个合格样本与三项研究声明，没有测量手写、清晰度、表格布局的样本多样性。
- 方案比较：全局操作员声明录入成本低，但不可从数据中复核；逐卡封闭类别码增加少量受保护输入，但能计算可审计的类别分布。选逐卡类别码；继续复用 Python 标准库聚合器和现有 unittest/CLI，不引入依赖。
- MVP：schema 1.1 加 `handwriting_code` H1–H5、`clarity_code` CLEAR/MODERATE/LOW、`table_layout_code` L1–L5；三个维度各至少两个类别。类别定义、映射和逐卡分配仅留在 MUSE 受保护工作区；被排除样本使用 `NOT_APPLICABLE` 且不计入多样性。只输出汇总类别计数和不同类别数。任何样本数或多样性门禁失败都会阻断 OCR 验收指标。
- 验证顺序：合成多样/同类输入的单元回归、完整离线套件、空模板 CLI，再在精确 pushed commit 上由 MUSE 隔离环境重复离线检查；不读取真实卡或标签。回滚路径为整体 revert schema、模板、测试和文档的同一提交；尚未创建或导出填充后的 1.1 数据。
- 本机验证已完成：11 个验收指标单测及 144/144 完整离线测试通过（Python 3.14.7 / Pillow 12.2.0），空模板返回预期 `BLOCKED`。MUSE 在精确提交 `1d6b8302eef102aa71f34a4b70f67f73b856eb5a` 的隔离 worktree/venv 上独立通过 144/144，空模板 CLI smoke PASS；真实数据/图片/reference、OCR/Baidu、iCloud/contact、生产、部署、raw export 均为 0，详见[schema 1.1 脱敏复验结果](wp11-30-card-muse-result-20261103-schema-1.1.json)。旧 143/143 结果只验证 schema 1.0。真实卡授权仍未确认，状态保持 `VALIDATION_PENDING`。

### WP11-M 当前候选 WP10 结构化结果复验（2026-11-03）

- **已核对 WP11-B：** MUSE 已在 0.7.0 / `29771eb33b07bd43150dec0a236c2711b290c165` 执行了真实模板隔离复验。结果 `FAIL`：决策 `REVIEW_REQUIRED`，姓名与 reviewed reference 不匹配，手机号/生日/身份证/性别不正确或缺失，草稿映射被拒；Python 3.12.3 / Pillow 10.2.0，90/90 离线测试通过，生产报告为 0.5.0 且未改变。当前 branch 的 `TEST_REPORT.md` 及 WP11-C–J 后续回放记录保留完整边界和原因码。
- **当前差距：** 最近一条 0.12.0 同输入回放为 `e9814eaee6b16d677ab06f0857fa2a5bd1f6a586`，仍 `REVIEW_REQUIRED`；缺少姓名/手机号等必需字段、地址冲突；身份证字段出现但没有 reviewed reference 核对，不能算准确。活动 MUSE 运行时与其 0.5.0 源 checkout 之间仍没有可验证的部署绑定。
- **WP11-M 当前候选精确复验（`6d5e7d4b8bbf29e8e5b4b1bc9bf43fa2d344cb6b`）：** MUSE 在隔离 Ubuntu 24.04.5/Python 3.12.3/Pillow 12.3.0 中通过 144/144 离线测试，并仅使用同一已授权 WP10 结构化结果重放当前 parser。结果为 `FAIL`：`REVIEW_REQUIRED`、草稿映射 `REJECTED`；主客户、姓名、手机、显式生日和性别缺失，身份证字段存在；原因码为 `table_layout_uncertain`、`main_customer_identity_unclear`、`mobile_missing`、`address_conflict`、`address_uncertain`。已审 reference 不可用，accuracy comparison `BLOCKED`，所有匹配均 `NOT_CHECKED`。生产包版本、运行时和部署绑定均 UNKNOWN。MUSE 报告没有新样本/图片、OCR/Baidu、iCloud/联系人、生产执行/写入、部署或 raw export。完整脱敏记录见[WP11-M 结果](wp11m-muse-current-candidate-result-20261103.json)。
- **方案与选择：** 仅依赖历史 sanitized 报告不会读取受保护数据，但不能验证当前 branch HEAD；在 MUSE 隔离环境中重放同一份此前已授权 WP10 OCR 结构化结果，能核实当前 parser，且无需新 OCR、不接触联系人。采用第二种。任务和机器结果模板为 [`WP11-M MUSE 当前候选复验`](wp11m-muse-current-candidate-retest-20261103.md) 与 [`结果模板`](wp11m-muse-current-candidate-result-template-20261103.json)。仅当结构化 result 缺失时才停止 parser replay；reference 缺失时仍报告 decision/field presence/reasons，但准确率对比标记 `BLOCKED`、所有字段匹配标记 `NOT_CHECKED`。不得从旧报告重建输入或 reference。
- **WP11-N 当前候选计数（`0c97938342d77ab23b5f061ad472529d3999918e`）：** MUSE 用相同 WP10 structured result（reference 未用）完成计数；纯字段标签分别为姓名1、手机1、身份证1、显式生日2、性别0、地址1、其他电话1。姓名一个 direct-right 候选、手机两个 next-row 候选、生日六个 next-row 候选和其他电话三个候选均无几何通过；地址四个候选中两个通过几何，但两个均未通过字段校验。性别有2个文本块、0个独立结构化 checked-state signal。身份证一个非邻接同排候选通过几何、字段校验和唯一归属门禁，但无 reference，准确性未知。所有字段 family-boundary exclusions 报告为0。总体仍 `REVIEW_REQUIRED`，草稿映射拒绝；这些计数不支持放宽 fail-closed 几何规则。MUSE 未使用 WP11-M 的解析状态，而是从同一 protected structured result 重新读取6次；reference reads为0。没有源码修改、OCR/provider、图片/新库存、联系人、生产操作、部署或 raw export。脱敏结果见[WP11-N 计数结果](wp11n-muse-value-free-wp10-gate-diagnostic-result-20261103.json)。
- **WP11-O 审计结果：** MUSE 已按任务完成静态只读来源核查，结论 `PARTIAL`，时间 `2026-11-03T18:02:55+08:00`。source checkout 可确认但没有 active-runtime binding；MUSE runtime、Seoul hash/version、OCR route 仍 UNKNOWN。被检查代码中的 adapter 未保留文本位置/概率/字符候选；UI/强制确认与不确定写入回滚在 inspected source 中未找到，但所有组件均未绑定到 active runtime，不能作为生产行为结论。操作计数确认没有读取凭据或日志、执行生产代码、OCR/联系人操作、写入、部署或导出。完整脱敏结果见 [WP11-O 机器结果](wp11o-muse-production-provenance-result-20261103.json)；具体原因码和哈希均保留在该结果中。
- **下一步（依赖顺序）：** (1) 取得能将 active MUSE runtime、workflow caller、Seoul deployment 绑定到不可变提交/镜像 digest 的证据；若当前 MUSE workspace 无此证据，准备由负责部署的一方提供 release manifest/source pin，而不扩大只读访问范围；(2) 在绑定源码中核对真实 UI review/edit/confirmation、live MCP schema、完整查重、create idempotency、readback 与 uncertain-write recovery；(3) 只有明确授权后打开 30 卡集合，先确认样本和 reviewed labels，再运行 schema 1.1 多样性/准确率门禁；(4) 全部安全、真实数据和隔离端到端门禁 PASS 后，才制定部署 pin、部署与回滚验证。不得跳步。
- WP11-M/N/O 本身不改解析器或生产。若未来针对同一 WP10 输入的解析器改动无法通过复验/合成回归，revert 该候选提交；部署前不改变生产。总状态仍为 `VALIDATION_PENDING`，30 卡授权未确认。

## 1. 业务决策

- 用户确认客户与公司均已授权完整家庭卡照片交由百度 OCR 处理。**本流程不做图片敏感信息遮盖**，不得继续将旧遮盖器作为上线前置需求。
- 保留完整原始家庭卡附件，不破坏性裁剪/涂黑；附件的访问权限、留存期限与删除策略仍须按现有获批流程执行。
- 本次仅建立**主客户**联系人；家属、保单、保费及其他卡片资料虽有未来业务价值，但本次不写入联系人。原图不提交 GitHub。
- 本次目标字段：姓名、性别、身份证号、生日、手机号；如卡片明确填写，亦提取地址和其他电话。不得猜测缺失字段。
- 优先映射到 iCloud 原生字段，**无法原生表示的本次目标字段每个占备注一行，格式「字段名：值」**；不得把整段 OCR 原文或未要求的家属/保单内容写入备注。
- 只有主客户身份、姓名、手机号可可靠确认且查重唯一无冲突时自动创建；无法判定时人工复核。精确已存在则跳过；不得自动覆盖旧联系人。写后读取核验，批量重试须幂等。

## 2. 字段映射

| 来源字段 | 目标字段 | 规则 |
|---|---|---|
| 主客户姓名 | 联系人姓名 | 保留准确姓名；不得从家庭成员列表误取 |
| 手机号 | phone（mobile） | 规范化后保留原始识别证据用于临时复核；不猜测数字 |
| 生日 | birthday | 仅在日期明确且有效时写入 |
| 地址（若有） | address | 保留原文、避免无依据拆分 |
| 其他联系电话（若有） | phone（other/home 等合适类型） | 不与手机号重复 |
| 性别 | note | `性别：女` 等，明确填写才写 |
| 身份证号 | note | `身份证号：...`，原文精确、必要校验；不写入电话字段 |

身份证号中的出生日期可以作为**待确认候选**，但不得在未明确审核规则前直接替代卡片生日；两者冲突转人工复核。身份证号 OCR 不确定、校验失败或身份关联不清时，禁止自动创建包含该身份证号的联系人；不能擅自补全。备注多行稳定排序：性别、身份证号、其他未来经明确批准且无原生字段的目标项目。空值不写。

## 3. 现有技术证据（按报告分层）

- WP1 MUSE 图片附件读取：PASS（仅合成测试图）。
- WP2 Codex OCR 包：`codex/wp2-muse-customer-card-ocr` / `ea7a088d0f1c78b4bec9bac737098d7ba4a1fc80`；MUSE Python 3.12 隔离 venv 25/25 Mock PASS。
- 百度主机 DNS/TCP/TLS/HTTP 直连：PASS；Token/OCR 端点未验证。
- 百度新版单 API Key Bearer 方案：PARTIAL；手写端点与最小权限 Key 的真实适配未证实。
- MUSE Python → stdin helper → Mock POST → JSON：`MUSE_BAIDU_CONNECTOR_MOCK_PASS`；**仅 Mock**，未注册真实 Secure Vault 连接器，也未证明生产凭据隔离。
- 真实百度 OCR、生产连接器、真实客户卡、iCloud 本工作流端到端写入：NOT TESTED。

## 4. 实施顺序及验收

### WP3：本文件计划同步
- 只改规划文档，不修改生产代码、不部署。
- 后续 Codex 在既有 OCR 分支上核查并吸收本修订，避免并行分支覆盖。

### WP4：Codex OCR 代码适配（离线）
- 取消旧 `PrivacyMaskResult` 强制依赖，改成**显式授权的完整图片处理模式**；不得伪造 VERIFIED 或悄悄删除所有安全控制。
- 将旧 AK/SK → Token → access_token 方案适配为**受保护连接器调用的 Bearer 路径**，以 MUSE 实际连接器接口为准；不要让 Python 读取明文生产 Key。
- 保留 EXIF、尺寸/体积检查、结构化 OCR 块、错误分类、不记录请求体/识别文本；核对百度手写接口真实尺寸与请求格式。
- 仅使用合成数据，增加 Bearer/401/403、门禁、空图、字段提取与隐私日志回归测试。
- 不得真实调用百度、访问 iCloud 或创建生产凭据。

### WP5：MUSE Secure Vault 私人连接器
- 经用户单独批准后创建最小权限的私人测试连接器；确认受保护凭据附加、不可回读、允许的主机/路径、Python 图片字节传输及 JSON 返回。
- 先 Mock 后再申请真实百度调用授权；未验证真实隔离不得声称生产可用。

### WP6：MUSE 字段抽取与 iCloud CRUD
- 单图至多一位主客户；MUSE 从完整 OCR 结果提取目标字段，其他字段不进入联系人。
- 查重：精确手机号、姓名、必要的身份证备注匹配；多候选、冲突或不完整搜索一律人工复核。
- 新建后回读校验姓名、号码、生日、备注；失败不盲重试；批次 idempotency；不得覆盖已有备注。
- 复用已存在的首尔 iCloud MCP / MUSE SDK Bridge，不修改服务器和其他 Agent。

### WP7：分阶段验收
1. 合成家庭卡离线 OCR Mock + 字段映射。
2. 真实 Secure Vault 连接器隔离 Mock。
3. 用户单独授权、确认百度额度/费用后，仅合成图真实 OCR Smoke。
4. 合成联系人 iCloud 端到端创建/回读/清理（单独确认写入）。
5. 真实客户卡小批量上线，复核字段质量、去重、失败处理及原图留存规则。

## 5. 安全边界与明确不做

- 不实施敏感信息像素遮盖；不因本次未使用其他卡片信息而删除它们。
- 不把真实图片、OCR 全文、身份证号、客户姓名手机号、密钥或认证请求写入公开 GitHub、普通日志或 Agent 长期记忆。
- 用户确认授权不等于已完成平台技术隔离验收；真实 Secure Vault、真实 OCR 和真实联系人写入仍需各自通过验收。
- 不引入 Mac Server、Pixel、DeepSeek、独立服务器、数据库或新 MCP。
- 本计划不自动批准创建真实密钥、付费请求或批量 iCloud 写入。

## 6. 下一步指令

Codex 首先只读检查当前 OCR 分支与本计划差异，提交 WP4 最小接口设计和离线测试计划；优先确认 MUSE 真实连接器 helper 规范，避免把 Bearer Key 暴露给 Python。获得接口证据后实施 WP4，提交新分支和测试回执。MUSE 同步准备 WP5 的最小权限连接器配置清单，实际创建需单独确认。
