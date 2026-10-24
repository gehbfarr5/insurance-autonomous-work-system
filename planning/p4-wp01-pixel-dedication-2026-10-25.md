# Pixel 专机化：系统更新与清理准备

日期：2026-10-25。状态：初查后用户已授权先备份至外置盘，再按计划逐步清理；外置盘备份进行中，尚未清理、更新系统、重启或访问签到页面。本记录用于对齐设备实际状态与专机化计划。

## 目标与边界

Pixel 后续仅承担科技个险相关工作；当前实施范围仍仅每日签到。专机化前先清点系统、旧任务、注入与主机控制入口，避免删除后丢失恢复路径。公司业务数据与其他个人数据不得进入公开仓库。

## 当前事实

通过已有 MacServer USB/ADB 只读检查：LineageOS 22.2-20260314-NIGHTLY-sargo、Android 15、安全补丁字段 2026-02-01；A/B 设备，当前槽位字段 _a。/data 约50G，已用13G、可用37G，约27%。第三方软件枚举36项；并非空间不足导致必须清理。

2026-10-25 直接查询官方构建 API，首项为 22.2-20261017-nightly-sargo，API35、安全补丁2026-10-01。官方 wiki 源文件 current_branch 为22.2。此证据支持优先评估同分支更新，不能据全局 LineageOS 23 发布推导本机应升 Android16。

