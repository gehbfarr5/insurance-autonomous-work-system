# 功能、部署与 Agent 完成度总账

> 审计日期 2026-11-07。**历史 PASS 只对应当时特定版本、执行者、范围**。下述状态不表示本次访问了生产环境。
>
> 标签：`HISTORICAL_PASS`、`PARTIAL`、`BLOCKED`、`UNVERIFIED_CURRENT`、`DESIGN_ONLY`、`OUT_OF_SCOPE`。

## 1. 基础设施与数据源

| 子系统 | 已做到 | 未完成与证据层级 |
| --- | --- | --- |
| Seoul 自建 MCP | 历史 Streamable HTTP、OAuth 2.1/DCR/PKCE、登录、服务健康和重启后回归。历史有 25→33 工具注册记录。 | **当前**运行服务对应的 commit、运行中 `tools/list`、实际容器配置/写闸未经此次独立验证；旧报告不等于当前状态。 |
| Contacts / CardDAV | 虚构联系人的 create/read/update/delete/清理与重启回归：Antigravity 现场回执、Issue #4 中有历史记录。 | MUSE 对任何特定真实客户的每次写入仍需对象匹配及业务授权；不能把测试对象通过当成客户经营闭环完成。 |
| Contacts Groups / CardDAV | 8 项分组工具扩展，历史首尔部署和独立客户端范围内回执；电话数字子串错误召回已在生产历史回执中修复。 | MUSE/Antigravity/WorkBuddy/Vela 的分组覆盖不同；Codex 新版 33 项工具独立回执不完整；当前运行版本与导出原始日志仍需核查。 |
| Calendar / CalDAV | `calendar_list`、`calendar_list_events`、create/update/delete 历史虚构对象全流程；用户后续提供 Calendar ETag 服务端完成报告。 | ETag 改造最终 GitHub 提交/首尔当前镜像/MUSE 当前 update CAS 功能未串成可审计版本链；需重新核对，不重复真实写操作补证明。 |
| Reminders / legacy CalDAV VTODO | `reminders_lists/list/create/update/delete` 在**旧可见的 CalDAV VTODO** 上有历史虚构 CRUD 回执；显式 VTODO 补丁由 PR #15 归档。 | 新版 iCloud Reminders 的目标列表未可靠暴露于旧 CalDAV。历史 VTODO PASS **不等于**升级版提醒事项支持。旧通道不能被默认视作新需求的 fallback。 |
| ChatGPT 自建 MCP 接入 | Chat 与 Work Cloud 共用 Sites 插件，虚构 `demo_contacts_groups_list` 各有真实工具调用报告。 | 真实 `icloud_contacts_groups_list` 失败，Sites v2 托管源码 checkout 受代理阻断，项目 `PARKED`；Work Local 未成功确立真实环境。 |

