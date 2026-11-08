# AG-03: Seoul → MacServer 只读网关部署与恢复方案 (Deployment & Recovery Plan)

- **编制日期**：2026-11-08
- **方案基线**：`feat/seoul-macserver-readonly-gateway` (AG-03 最终交付候选)
- **源码基准 Commit**：`92bd313154cfbc51fce7e8df5b3f73ea86a6f1c7` (apple-icloud-mcp 上游稳定基线)
- **唯一补丁文件**：`patches/0001-shared-gateway-wiring.patch`
- **补丁 SHA256**：`e84899f1f66b71f6310f56e113d4aec6281dfb4d583ab5509aa3d6442347883d`
- **唯一执行与复现入口**：`scripts/reproduce-ag03-delivery.sh`
- **生产基线镜像 ID**：`sha256:f3e697fe266f58910c01985f9c906a84479705846c88fd7d2ea1ccf12c0da2f0`
- **候选镜像 Tag / ID**：`insurance-carddav-mcp-carddav:candidate-ag03-delivery-20261108_114234` (`sha256:5302c0cd0c4493f770c0f270cee8c5d468f49b74dfb876a4834cbf9ac26162d1`)
- **目标环境**：
  - Seoul MCP 主机 (`lhins-84gffkd8` / `VM-0-10-ubuntu`)，生产容器 `insurance-carddav-mcp-carddav-1` (端口 `127.0.0.1:17734->17733/tcp`)
  - Intel MacServer (`macserver-ts`, LaunchAgent `gui/501/com.muse.macserver-eventkit`)
- **安全红线**：
  - 本方案为**候选部署方案**；未获用户明确批准前，**绝不连接生产环境执行部署或重启**。
  - **绝不执行真实写探针**：生产验收门禁仅限只读探测（`GET /health`、`reminders_lists` 与绑定测试列表的 `reminders_list`），严禁在真实服务上调用写操作。所有写拦截与零转发验证均由离线/隔离测试证明。
  - **标识脱敏**：全案禁止出现未脱敏的完整原始 UUID，仅使用脱敏标识 `9D9A****03F3`。
  - **运行配置实测备份**：恢复不能仅依赖 Git 历史 commit，必须完整备份并恢复宿主机正在运行的配置目录（含 `.env`、`docker-compose.yml`、Token Store 与未归档改动）。

---

## 一、实际共享服务影响分析 (Shared Services Impact Analysis)

在评估部署与故障恢复时，必须严格区分同宿主机及同容器内各个共享服务的影响范围：

### 1. 同宿主机其他独立容器（零影响，完全隔离）
- **受保护服务**：
  - `ydisks-xianyu-helper-app-1`（闲鱼助手，端口 18880）
  - `ydisks-xianyu-helper-postgres-1`（PostgreSQL 数据库，端口 5432）
  - `englishpod-web`（端口 8888）与 `englishpod-http-validation`
- **隔离机制**：属于独立的 Docker Compose 网络与不同的宿主映射端口。本网关的任何安装、启停或回滚**绝不触碰**上述容器。

### 2. 同容器内的其他业务模块（共享 OAuth 与服务生命周期，无缝兼容）
- **联系人模块 (`contacts`)**：基于 CardDAV 运行，承载原生联系人与联系人分组（PR #14）功能；
- **日历模块 (`calendar`)**：基于 CalDAV 运行，承载 ETag 并发冲突检测功能；
- **邮件模块 (`mail`)**：已在配置中禁用。
- **影响评估**：Reminders 只读网关复用既有 `/mcp` Streamable HTTP 协议端点、现有 OAuth 2.1 鉴权（`access-login`、PKCE）与会话生命周期管理，与 Contacts 及 Calendar 共享同一服务体系。在容器重启更新期间存在秒级的维护窗口，重启完成后 Contacts 与 Calendar 维持原配置无缝可用。

### 3. 多 Agent 租户共用影响（只读安全，零并发写冲突）
- **获授权 Agent**：Antigravity、MUSE、WorkBuddy 共用同一套 Apple ID；
- **只读保证**：网关在客户端和服务端硬编码拦截所有写操作（`PERMISSION_DENIED`），写请求零转发、零 VTODO 回落，因此开启网关**绝不会**向 iCloud 写入任何脏数据，**绝不会**引发多 Agent 间的数据并发修改或覆盖。

---

## 二、部署前准入核验检查单 (Pre-flight Checklist)

在获得用户专项命令后，核验以下条件：

1. **版本与测试验证**：
   - 确认合并基线为 `feat/seoul-macserver-readonly-gateway`；
   - 确认测试套件全部通过：
     - 本地 48 项单元与契约测试 PASS；
     - 共享服务 326 项全量 Vitest 单元与回归测试 PASS；
     - 外部容器验收套件（13 项端到端断言，含响应体停顿超时、非法字段拒绝、零写转发）PASS。
