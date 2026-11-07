# MUSE × iCloud MCP 全量工程盘点（2026-11-07）

> 状态：**审计盘点 / 非部署许可**。这份文档先于后续跨会话交接，仅记录原始目标、已交付能力、历史回执、当前阻断与 GitHub 归档缺口。**不能作为当前生产状态或操作授权的替代。**
>
> 证据标记：**GH-verified** = 本次从 GitHub API 确认；**historical-report** = 已有报告/旧工单所述（未在本次实时重跑）；**user-handoff** = 2026-11-07 之前用户交接与独立审计裁决；**not-verified** = 当前没有可独立复核的运行时证据；**design-only** = 决策而非已实现能力。

## 0. 原始目标与范围

使 **MUSE** 借由同一个首尔自建 iCloud MCP，安全完成 **联系人（含分组）/ 日历 / 提醒事项** 的发现、读取及经业务授权的新增、修改、删除，并支持其他已授权 Agent 共享同一数据源、各自拥有可审计身份。最终客户业务闭环是“联系人唯一识别 → 日历安排 → 提醒事项跟进 → 业务状态核对”，**不是**只要服务注册了工具就算完成。

项目范围之外：Mail 需独立条件及评估；Notes 不在上游实现范围；客户卡片 OCR 与保险工作流属于相关但独立的扩展工作包。

## 1. 总裁决（分层）

| 目标 | 历史已完成 | 2026-11-07 实际结论 |
| --- | --- | --- |
| 首尔 MCP / OAuth / 统一入口 | 历史核心联通与服务健康 PASS；历史注册工具 25→33 | **生产服务当下版本和动态 tools/list 本轮未验** |
| Contacts CRUD | 历史虚构对象全 CRUD、回读、清理与容器重启回归（Antigravity 回执） | **历史功能 PASS，当前具体生产客户操作不在本轮验收范围** |
| Contacts Groups（8 个工具） | 分组源码/服务端扩展及 MUSE、Antigravity、WorkBuddy、Vela/Hermes 的分范围验收回执 | **历史多客户端 PASS，不能推定每个 Agent 均完成所有 8 项 CRUD** |
| Calendar VEVENT | CalDAV 虚构事件 CRUD 与清理历史通过；后续 ETag 读取改造另有服务端验收报告 | **历史能力 PASS；ETag 是否已推 GitHub、MUSE 当前完整更新路径待核对** |
| 升级后的 iCloud Reminders | 旧 CalDAV VTODO 补丁已归档；A4 MacBook EventKit/HTTP/网络/离线适配分别获得部分证据 | **MUSE→Seoul→新版 Reminders 真实 E2E 未通过；旧 VTODO 不可视为新版列表的可靠通道** |
| MacServer EventKit | 已取得独立 MacServer SSH / Swift / codesign / EventKit 编译冒烟证据 | **未验证真实 EventKit/TCC，未部署新版 Bridge** |
| Seoul Linux PyiCloud | 仅隔离 Mock | **未进行 Apple 登录、真实 CloudKit 解析/CRUD 或持续可靠性验证** |
| MUSE iOS 前台执行器 | 目标方案已明确 | **连接器能力未验证** |
| 开发主控 | Antigravity 可在本机和 MacServer 执行，Seoul 管理 PARTIAL | **AG_CONTROLLER_WITH_EXTERNAL_ACCEPTANCE**；无法独立调度 MUSE Agent，最终验收需由 MUSE 会话触发 |
| 交接安全 | 多轮 R0/R0.1 文档迭代 | **ENGINEERING_HANDOFF_BLOCKED**；Gate A 材料准入 BLOCKED、Gate B 未授权、Gate C 待完成 |

**历史运行成功与当下运行成功必须分开；自述报告与独立原始日志亦必须分开。**

## 2. 项目推进主线

