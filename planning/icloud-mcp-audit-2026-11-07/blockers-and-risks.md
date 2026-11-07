# 阻断与风险总账（截至 2026-11-07）

> 目的：一次性收拢跨会话卡点，**不是**立即派发逐项修复，也不作为生产变更许可。优先级按“误操作危险 / 阻止原始目标 / 后续技术债”分类。各项当前状态由截至本次可见的用户审计、GitHub 工单与旧回执决定；除 GitHub 本身外，本轮不做 live 运行状态确认。

## A. 阻止最终业务目标的卡点

| ID | 优先级 | 现状 | 需要的证据 / 停止条件 |
| --- | --- | --- | --- |
| A-01 | P0 | **升级版 Reminders 没有 MUSE→Seoul→Apple 的真实读链路 PASS。** 旧 CalDAV VTODO 只说明遗留数据可见。 | 选定后端后，在单独获准的测试对象上记录真实 MUSE MCP 调用、响应、身份与审计；未完成不得标 `A4_MCP_READ_PASS`。 |
| A-02 | P0 | **MacServer 只有 SSH、Swift、codesign / EventKit 链接冒烟**；无真机 TCC/同步/Bridge/恢复证据。 | 经独立授权核验目标用户会话、TCC 和测试账户/列表；不以编译通过代替云端真实访问。 |
| A-03 | P0 | **PyiCloud 只通过 Mock，未证明能读取或安全写入此 iCloud 账户。** | 先离线协议/响应夹具审计，再按独立授权使用隔离测试账号；未满足认证、会话、数据一致性和异常恢复准入前不得升主力。 |
| A-04 | P0 | **iOS 前台执行器未验证。** | 需真实连接器/系统能力证据；不能因 iPhone 安装 MUSE 即假设具备系统 Reminders 写入能力。 |
| A-05 | P0 | **MUSE Agent 当前缺少供 Antigravity 直接派发任务的可靠入口。** | 保留 `AG_CONTROLLER_WITH_EXTERNAL_ACCEPTANCE`；MUSE 用户前台会话独立验收，不能把主机 ping/SSH 充当 Agent 调用。 |

## B. 风险治理、数据安全与生产版本

