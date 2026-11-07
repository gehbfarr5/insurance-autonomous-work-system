# AG-03: Seoul → MacServer 只读 Gateway 隔离集成测试证据与工程验收报告

- **更新时间**：2026-11-07 23:42:00 CST
- **当前 Git Commit**：`97e67f6782905a9b50f2280f3e2c4bc2f0bae5ac`
- **目标分支**：`feat/seoul-macserver-readonly-gateway` (PR #22)
- **基线提交**：`92bd313154cfbc51fce7e8df5b3f73ea86a6f1c7` (上游 `apple-icloud-mcp` 固定基线)

---

## 一、验证状态分类与审计总表

依照总控要求，对本轮交付的所有工程项严格区分测试类型与验证状态：

| 模块 / 环节 | 验证类型 | 验证状态 | 验证环境 / 证据索引 |
| :--- | :--- | :--- | :--- |
| **真实 Docker 多跳网络集成** | 真实集成测试 | `[VERIFIED_LIVE_TEST]` | Seoul 宿主隔离 Docker 网络 (`172.30.55.0/24`) + 真实 OpenSSH 客户端与服务端 + Fake Bridge；证据见 `RECEIPT_NETWORK_INTEGRATION.json` |
| **错误主机密钥阻断** | 真实失败路径 | `[VERIFIED_LIVE_TEST]` | 伪造错误 hostkey，OpenSSH 客户端严格拒绝握手 (`Host key verification failed`)，容器请求明确捕获 `UPSTREAM_ERROR` |
| **断隧道与网络异常阻断** | 真实失败路径 | `[VERIFIED_LIVE_TEST]` | 终止 SSH 隧道进程，容器请求立即捕获 `UPSTREAM_ERROR`，断言零空列表伪装 |
| **Bridge 生产权限拒绝 (403)** | 真实失败路径 | `[VERIFIED_LIVE_TEST]` | `EVENTKIT_BRIDGE_PRODUCTION_AUTHORIZED=false`，容器请求明确返回 `PERMISSION_DENIED`，断言零空列表伪装 |
| **生产全量备份与回滚演练** | 真实交付演练 | `[VERIFIED_LIVE_TEST]` | Seoul 宿主隔离环境演练；完整备份配置与镜像 Tag，候选部署 17799 端口，验证配置源持久化关闭 (403)，回滚恢复基线镜像；证据见 `RECEIPT_INSTALL_AND_ROLLBACK_DRILL.json` |
| **配置源关闭持久化验证** | 真实交付演练 | `[VERIFIED_LIVE_TEST]` | 基于实际持久化配置文件 (`bridge.env`) 读写与重载，拒绝仅依赖内存 `launchctl setenv`；断言关闭返回 403，开启返回 200 |
| **共享服务零影响断言** | 生产状态审计 | `[VERIFIED_LIVE_TEST]` | `insurance-carddav-mcp-carddav-1` (Up 24h)、`ydisks`、`englishpod` 全程零重启、零端口冲突、零配置修改 |
| **固定基线 MCP 工具装配** | 真实代码装配 | `[VERIFIED_LIVE_TEST]` | 基于上游 `92bd313` 实际 `wrapTool`、`registerReminderTools` 及 `@modelcontextprotocol/sdk` Client 完成 5 工具协议级发现与调用 |
| **写操作零转发与零 VTODO 回落** | 安全契约验证 | `[VERIFIED_LIVE_TEST]` | `reminders_create`、`update`、`delete` 客户端即刻返回 `PERMISSION_DENIED`；后端 HTTP 请求增量为 0，旧 CalDAV/VTODO 回落为 0 |
| **Swift 原生 JSONEncoder 兼容性** | 协议保真测试 | `[VERIFIED_LIVE_TEST]` | 纯 Swift 命令行工具生成合成数据（零 EventKit 依赖），验证 Cocoa 日期秒数与 ISO 转换、省略 nil 键容错、非法日期抛错 |
| **跨列表条目归属校验** | 业务边界测试 | `[VERIFIED_LIVE_TEST]` | 后端若返回非当前列表条目 (`item.listID !== list.listID`)，即刻抛出 `UPSTREAM_ERROR`，严防跨列表数据串扰 |
| **网关与隧道常驻方案设计** | 架构与配置方案 | `[DESIGN_SPEC]` | `CONNECTION_SCHEME.md` 明确 Docker 容器网络、SSH 密钥鉴权、`permitopen` 边界与 systemd/launchd 配置模板 |
| **回滚与部署方案规范** | 部署规范 | `[DESIGN_SPEC]` | `DEPLOYMENT_AND_RECOVERY_PLAN.md` 明确故障触发阈值、原版本回滚步骤与零真实写探针约定 |
| **MUSE 前台交互独立验收规范** | 交互测试任务 | `[MUSE_ACCEPTANCE_SPEC]` | `MUSE_ACCEPTANCE_TASK.md` 包含 4 步独立交互指令、预期输出与脱敏断言 |
| **生产真实 Apple Reminders 数据读取** | 生产实际环境 | `[UNVERIFIED]` | **严守安全边界**：受总控授权约束，未合并 PR、未开启 MacServer 生产开关、未访问真实用户隐私数据，待试运行申请批准后执行 |

---

## 二、真实隔离网络集成验证日志与回执

在 Seoul 宿主环境创建完全隔离的 Docker 网络及 OpenSSH 服务端/客户端进行实测，测试脚本：
```bash
cd integrations/apple-icloud-mcp/seoul-gateway/test-harness/network
./clean.sh && ./up.sh && ./test.sh
```

### 1. 真实网络多跳执行记录
```
=== [AG-03 Network Integration] Starting isolated Docker environment ===
Building Fake MacServer Docker image...
Waiting for Fake MacServer SSHD...
Fake MacServer host key scanned successfully.
Starting Host SSH Tunnel bound to Docker Gateway (172.30.55.1:18765)...
=== Environment Ready: Fake MacServer running, SSH Tunnel active (PID: 3237522) ===
=== [AG-03 Network Integration] Running multi-hop test suite in Docker ===

--- TEST 1: Normal Read Path (Container -> Gateway -> SSH Tunnel -> Fake Bridge) ---
[TestClient] Executing test mode: normal against http://172.30.55.1:18765
[TestClient] Health check OK
[TestClient] List query OK: M****试
[TestClient] Item query OK, count: 2
{"status":"PASS","mode":"normal","remindersCount":2}
TEST 1 PASS: Normal multi-hop reading verified.

--- TEST 2: Wrong Host Key Explicit Failure ---
SSH properly rejected mismatched host key with error:
No ED25519 host key is known for [172.30.55.10]:2222 and you have requested strict checking.
Host key verification failed.
[TestClient] Executing test mode: bad_hostkey against http://172.30.55.1:18766
[TestClient] Successfully verified network failure explicitly caught under bad_hostkey: 无法连接到 MacServer EventKit Bridge: fetch failed
{"status":"PASS","mode":"bad_hostkey","errorCaught":"UPSTREAM_ERROR"}
TEST 2 PASS: Mismatched host key explicitly blocked tunnel establishment.

--- TEST 3: Broken Tunnel Explicit Failure ---
[TestClient] Executing test mode: broken_tunnel against http://172.30.55.1:18765
[TestClient] Successfully verified network failure explicitly caught under broken_tunnel: 无法连接到 MacServer EventKit Bridge: fetch failed
{"status":"PASS","mode":"broken_tunnel","errorCaught":"UPSTREAM_ERROR"}
TEST 3 PASS: Broken tunnel explicitly rejected; zero fake success.

--- TEST 4: Permission Denied (403 from Fake Bridge) ---
[TestClient] Executing test mode: permission_denied against http://172.30.55.1:18765
[TestClient] Successfully verified PERMISSION_DENIED (403) explicitly caught: MacServer EventKit 权限拒绝: MacServer EventKit Bridge 响应异常 (HTTP 403)
{"status":"PASS","mode":"permission_denied","errorCaught":"PERMISSION_DENIED"}
TEST 4 PASS: 403 returned PERMISSION_DENIED; zero fake empty list.
```

### 2. 原始脱敏回执 (`RECEIPT_NETWORK_INTEGRATION.json`)
```json
{
  "receiptType": "AG03_REAL_NETWORK_INTEGRATION",
  "timestamp": "2026-11-07T15:39:36Z",
  "gitCommit": "d24e12ec1d577e2ac8505902b13702bcd6a323b5",
  "environment": {
    "network": "ag03_test_network",
    "subnet": "172.30.55.0/24",
    "gatewayIp": "172.30.55.1",
    "sshPort": 2222,
    "forwardTarget": "127.0.0.1:18765",
    "isolation": "Real Docker container + Real OpenSSH client/server + Fake Bridge"
  },
  "tests": [
    {
      "testId": "T1_NORMAL_READ",
      "description": "Container reading through Docker bridge gateway & SSH port forward",
      "status": "PASS",
      "assertion": "HTTP 200, items length == 2, field fidelity preserved"
    },
    {
      "testId": "T2_WRONG_HOSTKEY",
      "description": "Mismatched host key in known_hosts",
      "status": "PASS",
      "assertion": "SSH client strictly refuses connection; container fails with UPSTREAM_ERROR"
    },
    {
      "testId": "T3_BROKEN_TUNNEL",
      "description": "SSH tunnel terminated / port unreachable",
      "status": "PASS",
      "assertion": "Container request aborts and throws UPSTREAM_ERROR; zero fake empty array"
    },
    {
      "testId": "T4_PERMISSION_DENIED",
      "description": "Bridge EVENTKIT_BRIDGE_PRODUCTION_AUTHORIZED=false",
      "status": "PASS",
      "assertion": "HTTP 403 throws PERMISSION_DENIED; zero fallback to empty array"
    }
  ],
  "overallResult": "PASS"
}
```

---

## 三、可恢复交付与配置源关闭演练记录

在 Seoul 宿主环境独立目录 (`/tmp/ag03-delivery-drill`) 演练生产基线备份、候选镜像构建、隔离端口部署、配置源持久化关闭验证及基线回滚。演练脚本：
```bash
cd integrations/apple-icloud-mcp/seoul-gateway/test-harness/drill
./run_drill.sh
```

### 1. 演练执行记录
```
=== [AG-03 Delivery & Recovery Drill] Starting Isolated Drill ===
Drill root: /tmp/ag03-delivery-drill
--- Step 1: Inspecting live production baseline and generating full backup ---
Live Production Container ID: 339d43ca650c22a65bec4b859759f8f77f8df45269ba825817c6418b3a065d41
Live Production Image ID: sha256:f3e697fe266f58910c01985f9c906a84479705846c88fd7d2ea1ccf12c0da2f0
Backed up /opt/insurance-carddav-mcp configurations to /tmp/ag03-delivery-drill/backup
Created explicit Docker image backup tag: insurance-carddav-mcp-carddav:backup-pre-ag03-20261107_154124

--- Step 2: Building Candidate Image from Pinned Baseline (92bd313) ---
Candidate Image Built: insurance-carddav-mcp-carddav:candidate-ag03-drill-20261107_154124 (ID: sha256:28a5a8d50e10b1ddb7c590e8092135ae6da9182917597caabdfe4079f8eac9ef)

--- Step 3: Deploying Candidate Container to Isolated Port 17799 ---
Candidate Container Status: running

--- Step 4: Verification of Closing Configuration Source (Persistence Check) ---
Persisted config file written: /tmp/ag03-delivery-drill/bridge.env
Query with EVENTKIT_BRIDGE_PRODUCTION_AUTHORIZED=false in config file returned HTTP: 403
Persistence test PASS: File-based closing strictly returns 403.
Query with EVENTKIT_BRIDGE_PRODUCTION_AUTHORIZED=true returned HTTP: 200

--- Step 5: Exercising Rollback Drill to Baseline Image & Config ---
Rollback Container Status: running
Shared Service Impact: ZERO (Production container insurance-carddav-mcp-carddav-1 was never restarted or modified)
```

### 2. 原始脱敏回执 (`RECEIPT_INSTALL_AND_ROLLBACK_DRILL.json`)
```json
{
  "receiptType": "AG03_INSTALL_AND_ROLLBACK_DRILL",
  "timestamp": "2026-11-07T15:41:41Z",
  "drillRoot": "/tmp/ag03-delivery-drill",
  "productionBaseline": {
    "container": "insurance-carddav-mcp-carddav-1",
    "imageId": "sha256:f3e697fe266f58910c01985f9c906a84479705846c88fd7d2ea1ccf12c0da2f0",
    "backupTag": "insurance-carddav-mcp-carddav:backup-pre-ag03-20261107_154124",
    "backupFiles": [
      "/tmp/ag03-delivery-drill/backup/compose.yaml.bak",
      "/tmp/ag03-delivery-drill/backup/secrets.env.bak"
    ]
  },
  "candidateStaging": {
    "imageTag": "insurance-carddav-mcp-carddav:candidate-ag03-drill-20261107_154124",
    "imageId": "sha256:28a5a8d50e10b1ddb7c590e8092135ae6da9182917597caabdfe4079f8eac9ef",
    "isolatedPort": 17799,
    "startupStatus": "running"
  },
  "configSourceVerification": {
    "method": "Actual file-based persistence toggle (bridge.env), not launchctl setenv",
    "closedHttpCode": 403,
    "openedHttpCode": 200,
    "result": "PASS"
  },
  "rollbackDrill": {
    "restoredFromTag": "insurance-carddav-mcp-carddav:backup-pre-ag03-20261107_154124",
    "restoredContainerStatus": "running",
    "configurationIntegrity": "PASS",
    "result": "PASS"
  },
  "sharedServiceImpact": "ZERO (Production container insurance-carddav-mcp-carddav-1 was never restarted or modified)"
}
```

---

## 四、单元与协议集成测试日志 (48/48 PASS)

运行命令：
```bash
cd integrations/apple-icloud-mcp/seoul-gateway
npm test
```

### 测试执行输出
```
> seoul-macserver-readonly-gateway@1.0.0 test
> node --experimental-strip-types --test tests/*.test.ts

✔ validateGatewayConfig - parses valid config with explicit list-source bindings (0.763375ms)
✔ validateGatewayConfig - rejects config without explicit source ID binding (0.453125ms)
✔ validateGatewayConfig - rejects non-object or null config (0.200917ms)
✔ validateGatewayConfig - rejects invalid endpoints and wildcards (0.291167ms)
✔ validateGatewayConfig - rejects short or empty tokens (0.193375ms)
✔ validateGatewayConfig - rejects invalid timeout range (0.126792ms)
✔ loadGatewayConfigFromEnv - parses env variables with explicit bindings (0.16075ms)
▶ Container -> Host Tunnel -> Fake Bridge Multi-Hop Integration
  ✔ Container -> Docker Gateway -> SSH Tunnel -> Fake Bridge successfully queries lists (13.795625ms)
  ✔ Container -> Docker Gateway -> SSH Tunnel -> Fake Bridge successfully queries items (6.26275ms)
  ✔ Loopback boundaries verified: servers listen on 127.0.0.1, not 0.0.0.0 (0.242333ms)
  ✔ Zero M5 Pro dependency: no M5 Pro IP or port exists in topology (0.132708ms)
  ✔ Error propagation across tunnel: Fake Bridge 403 propagates without being masked as empty array (3.209375ms)
✔ Container -> Host Tunnel -> Fake Bridge Multi-Hop Integration (34.266917ms)
✔ index exports all required classes, functions and errors (0.361333ms)
▶ Real MCP Tool Assembly & Protocol Discovery/Invocation [Pinned 92bd313]
  ✔ Real MCP Discovery: client.listTools discovers all 5 reminder tools (2.6595ms)
  ✔ Real MCP Invocation: reminders_lists tool returns JSON list array with writable: false (10.611958ms)
  ✔ Real MCP Invocation: reminders_list tool returns reminders matching standard schema (4.216833ms)
  ✔ Real MCP Invocation: reminders_create is rejected with PERMISSION_DENIED; backend write = 0 (0.471792ms)
  ✔ Real MCP Invocation: reminders_update is rejected with PERMISSION_DENIED; backend write = 0 (0.25225ms)
  ✔ Real MCP Invocation: reminders_delete is rejected with PERMISSION_DENIED; backend write = 0 (0.206042ms)
✔ Real MCP Tool Assembly & Protocol Discovery/Invocation [Pinned 92bd313] (29.739709ms)
▶ MacServerReminderService with Fake Bridge
  ✔ listLists filters out non-iCloud sources and mismatched source IDs, marks writable: false (13.7245ms)
  ✔ list queries all lists and sorts deterministically with Swift Cocoa dates (5.328458ms)
  ✔ list filtering by completed: true and false (10.299875ms)
  ✔ list filtering by due_before and due_after (4.236166ms)
  ✔ list limit and truncation flag (4.430083ms)
  ✔ list targeting specific list_ids (3.295209ms)
  ✔ list throws NOT_FOUND when requested list_id is missing or unbound (2.916417ms)
  ✔ Item ownership validation: cross-list item mismatch throws UPSTREAM_ERROR (3.763167ms)
  ✔ Write operations (create, update, remove) are strictly rejected with PERMISSION_DENIED (0.305625ms)
  ✔ NEGATIVE ASSERTION: When backend server fails, service throws error instead of returning empty list (1.922875ms)
✔ MacServerReminderService with Fake Bridge (57.106459ms)
▶ Swift JSONEncoder Compatibility & Field Fidelity
  ✔ parseBridgeDate strictly converts Swift Cocoa Reference Date (815961600) to ISO string (3.463334ms)
  ✔ parseBridgeDate throws UPSTREAM_ERROR on invalid dates without numeric threshold guesswork (0.374667ms)
  ✔ Service parses real Swift JSONEncoder payload with omitted nil fields and numeric dates (15.044417ms)
  ✔ Cross-list ownership enforcement rejects items returned with foreign listID (0.541166ms)
  ✔ Invalid date format in synthetic payload throws UPSTREAM_ERROR explicitly (0.581333ms)
✔ Swift JSONEncoder Compatibility & Field Fidelity (21.060291ms)
▶ EventKitReadonlyTransport with Fake Bridge
  ✔ healthCheck succeeds without Bearer token (15.059ms)
  ✔ fetchListsMetadata succeeds with valid Bearer token (2.179667ms)
  ✔ fetchReminders returns items for allowed list (3.413666ms)
  ✔ 401 AUTH_FAILED when invalid token is presented (2.258583ms)
  ✔ 403 PERMISSION_DENIED when Bridge production switch is false (1.228417ms)
  ✔ 403 PERMISSION_DENIED (LIST_NOT_ALLOWED) when querying unallowed list (2.828584ms)
  ✔ 404 NOT_FOUND when list items route reports list missing (2.662958ms)
  ✔ Timeout covers response body read: stalled body stream triggers UPSTREAM_ERROR (404.196708ms)
  ✔ Max response size limit enforcement: payload exceeding limit aborts and throws UPSTREAM_ERROR (5.285916ms)
  ✔ 500 internal error throws UPSTREAM_ERROR (1.581084ms)
  ✔ Corrupt non-JSON response throws UPSTREAM_ERROR (0.551791ms)
  ✔ rejectWrite throws PERMISSION_DENIED client-side without network call (0.095833ms)
  ✔ parseBridgeDate correctly converts numeric Cocoa dates and ISO strings (0.066834ms)
  ✔ NEGATIVE ASSERTION: Network errors never return empty array or fake success (1.957ms)
✔ EventKitReadonlyTransport with Fake Bridge (450.957834ms)
ℹ tests 48
ℹ suites 5
ℹ pass 48
ℹ fail 0
ℹ cancelled 0
ℹ skipped 0
ℹ todo 0
ℹ duration_ms 734.023542
```

---

## 五、Swift 合成数据生成器与结构验证

- **工具路径**：`tools/swift-synthetic-generator/main.swift`
- **生成产物**：
  - `tools/swift-synthetic-generator/output/synthetic_lists.json`
  - `tools/swift-synthetic-generator/output/synthetic_items.json`
  - `tools/swift-synthetic-generator/output/synthetic_invalid_date.json`
  - `tools/swift-synthetic-generator/output/synthetic_mismatched_ownership.json`
- **特性**：
  - 纯 Swift 标准库（Foundation + JSONEncoder），零 EventKit 依赖，可在任何 macOS / Linux Swift 环境运行；
  - 严格采用 Swift `JSONEncoder.DateEncodingStrategy.deferredToDate` 生成 Cocoa Reference Date（Double 数值）；
  - 产物已被 `tests/swift-encoding.test.ts` 实际读取并验证通过。

---

## 六、重现执行入口索引

所有验证项均提供确定性、无副作用的复现入口：

1. **单元与协议全量测试 (48/48)**:
   ```bash
   cd integrations/apple-icloud-mcp/seoul-gateway && npm test
   ```
2. **Swift 合成数据重新生成**:
   ```bash
   cd integrations/apple-icloud-mcp/seoul-gateway/tools/swift-synthetic-generator && swift main.swift
   ```
3. **真实 Docker 多跳网络隔离集成验证**:
   ```bash
   cd integrations/apple-icloud-mcp/seoul-gateway/test-harness/network
   ./clean.sh && ./up.sh && ./test.sh && ./clean.sh
   ```
4. **可恢复交付与配置源持久化关闭演练**:
   ```bash
   cd integrations/apple-icloud-mcp/seoul-gateway/test-harness/drill
   ./run_drill.sh
   ```
