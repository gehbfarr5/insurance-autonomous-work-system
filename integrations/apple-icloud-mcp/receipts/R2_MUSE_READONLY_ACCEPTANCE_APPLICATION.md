# R2 MUSE 前台只读验收申请（一次审批制）

- **申请编号**: R2，**v2**（2026-11-11，可执行准备完成版）
- **基线**: R1-04 续跑回执（R1 PASS）@ `3e422b1`；归档收尾 @ `7e87950`
- **v2 修订说明**: 全部待核实项已完成离线核实——注入键从候选镜像 `dist/modules/reminders/gateway/config.js` 全文核实；写拒绝路径从 `service.js` 核实；凭据刷新从 `auth/provider.js` 核实；隧道变更从 AG07 回执 + AG05 受限模板核实；新增实际文件/进程/权限变化表、看门狗先就绪顺序条款、失败/到期合成事项清理责任与复验路径
- **性质**: 离线准备已由本文件完成；**Seoul 真实变更与 MUSE 验收均待本申请一次批准后执行**
- **目标**: 通过 Seoul 网关候选路由 + MacServer 新测试列表绑定，完成 MUSE 前台独立验收——补上 AG-07 遗留的 UNVERIFIED（非空读取 0 条），产出**目标匹配、真实非空字段、清理、恢复**四类证据

## 1. 复用资产（现状已核实，2026-11-11）

| 资产 | 现状 | 版本/标识 |
|---|---|---|
| Seoul 网关基线容器 | 运行中（AG07 回滚后），`127.0.0.1:17734→17733`，health 可达 | 镜像 `sha256:f3e697fe…c0da2f0` |
| Seoul 网关**候选镜像** | 本地镜像在库，未运行；reminders gateway 模块已从镜像内 dist 代码核实 | `faa6e380ee4b`，tag `candidate-ag05-delivery-20261108`，构建自 PR23 head `0da5f6e0…43f1` |
| gateway 模块文件（候选镜像内） | `dist/modules/reminders/gateway/{config,service,transport,index,types}.js` | 本轮逐一读取核实 |
| MacServer 桥 | production、闸门关、绑定新列表 | 二进制冻结 `f78e24e5…3074`；绑定 `591B****6450`（R1-04 续跑写入，源 `9BBB****CCB0`） |
| 客户端脚本 | AG07 使用的前台触发脚本 | `~/workspace/carddav-mcp-client/verify_muse_test_20261110.py`（MUSE 机，P1 前确认版本未变） |
| 隧道受限模板 | AG05 交付的 sshd drop-in 与 authorized_keys 模板 | `resident-tunnel/templates/seoul/60-macserver-gateway.conf.template`、`authorized_keys_entry.template` |
| Seoul secrets.env | 仅 iCloud 账户/应用密码/读写开关（READ=true、WRITE=false），**无桥注入键** | 本轮 server_read_file 核实 → 注入键需窗内以临时 env 注入 |

## 2. 数据范围事实（全部从候选镜像 dist 源码核实，反扩散条款的依据）

- **桥枚举端点暴露全部 iCloud 列表**（续跑 W0 `visible_list_count=3`）——桥自身不做列表隔离
- **候选镜像网关层硬约束白名单**（`gateway/service.js`，本轮核实）：
  - `fetchAllowedICloudLists()` 只返回 allowedLists 白名单中 listId 命中 **且** expectedSourceId/SourceName/SourceType 三重匹配的列表，其余一律丢弃
  - `list()` 未传 `list_ids` 时仅遍历上述白名单过滤结果——**留空也不会隐式查全部列表**（与基线直连 CalDAV 行为不同）
  - 传入白名单外的 `list_ids` → 直接 `NOT_FOUND`
  - 每条 Bridge 返回条目做 listID 归属一致性校验，不匹配即 `UPSTREAM_ERROR`
  - allowedLists 缺失或空 → 网关拒绝启动（`config.js`，显式绑定强制）
