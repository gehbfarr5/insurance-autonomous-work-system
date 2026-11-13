# secrets.env 输出定点暴露评估（2026-11-11）

- **性质**: 仅依据已有记录的离线评估；**未重新读取 secrets.env、未复制或转写任何敏感值**
- **触发**: 总控对 b009fab 隔离验证的审查意见；生产凭据变更**待单独批准**，本文档仅列选项与影响

## 1. 暴露事件（已有记录确认）

| # | 事件 | 时间 | 通道 | 输出内容（仅类别） |
|---|---|---|---|---|
| E1 | `docker inspect` 基线容器 env 输出 | 2026-11-11 R2 准备期 | 管理通道 `server_execute`，stdout 进入会话 | iCloud 账户标识字面值；env 键名清单 |
| E2 | `server_read_file` 读取 Seoul `/opt/insurance-carddav-mcp/secrets.env` 全文件（目的：核实无桥注入键） | 2026-11-11 R2 准备期 | 管理通道 `server_read_file`，stdout 进入会话 | iCloud 账户标识、iCloud 应用专用密码、`TOKEN_ENCRYPTION_KEY`、`ADMIN_PASSWORD_HASH`、READ/WRITE 开关 |

两事件均发生在 R2 申请 v1→v2 准备期，目的与范围已在申请 v2.1 §7.3 如实披露。

## 2. 输出位置与可访问主体（本机核查，2026-11-11）

- **落点**: 本机会话记录 `/Users/jin/.workbuddy/projects/Users-jin-Workbuddy-2026-11-10-13-08-22/c656e145-3c28-4d22-b423-2dc244622556.jsonl`（约 22MB，权限 0644）
- **量化（按行计数，未输出任何值）**: 账户标识 78 行；`softbank` 域 21 行；`TOKEN_ENCRYPTION_KEY` 键名 21 行；`ADMIN_PASSWORD_HASH` 键名 13 行。应用专用密码值：既有记录确认已随 E2 全文件输出进入会话；未统计行数（避免触碰值本身）
- **会话压缩摘要**（本会话上下文）中亦含账户标识字面值
- **可访问主体**:
  1. 本机用户账户（文件属主；0644 意味着本机其他本地用户亦可读——单用户 Mac 实际风险低）
  2. WorkBuddy 应用及其本地代理进程
  3. WorkBuddy 服务端会话存储（如存在云端副本——**无法从本机确认，标为不确定**）
  4. 本机备份/同步覆盖范围（Time Machine / iCloud Drive 是否覆盖 `~/.workbuddy`——**待核查，标为不确定**）
- **仓库与回执**: 全仓 grep（含全部回执/申请/提交）对账户标识与域名字面值 **0 命中**——敏感值未进入任何仓库文件、回执或提交

## 3. 凭据类别与风险

| 凭据 | 类别 | 暴露后果 |
|---|---|---|
| iCloud 账户标识 | 标识符 | 定向目标暴露；单独不可登录 |
| iCloud 应用专用密码 | **凭据（高）** | 与账户名配合可直接访问该 iCloud 账户的 CalDAV 数据（读） |
| `TOKEN_ENCRYPTION_KEY` | **凭据（高）** | 可解密网关 OAuth 令牌存储 → 恢复 MUSE 等客户端的 refresh token |
| `ADMIN_PASSWORD_HASH` | 哈希（中低） | 需破解才可用；保护网关 admin 端点 |
| READ/WRITE 开关 | 配置 | 非敏感 |

桥令牌（MacServer EventKit Bridge）**不在** secrets.env 中，未受本暴露影响。

## 4. 处置选项与影响

### A. 记录性处置（无生产影响，可立即）

| 选项 | 内容 | 对现有服务 | 对 OAuth 会话 | 对令牌存储 |
|---|---|---|---|---|
| A1 暴露登记 | 本文档 + 仓库零命中声明 | 无 | 无 | 无 |
| A2 本地会话记录脱敏 | 删除/遮蔽 jsonl 中含敏感值的行（需用户确认是否接受会话历史损失；不可逆） | 无 | 无 | 无 |
| A3 备份/同步范围核查 | 只读核查 Time Machine / iCloud Drive 是否覆盖 `~/.workbuddy` | 无 | 无 | 无 |

### B. 凭据轮换（**均待单独批准**；建议与 R2 窗口错开）

| 选项 | 内容 | 对现有服务 | 对 OAuth 会话 | 对令牌存储 |
|---|---|---|---|---|
| B1 轮换 iCloud 应用专用密码 | 用户在 Apple ID 生成新密码 → 更新 secrets.env → 重启基线容器 → health 复验 | **Seoul 基线容器 CalDAV 读中断至重启完成**（reminders 直连路径）；MacServer 桥不受影响（走 EventKit） | 无 | 无 |
| B2 轮换 `TOKEN_ENCRYPTION_KEY` | 停容器 → 备份并重置令牌存储 → 改 key → 起容器 → 客户端重新授权 | 网关 health 短暂中断；**启动时旧存储解密失败会拒绝监听**（`bin/http.js` 核实），必须同步重置存储 | **全部失效**（含 MUSE），需重新走 OAuth 授权 | **必须重置**（旧文件作废） |
| B3 轮换 `ADMIN_PASSWORD_HASH` | 重算哈希 → 更新 secrets.env → 重启 | admin 端点凭据更新；网关重启一次 | 无 | 无 |

### C. 排除项

- 不将任何明文值写入回执、申请或以明文传输到新位置（本轮已遵守）
- 不在未批准前改动 secrets.env 或重启容器

## 5. 建议

1. 立即执行 A1（本文档）；A2/A3 待用户确认后执行
2. B1/B2/B3 列为待批准项，**建议安排在 R2 验收完成之后**统一执行，避免与验收窗口交叉；其中 B2 影响最大（全量 OAuth 会话失效）
3. R2 窗内纪律维持 v2.1 §7.3：不读取 secrets.env；确需读取先请示并单独记账
