# R2 MUSE 前台只读验收申请（一次审批制）

- **申请编号**: R2，**v2.3**（2026-11-11，权限收窄核验与连接器实测后修订；放行材料版）
- **基线**: R1-04 续跑回执（R1 PASS）@ `3e422b1`；归档收尾 @ `7e87950`
- **v2.3 修订说明**:
  1. 会话记录文件权限收窄 0644→0600（属主不变，读取验证通过，历史保留）——核验记录见配套文档
  2. **MUSE 原生连接器实测可用**：`https://seoul-forge-01.tail4db0d9.ts.net/mcp` tools/list 成功（33 工具，reminders 5 个在列）；期间 OAuth access token 过期 401 → Manager 只读自动续期恢复（state 74→75），**无需重新授权、零缺口**；零业务工具调用
  3. §8.4 请求账重构：**明确区分 MUSE 原生调用（主验收）与工程复核/脚本复核**；T3 明确为"创建前准备 + 首次启动时生效"同一步骤
  4. 13 项隔离证据沿用不重跑
- **v2.2 修订说明**（对应总控令）:
  1. secrets.env 输出**定点暴露评估**完成（独立文档，未重读未复制敏感值），处置选项与服务/OAuth/令牌存储影响已列，生产凭据变更待单独批准
  2. MUSE **原生入口核实**：触发步骤、发起方确认脱敏记录、三通道分开标注、未就绪时最小接入方案（§8.5）；P1 增加入口自检
  3. 13 项隔离证据**沿用不重跑**（总控已审查）
- **v2.1 修订说明**（对应总控令五条）:
  1. 绑定配置经候选镜像**实际解析器**验证，**修正名称/类型顺序**（v2 草案顺序反了，会导致三重匹配失败、列表零可见）
  2. 反向监听、容器访问地址、首次启动配置三方对齐（生产网络实测）；隔离环境 13/13 PASS（连通语义 + 单列表过滤）
  3. 新增 §8：MUSE 入口、调用顺序、证据出处、**逐调用上游枚举核算表**（区分账户级元数据与 MUSE 可见范围），预算据此重算
  4. **生产写探针移出本轮**，改用候选源码 + 隔离写拒绝证据；OAuth 刷新与 Apple 会话刷新分开说明；secrets.env 读取范围披露
  5. 定点验证记录与申请同批提交；**真实 Seoul 变更与 MUSE 验收仍待一次批准**
- **目标**: 通过 Seoul 网关候选路由 + MacServer 新测试列表绑定，完成 MUSE 前台独立验收——补上 AG-07 遗留的 UNVERIFIED（非空读取 0 条），产出**目标匹配、真实非空字段、清理、恢复**四类证据

## 1. 复用资产（现状已核实，2026-11-11）

| 资产 | 现状 | 版本/标识 |
|---|---|---|
| Seoul 网关基线容器 | 运行中（AG07 回滚后），`127.0.0.1:17734→17733`，health 可达 | 镜像 `sha256:f3e697fe…c0da2f0` |
| Seoul 网关**候选镜像** | 本地镜像在库，未运行；reminders gateway 模块已从镜像内 dist 代码核实 | `faa6e380ee4b`，tag `candidate-ag05-delivery-20261108`，构建自 PR23 head `0da5f6e0…43f1` |
| gateway 模块文件（候选镜像内） | `dist/modules/reminders/gateway/{config,service,transport,index,types}.js` | 逐一读取核实；解析器与 service 已隔离实测（§3、§4） |
| MacServer 桥 | production、闸门关、绑定新列表 | 二进制冻结 `f78e24e5…3074`；绑定 `591B****6450`（源 `9BBB****CCB0`） |
| 客户端脚本 | AG07 使用的前台触发脚本 | `~/workspace/carddav-mcp-client/verify_muse_test_20261110.py`（MUSE 机，P1 前确认版本未变） |
| 隧道受限模板 | AG05 交付的 sshd drop-in 与 authorized_keys 模板 | `resident-tunnel/templates/seoul/60-macserver-gateway.conf.template`、`authorized_keys_entry.template` |
| Seoul secrets.env | 仅 iCloud 账户/应用密码/读写开关（READ=true、WRITE=false），**无桥注入键** | 读取范围披露见 §7.3 |

## 2. 数据范围事实（全部从候选镜像 dist 源码核实 + 隔离实测，反扩散条款的依据）

