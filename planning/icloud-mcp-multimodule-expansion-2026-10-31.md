# iCloud MCP 多模块扩展：联系人、日历、提醒事项、邮件（2026-10-31）

> **当前状态**：首尔运行的服务是 [MrZhongzq/apple-icloud-mcp](https://github.com/MrZhongzq/apple-icloud-mcp)，并非只实现 CardDAV 的联系人专用服务。现有生产配置**仅开启联系人读写**；日历、提醒事项、邮件全部关闭。此文为能力审计和下一阶段实施基线，**本轮未修改生产开关或执行真实业务写入**。

## 1. 已核实的代码能力

| 服务 | 协议 | 主要 MCP 工具 | 上游支持 | 当前首尔 env |
| --- | --- | --- | --- | --- |
| 联系人 | CardDAV | contacts_search/read/create/update/delete | 5 工具，完整 CRUD | READ=true、WRITE=true |
| 日历 | CalDAV | calendar_list/list_events/create_event/update_event/delete_event | 5 工具，创建/更新/删除 | READ=false、WRITE=false |
| 提醒事项 | CalDAV VTODO | reminders_lists/list/create/update/delete | 5 工具，完成/取消完成状态更新 | READ=false、WRITE=false |
| 邮件 | IMAP/SMTP | mail_folders/search/read/send/mark/move/delete | 7 工具 | READ=false、WRITE=false，且当前没有 ICLOUD_SENDER_1 |
| 公共会话 | OAuth MCP | apple_accounts、apple_login、work_done | 3 工具 | Contacts 已验证 |
| Apple Notes 备忘录 | 不支持 | 无 | 上游明确不支持 | 不适用 |

共 25 个候选工具（3+7+5+5+5），但各模块是否对当前账户有效取决于配置和实际认证；**工具在注册表中出现并不等于对应服务可用**。

**邮箱限制**：当前配置的 Apple ID 是 `gehbfarr5@i.softbank.jp`，`ICLOUD_SENDER_1` 未设置；有效的 mail sender 不是 `@icloud.com`、`@me.com`、`@mac.com` 或 `@icloud.com.cn`。上游 `src/core/config.ts` 在这种情况下强制 mailRead/mailWrite=false。简单把 ALLOW_MAIL_* 改成 true 也无法激活 iCloud Mail。需先确认/开通 Apple 赋予的实际 iCloud Mail 邮箱地址，才能单独做邮件测试。用户之前表示没有 iCloud Mail 地址，本轮不创建。

## 2. 本轮核验事实

- 首尔容器健康检查 `{"status":"ok"}`，Docker `healthy`，backup timer `active`。
- 读取首尔 `/opt/insurance-carddav-mcp/secrets.env` 的配置布尔值：`ALLOW_CONTACTS_READ_1=true`、`ALLOW_CONTACTS_WRITE_1=true`，`ALLOW_CALENDAR_READ_1=false`、`ALLOW_CALENDAR_WRITE_1=false`、`ALLOW_REMINDERS_READ_1=false`、`ALLOW_REMINDERS_WRITE_1=false`、`ALLOW_MAIL_READ_1=false`、`ALLOW_MAIL_WRITE_1=false`；`ICLOUD_SENDER_1` 未配置。**没有输出秘密原文**。
- 本轮调用 ChatGPT 已连接的 `iCloud Calendar` 插件 `get_profile`，其账户标识与部署 Apple ID 一致。这证明 ChatGPT 的**原生日历插件**已连接同一 Apple ID，但**不是**首尔自建 MCP Calendar 模块已开启，也不能替代 Antigravity/MUSE 的 CalDAV 接入验收。
- 2026-10-31 用户确认：**Antigravity 和 MUSE 两个 Agent 已完成现阶段接入**；这是用户提交的连接状态，没有在本轮拿到各 Agent 原始 OAuth/tools/list 回执。其他 Agent（Codex、WorkBuddy 本地/云任务、Vela/ChatGPT 自定义 MCP）仍按 Issue #6 跟进，不重新创建 Antigravity/MUSE 的已有凭据。

## 3. 保险业务适配

| 场景 | 需要的服务 | 数据原则 |
| --- | --- | --- |
| 找客户、校对联系信息、生日 | Contacts | iCloud 是身份/联系方式来源；不是保单数据库 |
| 平台会、客户见面、合同递送、活动排期 | Calendar | 使用原有 `工作` 日历，读取前识别 calendar_id；业务流先做去重 |
| 约访后回拨、活动报名待办、客户关怀任务 | Reminders | 作为动作待办与完成状态；与真正邀约/报名结果分开 |
| 保单到期提醒 | Contacts + Reminders + 合法保单数据源 | 仅凭通讯录无法推出保单到期日期 |
| 对外邮件沟通 | Mail | 当前账户无可用 iCloud Mail 发件身份，不能通过更改开关绕过 |

## 4. 下一阶段启用顺序与验收

**A：准备与只读识别（建议第一批）**

1. 保留现有 Contacts `true/true`，不要再跑一次已通过的联系人完整 CRUD。
2. 在启动维护窗口备份 `secrets.env` 和 compose、原 OAuth Token 数据，并核对源代码/部署版本匹配；**生产变量还没有修改**。
3. **候选变更**：`ALLOW_CALENDAR_READ_1=true`、`ALLOW_REMINDERS_READ_1=true`；写权限是否同步开启由用户对新模块授权决定（目前只确认 Agent 的联系人统一 CRUD，没有单独确认新数据域的执行范围）。
4. 仅重建 CardDAV 容器，保持既有 `/mcp` URL / Access Keys / Tailscale Funnel / Render 回退不变；先核对 health，再用已有 Antigravity/MUSE 的 OAuth 查 `apple_accounts` 能力矩阵、`calendar_list` 和 `reminders_lists`。发生认证/协议错误立刻回滚配置。

**B：写入验收（单独作为受控测试）**

1. 如用户同意新模块写入，把 `ALLOW_CALENDAR_WRITE_1`、`ALLOW_REMINDERS_WRITE_1` 打开；同一账户的所有获授权 Agent 都会获得相同能力，**没有 per-Agent Calendar/Reminders RBAC**。
2. 仅建立一条虚构日程、虚构提醒事项 → 读取/修改 → 删除后核对 0 残留；不要对每个 Agent 重跑同类 CRUD，后续分别做工具发现/正常查询即可。
3. 日历时间使用 ISO 8601 显式时区偏移（贵阳工作日历 `+08:00`）；上游重复事件创建是 UTC anchored，对夏令时地区的重复日程可能漂移。提醒事项的优先级 1=高、5=中、9=低；删除不可撤销，修改提醒 completion 会改变状态/时间。
4. 业务工作流落地：联系人精准定位→查询工作日历冲突→生成内部回访提醒→回写客户跟进状态至受控工作台账，最终使用原对象 ID + 写后 read-back 做验收。

**C：邮件单独评估**

仅当 Apple 账号已有真正的 iCloud Mail 地址才配置 `ICLOUD_SENDER_1` 并测试 IMAP/SMTP。对用户的 Gmail、公司 Outlook 或其他邮箱，应选相应的独立邮件连接器，不能把 Apple MCP 当作通用邮箱插件。上游邮件附件下载/发送都不支持。

## 5. 重要区别：服务能力不等于已开生产权限

- `apple_login` 会验证所启用协议，扩展 CalDAV 后应单独核验登录；不能用旧联系人 CRUD 的 PASS 推断日历/提醒事项 PASS。
- Apple iCloud MCP 使用一个 `/mcp` URL；不必为四个服务分别部署实例。保持 Apple app-specific password、Token store key 与 `/admin` 不变。
- ChatGPT 现有 iCloud Calendar 插件支持直接操作日历，并能查看联系人；它不是同一条自建 MCP 通道。避免从两个独立执行路径对同一日历重复创建事件。
- 已获授权 Agent 不做角色拆分的决定适用于现有联系人；新增 Calendar/Reminders 权限一旦打开，会作用于该 Apple 账号下所有成功 OAuth 的 Agent，应把这一影响作为变更记录。

来源：上游 README、`src/core/config.ts`、`src/modules/calendar/tools.ts`、`src/modules/reminders/tools.ts`、`src/modules/mail/tools.ts`；首尔配置布尔值只读核验。关联 [Issue #6](https://github.com/gehbfarr5/insurance-autonomous-work-system/issues/6)。