- **transport**（`gateway/transport.js`）：`GET {endpoint}/reminders/lists` 与 `GET {endpoint}/reminders/lists/{id}/items`，`Bearer` 头，listID URL 编码
- **因此 R2 的数据范围边界 = allowedLists 白名单（网关硬约束）+ 桥 allowlist（双层）**，两层都必须指向 `591B****6450`，并在窗内逐项验证（§6）

## 3. 注入键清单（候选镜像 `gateway/config.js` 核实，T3 注入内容）

| 类别 | env 键（多别名，取一） | R2 取值 |
|---|---|---|
| 端点 | `MACSERVER_EVENTKIT_ENDPOINT`（别名 `EVENTKIT_GATEWAY_ENDPOINT`/`EVENTKIT_BRIDGE_ENDPOINT`，默认 `http://127.0.0.1:18765`） | `http://172.19.0.1:18765`（容器经 docker bridge 网关达宿主隧道端口） |
| 桥令牌 | `MACSERVER_EVENTKIT_AUTH_TOKEN`（别名 `MACSERVER_EVENTKIT_TOKEN`/`EVENTKIT_BRIDGE_AUTH_TOKEN`/`EVENTKIT_BRIDGE_TOKEN`） | S0-lite 重发的桥令牌（0600 临时 env 文件，窗末删除） |
| 超时 | `*_TIMEOUT_MS`（500–60000，默认 5000） | 默认 |
| 响应上限 | `*_MAX_RESPONSE_SIZE`（1KB–50MB，默认 2MB） | 默认 |
| **列表白名单** | `MACSERVER_EVENTKIT_ALLOWED_LISTS`（别名 `EVENTKIT_ALLOWED_LISTS`；JSON 数组或 `listId:sourceId:sourceName:sourceType` 逗号格式） | `591B****6450:9BBB****CCB0:calDAV:iCloud`（**仅此一项**；缺失或空网关拒绝启动） |

## 4. 需要的临时变更（授权后生效，全部限时；实际文件/进程/权限变化）

| # | 变更 | 实际文件/进程变化 | 权限 | 回退 |
|---|---|---|---|---|
| T0 | 双端看门狗武装（**必须先于 T1–T4**，见 §5） | Seoul prechange watchdog 进程 ×1（期限 3562s）；MacServer 本地看门狗 supervisor ×1 | — | 到点自主回滚（AG07 双端精确到点先例） |
| T1 | 反向 SSH 隧道 MacServer→Seoul | Seoul：新增临时 sshd drop-in（仅 `PermitListen 172.19.0.1:18765 127.0.0.1:18765`、`GatewayPorts clientspecified`、ForceCommand /bin/false）+ sshd reload；MacServer：临时反向 ssh 进程（`-R 127.0.0.1:18765`，受限密钥） | drop-in 0644 | 窗末移除 drop-in + 结束 ssh 进程 + 端口释放核验（AG07 实证：drop-in 移除、端口释放零残留） |
| T2 | Seoul 容器镜像切换 | 基线 `f3e697fe` → 候选 `faa6e380`，容器重建（compose） | 不变（mem 256m、pids 128、no-new-privileges 沿用） | 窗末回滚基线镜像并核验 health 200（AG07 自动回滚机制复用） |
| T3 | 网关绑定注入 | 容器 env 注入 §3 五项（临时 env 文件） | **env 文件 0600、目录 0700，窗末删除** | 窗末回滚（manifest.env 备份机制复用） |
| T4 | MacServer 桥闸门 gate=true | plist 单键变更；launchd 服务重载（AG07 先例 pid 变更一次） | plist 备份 0600 | 窗末恢复 false 并核验 403（既有 gate 脚本纪律） |

## 5. 时限与看门狗（先就绪顺序条款）

- **单窗 3600 秒**（与 AG07 同规格），截止时刻为硬期限
- **顺序强制条款：T0 双端看门狗武装并确认在跑（pid + 期限记录）之后，才允许执行 T1–T4 任何一项**；任一看门狗未能就绪 → 不开窗、不执行任何临时变更
- Seoul prechange watchdog：到点自主回滚基线容器（AG07：pid 531350、timeout 3562s、精确到点触发）；MacServer 本地看门狗：到点恢复 gate=false（AG07：SIGTERM 到点、开关回 false）
- 每步实际请求逐次记账，超预算即停止