- **桥枚举端点暴露全部 iCloud 列表**（续跑 W0 `visible_list_count=3`）——桥自身不做列表隔离
- **候选镜像网关层硬约束白名单**（`gateway/service.js`，源码核实 + 隔离实测）：
  - `fetchAllowedICloudLists()` 只返回 allowedLists 白名单中 listId 命中 **且** expectedSourceId/SourceName/SourceType 三重匹配的列表，其余一律丢弃
  - `list()` 未传 `list_ids` 时仅遍历上述白名单过滤结果——**留空也不会隐式查全部列表**（与基线直连 CalDAV 行为不同）
  - 传入白名单外的 `list_ids` → 直接 `NOT_FOUND`（隔离实测证实）
  - 每条 Bridge 返回条目做 listID 归属一致性校验，不匹配即 `UPSTREAM_ERROR`
  - allowedLists 缺失或空 → 网关拒绝启动（隔离实测证实）
- **transport**（`gateway/transport.js`）：`GET {endpoint}/reminders/lists` 与 `GET {endpoint}/reminders/lists/{id}/items`，`Bearer` 头，listID URL 编码
- **因此 R2 的数据范围边界 = allowedLists 白名单（网关硬约束）+ 桥 allowlist（双层）**，两层都必须指向 `591B****6450`，并在窗内逐项验证（§9）

## 3. 绑定配置与注入键（候选镜像实际解析器验证后修正，T3 注入内容）

**解析器事实（`config.js` `loadGatewayConfigFromEnv`，隔离实测 PASS）**：冒号格式字段顺序为
`listId:expectedSourceId:expectedSourceName:expectedSourceType`——**第 3 位是名称、第 4 位是类型**。
v2 草案 `…:calDAV:iCloud` 顺序反了（实测产生 name=calDAV/type=iCloud，三重匹配必失败）——**已修正**。

| 类别 | env 键（多别名，取一） | R2 取值 |
|---|---|---|
| 端点 | `MACSERVER_EVENTKIT_ENDPOINT`（别名 `EVENTKIT_GATEWAY_ENDPOINT`/`EVENTKIT_BRIDGE_ENDPOINT`，默认 `http://127.0.0.1:18765`） | `http://172.19.0.1:18765`（对齐依据见 §4） |
| 桥令牌 | `MACSERVER_EVENTKIT_AUTH_TOKEN`（别名 `MACSERVER_EVENTKIT_TOKEN`/`EVENTKIT_BRIDGE_AUTH_TOKEN`/`EVENTKIT_BRIDGE_TOKEN`；**校验要求 ≥16 字符**，隔离实测） | S0-lite 重发的桥令牌（0600 临时 env 文件，窗末删除） |
| 超时 | `*_TIMEOUT_MS`（500–60000，默认 5000） | 默认 |
| 响应上限 | `*_MAX_RESPONSE_SIZE`（1KB–50MB，默认 2MB） | 默认 |
| **列表白名单** | `MACSERVER_EVENTKIT_ALLOWED_LISTS`（别名 `EVENTKIT_ALLOWED_LISTS`） | **`591B****6450:9BBB****CCB0:iCloud:calDAV`**（仅此一项；窗内用真实全值；JSON 等价格式 `[{"listId":…,"expectedSourceId":…}]` 亦可，缺省 name/type 自动补 iCloud/calDAV） |

## 4. 地址与首次启动配置对齐（本轮实测）

| 项 | 实测/核实结果 | 对齐结论 |
|---|---|---|
| 反向监听（Seoul sshd） | AG05 drop-in 模板：`PermitListen 172.19.0.1:18765 127.0.0.1:18765`、`GatewayPorts clientspecified`、`ForceCommand /bin/false` | 隧道绑定 `172.19.0.1:18765`（容器可达地址）与 `127.0.0.1:18765`（宿主核验地址）**均在白名单内**，T1 照模板执行 |
| 容器访问地址 | 生产 compose 网络 `insurance-carddav-mcp_default` 实测：Subnet `172.19.0.0/16`，**Gateway `172.19.0.1`**，基线容器 `172.19.0.2` | T3 端点 = `http://172.19.0.1:18765`（容器经 docker bridge 网关达宿主隧道端口），与监听白名单一致 |
| MCP 入口（候选镜像） | `server/httpApp.js:303`：`app.all('/mcp', requireBearerAuth(...))`（streamable HTTP，`bin/http.js` transport='streamable-http'）；`/health` 无鉴权仅回状态 | MUSE 与工程直连统一走 `/mcp`，Bearer 鉴权；health 走 `/health` |
| 首次启动配置 | `loadConfig(…, { allowNoAccounts: true })`（无 iCloud 账户可启动）；但 gateway 配置**空白名单拒绝启动**（隔离实测）；auth 令牌存储需 `TOKEN_ENCRYPTION_KEY`（secrets.env 已有） | **T3 注入必须在容器创建时完成**（compose env_file / -e 首启生效），不允许"先启动后热注入"；auth 依赖项已在位 |

