# iCloud CalDAV VTODO 生产热修复的可复现归档（2026-10-31）

> 结论：用户转交了 Antigravity 在首尔生产环境完成的 Calendar/Reminders 真实 OAuth + Apple CalDAV 虚构 CRUD、清理和 work_done 的 PASS 报告。本轮**独立核实运行源码与容器已经包含修复**，将原始生产差异作为可重放补丁保存。**没有重新执行 Apple CRUD**。
>
> Apple 数据仅使用虚构标签，没有在本仓库保存实际日历/联系人/提醒原文。

## 1. 三层证据

| 层级 | 结论 | 来源与限制 |
| --- | --- | --- |
| Antigravity 的实测报告 | OAuth 2.1 DCR+PKCE、Calendar 的 precheck/create/read/update/delete/0 residual、Reminders 的 precheck/create/read/update/delete/0 residual、work_done 全 PASS | 用户于 2026-10-31 提供的现场执行报告；**原始日志和本地测试脚本本轮尚未独立读取/导入 GitHub** |
| 首尔服务器当前源码 | 在 `/opt/insurance-carddav-mcp/source` 的两个文件中有未提交的 VTODO 补丁；Git 基线 `dd64a388a3d9aad769428cf1071ce4c823939b8a`，仅涉及 `src/providers/icloud/caldav.ts` 与 `src/modules/reminders/service.ts` | 本轮通过首尔恢复工具实际执行 `git status`、`git diff`、`git rev-parse`，没有读取真实用户数据 |
| 编译后镜像与现网 | 容器里 `dist/providers/icloud/caldav.js` 和 `dist/modules/reminders/service.js` 都包含 VTODO 分支；容器 `healthy`，`/health` 返回 ok；Calendar/Reminders READ/WRITE 均 true | 本轮只读核实运行文件，不是新一次 OAuth/Apple 调用，也不验证数据长期运行稳定性 |

## 2. 根因与生产修复（精确归档，不自行改写）

- 上游依赖 `tsdav@2.3.1` 的 `fetchCalendarObjects` 未指定 `filters` 时默认查询 `VEVENT`；Reminder 的 `VTODO` 集合被错误过滤。
- 生产修复在 `CalDavProvider.fetchObjects(calendarUrl, range?, component?)` 中新增 `component`，针对 VTODO 将 `filters` 显式设置为 `VCALENDAR → VTODO`。
- ReminderService 的 `list` 改为调用 `caldav.fetchObjects(list.url, undefined, 'VTODO')`。
- [源代码补丁](../patches/apple-icloud-mcp/0001-vtodo-explicit-filter-20261031.patch) 是在服务器对生产源码运行 `git diff` 导出的**精确副本**；`git apply --reverse --check` 在服务器现有源码上 PASS，证明快照与当前热修复一致。生成后本轮未改变生产源码或重新构建。
- [单元回归补丁](../patches/apple-icloud-mcp/0002-vtodo-unit-regression-20261031.patch) 为上游现有两条 `reminders-service.test.ts` 断言追加 `'VTODO'` 参数，防止回归成不带组件的查询；在现有源上 `git apply --check` PASS，但**尚未在 CI 上运行 Vitest**。

## 3. 后续构建如何避免把热修复覆盖

在保险项目仓库中执行，`upstream-source` 指一份 Git 基线相容的 [apple-icloud-mcp](https://github.com/MrZhongzq/apple-icloud-mcp) 源码工作区：

```bash
bash scripts/integrations/apply-icloud-vtodo-patch.sh --check /path/to/upstream-source
bash scripts/integrations/apply-icloud-vtodo-patch.sh --apply /path/to/upstream-source
cd /path/to/upstream-source
npm run typecheck
npm test
npm run build
```

- 脚本默认 `--check`，`--apply` 才修改目标源码；既有补丁识别为 `ALREADY_APPLIED`，可重复执行；遇到其他上游变更阻断而不覆盖。
- 本轮已在首尔临时**干净 Git 克隆**中完成 `--check → --apply → 再次 --apply` 全流程，验证首次可应用、二次幂等；对现有生产源码只作 `--check`，输出修复已存在、单元测试补丁可应用。临时克隆随后清理。
- 源码补丁仍需要被后续 Docker 构建流程显式应用或由上游接受 PR；**仅把补丁文件提交到保险仓库，不会自动影响未来从新源码构建的镜像**。
- 生产源 Git 工作区的两处文件当前仍为未提交改动；不要执行会丢弃它们的 `git reset --hard`、清理工作区或者无审查直接升级上游依赖。

### 审查注意

现有生产代码中的条件 `component === 'VTODO' || (!range && component !== 'VEVENT')`，除了显式 VTODO，还会把**没有 range、未指定 component**的调用归到 VTODO。当前已知 ReminderService 显式传 VTODO，CalendarService 的范围查询传 range；但这个隐式默认行为在未来新增调用方时可能有惊讶。**本轮如实保存与已通过 Apple CRUD 的生产版本完全一致的补丁，未对它自行改写。** 另行添加无 range 参数的 VEVENT 回归测试后，可简化为显式 `component === 'VTODO'` 并进行新的验证；不能把这种未来变更冒充已上线代码。

## 4. 尚未同步的 Antigravity 原始 E2E 脚本

用户报告的真实文件路径：

`/Users/jin/.gemini/antigravity/scratch/insurance-autonomous-work-system/tests/integrations/carddav/test-calendar-reminders-crud.mjs`

**本轮无法通过 GitHub 或首尔云主机读取 Mac 本地 file:// 文件**；该文件尚未出现在 GitHub `main`。为保留真实验收套件，请在该 Mac 的现有 Antigravity/Codex 会话中：

1. 在上述真实路径读取原脚本；不要重写一个行为相似但失去原回执的版本。
2. 先检查无真实 OAuth Token、Access Key、Apple 专用密码、管理员口令、客户或日历数据被硬编码。
3. 将其按原路径提交到 `gehbfarr5/insurance-autonomous-work-system` 的评审分支或 PR；保留测试执行日志的关键 PASS/FAIL 项和零残留证据（脱敏）。
4. 切勿为单纯同步源码而再跑一次 Apple CRUD。

## 5. 完成与仍需处理的项目

- **服务层功能验收**：用户报告 Calendar/Reminders 真实端到端 PASS（有明确虚构标签、创建、读取、更新、删除和零残留）。
- **当前源码与生产镜像**：独立核验 PASS，VTODO 修复确实已编译入运行服务。
- **可重放源码补丁**：已归档；脚本在干净临时源码上实测可应用且幂等。
- **原始端到端测试文件**：**未归档**，仍在本地 Mac，需另行提交。
- **CI 自动构建防漂移和上游合并**：未完成；源码依赖后续变更时必须重新核验。
- **MUSE 和后续 Agent 的 Calendar/Reminders 工具调用**：仍需每个客户端自行校验 tool list/login/read；不需要重复真实写入实验。
- **实际保险业务闭环**：尚未开始真实客户任务，本次虚构 CRUD 不能替代客户业务联调。

对应 [Issue #13](https://github.com/gehbfarr5/insurance-autonomous-work-system/issues/13)。