- [设备官方元数据](https://github.com/LineageOS/lineage_wiki/blob/main/_data/devices/sargo.yml)
- [官方构建 API](https://download.lineageos.org/api/v2/devices/sargo/builds)
- [设备下载入口](https://download.lineageos.org/devices/sargo/builds)

目录元数据发现 /data/local/tmp 残留旧 Hook APK、框架安装包、Frida/uiautomator/scrcpy 组件、SQL、UI dump、账号相关命名文件及旧数据库备份。仅列目录，不读取其中账号、业务数据或运行旧文件。文件存在不证明进程或任务仍运行。

MacServer LaunchAgent 文件内容匹配发现微信读书 bot/weekly、科技个险 import-queue-watchdog/control-center/watchdog、wsscrcpy 六个入口。此轮仅定位文件；未确认所有任务当前加载状态、目标设备、调用链或修改配置。卸载手机应用前必须逐项核对，防止主机继续发送任务。

## 初步处置清单（未执行）

| 分类 | 对象 | 理由与前置条件 |
| --- | --- | --- |
| 保留候选 | 科技个险、Magisk、Vector、输入法 | 构成业务与必要注入基础；更新后重新验证 |
| 优先隔离 | 旧 com.kjgx.hook、com.kjgx.capture、com.codex.termuxmonitor | 旧 Hook 已有启用及目标作用域证据；不继承旧客户/课程逻辑 |
| 移除候选 | 微信读书及 guardian/capture、ChatGPT、ReVanced、MifareClassicTool | 与专机目标无关；先确认数据保留要求并停掉外部触发链 |
| 待查依赖 | Clash Meta、HideMyApplist、FakeGApps、Play Integrity Fix、Shizuku、AppOps、AdAway、Greenify | 可能影响网络、APP启动、权限、后台；不可按名称批量删除 |
| 工具收敛 | Tasker、AutoX.js、Termux、uiautomator、文件管理器、安装器、应用商店、备份工具 | 先查现有任务与权限，最终仅保留选定执行与维护所需工具 |
| 文件归档清理 | /data/local/tmp 与用户共享存储 | 私密分类归档及恢复核对后删除；不公开内容，不执行旧脚本 |
| 主机入口停用候选 | 上述6个 LaunchAgent | 核对实际加载、脚本、目标设备及其他设备依赖后，分别处理 |

应用名称归类是处置建议，不代表已证明其全部行为。共享存储此次只读到符号链接，尚未完成内容目录清点；完整系统应用、权限/设备管理、Tasker/AutoX.js任务、全部框架作用域、主机cron等仍需进一步检查。

## 备份与复查进展（2026-10-25）

用户授权：先备份至已连接外置硬盘，再按已审阅计划逐步清理。当前不扩展到系统刷写、业务账号操作或签到。

外置盘 DTC810 已挂载，可用约211GiB；已建立仅当前用户可访问的私密备份目录。运行态文件备份覆盖 /data（包括应用APK、应用数据、共享存储、Magisk/Vector与旧自动化资料）和 /metadata，另准备保存 boot/dtbo/vbmeta 两槽位镜像。备份原始文件和准确路径仅保存在私密记录。此为文件层备份，尚无整机恢复验证，不保证应用运行中多文件一致性、硬件绑定密钥可移植性或完整SELinux/xattr还原。权限限制不等于磁盘加密。

初次传输因 exec-out 合并错误流导致归档头污染，已中断并保留诊断；改用 shell -T 的分离错误流。Toybox --selinux 读取标签失败，已中断该次归档；改用标准归档并单独保存标签清单，明确完整标签还原未验收。小归档二进制传输与读取检查退出0；完整归档仍待结束、检查、哈希和遗漏审阅，不能据小检查标记完整备份PASS。旧失败文件不作为恢复来源。

补充的真实状态：

- /data/media 约4.63GiB、/data/app约2.99GiB、/data/user约2.90GiB；这些目录会随运行变化，不能当精确最终归档大小。
- 框架数据库不仅启用旧科技个险Hook，也启用读书capture及guardian；guardian作用域包含android/system及读书APP。后续隔离需考虑系统进程重启生效，不能只卸载读书界面APP。
- 主机六个相关LaunchAgent中，读书weekly、科技个险import-queue-watchdog、wsscrcpy.server已加载；读书bot、control-center及其watchdog未加载。已保存plist、launchctl清单、cron和进程快照；是否指向本Pixel仍需核对具体调用链。
- 已补存完整包管理状态、后台服务/作业、权限与设备管理快照、Tasker/AutoX.js目录元数据及共享存储目录清单；快照归档不代表每项依赖已解释。
- 在已检查的历史注入安装材料目录与MacServer Downloads未找到匹配的sargo/Lineage系统zip或img，不声称已拥有当前旧ROM完整回退包。boot两槽位备份也不替代完整系统来源与兼容性核对。

清理先决条件补充：完整备份检查结束、定位影响清理对象的遗漏、核对Mac触发链；任何将移除的应用先核对APK/数据是否在有效归档中。先停用并观察再卸载，记录每批动作、复查结果与恢复位置。系统更新仍单列方案，确认恢复材料后实施。

## 两条路径与推荐

A：保留数据渐进整顿 → 同22.2分支更新 → 注入和APP重新验收。优点是保留登录与回退线索，推荐；缺点是必须逐项识别遗留。

B：备份后清空重建专机。基线更容易审阅，但丢失登录/私有配置风险高，重建和恢复成本更大；仅在无法解释的遗留或污染确有阻碍时采用。当前不建议先恢复出厂或跨分支刷机。

## 顺序、验收与恢复准备

1. 完成任务/权限/主机调用链清查，确定保留数据与私密备份去向。
2. 准备旧系统及匹配boot/recovery镜像来源与校验、当前模块配置备份、可物理接手恢复条件。不要把A/B另一槽位当作已验证备份；版本回退可能涉及数据兼容甚至清除。
3. 审阅并授权具体停用与清理项；先隔离旧任务，再分批清理，保留临时Mac维护链路。
4. 审阅并授权同分支更新方案，核查官方步骤和当前Magisk/Vector保留或恢复方式；更新不保证root/模块自动保留。
5. 核验启动、网络、root、最小无业务探针、APP启动；之后单独建立脱离Mac的远程控制/停止/恢复能力。
6. 最后进入签到工作包逐级验收，不因更新成功宣称签到成功。

reuse：现有手机、官方22.2更新分支、已有最小探针思路。adapt：root/注入恢复、专机网络与任务管理。avoid：整体继承旧自动化、批量无差别卸载、未备份刷机、把安全补丁属性当完整安全审计。

原始检查保存在工作区 .private/p4-wp01/pixel-cleanup-audit-2026-10-25，包含私密设备资料，不应提交；前轮环境证据见 pixel-environment-2026-10-24.md。清查仍在准备阶段，不标记整机专用化 PASS。