## 5. 需要的临时变更（授权后生效，全部限时；实际文件/进程/权限变化）

| # | 变更 | 实际文件/进程变化 | 权限 | 回退 |
|---|---|---|---|---|
| T0 | 双端看门狗武装（**必须先于 T1–T4**，见 §6） | Seoul prechange watchdog 进程 ×1（期限 3562s）；MacServer 本地看门狗 supervisor ×1 | — | 到点自主回滚（AG07 双端精确到点先例） |
| T1 | 反向 SSH 隧道 MacServer→Seoul | Seoul：新增临时 sshd drop-in（§4 模板内容）+ sshd reload；MacServer：临时反向 ssh 进程（`-R 172.19.0.1:18765`，受限密钥） | drop-in 0644 | 窗末移除 drop-in + 结束 ssh 进程 + 端口释放核验（AG07 实证零残留） |
| T2 | Seoul 容器镜像切换 | 基线 `f3e697fe` → 候选 `faa6e380`，容器重建（compose） | 不变（mem 256m、pids 128、no-new-privileges 沿用） | 窗末回滚基线镜像并核验 health 200 |
| T3 | 网关绑定注入（§3 五项）——**同一步骤**：创建前准备（0600 临时 env 文件写入 + compose 引用）与容器创建时首次启动生效，**非运行时热注入** | 容器 env 注入 | **env 文件 0600、目录 0700，窗末删除** | 窗末回滚（manifest.env 备份机制复用） |
| T4 | MacServer 桥闸门 gate=true | plist 单键变更；launchd 服务重载一次 | plist 备份 0600 | 窗末恢复 false 并核验 403 |

## 6. 时限与看门狗（先就绪顺序条款）

- **单窗 3600 秒**（与 AG07 同规格），截止时刻为硬期限
- **顺序强制条款：T0 双端看门狗武装并确认在跑（pid + 期限记录）之后，才允许执行 T1–T4 任何一项**；任一看门狗未能就绪 → 不开窗、不执行任何临时变更
- Seoul prechange watchdog：到点自主回滚基线容器（AG07：精确到点触发）；MacServer 本地看门狗：到点恢复 gate=false（AG07：SIGTERM 到点、开关回 false）
- 每步实际请求逐次记账，超预算即停止

## 7. 权限、凭据与刷新行为

### 7.1 凭据与写权限

- Seoul `TOKEN`/`ADMIN_PASSWORD`/`ICLOUD_APP_PASSWORD`：不读取、不落盘、回执掩码
- MacServer 桥令牌：S0-lite 重新提取，0600 受控目录；注入仅经 T3 临时 env 文件
- **写权限三层锁定（源码核实 + 隔离实测）**：
  1. 候选镜像 gateway `service.js`：`create/update/remove` **硬编码** `rejectWriteOp` → `PERMISSION_DENIED`，零转发/零 VTODO 回落（隔离实测三项 PASS）——**不依赖 env 开关，写请求不会到达桥**
  2. `ALLOW_REMINDERS_WRITE_1=false`（capability 门，provider 层）
  3. 桥 `REMINDERS_WRITE=false` + gate 关闭

### 7.2 刷新行为（OAuth 与 Apple 会话分开说明）