1. **10/30–10/31**：首尔统一 MCP、OAuth/Apple CardDAV 联系人虚构 CRUD、持久化及本地备份；Calendar/Reminders CalDAV 模块开关、VTODO 显式过滤；8 项分组工具。
2. **10/31–11/02**：MUSE/Antigravity/WorkBuddy/Vela/Codex 不同覆盖范围接入；Chat 与 Work Cloud 成功调用同一 Sites 插件的虚构工具，**真实** Site→iCloud 分组调用仍失败；ChatGPT Site 源码恢复受阻并暂停。
3. **11/03–11/05**：客户卡片 WP11 OCR 候选推进但未上线；Calendar ETag 服务端改造有独立报告，不自动代表 GitHub 已同步或 MUSE 端已通过。
4. **11/04–11/07**：确认升级版 Reminders 的旧 CalDAV 局限，探索 M5 Pro A4 EventKit Bridge；首尔→M5 网络端口曾实测可通、Bridge 鉴权旧记录已恢复，随后 Token 轮换、E2 ID 白名单隔离候选；**没有 Seoul rev3 部署，也没有新版 Reminders 的 MUSE E2E PASS**。
5. **11/07**：确立目标架构：**PyiCloud 经充分验证后优先主力；常驻 MacServer EventKit 为主备；iOS 上 MUSE 前台执行器为可选人工兜底；Seoul MCP 统一路由和安全账本。** M5 Pro 只作为工程主控，不作为生产依赖。目标架构是 design-only，不代表这些后端已上线。
6. **11/07**：交接安全审计仍 BLOCKED，已决定先暂停零散 R0.x 修复、进行此次全量盘点和版本归档，然后再讨论新会话交接。

## 3. GitHub 事实基线（本次核对）

- 项目仓库：[`gehbfarr5/insurance-autonomous-work-system`](https://github.com/gehbfarr5/insurance-autonomous-work-system)，**公开**，默认分支 `main`。
- 2026-11-07 核对的 main HEAD：`8b765b83c21a7cf291b0feac148fe4c8ea0cb0dc`，提交时间 **2026-11-04T11:48:26Z**，之后的 Reminders 架构讨论不在 main 的历史 HEAD 中。
- [PR #14](https://github.com/gehbfarr5/insurance-autonomous-work-system/pull/14) 多模块说明、[PR #15](https://github.com/gehbfarr5/insurance-autonomous-work-system/pull/15) VTODO 修复、[PR #16](https://github.com/gehbfarr5/insurance-autonomous-work-system/pull/16) WorkBuddy 连接修复均为 **merged**；[PR #17](https://github.com/gehbfarr5/insurance-autonomous-work-system/pull/17) WP11 OCR 候选 **open，未合并**。
- [Issue #4](https://github.com/gehbfarr5/insurance-autonomous-work-system/issues/4) Contacts 核心、[Issue #6](https://github.com/gehbfarr5/insurance-autonomous-work-system/issues/6) 多 Agent/ChatGPT、[Issue #7](https://github.com/gehbfarr5/insurance-autonomous-work-system/issues/7) 异地灾备、[Issue #13](https://github.com/gehbfarr5/insurance-autonomous-work-system/issues/13) Calendar/Reminders 历史扩展均为 **open**。
- 首尔上游源项目为 [`MrZhongzq/apple-icloud-mcp`](https://github.com/MrZhongzq/apple-icloud-mcp)；该 upstream 不是本账号可推送的项目归档仓库。GitHub 历史、首尔生产本地源码及运行中镜像不可互相等同。

## 4. 文档索引

- [模块及 Agent 完成度](./capability-inventory.md)
- [阻断与风险总账](./blockers-and-risks.md)
- [GitHub 差异核对、归档/上传计划](./github-reconciliation.md)
- [截至 2026-11-02 的历史主交接](../icloud-mcp-master-handover-2026-11-02.md)
- [历史 Agent 台账](../icloud-mcp-agent-connection-status-2026-11-01.md)

## 5. 本轮边界

仅盘点公开仓库与此前用户提供的审计信息。**本轮未连接 MUSE/MacServer/Seoul 生产主机，未核实实时写闸或 MCP tools/list，未做任何真实 iCloud 操作。** 生产快照、原始凭据、Apple 账号、客户信息、完整敏感日志、运行时可用 Token 都不得上传到此公开仓库。归档分支/PR 不授权部署、回退、重启或自动执行开发。