2. **凭据与绑定核验**：
   - 检查 MacServer 本地受限文件 `~/.config/muse-macserver/bridge.env`（0600）中的 `EVENTKIT_BRIDGE_AUTH_TOKEN`；
   - 确认待绑定的测试列表 `M****试`（脱敏标识：`9D9A****03F3`）具备显式来源绑定（`sourceType: calDAV`, `sourceName: iCloud`）。
3. **网络与接口核验**：
   - 确认 Tailscale 状态正常，MacServer (`100.100.172.91`) 在线；
   - 确认 Seoul 主机 18765 端口仅绑定在 `127.0.0.1`，无公网暴露。

---

## 三、部署执行步骤 (Deployment Steps)

### 步骤 1：全量运行态现场备份（包含未归档改动与配置文件）
在执行任何变更前，必须对 Seoul 运行目录进行完整快照：
```bash
BACKUP_TS=$(date +%Y%m%d%H%M%S)
cp -a /opt/insurance-carddav-mcp /opt/insurance-carddav-mcp.bak-${BACKUP_TS}
docker tag insurance-carddav-mcp-carddav:latest insurance-carddav-mcp-carddav:backup-pre-ag03-${BACKUP_TS}
```
**备份内容覆盖**：
- `.env` / `secrets.env`（运行态实际环境变量与 Token 加密密钥）；
- `docker-compose.yml`（容器网络与端口映射配置）；
- `data/`（持久化 Token Store 与会话记录）；
- 当前源码与未归档改动。

### 步骤 2：部署常驻 SSH 隧道服务（Seoul Host）
1. 在 Seoul 宿主机安装专用 Systemd 单元：
   ```bash
   cp config/seoul-macserver-tunnel.service.candidate /etc/systemd/system/seoul-macserver-tunnel.service
   systemctl daemon-reload
   systemctl enable --now seoul-macserver-tunnel.service
   ```
2. 校验隧道健康：
   ```bash
   curl -s http://127.0.0.1:18765/health | grep '"status":"ok"'
   ```

### 步骤 3：启用 MacServer 临时业务访问开关
1. 由用户在 MacServer 图形环境更新 `bridge.env`（保持受限权限 `0600`，仅修改目标授权键，完整保留 Token 与绑定配置）：
   ```bash
   sed -i '' 's/^EVENTKIT_BRIDGE_PRODUCTION_AUTHORIZED=.*/EVENTKIT_BRIDGE_PRODUCTION_AUTHORIZED=true/' ~/.config/muse-macserver/bridge.env
   ```
2. 重启守护进程以加载生产授权：
   ```bash
   launchctl kickstart -k gui/$(id -u)/com.muse.macserver-eventkit
   ```

### 步骤 4：直接加载已验收镜像 ID（避免现场重新构建产生版本偏差）
为彻底消除生产现场构建环境差异与依赖拉取风险，部署**直接使用已在干净环境全量验收通过的候选镜像 ID**：
- **已验收候选镜像 ID**：`sha256:5302c0cd0c4493f770c0f270cee8c5d468f49b74dfb876a4834cbf9ac26162d1`
- **对应镜像 Tag**：`insurance-carddav-mcp-carddav:candidate-ag03-delivery-20261108_114234`

执行锁定标签替换：
```bash
CANDIDATE_IMAGE_ID="sha256:5302c0cd0c4493f770c0f270cee8c5d468f49b74dfb876a4834cbf9ac26162d1"
docker tag "$CANDIDATE_IMAGE_ID" insurance-carddav-mcp-carddav:latest
```

### 步骤 5：注入匹配既定容器网络的 Compose 配置并平滑重启容器
1. 将与现有容器网络、存储卷及只读网关环境变量完全匹配的 Compose 候选配置（`config/compose.candidate.yaml`）部署至 `/opt/insurance-carddav-mcp/compose.yaml`：
   ```bash
   cp /path/to/integrations/apple-icloud-mcp/seoul-gateway/config/compose.candidate.yaml /opt/insurance-carddav-mcp/compose.yaml
   ```
2. 在 `/opt/insurance-carddav-mcp/secrets.env` 中注入网关鉴权令牌与绑定列表配置：
   ```env
   MACSERVER_EVENTKIT_AUTH_TOKEN=<SECRET_TOKEN_FROM_BRIDGE_ENV>
   MACSERVER_EVENTKIT_ALLOWED_LISTS=00000000-AAAA-BBBB-CCCC-000000000001:src-synthetic-icloud-test:iCloud:calDAV
   ```
