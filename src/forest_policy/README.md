# 森林离线策略与意图日志

从本地已有单次执行器中恢复的可公开部分。`policy.py`逐字复用；`journal.py`从私有`run.py`提取`atomic_json`和`Journal`，仅补独立导入；16个合成策略测试仅将Journal导入改为本目录。另含4项真实子进程中断/重启恢复测试：持久意图写入后SIGKILL、新进程只读对账不重放、未决结果继续阻塞、真实flock随进程退出释放。业务状态仍为合成数据，不涉及设备或服务重启；仅适用于支持fcntl/SIGKILL的macOS/Linux。无第三方运行依赖，使用Python 3.9+标准库（须有Asia/Shanghai时区数据）。本轮实测Python版本见核查报告。

在仓库根目录运行：

```sh
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s src/forest_policy -p 'test_*.py' -v
```

该命令只使用合成数据和临时目录，不连接手机或业务系统。策略检查日期、页面指纹、新查询回执、奖励ID与余额；提交前写持久意图，结果不明保留并拒绝重放。文件原子替换和fsync不等于设备强杀/重启恢复已经实测。调用方必须提供独占控制和受控适配器；本目录不是可直接部署的业务执行器。

`config.example.json`仅为脱敏配置说明，所有尖括号值必须由受控运行环境提供；当前公开代码不加载此文件。它不含实际端点、账号、凭据或当前云端调度配置，不要把模板里的schedulerEnabled=false解释为异地任务当前关闭。

私有完整实现：既有P4-WP01/forest-agent（主入口run.py、tasks.py、action.js、snapshot.js、refresh.js及固定指纹），依赖同级interface-audit桥及secureview-bridge APK。内部应用方法原文、登录适配、配置指纹、客户/账号相关材料、状态日志和构建包不发布。操作说明保存在原受控Agent操作说明.md；本轮没有启动该入口。旧本地副本有待修问题，见[核查报告](../../planning/local-evidence-audit-2026-10-29.md)。MUSE适配副本不在本公开目录，不能用本目录覆盖它。

复用决策：选择发布通用策略及日志；另一方案是将整个设备执行器逐字段脱敏，覆盖更广但容易泄露内部源码、端点或误导为可部署完整包。采用前者。没有新增框架、供应商或网络依赖，因此本次恢复工作有意省略新技术选型检索。原2026-10-26选型比较保留在私有实施决策.md，不以当时上游版本说明当前最新版本。

回退：撤销本次公开文件提交即可，不影响私有代码、手机或MUSE状态；真实业务记录不能通过Git回退撤销。
