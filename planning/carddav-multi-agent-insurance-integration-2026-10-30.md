# iCloud CardDAV MCP：云端持续运行与多 Agent / 客户经营集成（2026-10-30）

> 状态：**云端核心功能已由 Antigravity 完成真实 CRUD 验收；用户于 2026-10-30 确认当前采用统一 Agent 权限，不按职责划分读写角色；ChatGPT 实际连接和保险业务工作流仍待验收**。本页为下一批实施基线，不改变 P4/S1 的其他任务与调度。
>
> 证据：[Issue #4 云端验收](https://github.com/gehbfarr5/insurance-autonomous-work-system/issues/4#issuecomment-6525726042)；[原验收脚本](../tests/integrations/carddav/test-carddav-oauth-crud.mjs)。

## 1. 核验来源与结论边界

| 事实 | 依据 | 结论 |
| --- | --- | --- |
| 真实 OAuth + Apple CardDAV 登录、虚构联系人创建/读/改/删/零残留 | Antigravity 的云端执行记录（Issue #4） | **报告通过**；本轮未对生产联系人再次写入 |
| 容器重启后第二轮完整 CRUD 通过 | 同一份 Issue 评论 | **报告通过**；不代表主机重启、磁盘故障或 ChatGPT 接入通过 |
| Seoul Forge 独立容器与 Funnel | 本轮云主机现场只读确认 | `insurance-carddav-mcp-carddav-1` healthy；Funnel 开启；其他业务容器运行 |
| 持久化 Auth Store | 本轮直接在运行容器中使用内存中的加密密钥解密并只输出计数 | 4 个 OAuth 客户端、3 条令牌记录、1 把访问密钥且已启用，.env 账号开关开启；不输出账户或密钥 |
| Token 文件权限 | 本轮云端整改 | 原为 0644；现为 0600，运行时 umask=0077。上游以临时文件原子替换，故需持续保持严格 umask |
| 本机备份 | 本轮云端新增 | 每日 `insurance-carddav-backup.timer`；root-only 归档目录 `/var/backups/insurance-carddav-mcp`，保留约 14 天；已完成隔离解压及离线解密结构检查 |
| 异地备份 / 主机失效恢复 | 尚无支持证据 | **未验收**；当前备份和源数据在同一块云磁盘 |
| ChatGPT 自定义 MCP 实际连接 | 未取得 ChatGPT 连接/工具调用回执 | **未验收**；不能用 curl、Antigravity 或原生 iCloud 连接器的成功代替 |

## 2. 部署拓扑与安全边界

```text
ChatGPT / Codex / Antigravity / 其他获授权 Agent
       │
       │ OAuth + 各 Agent 同等联系人 CRUD 能力（建议分别发 Key 便于撤销；目前仅 1 把）
       ▼
https://seoul-forge-01.tail4db0d9.ts.net/mcp
       │ Tailscale Funnel / HTTPS
       ▼
127.0.0.1:17734
       │ Docker Compose /app/data 持久挂载
       ▼
apple-icloud-mcp  ── CardDAV ── iCloud Contacts
       │
       ├─ /opt/insurance-carddav-mcp/data：加密 OAuth/信封数据
       └─ /var/backups/insurance-carddav-mcp：仅本机 root 可访问归档
```

当前服务监听回环地址；没有改现有 Nginx 或其他容器。Render 旧服务作为回退保留，不得因本机备份成功自动停止。

**实际权限事实：** 上游 Access Key 可分别停用并使对应令牌/会话失效，但 `AccessKeyRecord` 没有工具级 RBAC 字段；`ALLOW_CONTACTS_READ_1=true` 与 `ALLOW_CONTACTS_WRITE_1=true` 授予已认证的 Agent 账号级联系人 CRUD 权限。当前这是符合用户要求的**统一权限**，不要求先实现细粒度权限网关。不同 Key 的用途是凭据轮换、撤销与操作追踪，不是划分读写角色。

## 3. 现阶段决定：所有获授权 Agent 使用统一联系人能力

**2026-10-30 用户确认：** 各个 Agent 的最终架构、职责还在建设，暂不按查询/规划/写入/管理拆成不同身份。所有完成接入授权的 Agent 均可根据任务使用联系人搜索、读取、新建、更新、删除；不再将“先实现强制只读网关”作为上线前置条件。

| 范围 | 本阶段执行方式 |
| --- | --- |
| Agent 权限 | 统一能力，允许 `contacts_search`、`contacts_read`、`contacts_create`、`contacts_update`、`contacts_delete`，以及必要的 `apple_login` / `work_done` |
| 连接方式 | 统一 MCP Endpoint / OAuth；能给每个 Agent 单独 Access Key 就单独创建，便于撤销；暂不按角色限制工具 |
| 日常维护 | 允许 Agent 在用户已授权的工作范围内自行新增、纠正、完善联系人，不要求每次都再审批 |
| 识别核验 | 修改/删除前定位唯一 `address_book_id + contact_id`，不根据模糊姓名直接覆盖；使用最新 `expected_etag` 降低并发覆盖风险 |
| 结果反馈 | 写后回读、异常时确认实际落地状态后再重试，避免重复新增、错改和误删 |
| 记录范围 | 审计记录动作、时间、Agent、匿名 ID、结果；公开仓库不得保存密码、客户信息或通讯录批量导出 |
| 高影响动作 | 批量删除、跨库迁移、不可恢复的批量更改或真实客户对外沟通，不能因为拥有 MCP 技术权限就假设已有对应的业务执行授权；按任务既有规则确认 |

不要将**各 Agent 具备相同工具能力**误写成“所有 Agent 可以不受任务范围约束地任意处理客户信息”。当前不强制做服务端按角色限制，也不需要阻塞 Agent 接入等待 RBAC 建设。未来若发现多用户共享、审计需求或误操作风险，再评估细粒度权限；**该项目前为可选升级，不是首批前置条件**。

## 4. 保险业务流程：统一 Agent 权限，按具体任务自主使用读写能力

### 4.1 联系人身份层（iCloud）

iCloud 联系人作为**联系方式和身份引用的可核对来源**，不是完整保险 CRM 或所有保单事实的唯一数据源。

联系人业务引用使用 `address_book_id + contact_id` 作为定位键；手机号仅用于候选匹配，**不能唯一确定客户**。如匹配到 0 个、多于 1 个，或同名多号码，必须转人工确认，不猜测或合并。

### 4.2 跟进业务层（独立受控台账，尚未部署）

客户分组、跟进时间、是否已邀约、来源、活动报名状态、下次联系日和业务核验状态，宜放在独立权限受控的业务台账中。避免把保单、疾病、财务等敏感内容批量追加到个人通讯录 Notes。

建议最小记录：`contact_ref`、`source`、`activity_id`、`followup_due_at`、`status`、`last_verified_at`、`revision`、`idempotency_key`；客户姓名/号码只在授权的私有系统中实时解析，不进入公开 GitHub。

**当前尚未选择并部署业务台账数据库；不要擅自复用其他项目的 Postgres 数据库或生产表。**

### 4.3 第一批工作流：联系人检索、维护与回访建议

1. 用户或已授权业务流指定联系人/名单来源 → `contacts_search`；精确核对到唯一 `address_book_id + contact_id`。匹配不唯一时先查证，不盲改。
2. `contacts_read` 检查资料和最新 ETag；允许 Agent 按获授权任务直接做联系人创建、单条字段更正、备注补全等工作，不需要角色分工或重复逐项请示。
3. 执行 `contacts_create` / `contacts_update` / `contacts_delete` 时先去重，优先带 `expected_etag`，变更后重新读取或搜索确认结果。涉及删除时核对唯一目标，记录操作原因、结果和可恢复线索；不能以工具返回成功代替状态验证。
4. 结合生日、客户回访、活动邀约生成下一步行动建议，已获授权的内部整理可由 Agent 自行推进；对外联络遵守对应业务任务的授权和执行规则。
5. 业务状态和保险专业信息宜留在受控工作台账；iCloud 联系人主要管理身份、联系方式与适量联系备注，不把保费、疾病等敏感数据批量写入 Notes。

`contacts_update` / `contacts_delete` 的 `expected_etag` 在上游是可选字段。本项目工作流**建议使用最新 ETag**，不要求本轮改造 MCP 底层接口；碰到并发冲突时重新读取，不自动强行覆盖。涉及 `phones/emails/addresses/urls/impp` 整体替换需核对是否误覆盖现有值。

### 4.4 本阶段推进顺序

- R0：将已验证的 MCP 地址接入更多获授权 Agent；所有 Agent 共享同等 CRUD 能力。
- R1：完成各 Agent 实际 OAuth 授权、工具发现、联系人检索的脱敏验证，记录独立连接结果。
- R2：选用虚构联系人或已明确获准的单一联系人，验证 Agent 在同等权限下可执行读写、去重、回读、异常处理。
- R3：逐步把客户回访、生日关怀、邀约记录与私有台账、工作日历联动；对外行动遵守业务授权边界。

## 5. 持久化、备份与恢复操作

现有源数据：`/opt/insurance-carddav-mcp/data`；服务：`insurance-carddav-mcp-carddav-1`；备份脚本：`/usr/local/sbin/insurance-carddav-backup`。

- `systemctl status insurance-carddav-backup.timer` 检查计划任务；每天北京时间约 04:15，系统随机延迟最多 10 分钟。
- 归档保留约 14 天；目录为 0700，备份归档 0600，**内含恢复密钥/Apple 凭据，绝不外发 GitHub 或日志**。
- 已执行一次隔离解压，并在 `--network none` 的一次性容器中用归档密钥验证加密快照可解开，检查至少包含 OAuth 客户端和 Access Key；不会写回实际服务。
- **未测试**：真实故障机恢复、异地恢复、凭据轮换后的历史备份安全、备份上传到独立存储。
- 需要设计异地加密备份（例如独立 COS 存储桶 + KMS / 独立管理的恢复密钥），确保不使用其他业务的未知密钥或公开对象权限；先明确恢复密钥托管和费用，再部署。

## 6. 接续验收门槛

| 验收 | 当前状态 |
| --- | --- |
| Apple OAuth + CardDAV CRUD + 重启后 CRUD | PASS（Antigravity 在 Issue #4 的实际执行报告；本轮不重复写真实联系人） |
| 容器 healthy / Funnel | PASS（本轮云主机现场检查） |
| 加密 Token 快照解密 | PASS（本轮仅读摘要） |
| 本机自动备份及离线归档恢复 | PASS（文件完整性和加密解密检查；不等于整机业务恢复） |
| 异地备份 + 独立主机恢复 | NOT TESTED |
| 按角色分层/工具级 RBAC | **暂缓，非当前需求**（用户确认统一 CRUD 权限） |
| Agent 实际联系人维护工作流 | NOT TESTED（仅虚构联系人 CRUD 有回执） |
| ChatGPT 自定义 MCP 连接的实测操作 | NOT TESTED |
| 私有客户跟进台账和活动邀约联动 | NOT IMPLEMENTED |
| Render 回退服务删除 | **NOT AUTHORIZED** |

MCP 的 `destructiveHint` 等工具注解不是访问控制。当前不建立分角色限制；各 Agent 获得同等技术权限后，仍按已授权任务范围执行并保留核验与审计。

## 7. 下一步执行顺序（按用户统一授权决定修订）

1. **不等权限网关：** 直接让已获准 Agent 接入现有 MCP，逐个验证 OAuth、`tools/list`、`apple_login`、联系人查询；按需新增独立 Access Key 便于断开单个 Agent。没有必要按 Agent 设读写角色。
2. 记录每个 Agent 的连接状态、可用工具、操作证据及故障回滚；不在公开仓库保存 Token 或联系人原文。
3. 选择虚构数据完成跨 Agent 新增/更新/删除的协调测试（避免同步冲突或重复记录），既有 Antigravity 云端 CRUD 已通过，无需无意义重跑相同测试。
4. 将联系人维护与回访/邀约记录接入未来的私有业务台账，按照已确认业务授权自主推进，重点验证唯一目标、去重、读写回验。
5. 异地加密备份和灾难恢复仍由 Issue #7 跟踪；Render 保留回退。细粒度工具网关仅在实际需求出现时再排期。

**变更范围：** 当前只修订联系人 Agent 统一权限与工作流先后顺序；不改变已有 S1/C 内部事务的执行进度或定时。
