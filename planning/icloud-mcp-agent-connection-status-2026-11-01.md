# iCloud MCP 多 Agent 接入与验收台账（2026-11-01）

> **当前状态记录；不是凭据清单，也不是“所有 Agent 均已验收”的结项声明。** 基于用户提供的 MUSE / WorkBuddy / Vela / Antigravity 执行回执、[Issue #6 的 Codex 真实 CLI 验收记录](https://github.com/gehbfarr5/insurance-autonomous-work-system/issues/6)、以及 2026-11-01 12:54（UTC+8）对首尔生产容器的独立只读健康核验。历史阶段说明保留在各 Issue 评论里，以本页日期和证据级别判断最新接入状态。

## 概况

- **已完成某个版本的自建 iCloud MCP 接入：5 个独立 Agent**：MUSE 个人云 Agent、Antigravity、WorkBuddy Desktop、Vela/Hermes、Codex CLI/Desktop。
- **新版分组功能已获独立客户端验收：4 个**：MUSE、Antigravity、WorkBuddy Desktop、Vela/Hermes。各自测试的覆盖范围不完全相同，不等于都完成了 Calendar/Reminders 全功能写入回归。
- **Codex 已连通，但新版 33 工具尚待单独复验**：2026-10-31 的真实 Codex CLI 回执是 25 项旧版工具、OAuth、Apple login、联系人无命中搜索、Calendar/Reminders 只读、重开持久性 PASS；不可据此认定新版 8 项分组工具已在 Codex 客户端加载。
- **仍未确认自建 MCP 完整接入**：ChatGPT Work；WorkBuddy 云端任务（不同于 Desktop）。
- 不是独立待接入 Agent：TGT（用户暂停）、Muse Code（区别于 MUSE 个人 Agent，按需）、Pixel 3a（执行器设备）。

## Agent 逐项台账

| Agent / 实际环境 | 接入状态 | 新版 8 分组工具 | 已有验收范围与局限 | 依据 |
| --- | --- | --- | --- | --- |
| **MUSE 个人云 Agent**（Meta Muse 持久 VM） | **CONNECTED / PASS** | **PASS** | 经持久 VM SDK Bridge 使用同一远程 MCP；用户报告多轮创建联系人、电话/备注修改、分组增删改与端到端回读通过。不可把 Muse Code 当成此 Agent。 | 用户 2026-10-31 最新交付；[#6 MUSE 原有 OAuth 回执](https://github.com/gehbfarr5/insurance-autonomous-work-system/issues/6#issuecomment-6539495029) |
| **Antigravity**（Mac 本地 Agent） | **CONNECTED / FULL PASS** | **PASS** | 用户报告：生产 OAuth、33 工具、联系人分组、数字搜索修复、Calendar/Reminders 真实 CRUD 与并发规范全量验收通过。 | 用户 2026-11-01 前最终验收结论；[#13 历史 CalDAV 证据](https://github.com/gehbfarr5/insurance-autonomous-work-system/issues/13) |
| **WorkBuddy Desktop**（本地桌面应用） | **CONNECTED / PASS** | **PASS** | 用户交付：原生连接及 Skill 生效、联系人 create/update、三态字段、ETag 冲突、分组复合创建预检；Calendar/Reminders 本轮仅做只读回归，桌面云任务另算。发现的数字误匹配已在服务端修复。 | 用户 2026-10-31 WorkBuddy 交付；[#6 早期接入回执](https://github.com/gehbfarr5/insurance-autonomous-work-system/issues/6#issuecomment-6540096929) |
| **Vela / Hermes Agent**（新加坡独立云 VM） | **CONNECTED / PASS** | **8/8 工具发现、分组 E2E PASS** | Hermes 原生 MCP + 复用 OAuth；用户报告 33 项工具发现、分组与成员真实 CRUD、测试对象清理及 Contacts/Calendar/Reminders 只读回归 PASS。**成员重复添加幂等性未单独执行**。 | 用户 2026-10-31 Vela 最终报告；[#6 历史初期阻塞](https://github.com/gehbfarr5/insurance-autonomous-work-system/issues/6#issuecomment-6540581502) |
| **Codex CLI/Desktop**（Mac 宿主 CLI） | **CONNECTED / OLD VERSION PASS** | **新版 33 工具未验收** | 真实 Codex CLI 已完成 OAuth、**旧版 25 工具**、apple_login、Contacts/Calendar/Reminders 只读及跨新会话持久性 PASS；此前 Codex 任务沙箱网络阻塞已由宿主 CLI 路径绕开。需要在新版服务下重新 tools/list 和最小只读工具调用。 | [#6 Codex 完整 PASS 回执](https://github.com/gehbfarr5/insurance-autonomous-work-system/issues/6#issuecomment-6540230339) |
| **ChatGPT Work** | **NOT VERIFIED** | **NOT TESTED** | 未证实当前 Work 账号/空间可创建并真实调用此自定义 MCP；不能以 WorkBuddy、已有 iCloud Calendar 插件或服务器 Healthy 替代 Work 的独立 OAuth/tools/list 验收。 | [#6](https://github.com/gehbfarr5/insurance-autonomous-work-system/issues/6) |
| **WorkBuddy 云端任务** | **NOT TESTED** | **NOT TESTED** | 云端执行环境与 Desktop 不同；授权持久性、独立沙箱联网和实际工具调用需要另测。 | [#6](https://github.com/gehbfarr5/insurance-autonomous-work-system/issues/6) |

**状态定义**：
- CONNECTED：有该 Agent 自身连接/OAuth/真实工具调用成功的证据；不等于全功能回归。
- PASS：在其声明的验收范围内通过；局限需保留。
- FULL PASS：本次仅用于 Antigravity 提交的完整端到端验收结论。
- OLD VERSION PASS：已接通旧版服务，但不自动升级为 33 工具版本 PASS。
- NOT VERIFIED / NOT TESTED：尚无独立有效证据，不能算完成。

## 生产服务与功能基线

- 统一目标：首尔 `apple-icloud-mcp` 自建服务，Streamable HTTP + OAuth；各 Agent 使用同一 Apple 联系人、日历与提醒事项源，未建立各自分叉的通讯录。
- 生产工具注册：**33 项**（历史 25 项 + 新增 8 项原生 Contacts Groups 工具）；启用联系人、日历和提醒事项读写；Mail 仍按服务端能力约束保持禁用。**工具可见不等于每一个模块均已由每个 Agent 独立验收。**
- 2026-11-01 12:54（UTC+8）服务器只读复核：本机 `/health` 返回 `{"status":"ok"}`，Docker 容器 `running/healthy`，分组源码注册 8 项，生产运行版包含 `MIN_PHONE_SEARCH_DIGITS` 搜索修复。
- `contacts_search` 原有“qz2 被数字 2 电话子串误召回”已由生产搜索逻辑修复；正式写入客户分组前仍必须核对匹配对象身份，避免仅靠模糊搜索结果决策。
- **安全约束**：各 Agent 共享授权业务能力，但应保留 Agent 级凭据审计；不得在公开仓库记录 Access Key、OAuth token、Apple 应用密码、真实客户资料、通讯录导出、完整凭据库路径或测试会话 ID。

## 尚待完成与推荐顺序

1. **Codex 新版核验（优先）**：复用当前 OAuth，不重建 Key；在真实宿主 Codex CLI 运行 `tools/list` 确认 33 项、8 个分组工具，执行 `contacts_groups_list` 和无命中随机标签查询（只读），必要时重载会话；形成脱敏回执。
2. **ChatGPT Work 自定义 MCP 能力与接入**：先验证账号/工作空间是否允许实际接入自建 MCP；如果不支持，明确 BLOCKED，而不是以浏览器健康检查判定通过。
3. **WorkBuddy 云端任务**：只有要在云端运行时才独立验收；不能复用 Desktop PASS 标签。
4. **统一治理**：对现有 Key 做归属与最后使用时间登记（在**私有安全台账**，公开 GitHub 只写是否具备独立撤销能力）；不因整理账目轮换运行中的密钥。
5. **业务闭环**：联系人唯一匹配→可核验跟进任务→日历/提醒事项，不把技术接入完成等同于保险客户工作流完工。避免触发 MUSE 既有自动化。

## 2026-11-01 ChatGPT 插件与运行面后续排查

**阶段性证据（不是 ChatGPT MCP 通过）**：

- 个人私有插件 `insurance-icloud-mcp` 有两份，同指向 `https://seoul-forge-01.tail4db0d9.ts.net/mcp`：v0.1.0（ID `plugins_6ae5971b69288191b59eaf6104a020a4`）、v1.0.0（ID `plugins_6ae596f08e6881919af6862a64092566`）。通过当前 Plugin Creator 读取其实际 `plugin.json`、`mcp.json`、`.codex-plugin/plugin.json`、`.mcp.json`。
- 两份均为 `streamable-http` + `OAuth DCR`，均声明了远程 MCP，均**未设置显式 `requires_local_executor: true`**。用户在网页插件目录发现两者均被标记「仅限桌面端」；官方插件文档说明，导入包声明 `mcp.json/.mcp.json` 时即使远程 HTTPS 也可能被分类为 Desktop only。这是插件包/运行面限制，**不等于服务器只能本地联网**。
- 用户报告插件已安装；网页 Chat 及「立即试用」会话没有暴露 `contacts_groups_list` 等自建工具（**0 个当前可调用自建工具**）。此时 `CHAT_MCP_NOT_AVAILABLE`，不能把普通 iCloud Calendar 或 Seoul Forge 恢复管理插件的工具算进来。
- 当前未取得 macOS **ChatGPT App / Chat Local / Work Local** 的自建工具实测；**不能把 Codex CLI 成功或网页版失败直接移植到这两种环境的判定**。本轮从 Chat 尝试读取已连接浏览器时返回“Requires originating browser context”，不能远程替代用户本地 App 的 UI 验收。
- 官方帮助文档：[Plugins in ChatGPT](https://help.openai.com/en/articles/20001256-plugins-in-chatgpt)、[Desktop-only plugins](https://developers.openai.com/plugins/deploy/desktop-only)、[Custom MCP availability](https://help.openai.com/en/articles/12584461-connecting-custom-mcp-servers-in-chatgpt)、[Sites-hosted plugin](https://help.openai.com/en/articles/20001547-hosting-a-plugin-with-chatgpt-sites)。
- **下一实测顺序**：Mac 最新 ChatGPT 桌面版 → 先 Chat 的本地执行支持面（如可用）再 Work Local → 指定 v1.0.0 插件，逐一核查可选、可连接、可发现 33 工具、只读 `contacts_groups_list`。不可调用时记录插件列表/权限提示，避免重试已有 OAuth 或创建第三份插件。
- **若桌面端仍失败**：按运行面/账号权限 BLOCKED 结案当前导入型插件方案；另外只做一项独立的 Sites 托管 MCP **只读演示可行性研究**，先虚构数据、验证权限和工具暴露，再研究到已部署首尔服务的安全 OAuth 桥接。不得把 Sites 理解为自动绕过订阅或工作空间 MCP 限制。
- **重复项**：目前建议 B v1.0.0 `KEEP_PRIMARY_CANDIDATE`、A v0.1.0 `DUPLICATE_CANDIDATE`；在安装/授权和依赖影响核对前均**不卸载**，不动首尔 OAuth/Token Store/其他 Agent。
- 用户已反馈 Codex 新版接入完成，但尚无可归档的最新版独立 `tools/list=33` 报告；在收到具体回执前仍保留 OLD VERSION PASS 的证据级别，不自动改写。

## 相关追踪

- [Issue #4：首尔 CardDAV 核心服务](https://github.com/gehbfarr5/insurance-autonomous-work-system/issues/4)
- [Issue #6：多 Agent 接入与客户工作流（保持 OPEN）](https://github.com/gehbfarr5/insurance-autonomous-work-system/issues/6)
- [Issue #13：Calendar / Reminders 扩展](https://github.com/gehbfarr5/insurance-autonomous-work-system/issues/13)

本页为 **2026-11-01 的阶段性接入台账**。状态变更时应附 Agent 自身的工具调用回执，更新时间与证据等级，并在 Issue #6 更新索引；不因服务器单次健康检查擅自将所有 Agent 标记为 PASS。