- **OAuth 刷新（MUSE ↔ 网关 Bearer 令牌）——会发生，已实证、属既有机制、无新增权限**：MUSE 客户端持网关签发的 access+refresh 令牌（AG07 已授权）。**access token TTL = 1 小时（2026-11-11 前台自检实测：16:38 取得、约 17:38 过期 401，Manager 只读自动续期恢复，state 版本 74→75）**——3600 秒窗内必然跨过一次到期，续期将自动发生；源码出处 `dist/auth/provider.js` `exchangeRefreshToken`（refresh token 30 天 TTL、`rotateRefresh` 轮换、重放检测即 revoke 全族）。刷新不扩大数据范围、不需新授权；窗内由通道 (b) 包装层记录，刷新请求不经桥、单独记账（§8.4）。
- **桥令牌：静态注入、无刷新逻辑**——网关侧无任何针对桥令牌的刷新代码（config.js 无刷新键），窗内使用 S0-lite 一次性令牌，窗末删除。
- **Apple 会话刷新（MUSE 机 iCloud 登录）——窗内不会发生、不由 WB 触发**：仅当用户 Apple 会话已过期且用户自行重新登录时发生（R1-04 先例：重登后同步生效）。R2 不需要也不安排 Apple 重登；若验收时发现会话已登出 → 停止并请示，不自行处理。

### 7.3 secrets.env 读取范围披露与暴露评估（v2.2 扩充）

- **实际读取**：R2 准备期经管理通道读取 Seoul `/opt/insurance-carddav-mcp/secrets.env` **全文件一次**（核实无桥注入键）；同轮 `docker inspect` env 输出曾带出 iCloud 账户标识。**敏感值未写入任何回执、申请或提交**（全仓 grep 零命中）。
- **定点暴露评估**（v2.2）：见配套文档 `R2_SECRETS_ENV_EXPOSURE_ASSESSMENT_20261111.md`——输出位置（本机会话记录 JSONL，22MB/0644，按行计数量化）、可访问主体（本机账户/WorkBuddy/云端会话存储与备份范围标不确定）、凭据类别分级（应用密码与 `TOKEN_ENCRYPTION_KEY` 为高危）、处置选项 A（登记/本地脱敏/备份核查，无生产影响）与 B（三项凭据轮换：**B2 轮换加密密钥将使全部 OAuth 会话失效并需重置令牌存储**；均待单独批准，建议与 R2 窗口错开）。
- **R2 窗内纪律**：不读取 secrets.env——桥令牌经 S0-lite 从 MacServer 侧获取；Seoul 侧注入值不来自 secrets.env；确需读取先请示并单独记账。生产凭据变更不在本申请范围内。

## 8. MUSE 前台原生 MCP：入口、调用顺序、证据出处与上游枚举核算

### 8.1 入口链

```
MUSE 前台（用户触发 / 原生工具调用）
  → https://seoul-forge-01.tail4db0d9.ts.net/mcp   （2026-11-11 前台自检确认可用）
  → Seoul 宿主 127.0.0.1:17734 → 容器 17733
  → app.all('/mcp', requireBearerAuth) —— MCP streamable HTTP（Bearer 鉴权）
```
工程直连与脚本复核走同一 `/mcp` 端点，仅发起方（OAuth client）不同。

### 8.2 调用顺序（窗内 P3/P4）

1. `initialize` → `tools/list`（step1 工具发现：确认 `reminders_lists`/`reminders_list` readOnlyHint=true，写工具存在但零调用）
2. `tools/call reminders_lists`（step2 列表发现：范围验证）
3. `tools/call reminders_list(list_ids=["591B****6450"])`（step3 非空读取 + 12 项字段断言；**list_ids 固定显式传入目标 ID**）
4. （用户删除事项后）重复步骤 3 → 断言 0 条
5. 工程直连复读步骤 3 → 复核 0 条

### 8.3 证据出处（三通道分开记录）

| 通道 | 内容 | 证据落点 |
|---|---|---|
| (a) 前台触发脚本 | MUSE 用户前台独立执行 `verify_muse_test_20261110.py`（P1 确认版本未变） | 脚本执行输出 + 参数记录 |
| (b) 脚本执行包装层 | `manager_configuration writes_enabled=false` 全程；Apple/OAuth 刷新是否发生的记录 | 包装层日志摘录（脱敏） |
| (c) 直接原生 MCP 工具调用 | 对 `/mcp` 端点的直接工具调用（step3 独立取证 + 删除后工程直连复读） | 调用/响应记录（脱敏） |

### 8.4 逐调用上游枚举核算（v2.3 重构：明确发起方）

关键机制：**网关的每一次 `reminders_lists` 或 `reminders_list` 调用都会先向桥发起 1 次账户级元数据请求**（`GET /reminders/lists`，桥返回全部 3 个列表）——这是"网关收到的账户级元数据"；白名单过滤后 MUSE 最终可见范围仅 1 个列表。条目调用另加 1 次 `GET /reminders/lists/{目标}/items`。

