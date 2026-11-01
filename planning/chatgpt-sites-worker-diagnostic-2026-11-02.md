# ChatGPT Sites v2 Worker — 一轮可观测排障与止损（2026-11-02）

> **阶段结果：`WORKER_SOURCE_ACCESS_BLOCKED / DIAGNOSTIC_ADAPTER_TESTED / NOT_DEPLOYED`**。本文件为本轮实际调查回执与执行手册。**真实 `icloud_contacts_groups_list` 仍未完成端到端验收**。

## 当前已核实的事实

- 继续复用原私人 Site `iCloud MCP Capability Test`，不是 v0.1.0/v1.0.0 导入型 MCP 插件。个人插件库可读其 App-backed 绑定（`.app.json` 和 `.codex-plugin/plugin.json`），但**插件归档不是 Site Worker 源码**。
- ChatGPT Library 中保留此 Site 的 `library_artifact_type=site` 页面文本投影，`source_version_number=2`、`projection_revision=10`，且显示“上游未配置”字样。该信息只是一份页面文本快照，**不能作为 Worker 真实 Secret 绑定未配置的结论**，但值得在源码恢复后检查运行时是否正确读取 `ICLOUD_BRIDGE_URL` 和 `ICLOUD_BRIDGE_TOKEN`。
- GitHub 目标仓库内容搜索 `icloud_contacts_groups_list`、`ICLOUD_BRIDGE_URL`、`bridge request failed` 等没有找到运行中的 Site Worker 源码。此前 Site 工作流有独立源码仓库/挂载缺失报告，此次当前会话没有 Site 后端编辑、Secret 设置、发布/回滚的接口，Browser API 则因缺失发起端浏览器上下文拒绝读取。
- **首尔只读验证（本轮）：** `chatgpt-sites-icloud-bridge.service` 为 active/running；生产 MCP Docker 容器 healthy。本机 `http://127.0.0.1:17735/v1/contacts/groups/list` 未带 Bearer 的 POST 返回 **401**（认证拦截正常）。桥接 Python 源中实际存在专门的 `call_real_groups` 与 `/v1/contacts/groups/list` 路径。**未在本轮读取或输出任何 Token/Secret 或真实联系人内容，也未重启/修改服务**。
- **外部连通性未证实**：本轮从独立沙箱访问首尔公开域名遭遇 DNS 失败；网页抓取端点也未成功取得响应。这只说明测试执行环境的网络受限，**不能证明 Site Worker DNS/TLS 有问题，也不能证明桥接公网可达**。首尔本机 HTTP 200/401 更不能替代 Site 出站测试。
- 用户 2026-11-02 的此前验收：普通 Chat 能发现并调用 Site v2 的 `icloud_contacts_groups_list`，但返回 `INVALID_ARGUMENT: iCloud bridge request failed`，且首尔桥接无相应请求记录。本轮没有新的真实 Chat 工具调用成功证据。

## 已完成的版本化候选模块

目录：[integrations/chatgpt-sites/worker-diagnostics](../integrations/chatgpt-sites/worker-diagnostics/README.md)

- `bridge-client.mjs`：纯服务端 ESM，无用户自定义 URL/tool name，固定 POST `/v1/contacts/groups/list` 和 `{}`；只允许 HTTPS 基址；使用 Site Secret（不进入前端）；返回时仅保留 `name` 和整数 `member_count`。
- `bridge-client.test.mjs`：Node 22 `node --test` 本地离线 **8/8 PASS**，覆盖成功、字段裁剪、缺配置、HTTP/URL 拒绝、401、fetch 抛错、JSON/schema 错误、Abort 超时。测试仅使用虚构内容，没有访问真实 iCloud。
- `README.md`：接入示例和分阶段日志规范，候选模块**尚未嵌入现有 Site v2，也尚未发布**。不能将 7/7 当作端到端 PASS。

## 下一轮唯一允许的 Site 改动（需要真正 Site 编辑环境）

1. **先恢复现有 Site v2 源码**：从 Work / Sites 原项目进入源代码编辑和部署面，核对项目身份和当前发布版本；导出/留存**当前 v2 备份**与回滚操作。不要创建第三个 Site 或重建旧式 MCP 插件。
2. 检查真实 `icloud_contacts_groups_list` handler：Secret 是在**服务器端**访问吗？是否读取正确键名？环境变量绑定缺失时是否在 `fetch()` 前抛错？是否意外以浏览器 JS 调用？是否构造了错误的 URL/路径？
3. 只对这一条只读工具加入或适配版本化的 `bridge-client.mjs`；保留 `demo_contacts_groups_list` 不变。记录允许的阶段与 trace ID：`config_present`, `request_prepared`, `fetch_started`, `response_received`, `success` 或对应脱敏错误分类。**不记录 URL、任何 Secret、异常原文、客户数据或响应正文**。
4. **先 mock 再外连**：在 Site 同一执行运行时做虚构 HTTP mock，验证只读请求及 Secret 缺失路径；从真实 Site Worker 运行网络直接发起 HTTPS 请求时，依据 trace ID 检查桥接是否有请求记录；不得用首尔本机 curl 冒充外部测试。
5. 有备份后发布一次、只做真实 Chat 一次只读 `icloud_contacts_groups_list` 验收；如果调用成功，核对其返回为真实分组名称/人数而非 demo 固定两组。只有全链路成功才记录 `SITES_CHAT_ICLOUD_READ_PASS`。
6. **止损条件**：若仍无法恢复 Site 源码、无法从 Worker 产生分阶段日志、或部署无法可靠回滚，停止这条 Site v2 的重复 Secret 改写/猜测性修补，不扩大 33 项工具。保留原运行版本和所有有效 Agent 授权，另行决定版本化 Site 的托管方式。

