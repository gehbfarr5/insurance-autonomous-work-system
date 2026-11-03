# 阳光森林有界诊断与恢复说明｜2026-11-04

## 状态与范围

记录更新时间：2026-11-03 15:37 CST。此说明只覆盖既有每日任务自然运行及一次性诊断证据收集，不启动任何业务动作，不改变调度、防重状态或凭据。

- MUSE 14:09 CST 快照报告既有 `Asia/Shanghai 09:00` 任务下一次为 11 月 4 日 09:00，且当时 running/queued/in-flight 均为 0。15:37 CUA 应用清单确认 MUSE 进程运行，但没有可用 MUSE 连接器，且本轮未打开界面；当前队列、锁与运行状态为 **UNKNOWN**。不要把旧快照或应用进程状态当成当前任务 readback。
- Pixel 15:22 CST 通过现有 `pixel3a-kjgx` 别名及其既有 `su` 路径只读复核：`sargo`、Android 15、启动完成；monitor 状态 `watching`、guard 未阻断、心跳新鲜、`requests=0`；设备操作锁、`blocked` 与 `stop` 标记不存在，monitor 自身锁存在。Forest 未在前台，设备 Dozing。
- 已部署的 monitor-only 候选 SHA-256 为 `2b611ca16f49523c74e544b96e19a7931db6af7d1ea4787ecea708b25e56241a`；其触发器与 worker 哈希仍为 `0243ee09abdbf07b162cc69c815ca69f00ad3519bda78df26d8588a5e9c0c499` 与 `f6fb7d23ebdb75183a62430d92aa7e161ff1ec7fc3db10f26ac857da8939000f`。已安装 v0.19 SecureView APK 哈希 `dbada93c1d0110fe86ef1c0cad77224e81c0f5939bd9462a3c0b9d5b72c48167` 与 runner pin 一致。
- 输入审计仍为 12 行，最后修改时间 2026-10-31 09:06:46 CST；现有状态记录为 `page_left`，本轮没有认证输入。固定窗口 sidecar 尚未出现，窗口为 2026-11-04 08:55–09:55 CST。登录字段逐项诊断仍不可用，因为 prepare observer 未部署。

完整只读 readback 及 MUSE 状态限制见[诊断检查点](forest-prepare-diagnostics-2026-11-03.md)。恢复基线哈希、设备备份位置、候选及离线验证材料见本机私有审阅包。

## 自然运行顺序

1. **先确认 MUSE 并发，再接触 Pixel。** 通过已有 MUSE 运行入口只读确认当前日程、运行/排队/在途任务及目标自然运行。只有确认没有其他设备任务占用、且目标任务身份明确后，才通过现有 Pixel 别名复读 monitor、设备操作锁及部署哈希。若 MUSE 当前任务或队列不可读/UNKNOWN，跳过 Pixel 连接和所有设备诊断；记录 UNKNOWN，等待可验证无并发后再继续。不手动启动、取消或改动原任务，不连接备用 SSH 路线。
2. **只允许既有自然调度发生。** 不点击入口，不重放、不补跑、不登录，不清理 `state`、防重记录、attempt 或 audit 文件。已有授权只覆盖原每日范围，不因诊断窗口扩大业务权限。
3. **窗口结束且确认无在途任务后只读采集。** 取得 MUSE 已脱敏的 `assistant` 与 `main` 两段唯一、非重叠起止时间，并确认任务已结束、没有其他设备任务运行，再通过本机私有 collector 从同一 Pixel 别名读取 sidecar 与 epoch 时间日志。若任务结束或设备独占状态无法确认，先不连接 Pixel、不采集；继续标记 UNKNOWN。命令与输入格式见私有包 `README.txt`。collector 仅写本机受限权限的脱敏结果，不向设备写入。
4. **缺失继续记 UNKNOWN。** 没有 sidecar、日志 marker 不在唯一分段内、MUSE 分段缺失/重叠、来源不可用时，不合成事件、不从空结果推出“未触发”，也不重试生产动作。`NOT_SENT`、`SENT`、`UNKNOWN`、页面完成和奖励确认分别保留。

## 异常停止与回滚

- 若哈希不符、stop/blocked 标记出现、monitor 状态异常、设备操作锁被占用或 MUSE 报告有并发运行：停止诊断动作；先读清在途状态，不启动另一个流程、不删锁或状态。当前只读检查不授权解除并发锁。
- 若安全原因要求停止 monitor，先复读操作锁及是否存在 `input_requested` 在途阶段；确认没有在途认证后才可用原有 `stop` 标记使其自行退出，并读回停止状态。不要 `kill` AutoX，也不要在窗口内以清锁方式恢复。
- 如需回滚已部署 observer，使用已验证的设备备份 `/data/user/0/org.autojs.autoxjs.v7/files/pixel-auth/monitor.js.rollback-20261103-1500`，其基线 SHA-256 为 `238d86a8ec06c5a92579ea54377956f282cbed824c32b2c56823a2924cb906fd`。操作前复读设备操作锁与当前候选哈希；恢复后必须复核 live 文件哈希，并通过既有 AutoX 启动方式确认 `watching`、新鲜 heartbeat、guard 清。若启动入口或 readback 不能确认，停在文件已回滚状态，不尝试任何业务动作。
- monitor 的 `requests` 是进程内计数，重启会归零。记录每次重启前后真实读数，不回填历史累计，不改写原始运行结果。
- v0.19 工件保持 pin；prepare observer 不部署。不得降低固定方法指纹、手势页/本人匹配或登录态门禁。

## 交接判据

运行证据由 MUSE 自然任务原始记录与本机脱敏导出组成，两者来源和时间分开标注。诊断阶段只有在实际环境/工件版本复核完成，且同轮日志把故障定位到明确阶段（或严格证明观测仍 UNKNOWN）、没有误触发业务时才算通过。一次自然运行或一次健康 readback 不代表日常业务成功、S1 完成或长期稳定。