**发起方定义（v2.3）**：
- **MUSE 原生调用** = 用户在 MUSE 前台直接发起的原生工具调用（主验收证据；通道 (a) 前台触发记录、(b) 包装层记录、(c) 调用/响应记录是**同一批调用的三个视角**，不是三次独立调用）
- **工程复核** = WB 经 `/mcp` 用独立 OAuth client 直连（仅删除后复读复核，不作为 MUSE 证据）
- **脚本复核** = 前台脚本独立读取（可选；若执行单独记账）

| # | 调用 | 发起方 | 桥侧上游请求 | 网关收到的账户级元数据 | MUSE 最终可见 |
|---|---|---|---|---|---|
| 0 | P1 入口自检 tools/list | MUSE 原生（**已于 2026-11-11 完成**，§8.5） | 0 | 0 | 33 工具清单 |
| 1 | 窗内 tools/list（step1） | MUSE 原生 | 0 | 0 | 工具清单 |
| 2 | reminders_lists（step2） | MUSE 原生 | 1× 元数据 | 3 列表（含 Production 列表） | **仅 1 列表**（白名单过滤） |
| 3 | reminders_list(list_ids=[目标])（step3 非空读取） | MUSE 原生 | 1× 元数据 + 1× 目标条目 | 3 列表 + 目标条目 | 目标列表条目（非空断言） |
| 4 | 删除后复读 reminders_list | MUSE 原生 | 1× 元数据 + 1× 目标条目 | 3 列表 + 目标条目 | **0 条**（清理证据） |
| 5 | 删除后直连复读 reminders_list | 工程复核 | 1× 元数据 + 1× 目标条目 | 同上 | 0 条（复核） |
| 6 | （可选）脚本独立复读 | 脚本复核 | 1× 元数据 + 1× 目标条目 | 同上 | 0 条；若执行单独记账 |
| — | 写调用 | 无 | **0（窗内零写）** | — | — |

**计划合计（不含可选行 6）：账户级元数据 4 次、条目 3 次、写 0 次；含脚本复核上限 5/4。**
**预算上限：枚举（账户级元数据）≤6、条目 ≤5、health ≤12、写 0；逐次记账，超出即停止。**
OAuth 刷新请求（`/token`）不经桥、不计入枚举/条目预算，单独记账（预计 ≤2 次，TTL 1 小时已实测）。
范围核对义务：每次元数据响应若出现非目标列表进入 MUSE 可见范围（≠1）→ 立即停止 + FAIL（§9）。

### 8.5 MUSE 原生入口核实（v2.3：实测已完成）

**2026-11-11 前台自检结果（用户在 MUSE 前台执行，仅工具发现、零业务调用）**：

| 项 | 结果 |
|---|---|
| 入口 | `https://seoul-forge-01.tail4db0d9.ts.net/mcp` **连通** |
| 首次 tools/list | `401 invalid_token`（本地 access token 为当日 16:38 取得、TTL 1 小时，已过期） |
| 恢复 | **Manager 只读自动续期成功**（state 版本 74→75），随后 tools/list 正常 |
| 工具清单 | 共 33 个：apple 2、mail 7、calendar 5、**reminders 5**（lists/list/create/update/delete）、contacts 14、work_done 1 |
| 业务调用 | **零**（未调用任何 reminders 业务工具，未读写任何提醒数据） |
| 重新授权 | **不需要，零授权缺口**（自动续期即恢复；OAuth 刷新机制实证，见 §7.2） |

**结论**：MUSE 原生入口**已就绪**，最小接入方案无需启用（降级为应急预案）。AG07 三类记录与本次自检记录分开标注：

| 记录 | 性质 | 出处 |
|---|---|---|
| 前台脚本 | MUSE 机上用户触发执行的客户端脚本 | AG07 回执 `client_script` 字段（窗内作为可选脚本复核） |
| 包装层日志 | 客户端包装层 `manager_configuration writes_enabled=False` 全程记录 | AG07 回执 + **本次自检 state 74→75 只读续期记录** |
| 工程直连 | WB 经 `/mcp` 独立 client 直连（准备验证与复核，**不作为 MUSE 发起证据**） | §8.3 通道 c |

