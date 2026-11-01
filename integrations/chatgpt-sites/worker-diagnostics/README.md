# iCloud Site Worker — 一次性只读诊断模块（未部署）

状态：`SOURCE_ADAPTER_TESTED / ORIGINAL_SITE_SOURCE_NOT_AVAILABLE / NOT_DEPLOYED`。

## 用途

作为原有 **iCloud MCP Capability Test v2** 的 Site **服务端 Worker** 调用 `icloud_contacts_groups_list` 时的候选替换模块。它不是完整 Site 源码，不能直接上传代替现有站点，也不适用于浏览器端 JS。

- 只允许 POST `ICLOUD_BRIDGE_URL + /v1/contacts/groups/list`，固定 `{}` 请求体。
- 服务端读取 `ICLOUD_BRIDGE_URL`、`ICLOUD_BRIDGE_TOKEN`；绝不可放进网页或 GitHub。
- 支持请求分阶段诊断：`config_missing`、`config_url_invalid`、`fetch_started`、`fetch_error`、`fetch_timeout`、`response_received`、`response_schema_invalid`、`success`。
- 日志仅允许追踪 ID、阶段、整数状态码和执行耗时，不记录密钥、完整 URL、原始响应体、联系人明细、异常消息。
- 输出仅限分组名称与整数成员数量，不接受工具名/路径/请求参数传入，不允许任意 MCP 转发。
- **原桥接目前没有经确认的公网访问能力**。仅首尔本机成功和无授权 HTTP 401 不能证明 Sites 出站能够访问它。

## 在恢复 Site 源码后如何接入

1. 在 Work / Sites 编辑器恢复当前 v2 Worker 的真实源码，确认 `icloud_contacts_groups_list` 的服务器端 handler 和环境绑定方式。
2. 将 `bridge-client.mjs` 作为纯服务端模块复制或适配（如果 Site 运行时不支持 ES Modules，需要调整），保留原 `demo_contacts_groups_list` 不变。
3. handler 调用示意：

```js
const result = await listIcloudGroups({
  env: serverEnv, // Site 受保护的服务端环境变量，不能来自客户端请求
  record: ({traceId,phase,status,ms}) => console.info('icloud-bridge-phase', {traceId,phase,status,ms})
});
return result;  // 按 Site MCP 框架的工具结果签名包装
```

4. 每次真实调用只观察脱敏阶段：若没有 `fetch_started` 即失败，则查环境绑定、校验或源代码；若有 `fetch_started` 但没有 `response_received`，查站点外连 DNS/TLS/入口；若是 `response_received` 401/403，查专用授权，切勿输出 Token。
5. 单独做授权外部可达性验证，要求是**从 Site 运行网络**发出，而非首尔本机或其他公网电脑代替。
6. 确认 Worker 改动与部署使用同一 Site 项目，只有在 mock 通过且上线回滚点明确后才发布。
7. Chat 实际调用 `icloud_contacts_groups_list` 并取得真实且脱敏的分组名称/人数，才能标为 `SITES_CHAT_ICLOUD_READ_PASS`。

## 本地离线验收

```bash
node --test bridge-client.test.mjs
```

该测试使用虚构响应和测试专用字符串，**不会向首尔或 iCloud 发起真实请求**。测试通过只代表候选模块的本地逻辑已验证。