## 6. 权限与凭据

- Seoul `TOKEN`/`ADMIN_PASSWORD`/`ICLOUD_APP_PASSWORD`：不读取、不落盘、回执掩码
- MacServer 桥令牌：R2 授权后 S0-lite 重新提取，0600 受控目录；注入仅经 T3 临时 env 文件
- **写权限三层锁定（已核实）**：
  1. 候选镜像 gateway `service.js`：`create/update/remove` **硬编码** `rejectWriteOp` → `PERMISSION_DENIED`，零转发/零 VTODO 回落——**不依赖 env 开关，写请求不会到达桥**
  2. `ALLOW_REMINDERS_WRITE_1=false`（capability 门，provider 层）
  3. 桥 `REMINDERS_WRITE=false` + gate 关闭
- **服务端写拒绝核实方式（窗内一次被拒探针）**：step3 之后经直接原生 MCP 调用一次 `reminders_create`（目标列表）→ 预期 `PERMISSION_DENIED`；该请求在网关服务层被拦截，**零桥请求、零上游**；计入写探针预算 ≤1，不触达 Apple
- **凭据刷新行为（源码出处已核实）**：网关 OAuth 令牌轮换机制位于候选镜像 `dist/auth/provider.js` 的 `exchangeRefreshToken`（refresh token 30 天 TTL、`rotateRefresh` 轮换、重放检测即 revoke 整个 token family）；AG07 回执 `apple_login: Successful (read-only token auto-refresh applied)` 为前台出处；R2 窗内在三通道 (b) 包装层日志复验并记录刷新行为
- 工程直连（WorkBuddy→桥/网关）：仅限准备验证与窗内直连核验，不替代 MUSE 验收证据

## 7. 数据范围验证（禁止隐式扩大到其他列表）

| 层 | 验证项 | 时机 |
|---|---|---|
| 桥层（工程直连准备验证） | 桥 allowlist 仅含新 ID `591B****6450`；桥请求日志逐条核对 | 窗前 + 窗内 |
| 网关层 | `reminders_lists` 返回**仅 1 个列表**（新 ID）；其余列表（含 Production"提醒 ⚠️"）隔离不可见——白名单三重匹配 + `list()` 遍历逻辑（§2）双重保证 | 窗内 step2 |
| 条目层 | 条目请求**仅**新列表 ID；白名单外 `list_ids` 应 `NOT_FOUND`；每条返回条目 listID 归属校验；请求完成后核对桥访问日志 | 窗内 step3 前后 |
| 违反判定 | 任何非目标列表在 step2 可见或 step3 可达 → **立即停止 + 回退 + 判定 FAIL** | 全程 |

## 8. 合成事项安排（创建/取证/清理责任；失败或到期路径）

- **创建**：MUSE 用户（你）在 MacServer 原生提醒事项 App 于窗前创建**恰 1 条**合成事项（字段沿用 R1-04 §1.3 规格，MARKER `R2SYN20261111A`）；输错不重试
- **取证**：窗内经 Seoul 路由真实非空读取，**三通道分别记录证据**：
  - (a) **前台触发脚本**：MUSE 用户前台独立触发（客户端脚本执行记录）
  - (b) **脚本执行包装层**：包装层日志（`manager_configuration writes_enabled=false` 全程；Apple 登录令牌自动刷新记录在此通道核验）
  - (c) **直接原生 MCP 工具调用**：对网关 streamable HTTP 的直接工具调用记录（readOnlyHint 路由）
  - 外加 (d) 被拒写探针记录（§6，仅通道 c）
- **清理责任（正常路径）**：用户精准删除该事项（只删一条）→ 窗内经 Seoul 路由复读确认 0 条（通道 a+c）→ 窗内工程直连复读复核 → 零残留
- **清理责任（失败/到期路径）**：
  - 窗口到期或任一停止条件触发时，无论进行到哪一步立即收尾回退；此时**删除合成事项的责任仍归用户**（原生 App 精准删除，WB 不代删、不重试任何写入类操作）
  - 若到期时"删除后 0 条复验"未在窗内完成：零残留证据降级为"用户已删除 + 原生 App 可见性确认"；**工程直连复读复验列为待一次批准的收尾项**（在桥闸门关闭状态下需临时单次开启），不默认执行
  - 复验路径固定：用户删除 → 原生 App 确认 → 待授权的一次工程直连复读（经桥绑定路径）→ 零残留回执补充
