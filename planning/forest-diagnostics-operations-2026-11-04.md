# 阳光森林有界诊断与恢复说明｜2026-11-04

## 状态与范围

记录更新时间：2026-11-03 16:33 CST。此说明只覆盖既有每日任务自然运行及一次性诊断证据收集，不启动任何业务动作，不改变调度、防重状态或凭据。

### 访问门禁历史记录｜2026-11-03 16:14 CST

CUA inventory returned “Mac is locked”; MUSE UI was not read at that time. The following 16:23 MUSE-only readback supersedes this unknown queue status. No Pixel connection followed. Private CUA error record: `muse-access-gate-20261103-1614.json`, SHA-256 `80b65bfcb899569a4f5d0169e66effff268ba659427a4ce59538d01325c4595a`.

### 最新MUSE只读回读｜2026-11-03 16:23 CST

MUSE confirmed the single enabled Asia/Shanghai 09:00 schedule, next trigger Nov 4, running/queued/in-flight `0/0/false`, runner lock `FREE`, no `forest-agent` process, latest scheduler failure Nov 3 09:11:17, last success Oct 31 09:15:50, and three consecutive failures. The query was accidentally truncated to keywords; MUSE stated this read was read-only and did not access Pixel, read business state, or change anything. The assistant/main status remains carried forward from earlier and was not reread. Pixel device state, device-operation lock, and foreground Activity remain UNKNOWN. Private sanitized readback `muse-access-readback-20261103-1623.json`, SHA-256 `984471e93c15f10ba975dd1c1ac93862192274b0111456591c576e5ec4dda3b9`; it is not a raw UI export.

### Runner static read｜2026-11-03 16:33 CST

MUSE recomputed the current live `run.py` hash and confirmed it matches the recorded deployment hash. Static flow: `Device.prepare()` polls resumed Activity with a 70-second deadline and 1-second interval; `Device.event()` writes prepare events; `Device.cleanup()` is called from `main()` and handles marker cleanup, app stop, and owner-checked lock release, with a failure branch on exception. MUSE attributed scheduler-level `FAILED` to the worker reporting unfinished work, consistent with the incomplete assistant/main segments. The 09:06:17–09:11:17 interval remains UNKNOWN because neither runner code nor scheduler metadata has a sub-step breakdown; this read also does not identify the specific prepare-timeout trigger. MUSE reported a private export of the exact live runner is available, but did not export or attach it. Private sanitized readback SHA-256: `fb4493eaf0f6161709225cb75940fecb5a3182806cc639e8829ffbd8d18605a0`.

### 最新只读复核｜2026-11-03 15:54—15:58 CST

- MUSE 15:54:29确认唯一既有每日09:00 CST任务，下次11月4日09:00；running/queued/in-flight为0/0/false，runner lock FREE，无forest-agent进程。最近调度失败11月3日09:11:17，最近成功10月31日09:15:50，连续失败3次。
- 在上述无并发readback之后，经唯一允许的`pixel3a-kjgx`别名及既有`su`路径于15:58:24只读回读：Android 15、boot完成、Dozing；monitor `watching`、guard清、heartbeat新鲜、requests=0；monitor lock存在，blocked/stop不存在。monitor/trigger/worker哈希分别为`2b611ca16f49523c74e544b96e19a7931db6af7d1ea4787ecea708b25e56241a`、`0243ee09abdbf07b162cc69c815ca69f00ad3519bda78df26d8588a5e9c0c499`、`f6fb7d23ebdb75183a62430d92aa7e161ff1ec7fc3db10f26ac857da8939000f`。
- 设备操作锁和前台Activity本次为UNKNOWN；v0.19 APK pin只在15:22最后直接核验并匹配。没有业务重跑、设备写入或state/cron/调度变更。后续窗口开始前仍须即时复核MUSE并发及设备锁；不因本次readback跳过门禁。
- 本次状态抄录存于仓库外受限私有文件`status-readback-20261103-1554-1558.json`，SHA-256 `58d9f090792927caa636cb4d59bfa37ccc8401cf53dc3bafad9f59ce9164bfaf`。它是脱敏操作员抄录，不是MUSE原始导出或Pixel stdout；UNKNOWN项和APK哈希的15:22读取时点均保留。
- 11月4日只读review包`auth-trigger-diagnostics-20261104-review-only`的SHA256SUMS于16:10 CST复算14/14匹配，随后原生命令`shasum -a 256 -c SHA256SUMS.txt`也返回14/14 OK；其monitor候选哈希与15:58 live读数一致。仓库外私有校验记录`review-package-integrity-20261103.json` SHA-256 `89721b3f7b1b5761b1fd672dc994364a889a6b8854169568e2fa5ecb2a5c5e1a`。清单完整性不代表窗口期Keyguard API/sidecar/MUSE对账已实机验收；只用此包中的collector说明，不应用窗口已过期的11月3日v3部署包。