参考：[Issue #4](https://github.com/gehbfarr5/insurance-autonomous-work-system/issues/4)、[Issue #6](https://github.com/gehbfarr5/insurance-autonomous-work-system/issues/6)、[Issue #13](https://github.com/gehbfarr5/insurance-autonomous-work-system/issues/13)、[历史主交接](../icloud-mcp-master-handover-2026-11-02.md)。

## 2. A4 升级版 Reminders 专项：按能力拆开

| 步骤 | 历史或当前材料 | 本次盘点裁决 |
| --- | --- | --- |
| 协议限制确认 | Mac 原生 EventKit 可发现新版列表；旧 CalDAV VTODO 数据不等价 | `HISTORICAL_PASS`：问题根因与替代架构方向明确 |
| M5 Pro EventKit 原生读取 | Mac Agent 报告实际 TCC 授权及列表读取，早期缺少跨 Agent 独立证据 | `PARTIAL`：仅本机历史证据，不能代替 MUSE |
| M5 Pro HTTP Bridge | Mac Agent 报告本地 8/8 与健康检查，历史首尔网络链路 TCP/HTTP 打通 | `PARTIAL`：可达 ≠ 当前升级版提醒事项数据读取验收 |
| Bridge 旧 Token 正向鉴权 | Phase 2.5S 从 MUSE 旧会话记录恢复 200/401/403/404 等只读历史结果；随后 Bridge Token 已轮换 | `HISTORICAL_PASS`（旧 Token、旧时点）；对轮换后版本 **NOT VERIFIED** |
| Seoul rev3 适配 | 离线 rev3 补丁、TypeScript/Reminders 专项测试、写闸审计有阶段报告 | `OFFLINE_ONLY`：未部署生产，不能当作 MUSE 的 MCP E2E |
| E2 精确列表 ID、metadata-only 与来源验证 | R3 隔离候选编译/签名，R4A 审查发现在允许列表状态下仍查询提醒数量、内容读取未强制核对 iCloud 来源；R4A 受 Codex 工作区写权限阻断 | `BLOCKED`：修复/再构建/完整安装与实际验收未完成 |
| MacServer EventKit | Antigravity 可 SSH 到独立常驻 Intel MacServer；Swift、codesign、EventKit 链接/Mock 前提 PASS | `PARTIAL`：真实 `EKEventStore`、TCC、同步、Bridge、锁屏/重启恢复 **未验证** |
| PyiCloud Linux | 隔离 Python 环境能安装依赖并通过 Mock 模型/读接口形状测试 | `PARTIAL`：真实账号、CloudKit 响应、认证与 CRUD **未验证** |
| MUSE iOS 前台连接器 | 人工前台兜底作为方案保留 | `DESIGN_ONLY`：未发现可复核的实际 iOS Reminders 连接器调用 |
| MUSE → Seoul MCP → 新版 EventKit Reminders | 无部署后由 MUSE 真实读取的完整原始回执 | **`A4_MCP_READ_PASS = BLOCKED`** |
| M5 Pro 实验退役 | 用户决定退出生产链路，清理实验 Bridge/MUSE 路由 | `PLANNED`：尚未安全回退；不得以杀进程/删除 app 代替服务管理器检查及可恢复归档 |

**当前架构不是 Linux 模拟 macOS EventKit。** 现有 A4 在 Mac 上执行 EventKit，Seoul 只做适配。未来 PyiCloud 候选是在 Linux 以非官方 iCloud 云端接口直连；是否合格取决于独立功能与持续性验收。

## 3. 多 Agent 接入能力对照

| Agent/运行面 | 历史已证实或有回执的范围 | 现在仍不能推断 |
| --- | --- | --- |
| MUSE 个人云 Agent | Contacts/Groups 多轮创建、修改、删除和回读的用户交付；此前 OAuth/SDK Bridge 连接记录 | Antigravity **无法从当前通道实际调用 MUSE Agent**；最新 `tools/list` 和新版 Reminders E2E 未验 |
| Antigravity（M5 Pro） | 真机 macOS Shell、获授权目录读写、MacServer SSH、EventKit 编译、Seoul 只读管理基础；历史 MCP 全功能回执 | Seoul 生产部署权限、MUSE 自动调用能力、MacServer 真实 TCC 并未因上述成功而自动获得 |
| WorkBuddy Desktop | 已连接，Contacts/分组和 Calendar/Reminders 只读回归不同范围 PASS | WorkBuddy Cloud 没有相同程度的独立验收 |
| Vela/Hermes | 旧阶段原生 MCP、33 工具发现、8 分组及测试数据回读有用户回执 | 当前服务器和其客户端工具集合未在本轮实时复核 |
| Codex CLI/Desktop | 旧 25 工具、OAuth、Contacts/Calendar/Reminders 只读回执 | 33 工具/8 分组最新版完整验收不足；A4 隔离工作区授权问题导致 R4 未完成 |
| ChatGPT Chat / Work Cloud | Sites MCP 虚构分组工具分别真实调用 | 真实 iCloud 分组桥接失败，不能记为生产接入；Work Local 不可确证 |
| MUSE iOS | 作为人工前台兜底的目标角色 | 连接器是否实际提供 EventKit 操作、前台执行与回传结果均未验证 |

**Antigravity 工程主控裁决：`AG_CONTROLLER_WITH_EXTERNAL_ACCEPTANCE`**。MUSE 最终必须在自己的会话中独立执行受限的真正调用；MacServer/Seoul 管理连接不等于 MUSE Agent 任务入口。

## 4. 与原目标相关但独立的扩展

- **联系人→客户经营跟进**：已有 CardDAV 客户跟进适配器及工作包，历史 PR #10 merged；仅证明特定适配器及离线验收，不意味着真实客户跟进、预约、提醒组成完整自动闭环。
- **客户卡片 OCR → Contacts**：WP11 代码/安全候选分支、[PR #17](https://github.com/gehbfarr5/insurance-autonomous-work-system/pull/17) OPEN，离线单测与 MUSE 拒绝/人工复核记录；不得记为已经部署或已获生产批准。
- **灾备**：Seoul 同盘受保护归档和隔离恢复有历史记录；**异地密钥隔离、不同主机恢复未 PASS**，[Issue #7](https://github.com/gehbfarr5/insurance-autonomous-work-system/issues/7) OPEN。
- **Mail / Notes**：不属于原三项核心功能的完成度；Mail 特定账户条件未满足，Notes 上游未支持。

## 5. 最终用户体验目标（尚未实现）

`MUSE → Seoul MCP Reminders Gateway → [合格的 PyiCloud / MacServer EventKit / 经确认的 iOS 前台执行器] → 同一 iCloud 数据源`。

- PyiCloud 通过完整测试后优先主力；未通过时 MacServer 主力。
- iOS 仅作为需要用户前台保持在线、单独验证过实际连接器的人工兜底。
- 读取可在合规健康/新鲜度范围内切换；写入一旦已发送且结果 UNKNOWN，**禁止自动跨后端重试**。
- 同一业务操作应由统一授权、对象映射、操作账本和写入拒绝/审批机制约束；不得凭名称模糊匹配跨后端对象。
- 生产操作、Token、Apple 数据、MUSE 真实 MCP 调用均需独立 Gate B/C 授权；本次 GitHub 归档不改变权限。
