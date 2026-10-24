# 云端 Android 初查线索（未选型）

> 2026-10-24：保留 P3 中已做的有限资料初查。用户随后要求具体技术问题递延到 P4 对应工作；本文件不作为 P3 收尾条件，也不要求立即继续调查。正式框架见[P3 结项](../p3-framework-and-p4-transition.md)。

## 首轮资料核查｜2026-10-24

问题画像：以 iPhone 为日常入口，尽量解除对实体 Pixel 和本地 Mac 的常驻依赖；保留已确认的注入必要前提。当前只有云端资料与开源文档证据，没有科技个险云端运行证据。未安装服务、上传 APP 或使用真实账号。

已检查本地可用技能目录，未发现 github-solution-research 技能；本次使用连接的 GitHub 及官方来源进行只读初查。尚未完成供应商/项目维护、发行版和适用许可的完整选型审查。

| 路线 | 已有直接证据 | 未证实与适配代价 | 当前判断 |
| --- | --- | --- | --- |
| 托管云 Android／设备镜像，以 Genymotion 为候选样本 | 官方文档提供 root 配置；SaaS 文档说明 arm64 应用部署、保存 recipe，以及运行时限管理 | root 不等于现有注入模块可用；SaaS 与 PaaS 能力不能混用。APP 登录、注入链、保存后的业务状态、长期运行条款及费用未核实 | 继续研究；不选定产品，不声称满足注入前提 |
| 云服务器自管 Android，以 redroid 为候选样本 | 上游 README 说明 Linux 宿主、arm64/amd64、多 Android 版本、数据挂载及 ADB；核心 Apache、内核模块 GPLv2，其他依赖需逐项审查 | 宿主内核与权限有要求；注入兼容和科技个险运行未证实。减少本地设备可能转为增加云端维护工作；不能以 root shell 推定 LSPosed 可用 | 作为另一条云端候选继续比较，暂不选定 |
| Pixel 独立执行 | 用户确认实体设备及注入环境曾验证可用 | 是否可脱离 Mac 常驻、如何编排/恢复仍未知 | 按用户选择保留为云端不满足条件后的备选 |

首轮推荐是研究顺序，而非产品选择：先取得现有注入方案的具体要求，再筛选云端环境；以“不需要本地 Mac 或 Pixel 常驻、允许且支持必要注入、状态可保持/恢复、结果可核对、维护负担可接受”为目标比较。供应商 root 宣传和通用安装成功均不足以判定可替代 Pixel。

复用／适配／避免：复用成熟产品或上游 Android 云运行能力，不从零制作云 Android；适配实际注入机制、APP/Android/CPU 版本、账号状态、任务编排及证据；避免把历史 LSPosed 实现当作必选或必能迁移，避免直接运行社区脚本和暴露公网 ADB。redroid 上游明确不应暴露公网 ADB。用户许可与工具可信度、账户隔离及凭据保护分别处理。

证据链接：

- Genymotion root：https://docs.genymotion.com/features/root/
- Genymotion SaaS 应用部署与 recipe：https://docs.genymotion.com/usage/saas/deploy_apps/
- Genymotion SaaS 运行时限：https://docs.genymotion.com/usage/saas/admin_interface/
- redroid 上游 README（本次读取 blob 8a6046306d3d35e90abffb1c5db0d96c672b6309）：https://github.com/remote-android/redroid-doc
- Magisk 官方 Zygisk 机制说明：https://topjohnwu.github.io/Magisk/guides.html

证据强度：上游对自身能力的文档说明；未覆盖本项目兼容性。检索出现的社区 redroid 注入适配仓库尚未核验维护、许可与具体版本，不作为已支持的依据。部分 Genymotion 注入安装支持页无法稳定读取，未据搜索片段锁定具体框架或安装方式。当前不提供未经核实的费用、工时或成功率。