- **恢复**：双端恢复核验（§9）

## 9. 双端恢复核验（窗末逐项）

| 端 | 核验项 |
|---|---|
| Seoul 基线容器 | 回基线镜像 `f3e697fe` + health 200；容器 env 无残留注入键（`docker inspect` 核对，输出即时掩码） |
| Seoul 临时监听 | 临时 sshd drop-in 移除、sshd 配置与窗前一致；18765 端口释放（`ss -ltn` 核对）；反向连接消失；T3 临时 env 文件删除 |
| Seoul watchdog | 终态 DISARMED / 到点自主回滚记录在案 |
| MacServer Bridge 健康 | 桥进程/服务健康（health OK）；gate=false 403 复核；plist 与改绑备份逐键比对仍仅两键差异 |
| MacServer 新绑定保留 | 绑定仍为 `591B****6450`（源 `9BBB****CCB0` 不变）——R1 成果不被 R2 破坏 |
| MacServer 临时项 | 反向 ssh 进程消失；S0-lite 临时令牌删除；看门狗退出 |

## 10. 失败停止条件

1. T0 看门狗未就绪 → **不开窗、不执行任何临时变更**，申请作废回执
2. step1 工具发现 / step2 列表发现 任一 FAIL → 停止、回退、如实回执（不进入 step3）
3. step3 空响应或任一字段 FAIL → 如实记录 UNVERIFIED/FAIL，**不重试、不重建、不编造**
4. 隧道/容器/闸门任一异常 → 看门狗自动回退 + 人工确认后收尾
5. 任何非目标列表数据出现（§7 违反判定）→ 立即停止 + 判定 FAIL
6. 窗口到期 → 无论进行到哪一步，立即收尾回退（AG07 硬期限纪律；合成事项清理按 §8 失败/到期路径）

## 11. 执行步骤（授权后按序）

| 步 | 内容 |
|---|---|
| P0 | 准备验证（工程直连）：核对 Seoul 现状（基线容器/无临时监听/mac-operator 受限账户与密钥在位）；核对候选镜像 ID 与 gateway 模块文件哈希；S0-lite 重发桥令牌；核对桥 allowlist 仅新 ID |
| P1 | 用户创建合成事项（恰 1 条，MARKER `R2SYN20261111A`）；确认前台脚本版本未变 |
| P2 | **T0 双端看门狗武装并确认（pid+期限记录）→ 然后依次 T1 隧道 → T2 容器切换 → T3 网关绑定注入（§3 五键）→ T4 闸门开启**；各步回退预检 |
| P3 | step1 工具发现 → step2 列表发现（范围验证 §7）→ step3 非空读取（三通道证据，字段断言沿用 R1-04 12 项保真断言集）→ step3.5 被拒写探针一次（§6） |
| P4 | 用户删除事项 → Seoul 路由复读 0 条（通道 a+c）→ 工程直连复核 → 零残留证据 |
| P5 | 双端恢复核验（§9 全表）→ 清理临时令牌/脚本/env 文件/drop-in |
| P6 | 脱敏回执 + 提交号 |

**请求范围预算**（窗内，逐次记账）：枚举 ≤4、条目 ≤8（全部新列表）、health ≤12、写探针 ≤1（零上游）；超出即停止。

## 12. 提交

- 本申请 v2: 见下方提交号
- 引用基线: `3e422b1`（R1 PASS）、`7e87950`（归档收尾）、AG07 回执（机制先例：双端看门狗到点自主回滚、隧道 drop-in 零残留）
- 核实出处（本轮离线，2026-11-11）：候选镜像 `dist/modules/reminders/gateway/{config,service,transport}.js`、`dist/auth/provider.js`；Seoul `secrets.env`（无桥注入键）；AG05 隧道受限模板；AG07 回执
