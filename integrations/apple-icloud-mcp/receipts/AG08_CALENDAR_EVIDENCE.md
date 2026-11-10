# AG-08 日历能力交付核验与证据归档

## 1. 源码版本与生产镜像对应依据

### 1.1 被测源码版本与来源
- **上游仓库**: `https://github.com/MrZhongzq/apple-icloud-mcp.git`
- **分支**: `master` (跟踪 `origin/master`)
- **提交哈希**: `92bd313154cfbc51fce7e8df5b3f73ea86a6f1c7`
- **提交信息**: `calendar: surface CalDAV ETag in listEvents`
- **提交作者与时间**: Muse, Thu Nov 5 23:33:16 2026 +0800

### 1.2 生产运行镜像与编译代码对应证据
- **当前运行容器**: `insurance-carddav-mcp-carddav-1` (运行于 Seoul 生产节点)
- **当前生产镜像 ID**: `sha256:f3e697fe266f58910c01985f9c906a84479705846c88fd7d2ea1ccf12c0da2f0`
- **镜像构建时间**: `2026-11-09T16:50:19.938790083Z`
- **编译产物 SHA256 校验**:
  * `/app/dist/modules/calendar/service.js`: `c5d529b827f08a89346d26cb6d6fefa9fe97ec70e9849b9df5b8299116472c64`
  * `/app/dist/providers/icloud/caldav.js`: `6264c69c9f09a445861a1307db51bc0b72837958875469260fc08005f1ed76ca`
  * `/app/dist/modules/calendar/tools.js`: `f1578fb3b8ffbc88fe15b13f8b302bfcc15f39b8869ae453844a123eec7dd18e`
  * `/app/dist/parsers/ical.js`: `c16d1e5dcde79c529d25ae82e3fbe98b94779a0f95edf185265a548d576bf92d`
- **源码对应证明**:
  生产容器内 `/app/dist/modules/calendar/service.js` 第 159-166 行完整包含 commit `92bd313` 新增的 ETag 外露代码：
  ```javascript
  if (object.etag) {
      for (const event of parsed)
          event.etag = object.etag;
  }
  ```
  且全天日期正则提取、`loadForWrite` 乐观锁前置拦截逻辑均 100% 具备。

---

## 2. 隔离单元测试执行证据 (144 项全数通过)

- **执行环境**: Seoul 节点独立隔离容器 `docker run --rm -v /opt/insurance-carddav-mcp/source:/app node:22`
- **测试命令**:
  ```bash
  docker run --rm -v /opt/insurance-carddav-mcp/source:/app node:22 sh -c \
    "cd /app && npx vitest run \
     tests/unit/modules/calendar-service.test.ts \
     tests/unit/parsers/ical.test.ts \
     tests/unit/parsers/ical-scope.test.ts \
     tests/unit/modules/calendar-scope.test.ts \
     tests/unit/parsers/ical-todo.test.ts \
     tests/unit/modules/calendar-tools.test.ts \
     tests/unit/parsers/ical-allday.test.ts \
     tests/unit/parsers/ical-timezone-isolation.test.ts \
     tests/unit/providers/caldav.test.ts"
  ```
- **退出码**: `0`
- **执行耗时**: 3.74s
- **测试套件输出摘要**:
  * `✓ tests/unit/modules/calendar-service.test.ts (30 tests) 243ms`
  * `✓ tests/unit/parsers/ical.test.ts (25 tests) 98ms`
  * `✓ tests/unit/parsers/ical-scope.test.ts (18 tests) 87ms`
  * `✓ tests/unit/modules/calendar-tools.test.ts (8 tests) 60ms`
  * `✓ tests/unit/modules/calendar-scope.test.ts (12 tests) 45ms`
  * `✓ tests/unit/parsers/ical-todo.test.ts (22 tests) 35ms`
  * `✓ tests/unit/providers/caldav.test.ts (15 tests) 30ms`
  * `✓ tests/unit/parsers/ical-timezone-isolation.test.ts (4 tests) 20ms`
  * `✓ tests/unit/parsers/ical-allday.test.ts (10 tests) 18ms`
- **总计**: `9 passed (9)`, `144 passed (144)`

---

## 3. ETag 请求级原子保护与调用链审计

### 3.1 调用链全景
1. **ETag 来源**:
   - `listEvents` / `fetchOne`: 上游 CalDAV 返回多响应 XML，`tsdav` 解析 `<d:getetag>` 并存入 `raw.etag`，在 provider 层投影为 `CalendarObject.etag`；
   - `create`: CalDAV `PUT` 创建响应返回 HTTP 响应头 `response.headers.get('etag')`。
2. **写前匹配与并发门控**:
   - `service.ts` 的 `loadForWrite(eventId, options.expected_etag)` 重新向 CalDAV 请求最新对象；
   - 若客户端提供 `expected_etag` 且与最新对象 `current.etag` 不一致，在本地立即阻断并抛出 `CONFLICT`，避免无谓网络传输。
3. **请求级 If-Match 原子保护**:
   - `service.updateEvent` 传递 `{ url: ref.resourceUrl, etag: current.etag, data: ics }`；
   - `service.deleteEvent` 传递 `{ url: ref.resourceUrl, etag: current.etag }`；
   - 底层 `caldav.ts` 调用 `client.updateCalendarObject` / `client.deleteCalendarObject`；
   - `tsdav` 核心实现 `updateObject` 与 `deleteObject` 严格将 `etag` 注入请求头：
     ```javascript
     headers: { "If-Match": etag, ... }
     ```
     对 `PUT` 与 `DELETE` 方法均生效。若在 `fetchOne` 与最终写入之间发生并发修改，服务端将返回 `HTTP 412 Precondition Failed`。
4. **412 错误映射与拦截边界核查**:
   - `caldav.ts: mapCalDavError` 明确映射：
     ```typescript
     if (status === 412) {
       return new AppError('CONFLICT', '该资源已被其他客户端修改', {
         hint: '重新读取该资源后再提交修改',
         cause: err,
       });
     }
     ```
   - **拦截层诚实边界**：在 MUSE 前台验证中，旧 ETag 确实被服务端准确拒绝并返回 `CONFLICT`；因现场未抓取原始 HTTP 报文，客观记录为“**旧 ETag 被服务端拒绝，具体拦截层未证实**”（可能由服务端 `loadForWrite` 读回比对阻断，或由上游 CalDAV 412 映射，不作过度推断）。
5. **重试与回退策略**:
   - `updateEvent` 与 `deleteEvent` 单次执行，**零自动重试，零无条件写入回退**；
   - 412 错误被标记为不可重试（`retryable: false`），直接抛给调用方处理；
   - `UNKNOWN` 状态（写入超时或中断）时，严格要求前端只读查验，禁止自动盲目重试。

---

## 4. 目标日历只读核验结果

通过直接连接 CalDAV 发现可用日历并排除纯 VTODO 集合，确定唯一测试候选：
- **日历名称**: `MUSE 测试`
- **组件支持**: `["VEVENT"]`
- **只读状态**: `writable: true`
- **目标绑定**: 精确 `calendar_id` 及 CalDAV 路径仅存放于受限本地配置中，前台交互按名称动态解析。
- **目标时间窗 (2026-11-15 ~ 2026-11-17) 初始状态**: 0 条既有事件，测试前缀 `[MUSE-TEST-CAL-20261110]` 严格净空。

---

## 5. 当前阶段结论

**现有生产日历具备受限验收候选条件，MUSE 原生前台 9 步闭环全数通过。暂缓 DELIVERED 判定，当前唯一优先主线任务为修复并隔离验证日常写入入口的 ETag 自动替换缺陷。**
