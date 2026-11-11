# R2 定点验证记录（隔离环境，2026-11-11）

- **性质**: 离线定点验证，配套 `R2_MUSE_READONLY_ACCEPTANCE_APPLICATION.md` v2.1；**未执行任何生产变更**
- **环境**: Seoul 一次性容器（`docker run --rm`），直接 import 候选镜像 `faa6e380ee4b` 内 `dist/modules/reminders/gateway/{config,service}.js` 实际代码；stub transport；**合成数据（LIST-A/B/C、SRC-A/B/C、ITEM-1/X），未触生产容器、未触真实 iCloud 数据、无网络暴露**
- **产物**: Seoul `/tmp/r2-isolated/{service_test.mjs,out.txt}`（无敏感值；窗末随临时项清理或归档说明）

## 1. 绑定配置解析器验证（候选镜像实际解析器）

| # | 断言 | 结果 |
|---|---|---|
| 1 | 冒号格式顺序 `listId:sourceId:sourceName:sourceType`：第 3 位=名称（iCloud）、第 4 位=类型（calDAV） | PASS |
| 2 | 错误顺序 `…:calDAV:iCloud`（v2 草案）实测产生 name=calDAV/type=iCloud（互换，三重匹配必失败，**不可用**） | PASS（检出） |
| 3 | JSON 格式 `[{"listId","expectedSourceId"}]` 缺省 name/type 自动补 iCloud/calDAV | PASS |
| 4 | 空白名单拒绝启动 | PASS |
| 5 | 桥令牌校验要求 ≥16 字符（验证中发现并确认） | 确认 |

**修正结论**：R2 白名单取值定为 `591B****6450:9BBB****CCB0:iCloud:calDAV`（名称第 3、类型第 4）。

## 2. 单列表过滤与连通语义（service 实际代码）

| # | 断言 | 结果 |
|---|---|---|
| 6 | 桥返回 3 列表 → `listLists()` 网关可见仅 1（`writable:false`） | PASS |
| 7 | `list()` 留空 list_ids → 仅查询白名单列表（1 条目），不隐式查全部 | PASS |
| 8 | 显式 `list_ids=[目标]` → 单条目返回，title/notes 等字段保真 | PASS |
| 9 | `list_ids` 白名单外 → `NOT_FOUND` | PASS |
| 10 | 非绑定列表（LIST-C）不可达 | PASS |

## 3. 写拒绝（隔离证据，替代生产写探针）

| # | 断言 | 结果 |
|---|---|---|
| 11 | `create` → `PERMISSION_DENIED`（零转发） | PASS |
| 12 | `update` → `PERMISSION_DENIED`（零转发） | PASS |
| 13 | `remove` → `PERMISSION_DENIED`（零转发） | PASS |

**结论**：`13/13 PASS`。生产窗口内零写探针、零写调用；写拒绝证据 = 本隔离记录 + `service.js` `rejectWriteOp` 源码。

## 4. 地址与首次启动配置对齐（同轮实测）

- 生产 compose 网络 `insurance-carddav-mcp_default`：Subnet `172.19.0.0/16`，**Gateway `172.19.0.1`**（基线容器 `172.19.0.2`）→ T3 端点 `http://172.19.0.1:18765`
- AG05 drop-in 模板 `PermitListen 172.19.0.1:18765 127.0.0.1:18765` → 监听白名单覆盖容器可达地址与宿主核验地址，双方对齐
- MCP 入口：`server/httpApp.js:303` `app.all('/mcp', requireBearerAuth(...))`，streamable HTTP；`/health` 无鉴权
- 首次启动：`loadConfig(…, { allowNoAccounts: true })`；gateway 配置空白名单拒绝启动 → **T3 注入必须在容器创建时完成**；auth 令牌存储需 `TOKEN_ENCRYPTION_KEY`（secrets.env 已有）

## 5. 敏感信息声明

- 本验证全程使用合成 ID 与合成令牌（`test-token-0123456789abcdef`）；未读取、未输出、未落盘任何真实账户、令牌或密码。
- 同轮 `docker inspect` env 尝试因 Go template 转义失败，仅产生模板错误文本，**无 env 值落盘**。
