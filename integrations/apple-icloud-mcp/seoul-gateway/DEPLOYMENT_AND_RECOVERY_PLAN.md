# AG-03: Seoul → MacServer 只读网关部署与恢复方案 (Deployment & Recovery Plan)

- **编制日期**：2026-11-08
- **方案基线**：`feat/seoul-macserver-readonly-gateway` (AG-03 最终交付候选)
- **源码基准 Commit**：`92bd313154cfbc51fce7e8df5b3f73ea86a6f1c7` (apple-icloud-mcp 上游稳定基线)
- **唯一补丁文件**：`patches/0001-shared-gateway-wiring.patch`
- **补丁 SHA256**：`70ee262ee062a64c076ee0c935ea74cd33e9238bca8cd1ff3b755147b2798980`
- **唯一执行与复现入口**：`scripts/reproduce-ag03-delivery.sh`
- **生产基线镜像 ID**：`sha256:f3e697fe266f58910c01985f9c906a84479705846c88fd7d2ea1ccf12c0da2f0`
- **候选镜像 Tag / ID**：`insurance-carddav-mcp-carddav:candidate-ag03-delivery-20261108_125026` (`sha256:b812009113d9ab16b6cbca686bbea2f21e9111136b489e385555cffbcbcebb61`)
- **预期工具名称集合**：33 项工具（25 项基础工具 + 全部 8 项联系人分组工具恢复，逐项精准比对）
- **进程管理原则**：零批量杀进程（禁止 `fuser -k` / `pkill -f`），端口占用直接退出拒绝，精确 PID 启停与 `ag03_run_id` 资源标签清理
- **接口绑定与网络隔离**：Fake Bridge 严格限制在独立测试网桥接口（`172.30.56.1:18765`），零宿主通配监听（无 `0.0.0.0` / `*`）
- **Compose 优先级与 Fail-Fast**：保留现有账户、加密密钥及 Contacts/Calendar 原权限，仅显式注入网关配置；缺失必要网关变量（`${VAR:?error}`）立即拒绝启动
- **中断与信号处理确定性**：捕获 INT/TERM 严格以非零状态（130/143）退出，重入守卫确保清理仅执行一次，中断绝无残留且绝无 PASS 回执
- **部署与测试配置一致性**：部署与测试共用同一 `config/compose.candidate.yaml` 规格
- **回执生成时序**：仅在测试完成、资源彻底清理无残留、生产容器状态前后校验一致后生成最终 PASS 回执
- **确定性生产启动与恢复套件**：`scripts/production-entry.sh` 与 `tests/test-production-drills.sh`（全量覆盖部署、启动失败回滚、健康超时回滚、独立环境恢复、`docker-compose.yml` 优先级遮蔽防护、以及中断信号自动回滚等 6 项严格演练，实测 6/6 全部通过）
- **运维维护窗口**：预计 3~10 秒（仅含容器平滑重启及 `/health` 就绪等待，无需拉取或重新构建镜像）
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
- **已验收候选镜像 ID**：`sha256:b812009113d9ab16b6cbca686bbea2f21e9111136b489e385555cffbcbcebb61`
- **对应镜像 Tag**：`insurance-carddav-mcp-carddav:candidate-ag03-delivery-20261108_125026`

执行锁定标签替换：
```bash
CANDIDATE_IMAGE_ID="sha256:b812009113d9ab16b6cbca686bbea2f21e9111136b489e385555cffbcbcebb61"
docker tag "$CANDIDATE_IMAGE_ID" insurance-carddav-mcp-carddav:latest
```

### 步骤 5：注入匹配既定容器网络的生产 Compose 配置并平滑重启容器
1. 将与现有生产容器网络（`insurance-carddav-mcp_default`）、持久化数据目录及 SSH 转发端点完全匹配的生产 Compose 配置（`config/compose.production.yaml`）部署至 `/opt/insurance-carddav-mcp/compose.yaml`：
   ```bash
   cp /path/to/integrations/apple-icloud-mcp/seoul-gateway/config/compose.production.yaml /opt/insurance-carddav-mcp/compose.yaml
   ```
2. 在 Seoul 宿主机创建受限网关配置文件 `/opt/insurance-carddav-mcp/gateway.env`（权限 `0600`，仅 root 可读）：
   > [!IMPORTANT]
   > **真实绑定标识隔离原则**：真实绑定列表与 Token 必须从 MacServer 本地受限文件 `~/.config/muse-macserver/bridge.env` 提取，严禁将隔离测试中的合成标识（`00000000-AAAA-...`）或测试网桥（`172.30.56.0/24`）复制写入生产！
   ```env
   # /opt/insurance-carddav-mcp/gateway.env (0600)
   MACSERVER_EVENTKIT_ENDPOINT=http://172.19.0.1:18765
   MACSERVER_EVENTKIT_AUTH_TOKEN=<SECRET_TOKEN_FROM_MACSERVER_BRIDGE_ENV>
   MACSERVER_EVENTKIT_ALLOWED_LISTS=9D9A****03F3:src-***:iCloud:calDAV
   MACSERVER_EVENTKIT_TIMEOUT_MS=3000
   ```
3. 调用统一生产入口执行平滑重启（或由 `scripts/production-entry.sh deploy` 自动化执行）：
   ```bash
   APPLY_PRODUCTION_APPROVED=1 scripts/production-entry.sh deploy
   ```
   **执行流包含**：
   - 配置与环境变量预检校验（Fail-Fast 强校验）；
   - `/opt/insurance-carddav-mcp` 运行态全量快照备份；
   - 锁定已验收候选镜像 ID `sha256:b812009113d9ab16b6cbca686bbea2f21e9111136b489e385555cffbcbcebb61`；
   - 执行 `--no-build` 重启，约 3~5 秒瞬态维护窗口；
   - 验证健康检查（200 OK）与运行中镜像 ID 校验。

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
可直接调用唯一生产恢复入口执行自动化回滚：
```bash
scripts/production-entry.sh rollback /opt/insurance-carddav-mcp.bak-[TIMESTAMP]
```
或按标准原子步骤手动执行：
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