**发起方确认记录（脱敏，回执仅记以下字段）**：
- 网关侧：请求所载 Bearer token 绑定的 **client_id 名称**（MUSE 与工程直连/脚本复核**分用不同 client/token**——P0 强制，日志按 client_id 区分发起方）+ `mcp-session-id` 尾号
- 客户端侧：包装层日志时间戳 ↔ 前台记录时间戳互证
- 记录内容：时间戳、client_id、session 尾号、工具名、返回条数；**不含令牌、完整列表 ID 或任何敏感值**

**应急预案（最小接入方案，仅入口失效时启用）**：
1. MUSE 客户端添加 streamable HTTP MCP server：`https://seoul-forge-01.tail4db0d9.ts.net/mcp`
2. 完成 OAuth 登录（访问密钥 → 授权码 → 令牌；复用已注册 client）
3. `tools/list` 自检（0 上游）确认 readOnlyHint 标注；仍未就绪则不开窗、回执如实记录

## 9. 数据范围验证（禁止隐式扩大到其他列表）

| 层 | 验证项 | 时机 |
|---|---|---|
| 桥层（工程直连准备验证） | 桥 allowlist 仅含新 ID `591B****6450`；桥请求日志逐条核对 | 窗前 + 窗内 |
| 网关层 | `reminders_lists` 返回**仅 1 个列表**；其余列表（含 Production"提醒 ⚠️"）隔离不可见——白名单三重匹配 + `list()` 遍历逻辑双重保证（**隔离实测已证实机制**，窗内对真实数据复验） | 窗内 step2 |
| 条目层 | 条目请求**仅**新列表 ID；白名单外 `list_ids` 应 `NOT_FOUND`；每条返回条目 listID 归属校验；请求完成后核对桥访问日志 | 窗内 step3 前后 |
| 违反判定 | 任何非目标列表在 step2 可见或 step3 可达 → **立即停止 + 回退 + 判定 FAIL** | 全程 |

## 10. 合成事项安排（创建/取证/清理责任；失败或到期路径）

- **创建**：MUSE 用户（你）在 MacServer 原生提醒事项 App 于窗前创建**恰 1 条**合成事项（字段沿用 R1-04 §1.3 规格，MARKER `R2SYN20261111A`）；输错不重试
- **取证**：窗内经 Seoul 路由真实非空读取，三通道证据见 §8.3
- **清理责任（正常路径）**：用户精准删除该事项（只删一条）→ 窗内经 Seoul 路由复读确认 0 条（通道 a+b）→ 工程直连复读复核（通道 c）→ 零残留
- **清理责任（失败/到期路径）**：
  - 窗口到期或任一停止条件触发时，无论进行到哪一步立即收尾回退；此时**删除合成事项的责任仍归用户**（原生 App 精准删除，WB 不代删、不重试任何写入类操作）
  - 若到期时"删除后 0 条复验"未在窗内完成：零残留证据降级为"用户已删除 + 原生 App 可见性确认"；**工程直连复读复验列为待一次批准的收尾项**（桥闸门关闭状态下需临时单次开启），不默认执行
  - 复验路径固定：用户删除 → 原生 App 确认 → 待授权的一次工程直连复读（经桥绑定路径）→ 零残留回执补充
- **恢复**：双端恢复核验（§11）

## 11. 双端恢复核验（窗末逐项）

| 端 | 核验项 |
|---|---|
| Seoul 基线容器 | 回基线镜像 `f3e697fe` + health 200；容器 env 无残留注入键（`docker inspect` 核对，输出即时掩码） |
| Seoul 临时监听 | 临时 sshd drop-in 移除、sshd 配置与窗前一致；18765 端口释放（`ss -ltn` 核对）；反向连接消失；T3 临时 env 文件删除 |
| Seoul watchdog | 终态 DISARMED / 到点自主回滚记录在案 |
| MacServer Bridge 健康 | 桥进程/服务健康；gate=false 403 复核；plist 与改绑备份逐键比对仍仅两键差异 |
| MacServer 新绑定保留 | 绑定仍为 `591B****6450`（源 `9BBB****CCB0` 不变）——R1 成果不被 R2 破坏 |
| MacServer 临时项 | 反向 ssh 进程消失；S0-lite 临时令牌删除；看门狗退出 |
| Seoul 隔离验证产物 | `/tmp/r2-isolated/`（合成数据、无敏感值）窗末一并清理或随回执归档说明 |