3. 以 `--no-build` 模式拉起容器，并验证运行时环境变量注入与健康状态：
   ```bash
   cd /opt/insurance-carddav-mcp
   docker compose up -d --no-build carddav
   
   # 验证环境变量进入容器
   docker inspect insurance-carddav-mcp-carddav-1 --format '{{range .Config.Env}}{{println .}}{{end}}' | grep "MACSERVER_EVENTKIT"
   
   # 验证健康检查
   curl -sf http://127.0.0.1:17734/health
   ```

### 步骤 6：生产只读可用性门禁核验（严禁写探针）
1. 通过已鉴权的 MCP Client 调用 `reminders_lists`，验证仅返回白名单绑定的测试列表，且属性标记为 `writable: false`；
2. 调用 `reminders_list`，验证正常读取返回条目数组或空列表；
3. **安全红线**：严禁向生产服务发起 `reminders_create` 等写调用。写拦截逻辑已由包含 13 项外部验收测试与 48 项单元测试的测试套件严格保证。

---

## 四、原版本与配置恢复步骤 (Rollback & Restoration Plan)

若试运行期间出现任何异常（连接超时、鉴权失败、响应异常或共享模块受到干扰），立即执行以下确定性回滚：

### 1. 恢复步骤与持久化状态一致性原则

> [!IMPORTANT]
> **配置与持久化状态备份一致性原则**：
> - 在试运行期间，合法的 MCP 客户端（Antigravity / MUSE / WorkBuddy）可能会正常刷新或轮换 OAuth 2.1 Access / Refresh Token，写入持久化目录 `/opt/insurance-carddav-mcp/data/tokens.json.enc`。
> - **严禁盲目全量覆盖持久化数据**：回滚时必须严格解耦**代码配置回滚**与**业务 Token 状态**。若试运行期间底层数据结构未损坏且无脏数据注入，保留当前 `data/` 目录中的 Token 状态，避免因覆盖导致已建立合法会话的客户端集体掉线；若必须排查数据损坏，应先将当前 `data/` 进行增量归档快照，再做选择性还原。
> - **直接使用记录的基线镜像 ID**：基线容器明确使用经记录的实际生产镜像 ID `sha256:f3e697fe266f58910c01985f9c906a84479705846c88fd7d2ea1ccf12c0da2f0`，不依赖可能被二次覆盖的动态 tag。

#### 步骤 A：还原 Seoul 代码、配置与基线镜像
```bash
# 1. 停止当前候选容器
cd /opt/insurance-carddav-mcp && docker compose stop carddav

# 2. 还原配置文件与未归档源码改动（显式排除 data/ 运行时 Token 状态以防覆盖合法 Token）
rsync -a --exclude 'data/tokens.json.enc*' /opt/insurance-carddav-mcp.bak-${BACKUP_TS}/ /opt/insurance-carddav-mcp/

# 3. 将生产 latest 标签锁定恢复至已确认的基线镜像 ID (sha256:f3e697fe266f58910c01985f9c906a84479705846c88fd7d2ea1ccf12c0da2f0)
BASELINE_IMAGE_ID="sha256:f3e697fe266f58910c01985f9c906a84479705846c88fd7d2ea1ccf12c0da2f0"
docker tag "$BASELINE_IMAGE_ID" insurance-carddav-mcp-carddav:latest

# 4. 重新启动基线容器
cd /opt/insurance-carddav-mcp && docker compose up -d --no-build carddav
```

#### 步骤 B：关闭 MacServer 业务激活开关
在 MacServer 上恢复安全锁定状态（仅修改目标业务开关，严格保留 Token、白名单与来源绑定）：
```bash
sed -i '' 's/^EVENTKIT_BRIDGE_PRODUCTION_AUTHORIZED=.*/EVENTKIT_BRIDGE_PRODUCTION_AUTHORIZED=false/' ~/.config/muse-macserver/bridge.env
launchctl kickstart -k gui/$(id -u)/com.muse.macserver-eventkit
```
验证业务接口恢复返回 HTTP 403 `PERMISSION_DENIED`。

#### 步骤 C：停止并禁用 Seoul SSH 隧道
```bash
systemctl stop seoul-macserver-tunnel.service
systemctl disable seoul-macserver-tunnel.service
```

### 2. 恢复后验收准则
- 确认 Seoul 容器正常运行（`docker ps --filter "name=insurance-carddav-mcp-carddav-1"` 状态为 `Up (healthy)`）；
- 确认 `curl -sf http://127.0.0.1:17734/health` 返回 200 OK；
- 确认 Contacts 联系人分组功能（PR #14）与 Calendar 日历读取完全恢复正常；
- 确认 MacServer 守护进程处于非激活锁定状态（业务端点返回 403）；
- 确认同宿主机其他容器（`ydisks`, `englishpod`）运行稳定，不受任何波及。