## 授权与生产安全

- Chat 与 Work 使用**同一个 Sites 插件**时复用该 Site 的一套独立服务端授权；两种运行模式分别做工具可用性验收。Work 若采用独立直连才另建 OAuth 身份。
- 首尔桥接继续实施**服务器端**方法白名单与输出字段裁剪；原 MCP 的 `scope=mcp` 不等于只读权限。不要将全 MCP Token 放在 Site、前端、日志或公开仓库。
- 之前曾有凭据在聊天中暴露。应列入待计划轮换清单，先审查对其他 Agent 的依赖和无损替换步骤，再在安全通道轮换；此次未更改凭据。
- 完整 33 项工具接入需另列只读/写入、批量修改、删除、幂等性/ETag 与显式审批门槛。**当前仅聚焦真实分组只读。**

## 2026-11-02 新增重要发现：Funnel `/bridge` 路由

通过首尔服务器实际运行的 `tailscale funnel status --json` **只读取证**（没有改变任何 Funnel 配置）：

- HTTPS :443 的 handler `/` 指向 **127.0.0.1:17734**（原 MCP）；
- HTTPS :443 的 handler `/bridge` 指向 **127.0.0.1:17735**（独立受限桥接）；
- 17735 仅监听 **127.0.0.1**，因此云端 Site 必须通过已授权的公开 Funnel 路由访问，不能直接访问服务内部环回端口。
- 这揭示一个**具体、可验证的路径错配风险**：如果 Site Worker 使用不带 `/bridge` 的 HTTPS 基址，向 `/v1/contacts/groups/list` 发起调用，就可能命中根路由的原 MCP 而非只读桥接。正确的候选外部路径应为 `/bridge/v1/contacts/groups/list`，但**实际 Site Secret 的 URL 值未读取，尚不能断定它当前缺少前缀**。
- 官方 Tailscale Serve/Funnel `--set-path` 文档说明前缀挂载和反向代理机制；站点运行时是否准确匹配并把前缀转给预期后端，仍需真实 Site Worker 外连证据确认。
- 已更新版本化候选 `bridge-client.mjs`，严格接受 HTTPS 根路径或 `/bridge` 基址，保留固定只读 endpoint，新增 /bridge 路由单元测试，离线 **8/8 PASS**。没有修改真正的 Site v2 Worker 或生产服务器。
- 本轮 Chat 会话对现有 `icloud_contacts_groups_list` **再次实际只读调用**：仍返回 `INVALID_ARGUMENT: iCloud bridge request failed`。随后首尔桥接最近五分钟的 `journald` 统计为 0 行；这与“没有观察到桥接请求”一致，但**日志可能没有完整记录所有请求**，不能单独证明请求绝对没到达。
- 从首尔本机访问自己 Funnel 域名的测试出现 TLS 校验证书错误；既有环境存在内外路由差异，**不能使用该本机回环测试替代云端公网连通性测试**，也不要用 `curl -k` 的状态码冒充端到端 TLS 通过。

**Worker 源码恢复后的新增第一步：** 在不输出 Secret 值的前提下，审查 `ICLOUD_BRIDGE_URL` 的**URL pathname 是否等于 `/bridge`**，并通过 Worker 分阶段日志确认 `fetch_started` 是否触发；不要再次盲目更换 Token 或重建插件。

## 已知状态

| 验收环节 | 状态 |
| --- | --- |
| Sites → Chat MCP tool discover/call | **PASS（虚构 demo）** |
| Site v2 的真实 `icloud_contacts_groups_list` 工具可调用性 | **PASS（调用入口存在，但结果报错）** |
| 首尔受限桥接进程及本地认证拦截 | **PASS（基础健康检查）** |
| Worker 源码可控/可部署 | **BLOCKED（尚未取得源码编辑入口）** |
| Worker → 首尔桥接公网连通 | **UNVERIFIED** |
| Chat → 真实 iCloud 分组数据 | **FAIL / NOT PASS** |
| 其余 32 项扩展 | **NOT STARTED** |