## 12. 失败停止条件

1. T0 看门狗未就绪 → **不开窗、不执行任何临时变更**，申请作废回执
2. step1 工具发现 / step2 列表发现 任一 FAIL → 停止、回退、如实回执（不进入 step3）
3. step3 空响应或任一字段 FAIL → 如实记录 UNVERIFIED/FAIL，**不重试、不重建、不编造**
4. 隧道/容器/闸门任一异常 → 看门狗自动回退 + 人工确认后收尾
5. 任何非目标列表数据出现（§9 违反判定）→ 立即停止 + 判定 FAIL
6. 窗口到期 → 无论进行到哪一步，立即收尾回退（AG07 硬期限纪律；合成事项清理按 §10 失败/到期路径）

## 13. 执行步骤（授权后按序）

| 步 | 内容 |
|---|---|
| P0 | 准备验证（工程直连）：核对 Seoul 现状（基线容器/无临时监听/mac-operator 受限账户与密钥在位）；核对候选镜像 ID 与 gateway 模块文件哈希；S0-lite 重发桥令牌；核对桥 allowlist 仅新 ID；**确认工程直连使用独立 OAuth client/token（与 MUSE 分离，供日志区分发起方）** |
| P1 | 用户创建合成事项（恰 1 条，MARKER `R2SYN20261111A`）；确认前台脚本版本未变；**MUSE 原生入口自检已完成（2026-11-11，§8.5：连通 + tools/list 33 工具 + 自动续期恢复，零业务调用）**——窗内仅复用该入口，应急预案备用 |
| P2 | **T0 双端看门狗武装并确认（pid+期限记录）→ 然后依次 T1 隧道 → T2 容器切换 → T3 网关绑定注入（§3 五项；创建前准备与首次启动生效为同一步骤）→ T4 闸门开启**；各步回退预检 |
| P3 | 按 §8.2 顺序执行：step1 工具发现 → step2 列表发现（范围验证 §9）→ step3 非空读取（三通道证据 §8.3，12 项保真断言沿用 R1-04）；逐调用按 §8.4 表记账 |
| P4 | 用户删除事项 → Seoul 路由复读 0 条（通道 a/b）→ 工程直连复读复核（通道 c）→ 零残留证据 |
| P5 | 双端恢复核验（§11 全表）→ 清理临时令牌/脚本/env 文件/drop-in |
| P6 | 脱敏回执 + 提交号 |

**窗内零写操作**：写探针已移出本轮（§7.1），窗内 `reminders_create/update/delete` 零调用。

## 14. 隔离验证记录（本轮离线完成，2026-11-11；**总控已审查，沿用不重跑**）

- 方法：在 Seoul 以 `docker run --rm` 一次性容器直接 import 候选镜像内 `dist/modules/reminders/gateway/{config,service}.js` 实际代码；stub transport（合成 3 列表 + 合成条目）；**未触生产容器、未触真实 iCloud 数据、无网络暴露**
- 结果：**13/13 PASS**——解析器顺序 3 项（含错误顺序检出）、JSON 格式与空拒绝 2 项、单列表过滤 5 项（3→1 可见、留空仅白名单、显式 list_ids 保真、白名单外 NOT_FOUND、非绑定列表不可达）、写拒绝 3 项（create/update/remove → PERMISSION_DENIED 零转发）
- 产物：Seoul `/tmp/r2-isolated/{service_test.mjs,out.txt}`（合成数据，无敏感值）；明细随验证记录提交

## 15. 提交

- 本申请 v2.3 + 放行核验记录（`R2_PRECHECK_VERIFICATION_20261111.md`，含权限收窄与连接器实测）+ 暴露评估（`R2_SECRETS_ENV_EXPOSURE_ASSESSMENT_20261111.md`）: 见下方提交号
- 引用基线: `3e422b1`（R1 PASS）、`7e87950`（归档收尾）、`4ce6074`（v2）、`b009fab`（v2.1）、`83415d8`（v2.2）、AG07 回执（机制先例）
- 核实出处（本轮离线，2026-11-11）：候选镜像 `dist/modules/reminders/gateway/{config,service,transport}.js`、`dist/auth/provider.js`、`dist/server/httpApp.js`、`dist/bin/http.js`；生产网络 `docker network inspect` 实测；AG05 隧道受限模板；AG07 回执
