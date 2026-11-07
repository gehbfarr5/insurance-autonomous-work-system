# AG-03: Seoul → MacServer 常驻连接方案 (Persistent Connection Scheme)

- **设计版本**：v1.1 (容器网络拓扑与 SSH 安全特权加固)
- **基线分支**：`feat/seoul-macserver-readonly-gateway`
- **目标端点**：
  - **Seoul MCP 容器**：`insurance-carddav-mcp-carddav-1` (Bridge 网段 `172.19.0.2`，网关 `172.19.0.1`)
  - **Seoul 宿主机**：`VM-0-10-ubuntu` (Tailscale: `100.82.240.43`)
  - **MacServer 常驻宿主**：`macserver-ts` (Tailscale: `100.100.172.91`, macOS 15.7.7 x86_64, `gui/501`)
- **前置原则**：
  1. Seoul Host 为 MUSE 的**唯一**统一入口网关。
  2. 链路**绝对不依赖 M5 Pro**（M5 Pro 完全从运行时数据路径中剥离）。
  3. **严格维持 Loopback 边界，严禁公网暴露**（全链路封闭于 Tailscale WireGuard 私网及 loopback）。
  4. 网络与服务配置本轮仅作候选准备，部署另行审批。

---

## 一、真实容器网络拓扑与多跳链路 (Container Topology)

生产环境中，Seoul MCP 运行于独立 Docker 容器内，其网络拓扑如下：

```
[MCP Client (容器内 172.19.0.2)]
    │
    │ HTTP 请求 (目标: http://172.19.0.1:18765 或 http://host.docker.internal:18765)
    ▼
[Seoul Docker 网桥网关 (172.19.0.1:18765)]
    │
    │ 宿主 SSH 本地转发监听 (-L 172.19.0.1:18765:127.0.0.1:18765)
    ▼
[Seoul 宿主 SSH 隧道进程 (seoul-macserver-tunnel.service)]
    │
    │ Tailscale WireGuard P2P 加密隧道 (100.82.240.43 -> 100.100.172.91)
    ▼
[MacServer SSH 守护进程 (100.100.172.91:22)]
    │ 校验主机公钥、专用私钥及转发权限 (permitopen="127.0.0.1:18765")
    ▼
[MacServer 回环接口 (127.0.0.1:18765)]
    │
    ▼
[EventKitBridgeServer (PID resident in gui/501)]
    │
    ▼
[Apple 原生 EventKit (只读查询)]
```

---

## 二、SSH 身份、主机密钥校验及转发特权限制

为实现零信任安全基线，SSH 隧道采用精细化特权收敛：

### 1. 专用 SSH 身份认证 (Dedicated Identity)
- **密钥路径**：`/root/.ssh/id_ed25519_macserver_tunnel`（权限 `0600`，仅 Seoul root 用户可读）；
- **公钥分发**：放置于 MacServer `~jin/.ssh/authorized_keys`；
- **禁止交互登录**：使用 `-N -T` 参数（不分配 TTY、不执行远程 Shell）。

### 2. 严格主机密钥校验 (Strict Host Key Checking)
- **参数配置**：
  ```
  StrictHostKeyChecking=yes
  UserKnownHostsFile=/root/.ssh/known_hosts
  ```
- **安全保障**：预先录入 MacServer Tailscale IP (`100.100.172.91`) 的 Ed25519 主机公钥指纹。若发生网络中间人篡改或主机变动，SSH 立即拒绝连接，防止假冒。

### 3. MacServer 端最小化转发权限 (PermitOpen Restriction)
在 MacServer 的 `~/.ssh/authorized_keys` 中，针对该专用公钥强制施加选项前缀：
```
command="",no-pty,no-X11-forwarding,no-agent-forwarding,permitopen="127.0.0.1:18765" ssh-ed25519 AAAA...
```
**特权封锁保障**：
- **禁止执行命令** (`command=""`)：即使获得私钥也无法执行任何远程 Shell 命令；
- **禁止无限制转发** (`permitopen="127.0.0.1:18765"`)：禁止跳板攻击，该 SSH 会话**仅能且只能**连接 MacServer 本地 `127.0.0.1:18765`，无法探测局域网其他任何机器或端口。

### 4. Loopback 边界保留与公网防暴露
- Seoul 侧 SSH 仅绑定：
  - `127.0.0.1:18765`（宿主机本地回环）
  - `172.19.0.1:18765`（Docker 容器网桥网关，仅供容器内访问）
- **绝不监听 `0.0.0.0`**：公网网卡完全不可见该端口；
- 配置层硬编码校验：`validateGatewayConfig` 遇到 `0.0.0.0`、`::`、`*` 时立即报错崩溃。

---

## 三、彻底解除 M5 Pro 依赖 (Zero M5 Pro Dependency)

- 生产及候选链路中已完全消除 `100.69.145.3` 和端口 `18443`；
- 无论 M5 Pro 处于在线、关机、休眠还是实验性 A4 进程退役，Seoul → MacServer 只读通道均独立自洽运行。

---

## 四、候选交付文件清单

- **Systemd 单元文件**：[`config/seoul-macserver-tunnel.service.candidate`](file:///Users/jin/.gemini/antigravity/scratch/ag01-workspace/insurance-autonomous-work-system/integrations/apple-icloud-mcp/seoul-gateway/config/seoul-macserver-tunnel.service.candidate)
- **环境变量配置模板**：[`config/gateway.env.candidate`](file:///Users/jin/.gemini/antigravity/scratch/ag01-workspace/insurance-autonomous-work-system/integrations/apple-icloud-mcp/seoul-gateway/config/gateway.env.candidate)
- **JSON 配置模板**：[`config/gateway-config.json.template`](file:///Users/jin/.gemini/antigravity/scratch/ag01-workspace/insurance-autonomous-work-system/integrations/apple-icloud-mcp/seoul-gateway/config/gateway-config.json.template)
- **多跳网络隔离集成测试**：[`tests/container-tunnel.test.ts`](file:///Users/jin/.gemini/antigravity/scratch/ag01-workspace/insurance-autonomous-work-system/integrations/apple-icloud-mcp/seoul-gateway/tests/container-tunnel.test.ts)
