# iCloud CardDAV MCP：本地与云端 Agent 全量接入盘点（2026-10-31）

> 状态：**盘点/接入策略确认；不是各客户端已经连接成功**。2026-10-31 用户新增决定：**TGT 暂时忽略，不纳入实施。**本次从已有项目记录、GitHub Issue、WorkBuddy 2026-10-27 环境盘点及厂商当前文档交叉整理。此前项目没有正式冻结过完整 Agent 品牌清单，不能把候选名称写成已部署。
>
> 现有联系人服务（已部署，不重建）：`https://seoul-forge-01.tail4db0d9.ts.net/mcp`；云端 Apple CardDAV OAuth/虚构联系人 CRUD/重启后复验报告见 [Issue #4](https://github.com/gehbfarr5/insurance-autonomous-work-system/issues/4#issuecomment-6525726042)。用户已确认：**所有获授权 Agent 具有相同联系人完整 CRUD 能力，暂不按角色做权限网关**。

## 1. 先明确 Agent 与基础设施的区别

- **独立 Agent 运行时**：有自己的模型/决策过程、工具注册与连接/凭据来源；需要单独做 MCP 客户端连接验收。
- **执行环境**：本地 Mac、云端持久 VM、临时云任务沙箱、Android Pixel。它本身并不是独立 MCP 客户端；只在其中确实有 Agent 运行时才需要接入。
- **MCP 服务节点**：首尔 `seoul-forge-01` 当前是联系人数据访问服务/云服务器，不是已经部署的通用多 Agent 调度器。将来可以在此部署无人值守工作流 Agent，但当前不能标记为已完成。
- **业务职能**：`Scout → Architect → Builder → Verifier → Reporter` 是已确认的逻辑职责，不要求五个不同 Agent，更不应为每种职责单独再建一把 MCP Key。
- **Pixel 3a** 承载科技个险 Android 自动化；默认由调用它的 Agent 使用 MCP，不给 Pixel 或普通脚本重复部署联系人 OAuth，除非已确认设备内部有独立需要联系人数据的 Agent。

## 2. 全量 Agent 清单：存在、可能与待核实

| 对象 | 当前运行归类 | 用户/项目记录与来源 | MCP 接入方式 | 当前实际状态 | 优先级 |
| --- | --- | --- | --- | --- | --- |
| **Meta MUSE 个人 Agent** | **云端持久 VM** | 本项目 MUSE 已承担阳光森林每日 09:00 调度，保留持久 state；Meta 确认 Muse Secure VM 是持久云机 | **先在 Muse 对话内请求创建 Custom Connector**，目标为公开 Streamable HTTP MCP URL + OAuth。第三方已有基于 SDK 桥接案例；该实例是否能直接处理目标 MCP 的 OAuth，**必须实测**，不要把 Muse Code 的配置当成个人 Muse 的设置 | **MUSE 云端业务运行有证据；CardDAV MCP 未接入/未验收** | **P0** |
| **Codex CLI/Desktop** | 本地 M5 Pro Mac | [Issue #6 本地回执](https://github.com/gehbfarr5/insurance-autonomous-work-system/issues/6#issuecomment-6527350475)：Codex CLI 0.162.0，MCP URL 已加入，OAuth 页面已打开；专属 Access Key 已发放 | `codex mcp login icloud-carddav` 完成已有 OAuth；不重复 `mcp add` 或发 Key；再在 Codex 内 tools/list + apple_login + contacts_search | **MCP 配置 PASS，OAuth/真实工具调用未验收** | **P0** |
| **Google Antigravity IDE** | 本地 M5 Pro Mac | 同 Issue #6 本地回执：Antigravity.app 2.27.0，`~/.gemini/config/mcp_config.json` 已加 `serverUrl`，IDE 未显示条目；独立 Key 已发 | IDE `MCP Servers → Manage MCP Servers → View raw config` 找到实际读取配置，Reload/Refresh 后 Authenticate，OAuth + tools/list；不能只用原自动化测试脚本的成功作为 IDE 成功 | **配置文件存在，IDE 未加载、OAuth 未验收** | **P0** |
| **Tencent WorkBuddy 桌面版** | 本地 M5 Pro Mac Electron | 2026-10-27 本机只读盘点：WorkBuddy 5.9.2，shell/MCP 均由本机执行；当时 `~/.workbuddy/mcp.json` 仅 `andromeld` disabled | 用户级 `~/.workbuddy/mcp.json` 添加独立远程 HTTP MCP 条目，或界面「连接器→自定义连接器」；按 OAuth+PKCE 授权。**保留现有其他连接器** | **支持原生 MCP；本服务未见安装回执** | **P0** |
| **Tencent WorkBuddy 云端任务** | 按任务启动的**隔离云沙箱** | 盘点说明云任务是独立执行模式，个人连接凭据本地保存，云端持久性/凭据复用未证实 | 在真正云任务中单独验证远程 MCP/云托管 OAuth；不能直接复用桌面端 `~/.workbuddy` Token。是否重复 OAuth、密钥是否跨任务保存待测 | **云端 MCP 未验收；不是持久 VM 的替代** | P1 |
| **ChatGPT Chat / ChatGPT Work** | OpenAI 托管交互和云工作能力 | Work 可用已连接插件，但不表示当前账号可以添加任意 MCP；ChatGPT 自定义 MCP 的完整读写官方当前面向 Business / Enterprise/Edu Web | 符合账户工作空间权限时通过 Plugins 加自定义 MCP 并 OAuth；否则使用已连接的 iCloud 相关插件完成适用任务，不谎称它与自建 CardDAV 是同一连接 | **自建 MCP 连接未验收；平台套餐可能构成限制** | P1 |
| **Vela 微信侧 Agent** | 微信侧信息/任务枢纽（宿主环境未证实） | 2026-10-26 用户交接将 Vela 定位为微信侧信息枢纽，不要求 ChatGPT 与 Vela 实时自动双向同步 | 先调查它是否允许自定义远程 MCP；有则直接 OAuth；若只能访问 HTTP/工具 API，则由其提供方已支持的工具桥接。未知就不创建无依据服务 | **未见自建 MCP 配置/调用回执** | P1 |
| **Muse Code** | Meta 终端编程 Agent，**不等于 MUSE 个人云 VM** | Meta Model API 文档支持 `mcp_servers`、`transport: streamable_http`、`url`、`headers` | 仅在用户实际上单独使用 Muse Code 时配置；其 OAuth 自动 DCR 能力需以实测为准（文档仅明确 HTTP/headers） | **是否安装/启动未知，不作为 MUSE 替代或重复必接项** | P2 |
| **未来首尔常驻业务 Agent** | 候选自建云端运行器，**尚未部署** | 当前首尔实例已有 CardDAV MCP 与备份；没有独立无人值守客户跟进 Agent 的运行证据 | 在首尔/其他云环境采用 SDK Streamable HTTP MCP Client + OAuth 会话/刷新；不需要另外部署 CardDAV Server。可用已验证的 `src/customer-ops/carddav-followup.mjs` 作为业务模块 | **未实施** | P2，依据实际任务需求 |
| **Claude Code / Gemini CLI 等** | 过去讨论过的候选开发工具 | 过去工具选型有提到，但没有在本项目里证实实际安装/常用 | 如确定投入日常执行，再用其原生远程 MCP 配置接入，不提前膨胀清单 | **观察位，非必接** | P3 |

## 3. 执行优先顺序：云端持续性 + 已有部署事实

- **第一批 P0**：MUSE 云端个人 Agent（因为它是真正已在承担日常工作的云执行环境） + Codex + Antigravity + WorkBuddy 桌面。这四个是明确应测试的独立客户端，**每个都必须在自身的执行会话中验收**。不因为服务端已经通过 Apple CRUD 就宣布客户侧接通。
- **第二批 P1**：WorkBuddy 云端任务、Vela 微信侧、符合账号权限的 ChatGPT/Work，。先核查是否原生 MCP/OAuth；不确定则标 BLOCKED/TO VERIFY，不预装不明桥接。
- **后续 P2**：Muse Code（只有另行使用时）、首尔常驻业务 Agent（只有真正需要无人值守客户经营时）。与 MUSE 现有每天09:00任务**不复建调度**，不将已有工作流迁移到首尔。
- **不作为独立必接目标**：Pixel Android 执行器、Tailscale、首尔 SSH/恢复插件、GitHub Actions、单纯定时器/数据库。除非它们自身运行独立决策 Agent；不能按机器数机械分配 MCP 身份。

## 4. 不改变的共识与轻量验收

- 所有**已获授权**的 Agent 均获得完整 Contacts **search/read/create/update/delete**；目前**无需按读/写角色做 RBAC**。不同 Access Key 只是管理、撤销方便，不能被解释成不同业务功能权限。
- 联系人身份来源是 iCloud CardDAV；生日可从联系人属性获得。保单到期日、已缴保费、活动报名状态等不能由联系人本身推出，需要来自对应已授权业务数据源。
- 任意客户端至少验收：联网 health → OAuth/DCR/PKCE → `tools/list` → `apple_accounts` → `apple_login` → `contacts_search`（不暴露数据内容）→ `work_done`。只有 UI 配置文件存在而无真实工具调用，**状态仍为 BLOCKED**。
- 已完成的 Antigravity 服务器级虚构联系人 CRUD 和容器重启验收不重跑；必要时只对**新增客户端自己的写路径**做唯一虚构联系人实验，清理后 0 残留。禁止为了覆盖矩阵而对每个客户端反复写联系人。
- 尽量使用现有 Access Key；Codex/Antigravity 已发放专属 Key，**不得重复生成和覆盖**。MUSE/WorkBuddy 等新增目标需在合法可用的管理会话中创建 Key 或按其平台允许的认证方式接入；不可把服务器 ADMIN_PASSWORD_HASH、Apple 专用密码当 MCP OAuth Access Key。
- 不能把凭据/生产客户数据放入公开 GitHub，即便用户允许在私有安全通道传递完整凭据。
- 当前服务 `ALLOW_CONTACTS_READ_1=true`、`ALLOW_CONTACTS_WRITE_1=true`；邮件、日历、提醒事项关闭。Render pilot 仍保留回退。

## 5. 厂商资料与条件验证（2026-10-31）

- **MUSE 个人 Agent 云 VM**：Meta 官方 <https://ai.meta.com/muse/> 、<https://about.fb.com/news/2026/09/introducing-muse-personal-ai-agent/>；是持久个人云机，并不自动等于 Muse Code。
- **Muse Code MCP**：Meta 官方 <https://dev.meta.ai/docs/muse-code/extending>；支持 `streamable_http`。Muse 个人自定义 Connector 实际可否直接使用现有 MCP 的 DCR/PKCE，需测试；非官方案例：<https://www.cdata.com/kb/tech/mode-cloud-muse.rst>、<https://parallel.ai/articles/meta-muse-custom-integrations>。
- **Codex 官方 MCP**：<https://learn.chatgpt.com/docs/extend/mcp>、<https://learn.chatgpt.com/docs/cli/reference>；支持 HTTP MCP 和 `codex mcp login`。
- **Antigravity 官方 MCP**：<https://antigravity.google/docs/mcp>；全局 `~/.gemini/config/mcp_config.json`，项目 `.agents/mcp_config.json`，远程用 `serverUrl`，IDE 从 `View raw config` 进入并 Authenticate。
- **WorkBuddy 官方 MCP**：<https://www.workbuddy.ai/docs/zh/workbuddy/From-Beginner-to-Expert-Guide/Function-Description/MCP-Guide>、<https://open.workbuddy.cn/docs/connector>；有用户/项目配置和 OAuth+PKCE，但云端任务个人凭据复用仍需实际单测。
- **ChatGPT 官方自建 MCP**：<https://help.openai.com/en/articles/12584461-connecting-custom-mcp-servers-in-chatgpt>；完整 read/write MCP 目前限 Business 和 Enterprise/Edu web。

## 6. 接续工作包

| ID | 具体任务 | 完成凭据 |
| --- | --- | --- |
| AG-01 | 在**现有 MUSE 云端会话**尝试创建/使用 CardDAV 自定义 Connector；读取 tools 和唯一不存在标签 0 匹配，确认会话可持续并不影响每日调度 | MUSE 自身工具回执、持久性说明、BLOCKED 原因（若失败） |
| AG-02 | 恢复 Codex OAuth 页面并使用现有 Key 完成回调；重新打开实际 Codex 会话查询工具 | Codex tool list、apple_login/search 回执 |
| AG-03 | 确认 Antigravity IDE 实际 MCP 配置路径、刷新加载和 Authenticate；不重复另建 Key | Antigravity IDE tool list、apple_login/search 回执 |
| AG-04 | 在 WorkBuddy 桌面本地用户级 MCP 配置远程服务，OAuth 登录并查工具；不覆盖已有 mcp.json | WorkBuddy 本机 tool list、apple_login/search 回执 |
| AG-05 | 在 WorkBuddy 独立云任务实测 MCP 可达、是否能 OAuth/持久 Token | 云任务本身回执，不使用桌面成功代替 |
| AG-06 | 核实 Vela 的运行宿主和自定义 MCP 接口；使用已有配置能力连接，不虚构支持 | Vela 工具回执或有依据的限制 |
| AG-07 | 按实际账号权限验证 ChatGPT 自定义 MCP；不能使用时标记平台 BLOCKED 并保留已有 iCloud 插件能力 | ChatGPT 本体工具发现/限制回执 |
| AG-08 | **TGT 暂停**：用户于 2026-10-31 明确要求忽略，不调查名称、不配置、不计入本批验收 | PAUSED_BY_USER |
| AG-09 | 当真实业务需要时，复用 [CardDAV 客户跟进 MVP](carddav-customer-followup-mvp-2026-10-31.md) 接入回访/邀约，不自动创建第二定时器 | 用唯一虚构数据/获授权任务验证，状态与业务结果分开 |

**约束**：先按上表逐 Agent 的真实环境验收。用户明确希望云端工作不依赖 Mac 常驻。改变 MUSE 现有 forest 09:00 任务、构建新调度、真实客户批量变更均不是本轮内容。


## 7. 2026-10-31 真正开始接入后的补充（以此节覆盖历史“待发 Key”信息）

- **MUSE 个人云 Agent：** 可直接转交 [原云端会话执行说明](agent-onboarding/muse-personal-carddav-execution-2026-10-31.md)。此处**没有 Muse 已连接客户端**可调用，不能把 GitHub 文件创建当作 MUSE OAuth 完成；必须由 MUSE 自身执行网络、OAuth 和 tools/list 才能升级状态。Meta Muse 个人 VM 与 Muse Code 终端工具分开。
- **WorkBuddy 桌面：** 提供 [可重复运行的本地配置助手](../scripts/agent-onboarding/workbuddy_carddav.py)，它只会合并 `~/.workbuddy/mcp.json` 的远程服务条目，默认 dry-run，显式 `--apply` 才落盘，先备份现有配置；配套 [6 项测试](../tests/agent-onboarding/test_workbuddy_carddav.py)。**这不是 WorkBuddy UI 授权回执。**
- **已有 Codex / Antigravity：** 当前首尔 Auth Store 中已有独立 Key，不重复生成；本地 UI OAuth 与 MCP tools/list 仍待获取自身回执，见 [Issue #6](https://github.com/gehbfarr5/insurance-autonomous-work-system/issues/6#issuecomment-6527350475)。
- **历史其他工具：** 以前讨论/使用过 Antigravity CLI(`agy`)、Gemini CLI，以及 OpenClaw 的方案评估。这些不等于保险项目现阶段有独立常驻实例，也不作为首批必接。必要时后续单独确认是否与现有桌面 Agent 共享配置。
- **TGT：** 按用户最新要求明确为 `PAUSED_BY_USER`，不再调查、询问或部署。
