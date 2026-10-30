# iCloud CardDAV MCP：云端持续运行与多 Agent / 客户经营集成（2026-10-30）

> 状态：**云端核心功能已由 Antigravity 完成真实 CRUD 验收；多 Agent 权限隔离、ChatGPT 实际连接和保险业务数据写入尚未生产验收**。本页为下一批实施基线，不改变 P4/S1 的其他任务与调度。
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
ChatGPT / Codex / 其他 Agent（未来）
       │
       │ OAuth + 每 Agent 独立 Access Key（目前仅有 1 把，不等于已完成分配）
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

**重要：** 上游 Access Key 可独立吊销其授权码、令牌和会话，但 `AccessKeyRecord` 没有工具白名单或每 Key 联系人只读权限字段。服务器端 `ALLOW_CONTACTS_WRITE_1=true` 属于 iCloud 账号能力。**不同 Agent 各有一把 Access Key ≠ 不同 Agent 已被限制到 read-only。** OAuth scope=`mcp` 也不构成工具级只读权限。

因此未完成强制策略网关前：**不要把现有可写 MCP URL/Key 直接分发给多个未经写入授权的 Agent。**

## 3. 多 Agent 接入与权限分层（待实现）

| 身份 | 可调用能力 | 禁止动作 | 必须记录 |
| --- | --- | --- | --- |
| 查询 Agent | 受控联系人搜索、精确读取、去重候选、回访计划草案 | 直接接触上游写工具、导出整个通讯录 | agent_id、请求标识、检索依据、命中数量 |
| 跟进规划 Agent | 在已获授权的元数据范围内生成分类、邀约/生日/保单到期的待办建议 | 更改 iCloud 个人字段或发送消息 | 来源、时间、建议及依据，不写真实客户信息到公开仓库 |
| 联系人写入 Agent | **只能经过服务器端受控网关**进行明确允许的字段级单记录更新 | 批量改写、无确认删除、覆盖其他人员的备注、静默创建重复联系人 | 操作前后的字段摘要、唯一 ID、ETag、审批或预授权规则、回读结果 |
| 管理 Agent | 诊断健康、备份、权限审核、暂停/撤销连接 | 默认读取完整客户联系人或自行扩大权限 | 变更审计、回退方案 |

实施顺序：

1. 为每个 Agent 建立独立身份和审计日志（不能仅靠共享 Access Key 或代理层自然语言提示）。
2. 增加**服务端强制执行**的工具允许列表：查询身份仅放行 `contacts_search` / `contacts_read` / 必要会话工具；拒绝 `contacts_create`、`contacts_update`、`contacts_delete`；其他邮件/日历/提醒工具默认拒绝。测试绕过与 403/deny 行为。
3. 写入身份只放行受控 `contacts_update` 且仅允许明示的字段，默认禁止 `contacts_delete`；如需新增或删除，单独的高权限工作流和显式授权。
4. 验证停用某把 Key 后其 OAuth 令牌和会话被立即切断，而其他 Agent 不受影响；收集脱敏回执。
5. 每个 Agent 的凭据使用 Secret Store，而非共享聊天文本、公共 GitHub 或永久明文环境日志。

注意：**目前不是已实现的 RBAC**，表格代表下一阶段需要实现和验证的真实技术边界。

## 4. 保险业务流程：优先“查询—建议—核实”，再扩大写入

### 4.1 联系人身份层（iCloud）

iCloud 联系人作为**联系方式和身份引用的可核对来源**，不是完整保险 CRM 或所有保单事实的唯一数据源。

联系人业务引用使用 `address_book_id + contact_id` 作为定位键；手机号仅用于候选匹配，**不能唯一确定客户**。如匹配到 0 个、多于 1 个，或同名多号码，必须转人工确认，不猜测或合并。

### 4.2 跟进业务层（独立受控台账，尚未部署）

客户分组、跟进时间、是否已邀约、来源、活动报名状态、下次联系日和业务核验状态，宜放在独立权限受控的业务台账中。避免把保单、疾病、财务等敏感内容批量追加到个人通讯录 Notes。

建议最小记录：`contact_ref`、`source`、`activity_id`、`followup_due_at`、`status`、`last_verified_at`、`revision`、`idempotency_key`；客户姓名/号码只在授权的私有系统中实时解析，不进入公开 GitHub。

**当前尚未选择并部署业务台账数据库；不要擅自复用其他项目的 Postgres 数据库或生产表。**

### 4.3 第一个可实施工作流

1. 用户指定联系人或名单来源 → `contacts_search` 有限查询，取得候选数量；
2. 精确匹配唯一联系人 → `contacts_read`；检查数据新鲜度、冲突、目标字段；
3. 生成“联系建议/下次跟进/活动候选”草稿，交用户审阅，**不自动对外发送**；
4. 记录为私有跟进任务（待台账接入），不写入 iCloud Notes；
5. 如果用户确认特定联系人变更或有明确的长期规则授权，受控写网关再按唯一 `contact_id`、最新 `expected_etag` 执行**单条字段补丁**；
6. 写后重新读取校验，不依赖仅有的操作成功提示；失败时先查真实状态、避免盲目重放；
7. 删除一律默认禁止。批量操作必须拆成可审计、可中止的单记录步骤，并另外授权。

上游 `contacts_update`、`contacts_delete` 支持可选 `expected_etag`（乐观锁），正式写入应将其设为必填。省略字段表示不改；`phones/emails/addresses/urls/impp` 是整体替换，尤其不得未经核对覆盖。

### 4.4 逐步接入的业务场景

- R0：获授权 Agent **只读**查询、去重、准确定位联系人（不自动下载整本通讯录）；
- R1：客户生日、活动邀约、售后联系建议，生成草稿并由用户决定；
- R2：在服务端强制授权、审计、ETag 和回读通过后，开放**单记录受控更新**；
- R3：再与工作日历、活动报名/电话邀约状态联动；真实对外联系需单独获准。

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
| 按 Agent 工具级只读/写权限隔离 | NOT IMPLEMENTED |
| 单条带 ETag 的生产联系人更新 | NOT TESTED（仅测试联系人 CRUD 有回执） |
| ChatGPT 自定义 MCP 连接的实测操作 | NOT TESTED |
| 私有客户跟进台账和活动邀约联动 | NOT IMPLEMENTED |
| Render 回退服务删除 | **NOT AUTHORIZED** |

不要把服务工具注册的 MCP `destructiveHint` 等注解当作访问控制；**授权检查必须在真正执行工具的服务器端完成**。

## 7. 下一步执行顺序

1. 先完成工具级隔离网关的设计、部署、单元测试与绕过测试；查询 Agent 默认只读。
2. 建立独立 Agent Access Key，并证实跨身份隔离及停用后令牌失效。
3. 在 ChatGPT 实际连接管理中完成用户授权，并回传 `tools/list` 和 `contacts_search` 的脱敏实测证据。
4. 建立最小私有跟进台账，选择单个已授权客户样例开展读→建议→确认闭环；生产联系人写入暂不默认开放。
5. 完成异地加密备份和灾难恢复演练后，再重新评估 Render 回退退出条件。

**变更范围：** 本文只属于联系人共享基础设施与 S2 客户经营候选的下一批任务；不改变已有 S1/C 内部事务的执行进度或定时。
