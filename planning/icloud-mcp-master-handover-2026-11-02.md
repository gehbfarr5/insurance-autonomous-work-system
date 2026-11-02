# iCloud MCP 项目全阶段归档与暂停交接（截至 2026-11-02）

> **统一结论：\`CORE_PRODUCTION_OPERATIONAL / MULTI_AGENT_CONNECTED / CHAT_SITES_MCP_PASS / WORK_CLOUD_SITES_MCP_PASS / CHATGPT_ICLOUD_REAL_DATA_BLOCKED / PARKED\`**
>
> 本文件是跨阶段的**总索引和项目决策记录**，不是把全部工具、Agent、ChatGPT 接入认定为全功能 PASS，也不是任何生产 Token 或客户资料的保存位置。旧 Issue、原始验收和规划文档按当时阶段保留，**最新结论以本文为准**。归档后当前 ChatGPT→真实 iCloud 的进一步接入、Sites v2 修复与重复验收暂停；现有其他 Agent 和首尔生产 MCP 不受影响。

## 1. 项目目标、边界和当前结论

**原始业务目标**：用同一个自建 Apple iCloud 数据源，为多个 Agent 提供 Contacts/CardDAV、Calendar/Reminders/CalDAV 的查询和受授权的 CRUD；最终让 ChatGPT Chat 和 Work 也可以操作同一套联系人、分组、日历和提醒事项，支撑保险客户经营工作流。Mail 单独评估，Notes 不在上游能力范围。

**当前已完成**：
- 统一的首尔云端 MCP、Streamable HTTP 和 OAuth 2.1 认证基础设施；生产 MCP 的**注册工具数为 33**（原 25 + 联系人分组 8）。
- 联系人、日历、提醒事项的真实协议和虚构测试对象 CRUD 有实测回执；生产数据与业务客户不作为无授权测试对象。
- 五个外部 Agent 已在**不同版本/不同覆盖范围**上连接成功：MUSE、Antigravity、WorkBuddy Desktop、Vela/Hermes、Codex；其中 Codex 的**新版 33 工具独立核验仍缺证据**。
- 现有私人 ChatGPT Site \`iCloud MCP Capability Test\` 已证明：**普通 Chat 与 Work Cloud 都能实际调用同一 Sites-hosted MCP 插件的虚构只读工具**。
- 已创建首尔独立受限桥接 API，服务端限制为只读 \`contacts_groups_list\` 并裁剪输出 \`name\`、\`member_count\`；首尔本机带授权预检的成功回执并不等于 Site 云端端到端成功。

**当前未完成/阻断**：
- 普通 Chat 调用现有 Site v2 的**真实** \`icloud_contacts_groups_list\` 返回 \`INVALID_ARGUMENT: iCloud bridge request failed\`，首尔侧没有与之对应的成功处理证据；Work Cloud 尚未对真实工具独立调用。
- 原 Site Worker 源码无法经官方托管 Git 流程 checkout：执行环境的 Git 代理连接失败，无法安全修复或发布。**真实数据链路不具备 PASS 证据**；其余 32 项未在 Site 桥接公开，不能算 ChatGPT 已接入。
- Work Local **没有完成有效环境验收**；不应认定它已证明不可行或已经通过。
- 联系人→业务台账→日历→提醒事项的完整真实业务流程尚未完成。

## 2. 主要时间线与已做尝试

| 时间 | 尝试或建设 | 实际结果和边界 |
| --- | --- | --- |
| 2026-10-30 前后 | 调研上游 \`MrZhongzq/apple-icloud-mcp\`、其他 iCloud MCP 候选；探索 Render 云端试点，制作部署前测试包 | Render 试点历史上有健康/OAuth/虚构 CRUD 回执；早期阶段也遇到部署/持久化及外部连接限制。后来转为首尔生产基线；**不要拿早期的 NOT DEPLOYED 覆盖后期 PASS**。 |
| 2026-10-30 | 首尔自建 MCP：TLS/Tailscale Funnel、OAuth 2.1、Apple CardDAV 登录、虚构联系人 create/read/update/delete/零残留、重启后回归 | 依据 Antigravity/Issue #4 验收与服务器独立健康核验，核心 Contacts 能力已 PASS；独立主机异地灾备未验收。 |
| 2026-10-30—31 | Token Store 加密权限、主机备份、离线隔离解密；本地 Credential Vault | 本机受限备份/解密已验证；同磁盘备份≠异地灾备。不得把备份及恢复密钥提交仓库。 |
| 2026-10-31 | Calendar/Reminders 读写开关上线；Mail 保持关闭 | 配置部署与容器健康 PASS；随后 Antigravity 真实 Apple CalDAV 以虚构对象完成完整 CRUD/清理回执。 |
| 2026-10-31 | 修复 Reminders \`VTODO\` 查询过滤（上游默认 \`VEVENT\` 会漏提醒），保存补丁和测试 | 首尔生产已包含修复；PR #15 记录可重放的补丁。Mac 原始 E2E 脚本/日志尚未完整入仓，不能冒称都已归档。 |
| 2026-10-31—11-01 | 原生联系人分组实现并部署；8 个新 MCP 工具；修复电话数字子串导致联系人误召回 | 生产注册数 25→33。MUSE、Antigravity、WorkBuddy Desktop、Vela/Hermes 的分组相关独立回执已通过；Codex 33 工具未取得完整独立证明。 |
| 2026-10-31—11-01 | MUSE、Antigravity、WorkBuddy Desktop、Vela/Hermes、Codex 接入 | 各 Agent 使用同一首尔服务；验证覆盖和先后顺序详见第 4 节与 Agent 台账。 |
| 2026-11-01 | ChatGPT 导入型私人插件 v0.1.0 与 v1.0.0；网页 Chat/桌面 Chat、「立即试用」；Work/Work Local 排障 | 两份导入型插件虽然有配置/安装证据，实际 Chat 工具未暴露；Work Local 没有进入可确证的本地执行环境。**重复重建同类插件无收益**。 |
| 2026-11-01 | 创建私人 Site \`iCloud MCP Capability Test\` 并发布 MCP 虚构只读工具 | Chat 真实调用 \`demo_contacts_groups_list({})\`，返回 \`测试客户=3\`、\`测试家庭=2\`；\`SITES_CHAT_MCP_PASS\`。 |
| 2026-11-02 | 对同一 Site v2 新增真实只读工具和首尔独立受限桥接；Site 关联插件刷新授权 | 工具 \`icloud_contacts_groups_list\` 在普通 Chat 可见且确实被调用，但连续报 \`iCloud bridge request failed\`；只有首尔本机桥接预检成功，未取得 Site→首尔生产成功证据。 |
| 2026-11-02 | 首尔只读核验受限桥接、Funnel 路由、候选 Worker 诊断模块 | 系统服务 active、健康；未授权请求 401。Funnel :443 \`/\`→17734（原 MCP）、\`/bridge\`→17735（受限 API）。Site 的配置基址 pathname 已是 \`/bridge\`，但真实 Worker 源码不可见，**不能确认其是否正确保留路径**。诊断模块 mock **8/8 PASS，未部署**。 |
| 2026-11-02 | 尝试恢复 Site 官方托管源码（\`sites/1.1.2\`） | 第一次非空目录且无 \`hosting.json\` 在本地退出；第二次空目录到 \`git ls-remote\` 时无法连接 \`127.0.0.1:7897\`，exit 128；无 checkout、无修复发布。按止损条件停止。 |
| 2026-11-02 | Work Cloud 在远程 Linux x86_64 工作区实际调用同一 Sites 插件的 \`demo_contacts_groups_list({})\` | 返回同两项虚构分组；\`WORK_SITES_MCP_PASS\`。证明 **Chat 与 Work Cloud 可复用同一插件**，但未证明 Work 真实 iCloud 读取。 |
| 2026-11-02 | GitHub/社区与官方 Chat/Work 合并方向调研 | 确有多个 Sites Git 代理/DNS 失败公开报告，不能证明本项目同一根因。Chat/Work 统一产品方向已公开讨论，**不代表当前已全面上线或自动修复 Sites 源码**；不以未来合并作为唯一恢复策略。 |

## 3. 实际部署架构、服务与安全边界

### A. 首尔生产 MCP

- 服务器：\`seoul-forge-01\`（统一业务数据源，非多个 iCloud 后端复制）。
- MCP HTTPS：\`https://seoul-forge-01.tail4db0d9.ts.net/mcp\`；Streamable HTTP，OAuth 2.1 / DCR / Authorization Code + PKCE S256 / Refresh。
- 上游基础项目：[\`MrZhongzq/apple-icloud-mcp\`](https://github.com/MrZhongzq/apple-icloud-mcp)。Contacts/CardDAV、Calendar/Reminders/CalDAV；Mail 仍不允许，Notes 不支持。
- 原有 25 工具 + 8 分组工具 = **33 注册工具**。分组新增：\`contacts_groups_list\`、\`contacts_groups_members\`、\`contacts_groups_create\`、\`contacts_groups_rename\`、\`contacts_groups_add_members\`、\`contacts_groups_remove_members\`、\`contacts_groups_delete\`、\`contacts_create_in_groups\`。
- 生产已修复：Reminders \`VTODO\` 过滤；\`contacts_search\` 的电话号码误召回。生产完整 CRUD 授权是用户对获授权 Agent 的既有决策；**每个 Agent 是否实际完成某种 CRUD 验收，要看独立回执**。
- 主机持久存储、root-only 备份/加密恢复已做本机验证；**异地备份+灾难恢复尚未 PASS**（Issue #7）。
- 其他 Agent 原授权有效；本次归档不会轮换 Key、改变开关或触发真实客户修改。

### B. ChatGPT 私人 Sites 插件

- Site：\`iCloud MCP Capability Test\`，项目 ID \`appgprj_6ae74a5f951c81918542ca3d380f8f3c\`，已发布 **v2**。
- 发布版本 ID：\`appgprj_6ae74a5f951c81918542ca3d380f8f3c~appgver_2011b657ef6481918cb478250ae79a7c\`。
- 当前 Site 源码元数据 commit：\`7260091c01fa91b3c1383f3d00c3080507a8d4f2\`，Cloudflare Artifact \`main\` 分支；**这是元数据里的版本号，不是本次成功 checkout 取得的 SHA**。
- Site 私人插件可在普通 Chat 与 Work Cloud 被实际调用；\`demo_contacts_groups_list\` 只返两项虚构数据；\`icloud_contacts_groups_list\` 是真实桥接工具入口，但实际调用报错。
- Site 的服务器端 \`ICLOUD_BRIDGE_URL\` 已配置为 HTTPS 且 pathname 为 \`/bridge\`；\`ICLOUD_BRIDGE_TOKEN\` 以 Secret 项存在，但隐藏值**无法独立确认为非空**。不要把键存在误当认证成功。
- Site/插件本体不是原始 MCP 客户端的“直连”。其工具需要 Site Worker 在**服务端**发出受控 HTTPS 请求；不得把桥接 Secret 或全权限 MCP Token 放到浏览器 JS。

### C. 首尔受限桥接

- 生产桥接为独立 \`chatgpt-sites-icloud-bridge.service\`，仅暴露白名单操作 \`POST /v1/contacts/groups/list\`，响应仅 \`name\` 与整数 \`member_count\`。
- 本机监听 \`127.0.0.1:17735\`；Tailscale Funnel 公网路由前缀为 \`/bridge\`，完整候选路径应为 \`/bridge/v1/contacts/groups/list\`。原 MCP 在 17734 的 \`/\` 路由。
- 首尔本机带授权只读 POST 曾回 HTTP 200、报告 1 个真实分组；无授权 POST 回 401；**这不足以证实从 Site 的出站网络可达，也不证明 Site Worker 已发起 fetch**。
- 生产 MCP 的 \`scope=mcp\` 不是强制的逐工具“只读权限”；桥接必须在可信服务端做白名单、鉴权、限流、审计、字段裁剪、独立撤销，禁止通用任意 tool-name 转发。

### D. 密钥和权限最终决策

- Chat + Work Cloud 共用**同一个 Sites 插件**，只需要一套专用的 Site→首尔服务端授权；不因两个使用界面先行复制两份凭据。
- 若将来 Work 改为**独立直接 MCP 客户端**，应新建独立连接身份用于审计/撤销。
- 不复用 MUSE/Codex/Antigravity/WorkBuddy/Vela 的既有生产访问密钥；各 Agent 的授权和撤销保持独立管理。
- 源码 checkout 用的官方**临时仓库凭据**与 iCloud/生产 OAuth Key 不同。此前仅通过受保护 stdin 使用，没有存入 GitHub；这条授权并未解决 Git 出站连接。
- 曾有生产凭据进入聊天上下文。须留在**私有密钥治理清单**计划轮换，在确认依赖和恢复措施后再操作；本公开文件不得存储值、客户数据或恢复密钥。

## 4. 各 Agent 的真实验收差异

| Agent | 运行环境/接入路径 | 最新可证实程度 | 不能由此推断 |
| --- | --- | --- | --- |
| **MUSE 个人云 Agent** | 持久云 VM + SDK Bridge | CONNECTED/PASS；用户报告联系人和分组多轮真实操作、回读、清理通过 | 不能把 Muse Code 当 MUSE；不代表每项 Calendar/Reminders 都独立全量验收 |
| **Antigravity** | Mac 本地 | FULL PASS 报告；33 项工具、分组、搜索修复、Calendar/Reminders 虚构 CRUD/零残留 | 不等于 ChatGPT Work Local 也具备同样的工具 |
| **WorkBuddy Desktop** | Mac 本地，OAuth MCP | CONNECTED/PASS；联系人三态字段、ETag 冲突、部分分组及只读模块回归 | 不是 WorkBuddy Cloud 的独立验收 |
| **Vela / Hermes** | 新加坡常驻云 VM，原生 MCP | CONNECTED/PASS；33 项工具发现、8 项分组工具、分组 E2E、其他模块只读回归 | 成员重复添加幂等性专项尚缺回执 |
| **Codex CLI/Desktop** | Mac 宿主 CLI，OAuth MCP | 旧版 25 工具、登录、Contact/Calendar/Reminders 只读及会话持久性 PASS；用户另报告最新版已接入 | **没有独立归档的 33 工具+8 分组最新版全量验收回执** |
| **ChatGPT 普通 Chat** | 同一 Sites-hosted 私人插件 | \`SITES_CHAT_MCP_PASS\`（仅虚构 demo）；真实 \`icloud_contacts_groups_list\` 工具入口能调用但报错 | 不是 \`CHAT_ICLOUD_READ_PASS\` |
| **ChatGPT Work Cloud** | 远程 Linux 工作区，复用同一 Site | \`WORK_SITES_MCP_PASS\`（真实 demo 工具调用；不是 Work Local） | 还没有真实 iCloud 数据读取验收 |
| **ChatGPT Work Local** | 未获得已确证的本地执行环境 | \`WORK_LOCAL_UNAVAILABLE\` | 不能宣称 Work Local 已成功或已证实不支持 |
| **WorkBuddy Cloud** | 与 Desktop 不同执行环境 | NOT TESTED | 不复用 Desktop 的 PASS |

已暂停或不列为独立接入目标：TGT（明确暂停）、Muse Code（不是 MUSE 个人 Agent）、Pixel（远程执行设备，不是此 MCP 业务 Agent）。

具体历史回执以 [Agent 台账](./icloud-mcp-agent-connection-status-2026-11-01.md) 和 [Issue #6](https://github.com/gehbfarr5/insurance-autonomous-work-system/issues/6) 的原始评论为准。

## 5. ChatGPT 接入路线：尝试清单与效率判断

| 路线或操作 | 实际尝试 | 结果 / 下一步决策 |
| --- | --- | --- |
| 原生远程 MCP 配置、导入型私人插件 | 创建 \`insurance-icloud-mcp\` v0.1.0（\`plugins_6ae5971b69288191b59eaf6104a020a4\`）及 v1.0.0（\`plugins_6ae596f08e6881919af6862a64092566\`），MCP 配置目标均指向首尔 | Web/桌面 Chat 不能发现预期自建工具；平台标记 Desktop only；**不再重复重建同类导入插件**。两份暂保留，待实际依赖审计才讨论清理。 |
| Work Local 自建 MCP | 桌面工作流与当前工具目录调查，无法确认真实本地 Work | \`WORK_LOCAL_UNAVAILABLE\`，不是网络服务器或 OAuth 的有效负向 E2E 结论。 |
| Sites 托管插件的虚构 MCP 工具 | 新建并发布私人 Site，Chat 调用 \`demo_contacts_groups_list({})\` | **Chat PASS**，同两个虚构分组数据；证明 Chat 真实 MCP 调用路径可用。 |
| Work Cloud 复用同一 Sites 插件 | 远程 Linux x86_64 工作区中实际调用同一 demo | **Work Cloud PASS**；不必为两个界面分别建 Site、插件、桥接密钥。 |
| Sites v2 真实只读 iCloud 工具 | 扩展 \`icloud_contacts_groups_list\` 并发布 v2，首尔新增专用只读桥接 | Chat 发现和实际调用工具，但返回 \`INVALID_ARGUMENT: iCloud bridge request failed\`；Site→首尔实际失败原因尚不明。 |
| 重写 Site Secret / 再发布 | 曾重新保存相同 Secret 并按原版本部署 | 失败不变；**重复写入 Secret 和把约 9 秒本机预检误判为 Worker 4 秒超时都无充分证据**。 |
| URL 路由诊断 | 首尔验证 Funnel \`/bridge\`→17735；检查 Site \`ICLOUD_BRIDGE_URL\` 已含该前缀 | 路径配置项看似正确，**仍不能确认 Worker 是否在使用 \`new URL('/v1/...',base)\` 等逻辑抹掉前缀**；源代码不可读，不能定位根因。 |
| Worker 候选源码和 mock 测试 | GitHub \`integrations/chatgpt-sites/worker-diagnostics/\` 的只读 \`bridge-client.mjs\`、测试、说明 | **8/8 offline mock PASS**，可分类 Secret 缺失、DNS/TLS fetch、401、超时、JSON/schema；**该代码未部署到 Site**。 |
| 官方 Sites v2 源码 checkout | \`sites/1.1.2\` 第一次非空目录缺 \`hosting.json\`；第二次空目录到 \`git ls-remote\` 阶段 | Git 代理 \`127.0.0.1:7897\` 不可连接，**exit 128**；无 checkout 路径，未读取 Worker，未发布新版。按止损条件已停。 |
| 提交 OpenAI Support 的可能性 | 已准备完整脱敏工单，但项目回执中没有实际提交/工单编号 | 可留作可选正式报告，**不作为项目主进度依赖或确定会解决的修复机制**。 |
| 替代路径：Custom GPT Actions / Cloudflare Workers / 直接远程 MCP | 调研成熟 REST Actions、Cloudflare Agents/MCP SDK、官方自定义 MCP 能力 | 技术可能，但未证明此账号下可不依赖 Sites 而直接调用生产 33 工具。**调研≠部署或端到端 PASS**；暂不迁移，也不为此另启云服务器。 |

### Sites 源码故障的准确证据

- 原 Site 绑定到官方 Cloudflare Artifact 仓库 \`main\`；原发布 v2 仍在线。
- 本轮第一次工作目录选择失败是本地流程问题，不应归因于代理。
- 第二次空目录按官方工作流走到 \`git ls-remote\`：连接执行环境的代理 **\`127.0.0.1:7897\`** 即失败，exit **128**，**在任何成功 fetch/checkout 之前**。不能证明仓库权限拒绝，也不能证明生产 Site 无法运行。
- 工具元数据、Site 页面投影和已经安装的 App 绑定文件**不是 Worker 源码**，不能用修改插件描述来代替真正源代码修复。
- 用户明确要求继续开发前必须恢复已有项目源码且可回滚；当前满足止损条件，标记 \`SITE_SOURCE_CHECKOUT_BLOCKED / STOPPED\`。不再申请新的 PAT、重复改代理、克隆新 Site 或通过新 Secret 猜测修复。

## 6. 技术调研、GitHub 社区证据与产品变化

**已核实的一手/社区资料：**

| 资料 | 内容 | 对本项目的意义 |
| --- | --- | --- |
| [上游 apple-icloud-mcp](https://github.com/MrZhongzq/apple-icloud-mcp) | CardDAV/CalDAV + 远程 Streamable HTTP/OAuth；原仓工具 25 项 | 说明首尔生产基于成熟现有实现，再叠加本项目分组修复 |
| [OpenAI Sites-hosted MCP 官方文档](https://help.openai.com/en/articles/20001547-hosting-a-plugin-with-chatgpt-sites) | Site MCP 工具可通过插件在 ChatGPT 调用；需另行完成外部 API 的授权与连通 | 支持 Chat/Work 已通过的“虚构工具”路线，**不保证**真实桥接自动成功 |
| [OpenAI Sites 创建与编辑文档](https://help.openai.com/en/articles/20001339-creating-and-using-chatgpt-sites) | Site 所有者控制编辑/发布；发布后的 Site 与插件权限独立 | 说明恢复源码和安全发布是业务继续推进的前提 |
| [openai/codex #49573](https://github.com/openai/codex/issues/49573) | 多名开发者报告 Sites Git 代理连接失败/发布中断 | 说明有外部相似症状，**不证明同一个根因** |
| [openai/codex #50444](https://github.com/openai/codex/issues/50444) | 现有 Site 在 Git \`ls-remote\` 阶段代理 \`browser-proxy:8889\` 失败 | 与本项目 \`127.0.0.1:7897\` 失败阶段相似，但具体代理不同 |
| [openai/codex #56576](https://github.com/openai/codex/issues/56576) | 2026-10-23 macOS 下旧/新私人 Site Git DNS 失败 | 不建议简单重建新 Site 当作确定解法 |
| [Cloudflare Agents](https://github.com/cloudflare/agents)、[Cloudflare OAuth Provider](https://github.com/cloudflare/workers-oauth-provider)、[MCP TypeScript SDK](https://github.com/modelcontextprotocol/typescript-sdk) | 可复用的远程工具、授权与可测试源码模式 | 属于未来架构候选，**没有在本项目替换/上线** |

**Chat/Work 产品变化（截至本归档日期）：**
- 2026-10-28 有 OpenAI 负责人[公开表示](https://x.com/thsottiaux/status/2115588390414581916)正在研究把 Chat 与 Work 的优势合并，称当时并未正式推出；[BleepingComputer 2026-11-01 报道](https://www.bleepingcomputer.com/news/artificial-intelligence/openai-says-its-doubling-pro-usage-limits-and-bringing-work-features-to-chat/)提到面向小范围用户的合并体验测试计划。[OpenAI ChatGPT 发布说明](https://help.openai.com/en/articles/6825453-chatgpt-release-notes)截至当前日期未提供此次合并全面开放的确认。**明确区分产品方向、媒体报道与当前账号实际开通状况**。
- 这个变化可能减少模式切换和重复编排，但**不自动修改 Site Worker、Git 源码仓库、桥接 OAuth 或当前账号的自定义 MCP 直接接入权限**。
- 已有独立实测的“同一个 Site 插件同时服务 Chat/Work Cloud”是稳定的设计发现；产品若合并，也不需要重新为 UI 模式配置两把 Site Secret。未来只以真实版本说明和端到端调用证据决定是否重新开启。

## 7. 已投入但效果有限的操作与明确停止项

- 反复创建/检查旧式私人 MCP 导入插件：**不能让 Chat 工具出现**；停止新增重复插件。
- 反复点击“立即试用”或只读插件元数据：只能证明插件包存在，**不能替代 tools/list 和实际调用**。
- 只从首尔本机 curl 成功推断云端 Site 能访问：**证据不成立**；以后必须在真正的 Site Worker 运行时核实。
- 依据 Site \`/mcp\` HTTP 200 就认为真实业务调用已成功：**错误**，需要 MCP tool result 和后端请求相关日志。
- 以 \`demo_contacts_groups_list\` 的 PASS 代替真实 iCloud PASS：**禁止**。
- 在 Worker 源码完全不可读时反复重写 Secret、改超时、盲目再部署：**收益低且有风险**，停止。
- Sites 源码 checkout 网络/代理错误已重复定位；**当前不再尝试新的短期凭据、持久 PAT 或新 Site 来绕过**。
- 不为 Chat 与 Work 两个使用界面建立重复桥接密钥；若未来 Work 独立直连才重新审议。
- 不在无人工授权下对真实客户数据做端到端 CRUD、删除、批量改动或自动客户外呼。

## 8. 当前正式决策（\`PARKED\`）与恢复触发条件

**当前决策**：ChatGPT→真实 iCloud 接入子项目暂停；不是撤销前期成功的 Sites 工具验证或关闭首尔生产服务。Issue #6、#4、#13、#7 保持原有追踪状态；其他 Agent 正常工作。旧版 Site v2 保留、不修改；完整 33 项 Site 暴露计划暂停。

**可恢复条件（满足任一后再单独发起新决策）**：
1. 官方 Sites 源码 checkout 在原项目上恢复、能读到 Worker handler、能版本化/回滚；随后先用现有候选模块只修复 \`icloud_contacts_groups_list\` 的**真实只读**链路，再由 Chat 和 Work Cloud 各自独立验收。
2. OpenAI 发布并给当前账号提供**真实可用且受支持**的远程 MCP 直接连接/统一 Chat-Work 接入；确认是否能直接连接现有首尔 MCP、是否支持所需权限/授权/工具调用，先只读真实分组，不在身份/权限未审计前开放写入。
3. 若两者都不具备，再另行评价**源码由本项目完全版本化、插件入口可用**的替代 Site/REST 集成；该选项属于**新技术方案审批**，不能视为本轮已完成。

**最小复验顺序**：
- 环境/授权明确可用 → Site 源码实际可读/可部署或官方直接 MCP 连接可用 → 真实只读 \`contacts_groups_list\` 工具结果 → 记录一条可追踪的成功调用/审计 → 最后再分批开放更多读取及受控写入。
- Chat 与 Work Cloud 的 \`demo_contacts_groups_list\` PASS **已完成，不再重复**。
- 生产 Key 出现过聊天暴露的历史风险应进入**单独私有安全治理**，确认当前被哪些有效 Agent 使用后计划轮换，不在公开 Issue 中贴值。
- 异地灾备（Issue #7）、Codex 最新 33 工具证据、原始 CalDAV E2E 测试脚本、WorkBuddy Cloud、保险客户业务闭环都是**其他独立后续事项**，不被 ChatGPT 子项目暂停所冻结。

## 9. 原始资料 / 代码 / 项目追踪索引

**运行与多模块**
- [Issue #4 — 首尔 CardDAV 核心与旧 Render 试点](https://github.com/gehbfarr5/insurance-autonomous-work-system/issues/4)
- [Issue #7 — 同磁盘备份与异地灾备缺口](https://github.com/gehbfarr5/insurance-autonomous-work-system/issues/7)
- [Issue #13 — Calendar/Reminders 与 Mail 范围](https://github.com/gehbfarr5/insurance-autonomous-work-system/issues/13)
- [多模块源代码能力审计（当时基线）](./icloud-mcp-multimodule-expansion-2026-10-31.md)
- [VTODO 热修复与 PR #15 验收记录](./icloud-caldav-vtodo-production-hotfix-2026-10-31.md)

**Agent 与 ChatGPT**
- [Issue #6 — 各 Agent 接入，最新 ChatGPT 阻断](https://github.com/gehbfarr5/insurance-autonomous-work-system/issues/6)
- [各 Agent 独立验收台账（含历史阶段）](./icloud-mcp-agent-connection-status-2026-11-01.md)
- [Chat Sites 虚构 MCP POC 与独立 PASS](./chatgpt-chat-sites-mcp-poc-2026-11-01.md)
- [Sites→iCloud 生产桥接设计与密钥边界](./chatgpt-sites-icloud-production-bridge-2026-11-01.md)
- [Site v2 源码/桥接失败与 Git 代理阻断回执](./chatgpt-sites-worker-diagnostic-2026-11-02.md)
- [未部署的 Worker 诊断模块与 8 项单测](../integrations/chatgpt-sites/worker-diagnostics/README.md)

## 10. 证据分级与归档范围说明

1. **LIVE TOOL PASS**：对应运行模式中实际发现并调用工具，核对其返回结果（本项目 Chat/Work Cloud 的 Sites 虚构工具满足此级别）。
2. **PRODUCTION E2E PASS（回执）**：指定 Agent 连接生产服务并读写虚构 Apple 对象、回读和零残留；以用户提供原始回执或 Issue 评论为依据。不替代未来其他 Agent 的独立验证。
3. **SERVER READONLY VERIFIED**：服务器运行、端口、健康、配置和请求认证检查；不等于客户端或真实业务 E2E。
4. **MOCK ONLY**：离线/模拟 8/8，不代表 Site Worker 当前代码或外部网络成功。
5. **CONFIG/METADATA ONLY**：插件、Site、环境变量键、仓库绑定存在；不代表授权或外连成功。
6. **UNVERIFIED/BLOCKED**：无有效运行环境、源码/网络阻断或数据结果失败，不能以技术可能性补证。

**覆盖限制**：本归档以本项目 GitHub 原有文档、Issue 回执、用户转交的 Sites/Work 验收报告和公开社区资料为依据。尚未出现在 GitHub 的本地 E2E 脚本、历史原始日志与敏感配置不予假装已上传；只有后续实际校验并脱敏提交后才能标为归档完成。任何时点的历史 NOT TESTED/PASS 都必须连同日期阅读，不应覆盖比它更新的实测结果。

**本轮归档操作本身**：仅 GitHub 文档/Issue/README 维护；**没有再次调用真实 iCloud、修改首尔进程、调整 OAuth/Secret、改 Site v2 或试图绕过官方源码代理限制**。