- **前一时点记录（15:37，已由上方15:54状态读回更新）：** MUSE 14:09 CST 快照报告既有 `Asia/Shanghai 09:00` 任务下一次为 11 月 4 日 09:00，且当时 running/queued/in-flight 均为 0。15:37 CUA 应用清单确认 MUSE 进程运行，但未读回任务状态。不要把旧快照或应用进程状态当成当前任务 readback。
- Pixel 15:22 CST 通过现有 `pixel3a-kjgx` 别名及其既有 `su` 路径只读复核：`sargo`、Android 15、启动完成；monitor 状态 `watching`、guard 未阻断、心跳新鲜、`requests=0`；设备操作锁、`blocked` 与 `stop` 标记不存在，monitor 自身锁存在。Forest 未在前台，设备 Dozing。
- 已部署的 monitor-only 候选 SHA-256 为 `2b611ca16f49523c74e544b96e19a7931db6af7d1ea4787ecea708b25e56241a`；其触发器与 worker 哈希仍为 `0243ee09abdbf07b162cc69c815ca69f00ad3519bda78df26d8588a5e9c0c499` 与 `f6fb7d23ebdb75183a62430d92aa7e161ff1ec7fc3db10f26ac857da8939000f`。已安装 v0.19 SecureView APK 哈希 `dbada93c1d0110fe86ef1c0cad77224e81c0f5939bd9462a3c0b9d5b72c48167` 与 runner pin 一致。
- 输入审计仍为 12 行，最后修改时间 2026-10-31 09:06:46 CST；现有状态记录为 `page_left`，本轮没有认证输入。固定窗口 sidecar 尚未出现，窗口为 2026-11-04 08:55–09:55 CST。登录字段逐项诊断仍不可用，因为 prepare observer 未部署。

完整只读 readback 及 MUSE 状态限制见[诊断检查点](forest-prepare-diagnostics-2026-11-03.md)。恢复基线哈希、设备备份位置、候选及离线验证材料见本机私有审阅包。

## 自然运行顺序

1. **先确认 MUSE 并发，再接触 Pixel。** 通过已有 MUSE 运行入口只读确认当前日程、运行/排队/在途任务及目标自然运行。只有确认没有其他设备任务占用、且目标任务身份明确后，才通过现有 Pixel 别名复读 monitor、设备操作锁及部署哈希。若 MUSE 当前任务或队列不可读/UNKNOWN，跳过 Pixel 连接和所有设备诊断；记录 UNKNOWN，等待可验证无并发后再继续。不手动启动、取消或改动原任务，不连接备用 SSH 路线。
2. **只允许既有自然调度发生。** 不点击入口，不重放、不补跑、不登录，不清理 `state`、防重记录、attempt 或 audit 文件。已有授权只覆盖原每日范围，不因诊断窗口扩大业务权限。
3. **窗口结束且确认无在途任务后只读采集。** 取得 MUSE 已脱敏的 `assistant` 与 `main` 两段唯一、非重叠起止时间，并确认任务已结束、没有其他设备任务运行，再通过本机私有 collector 从同一 Pixel 别名读取 sidecar 与 epoch 时间日志。若任务结束或设备独占状态无法确认，先不连接 Pixel、不采集；继续标记 UNKNOWN。使用本机私有包`auth-trigger-diagnostics-20261104-review-only/README.txt`中的输入契约；先在包目录执行`shasum -a 256 -c SHA256SUMS.txt`，14个成员均须为OK。该包要求仅输入脱敏的唯一assistant/main区间，collector命令为：

   ```sh
   python3 collect-run-diagnostics.py --segments <sanitized-segments.json> --output <private-result.json>
   ```

   在该私有包目录内运行。输入与输出均留在本机私有目录，不上传MUSE原始结果或Pixel日志。不要使用固定窗口已过期的`auth-trigger-diagnostics-keyguard-v3-bounded`部署包；也不要执行私有归档`delivery-package-v4/INSTRUCTIONS.txt`中的2026-11-02单次补跑指令，该次已按授权完成。当前只允许自然调度与此处说明的只读采集。
4. **缺失继续记 UNKNOWN。** 没有 sidecar、日志 marker 不在唯一分段内、MUSE 分段缺失/重叠、来源不可用时，不合成事件、不从空结果推出“未触发”，也不重试生产动作。`NOT_SENT`、`SENT`、`UNKNOWN`、页面完成和奖励确认分别保留。

## 异常停止与回滚

- 若哈希不符、stop/blocked 标记出现、monitor 状态异常、设备操作锁被占用或 MUSE 报告有并发运行：停止诊断动作；先读清在途状态，不启动另一个流程、不删锁或状态。当前只读检查不授权解除并发锁。
- 若安全原因要求停止 monitor，先复读操作锁及是否存在 `input_requested` 在途阶段；确认没有在途认证后才可用原有 `stop` 标记使其自行退出，并读回停止状态。不要 `kill` AutoX，也不要在窗口内以清锁方式恢复。
- 如需回滚已部署 observer，使用已验证的设备备份 `/data/user/0/org.autojs.autoxjs.v7/files/pixel-auth/monitor.js.rollback-20261103-1500`，其基线 SHA-256 为 `238d86a8ec06c5a92579ea54377956f282cbed824c32b2c56823a2924cb906fd`。操作前复读设备操作锁与当前候选哈希；恢复后必须复核 live 文件哈希，并通过既有 AutoX 启动方式确认 `watching`、新鲜 heartbeat、guard 清。若启动入口或 readback 不能确认，停在文件已回滚状态，不尝试任何业务动作。
- monitor 的 `requests` 是进程内计数，重启会归零。记录每次重启前后真实读数，不回填历史累计，不改写原始运行结果。
- v0.19 工件保持 pin；prepare observer 不部署。不得降低固定方法指纹、手势页/本人匹配或登录态门禁。

## 交接判据

运行证据由 MUSE 自然任务原始记录与本机脱敏导出组成，两者来源和时间分开标注。诊断阶段只有在实际环境/工件版本复核完成，且同轮日志把故障定位到明确阶段（或严格证明观测仍 UNKNOWN）、没有误触发业务时才算通过。一次自然运行或一次健康 readback 不代表日常业务成功、S1 完成或长期稳定。
