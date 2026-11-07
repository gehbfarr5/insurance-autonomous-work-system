# GitHub 版本核对与后续归档计划

> 基线日期：2026-11-07。**本次 GitHub 动作为文档审计分支 / 待审 PR，不修改生产运行代码或服务。**
>
> 本仓库为 **public**。所有上传都必须遵守严格数据最小化：不提交 Apple 账号/邮箱、真实客户名单、完整生产日志、授权头、Token、密码、Cookie、带凭据的环境配置、生产快照或密钥备份。来源不明、未经脱敏/核对的 ZIP 不可直接 git add。

## 1. 核对结果

| 项 | GitHub 事实 | 含义 |
| --- | --- | --- |
| 主仓库 | [gehbfarr5/insurance-autonomous-work-system](https://github.com/gehbfarr5/insurance-autonomous-work-system)，public，`main` | 原目标的业务与集成归档应以此为主，不混入上游源码仓库 |
| `main` HEAD（本次查证） | `8b765b83c21a7cf291b0feac148fe4c8ea0cb0dc`，2026-11-04 11:48:26 UTC | 11/05–11/07 的 A4/新架构记录未反映在此主分支 HEAD |
| 上游 | [MrZhongzq/apple-icloud-mcp](https://github.com/MrZhongzq/apple-icloud-mcp)，`master` | 独立仓库；不可把它、Seoul 脏工作树和运行容器当作同一个版本 |
| 联系人与分组 | PR #14 merged，另有历史 agent/client/权限分支、Issue #4/#6 open | 原先可复用的能力已经有部分代码/文档归档；应按真实生产补丁与提交重新对齐 |
| 日历和旧 VTODO | PR #15 merged，Issue #13 open | VTODO 修复补丁已入 GitHub；原始 E2E 脚本与最新 Calendar ETag 生产来源仍待归档 |
| WorkBuddy | PR #16 merged | 不需要以未合并为由重复开发此已合并支线 |
| OCR 扩展 | PR #17 open，WP11 隔离候选 | 不得算成联系人生产 OCR 已上线或自动合并 |
| 灾备 | Issue #7 open | 仅本地受保护备份的历史证据，不代表异地恢复 PASS |

参考已有归档：
- [2026-11-02 iCloud MCP 总交接](../icloud-mcp-master-handover-2026-11-02.md)
- [2026-11-01 Agent 连接台账](../icloud-mcp-agent-connection-status-2026-11-01.md)
- [2026-10-31 CalDAV VTODO hotfix](../icloud-caldav-vtodo-production-hotfix-2026-10-31.md)
- [2026-11-01 ChatGPT Sites 桥接诊断](../chatgpt-sites-icloud-production-bridge-2026-11-01.md)
- [本次能力总账](./capability-inventory.md)
- [本次阻断总账](./blockers-and-risks.md)

## 2. 真正需要 GitHub 版本化的项目对象

| 版本化对象 | 目前状态 | 接下来放入 GitHub 的条件 |
| --- | --- | --- |
| A. 功能总账与阻断总账 | **本次新建的审计文档** | 脱敏、标注证据等级、经 PR 审核合并 |
| B. 联系人/分组的生产补丁 | 历史 PR 部分已合并；Seoul 当前源码未与 GH 重新绑定 | 对具体文件构建“原始 commit → 本地 diff → 运行镜像”的映射后，保留所有独立业务改动再建立源码 PR |
| C. Calendar ETag 改造 | 有用户提供的服务端完成报告；**不能凭报告断言已推 GitHub 或 current HEAD 含补丁** | 获取实际原始 diff、测试、生产 build/image 标识；敏感审计清理后单独归档 |
| D. legacy VTODO 修复 | PR #15 merged | 不重传相同补丁；只登记已合并版本与新方案中“不作升级版 Reminders fallback”的限制 |
| E. M5 A4 EventKit/Bridge/E2 补丁及构建 | 多份本地报告、rev3/R3 候选、签名/哈希；未完成 R4 metadata-only 与来源约束 | 将**可复现源码补丁和安全测试**放独立评审分支；二进制/签名/凭据配置不要直接复制到公开仓库；测试记录必须脱敏与版本精确一致 |
| F. MacServer EventKit | 仅 MacServer SSH/编译冒烟 | 未来开发实施可版本化；现在不能发布“已运行”的部署脚本/验收报告 |
| G. PyiCloud | 已有一个 Mock 代码/结果文件，但此前证据包曾未在清单中覆盖 | 在独立隔离目录验证来源/许可证与脱敏后，按真实 Mock 能力提交；不加入 Apple 会话文件 |
| H. Seoul Reminders Gateway / 后端路由 | 仅架构决策，服务端 E2 第二道检查缺失 | 新的隔离开发分支、Fake/fixture 测试、写保护、安全审查；不得直接推生产工作树 |
| I. MUSE Agent 操作/验收 | 历史联系人成功回执、新提醒 E2E 被阻断；不能由 Antigravity 直接调用 MUSE | 可入库独立测试协议与脱敏回执，不上传真实 Agent 对话、客户内容或 Token |
| J. iOS 前台兜底 | 设计，无已验证连接器 | 仅归档研究与能力探针设计，不写为已上线 |
| K. GitHub/本机证据快照 | 多轮审计包有哈希/日志缺口，可能包含敏感环境标识 | 公开仓库只存脱敏 manifest、内容类型、时间、完整校验值、证据所在地的非敏感代号；私有快照留在受控介质 |

## 3. 版本标识必须分层记录

对于每个可执行组件，未来版本表至少有以下字段：

- `component` / `environment` / `execution_host_type`
- `source_repository` / `branch` / `base_commit`
- `patch_ids`、补丁 SHA256、补丁应用后的工作树提交
- `built_artifact_digest`、`deployed_image_digest`、配置 schema 版本
- `observed_at`、`observer`、`evidence_kind`（原始日志/工具返回/用户报告）
- `capabilities_tested`、`tests_passed`、`tests_not_run`
- `writes_enabled` 的**允许字段级结果**（只记录 SET_TRUE/SET_FALSE/UNSET/INVALID/UNVERIFIED，不记录完整 env）
- 回滚依赖、停止条件、授权记录与 GitHub PR/Issue

尤其需要一份 **Seoul 源码目录现存改动（历史 15 modified + 6 untracked）→ 对应主仓/上游 commit → 实际运行镜像** 的差异清单。未确认前不重置生产工作树，也不把它整个复制到公开 GitHub。

## 4. 建议 Git 工作流

1. **本次**：独立 `audit/muse-icloud-master-inventory-20261107` 分支，仅提交审计文档；开启 **draft PR**，先审阅、不合并。
2. **下一批**：由 M5 Pro Antigravity 在用户另行授权的正确本机工程工作区逐文件盘点本地源码/补丁/日志，建立带 SHA256 的非敏感 manifest；不需要为了归档而重跑生产写入。
3. **Seoul 差异归档**：先保存现场精确快照和差异、确定私有配置剔除范围；再通过独立源码 PR，不覆盖 Calendar/Contacts 的已运行改动。
4. **EventKit/MacServer/PyiCloud**：分别使用 feature branches，实验报告只描述实际证据，Mock 与生产能力不混记；源码可公开性需先审查。
5. **PR 合并规则**：只有代码评审与脱敏检查完成后合并文档/源码；**GitHub merge 不代表生产部署**；每次真实部署还需单独授权。

## 5. 归档后状态（不会自动变更）

- `AG_CONTROLLER_WITH_EXTERNAL_ACCEPTANCE` 保留。
- `ENGINEERING_HANDOFF_BLOCKED` 保留；Gate A 材料准入仍 BLOCKED，Gate B 未授权，Gate C 未完成。
- `A4_MCP_READ_PASS = BLOCKED` 保留。
- `PYICLOUD_BACKEND = MOCK_ONLY`；`MACSERVER_EVENTKIT = COMPILE_SMOKE_ONLY`；`IOS_FALLBACK = UNVERIFIED`。
- 历史 `33` 项是注册和旧工具发现记录，**不是** 2026-11-07 的运行时重新验收。
- 此次 GitHub 文档上传不改变任何真实 iCloud、OAuth、生产 MCP、Tailscale 或 M5 Bridge 状态。

**本次阶段收尾标准**：已经公开安全归档总账并给出 GitHub 的可核查分支/PR 记录；只有在完成盘点后才讨论新会话的交接形式。