| ID | 优先级 | 现状 | 强制约束 |
| --- | --- | --- | --- |
| B-01 | P0 | **Seoul 生产工作树历史有 15 modified + 6 untracked**，且后续报告与上游 GitHub HEAD/容器镜像未组成精确版本链。 | 不直接 `git reset --hard`、无范围 `checkout/clean` 或覆盖现场；先获得操作当天的完整文件/镜像/配置快照、变更基线、回滚负责人。 |
| B-02 | P0 | **M5 Pro A4 实验 Bridge 退役尚未安全执行**；服务管理器、自启、Token 和 Tailscale 实验放行有历史记录。 | 先识别真实服务生命周期、启动机制及依赖，归档可恢复的完整签名应用；只按单项授权停用和撤销，不用 `kill` 加 `rm -rf` 代替精确回退。不要重新启用旧 CalDAV 的生产写入。 |
| B-03 | P0 | **写入授权语义跨三后端尚未形成统一可运行保障**；旧账号/配置可能有历史写权限，新版本 rev3 离线双闸不等于生产当前状态。 | 当前写闸状态标 `UNVERIFIED_CURRENT`；不以向生产发 create/update/delete 探测拒绝；只在隔离桩 assert 零下游写入。已发送/UNKNOWN 状态绝不跨后端重试。 |
| B-04 | P0 | **Gate A 交接材料仍 BLOCKED；Gate B 未授权；Gate C 未完成**，R0/R01 修订出现回退精度、安全查询与状态自相矛盾。 | 交接包不能视作生产执行剧本。允许独立规划；“隔离开发”只在确证隔离的环境开展，Seoul 生产主机上的普通目录不天然等于隔离环境。 |
| B-05 | P1 | **运行中 MCP `tools/list` 与源码 33 项历史注册表尚未独立核实一致**；Calendar ETag 源码/镜像/GitHub 同步状态不明确。 | 区分历史 33、静态注册扫描、真实 Seoul MCP 工具发现、真实 MUSE 发现，逐项记录执行环境与时间。 |
| B-06 | P1 | **GitHub `main` 与 11/05–11/07 的本机/Seoul A4、ETag、R0.x 项目材料未同步**，原始 E2E 脚本和多份脱敏日志缺失。 | 仅审查后分类提交源码/测试/脱敏证据；补丁不能凭历史报告自动合入生产分支。 |
| B-07 | P1 | **异地加密备份和异机灾难恢复未通过**；本地或同盘加密备份 ≠ 灾备。 | 参见 [Issue #7](https://github.com/gehbfarr5/insurance-autonomous-work-system/issues/7)；不在 GitHub 上传密钥、完整 Token Store、生产快照。 |
| B-08 | P1 | **多 Agent 接入虽有多个历史 PASS，但凭据治理、客户端版本及运行时动态验收不完整。** | 只发布脱敏名称级/功能级状态；不得展示可定位个人账号、连接 Secret、OAuth 令牌。 |
| B-09 | P1 | **真实客户工作流尚未完整端到端验收**（联系人唯一定位→日历安排→提醒事项跟进）。 | 技术功能成功不等于保险客户操作完成；真实客户行为需单独业务授权与数据最小化。 |

## C. 已有结论、但此刻应冻结的支线

- ChatGPT Sites 的虚构只读工具在普通 Chat/Work Cloud 历史 PASS；**真实** iCloud Site v2 接入失败且源码 Git checkout 受阻，子项目已 `PARKED`。不要把这条支线重新作为 MUSE 原目标的先决条件；见 [Issue #6](https://github.com/gehbfarr5/insurance-autonomous-work-system/issues/6)。
- Codex 的 Mac 本机 E2 修改曾被工作区写入授权拒绝；不把此环境阻断误判为 Swift/EventKit 技术失败。最终工程主控由 Antigravity 担任，MUSE 独立验收。
- WP11 OCR [PR #17](https://github.com/gehbfarr5/insurance-autonomous-work-system/pull/17) 仍 OPEN，不作为联系人/日历/提醒三功能核心已交付范围；其客户样本或 OCR 原始图片不得公开。
- R0/R01 多轮文档补丁不能用一个总称 `READY` 覆盖 Gate A/B/C。暂不再无限追加微型文档任务；这次先完成可追溯总账，再讨论新会话工程实施。

## D. 未来主备切换的关键安全约束（设计，不是上线状态）

1. 后端健康检查只能辅助只读路由，且需验证数据同步的新鲜度。健康 200、可达网络及工具注册不代表 Reminders 读取成功。
2. 写入权限必须遵循统一操作 ID、单次批准、对象身份核对、发送中/已生效/结果不确定账本；后端不同对象 ID 不能直接互换。
3. PyiCloud 为非官方接口路线，须单独评估 Apple 登录凭据、2FA/session 更新、协议变更和 CRDT/字段保真；MacServer EventKit 的成功不证明 PyiCloud 成功。
4. EventKit 应作为 MacServer 常驻用户会话服务；屏幕锁定、系统重启、尚未登录、网络中断与授权撤销必须分别验证。M5 Pro 仅作为开发主控，不列入生产依赖。
5. iOS 仅在原生连接器已证明可调用、前台用户确认并具有操作结果回传能力后，列为人工兜底。不能绕过一次 UNKNOWN 写入的冲突检查。

## E. 解除阻断的证据等级

- `DESIGN_COMPLETE`：方案写清楚，但未实际执行。
- `OFFLINE_PASS`：隔离源码/Mock/构建 PASS。
- `BACKEND_READ_PASS`：已授权真实后端对限定测试数据只读回执 PASS。
- `BACKEND_WRITE_PASS`：独立授权、受控测试账号、去重与回滚完成。
- `MUSE_MCP_E2E_PASS`：MUSE 本体发起，真实 Seoul MCP + 目标后端、回执/时间和写入状态可核验。
- `PRODUCTION_READY`：通过安全、可恢复部署与监控等额外门槛。

**后一级不自动继承前一级；不能从历史 PASS 推断当前生产状态。**
