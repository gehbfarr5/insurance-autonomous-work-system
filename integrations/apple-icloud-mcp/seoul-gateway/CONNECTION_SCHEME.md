# AG-03: Seoul → MacServer 常驻连接方案 (Persistent Connection Scheme)

- **设计版本**：v1.0 (AG-03 Gateway 候选)
- **基线分支**：`feat/seoul-macserver-readonly-gateway`
- **目标端点**：
  - **Seoul MCP 主机**：`VM-0-10-ubuntu` (Tailscale: `100.82.240.43`, 公网出口受安全组严密保护)
  - **MacServer 常驻宿主**：`macserver-ts` (Tailscale: `100.100.172.91`, macOS 15.7.7 x86_64, `gui/501`)
- **前置原则**：
  1. Seoul Host 为 MUSE 的**唯一**统一入口网关。
  2. 链路**绝对不依赖 M5 Pro**（M5 Pro 完全从运行时数据路径中剥离）。
  3. **严禁扩大公网暴露**（全链路封闭于 Tailscale WireGuard 私网及 loopback）。
  4. 网络与服务配置本轮仅作候选准备，部署另行审批。

---

## 一、网络现状与设计权衡

### 1.1 现状分析
1. **MacServer 局部安全**：`EventKitBridgeServer` 依据安全基线严格监听在 `127.0.0.1:18765`（回环地址），防止同内网未授权进程探测。
2. **跨机通信需求**：运行在 Seoul 容器中的 MCP 网关需要安全请求 MacServer 的只读 HTTP 接口（`GET /health`、`GET /reminders/lists`、`GET /reminders/lists/:id/items`）。
3. **M5 历史依赖解除**：前期实验（A4）将请求指向 M5 Pro (`100.69.145.3:18443`)。本方案彻底断开与 M5 Pro 的任何联系，实现端到端常驻直连。

---

## 二、候选方案对比与选型

### 方案 A：Tailscale 私网 SSH 隧道守护（推荐候选，Candidate 1）

```
[MUSE 前台] 
    │ HTTPS
    ▼
[Seoul Host (100.82.240.43)]
    │ 
    ├─► apple-icloud-mcp 网关容器 (请求 http://127.0.0.1:18765)
    │        │
    │        ▼
    └─► systemd 守护进程: seoul-macserver-tunnel.service
             │ 
             │ SSH Local Port Forwarding (-L 127.0.0.1:18765:127.0.0.1:18765)
             │ 运行于 Tailscale WireGuard P2P 加密隧道内 (100.82.240.43 -> 100.100.172.91)
             │
             ▼
[Intel MacServer (100.100.172.91)]
    │
    └─► EventKitBridgeServer (监听 127.0.0.1:18765)
             │ 
             ▼
        EventKit 原生只读接口 (TCC: authorized, read-only)
```

**核心优势**：
- **零配置侵入**：MacServer 端已部署的 `EventKitBridgeServer`（`127.0.0.1:18765`）无需做任何代码修改或重新启动；
- **双重认证与加密**：Tailscale WireGuard 传输层加密 + SSH 专用公钥认证（`id_ed25519_macserver_tunnel`）；
- **系统级自愈**：通过 Seoul systemd 监督，断线后 `Restart=always` 自动重连；
- **公网零暴露**：SSH 服务仅绑定 Tailscale 网卡，且仅转发 `127.0.0.1`。

**候选配置交付**：
- Systemd 单元文件：`config/seoul-macserver-tunnel.service.candidate`

---

### 方案 B：MacServer 监听 Tailscale 私网 IP（备用候选，Candidate 2）

若未来希望精简 SSH 进程，可在 MacServer 守护配置中允许绑定至 Tailscale 单一接口：
- 绑定地址：`100.100.172.91:18765`；
- 访问控制：通过 Tailscale ACL（只允许 Seoul `100.82.240.43` 出站访问 MacServer `100.100.172.91:18765`）；
- 应用层安全：每次调用强制验证 32 字节 Bearer Token 及生产激活开关。

*注：当前版本优先使用方案 A，以保持 MacServer 运行中的 candidate 安装包（97571d4）状态绝对不受扰动。*

---

## 三、网络安全与红线保障

1. **绝对禁止通配监听 (`0.0.0.0`)**：
   - 网关配置解析器 `validateGatewayConfig` 已硬编码断言：若 endpoint 主机为 `0.0.0.0`、`::` 或通配符，立即抛出 `INVALID_INPUT` 并拒绝启动。
2. **彻底脱离 M5 Pro**：
   - 生产与候选配置中已完全清除 `100.69.145.3` 和 `18443` 端口；
   - 无论 M5 Pro 处于开机、休眠还是实验进程退役状态，均不影响 Seoul → MacServer 链路。
3. **只读保护与降级防护**：
   - 写操作（POST/PATCH/DELETE）在 Seoul 端 `transport.ts` 与 `service.ts` 均被强制拦截并抛出 `PERMISSION_DENIED`；
   - 严禁向 MacServer 转发写请求，且严禁回落至已废弃的旧 VTODO 写入逻辑；
   - 故障时禁止假充空列表返回成功。

---

## 四、部署就绪度

- 配置文件与 Systemd 单元已在 `integrations/apple-icloud-mcp/seoul-gateway/config/` 完成编制；
- **当前状态**：`READY_FOR_APPROVAL`（未部署至 Seoul 生产，等待专项部署授权）。
