# 实际组件快照采集与对账候选

本机实现已通过隔离集成，MUSE有限安装证据已核对；尚未取得采集器真实业务正例。与旧纯布尔校验不同，`ai-snapshot.js`从已有根容器遍历组件、读取实际props/setupState/provides，将记录、会话、最后回答、结束和解析状态关联后输出最小快照。此处“实际”指实现的输入接口是真实组件树，不表示已在生产取得正例。错误/未知字段明确REVIEW。

复用Vue既有组件/provides结构和当前CDP的Runtime.evaluate（awaitPromise/returnByValue），不新增依赖或服务。原组件提供记录、回答列表和已核实的结束字段；源码及来源资源路径私存。相比增加网络观测，此路径范围小、可离线验证；成功空查询由下方新增被动观察器接入；单独页面快照仍不具有同周期响应与赋值证据。不会直接请求业务接口或替换网络函数。

- `collectAiSnapshot(root, options, digest)`：读取已有根；options需要每个持久意图独立的随机salt（至少32字符）、已选通用问题、明确versionBinding。不得将salt或含问题的表达式公开。所有记录/会话/问题用同一salt作SHA256关联，只输出指纹和必要布尔，不输出正文/客户/ID值。客户状态未知、根/记录/提供者不唯一、截断、读取错误均显式REVIEW。已知Vue computed/ref的值是需要读取的状态；不保证不执行这些已知计算getter，不枚举任意字段值或调用set函数。
- `buildExpression(context)`：构造现有CDP可执行的异步表达式；严格origin/path及必需已加载资源文件名，绑定采集代码和版本profile。只构造不连接，不导航/发问/选客户/写存储。资源文件名匹配**不是资源内容SHA验证**；上线前仍须绑定真实APP/模块/运行器版本及来源profile，并核对漂移。WebCrypto缺失会失败，不用弱哈希替代。
- `reconcile(before, after)`：允许确认取得的空基线，不制造前一记录占位ID；拒绝已有记录、问题/会话错配、状态不明或未结束。ACCEPT只表示结构化回答完成，不代表奖励到账/每日五项或长期运行通过。

受控适配接入位置：现有assistant.py持久DISPATCHING前采基线并私存salt/profile/指纹；原DOM动作后采快照并对账，替换当前文字增长轮询。UNKNOWN的意图保持不可重放；恢复缺基线时REVIEW。备份/漂移/原状态保护及隔离恢复集成测试已完成，原有生产状态文件保持不变；本目录不包含内部适配原文。现有60秒CDP总截止继续保留。

```sh
node tools/receipt-collector/test-collector.cjs
node tools/receipt-collector/test-expression.cjs
```

覆盖首次空基线、组件树采集、隐私、继承、重放、缺字段、错误/停止/暂停、上下文变化、错误目标和缺资源等。合成组件测试不是实机/业务正例。早期离线阶段设备APP未运行；后续仅首页基线检查在准备阶段超时并清理，发现本地登录未对账保护。当前没有实机采集或奖励正例；09:00自然结果未到时不判漏跑。

依据：[Vue组件实例源码](https://github.com/vuejs/core/blob/main/packages/runtime-core/src/component.ts)、[Vue provide/inject](https://vuejs.org/guide/components/provide-inject)、[CDP Runtime.evaluate](https://chromedevtools.github.io/devtools-protocol/tot/Runtime/#method-evaluate)。复用官方现有机制，适配项目字段；避免引入第三方Agent/网络拦截框架。官方main仅解释机制，不证明生产Vue具体版本相同。

## 10月30日集成与恢复补核

`bridge.py`供现有运行器调用：本机Node构造表达式，使用现有evaluate读取，持久化基线/随机盐后才允许原运行器进入DISPATCHING。子进程失败不输出私密上下文；采集截止向CDP传递，旧不支持total_timeout的适配器必须同时应用受控补丁，不能静默忽略。私有运行器补丁只在受控交付包，不公开内部页面/配置原文。

`empty_list_observer.py`在独立已连接CDP会话上被动观察目标页新发生的查询。仅保留去敏事件字段，读取指定响应正文后在内存检查业务code与空content，不保存响应正文、头、查询参数或请求数据。要求唯一requestId、非空loaderId、HTTP/业务成功、完整加载及原数组对象被新空数组替换且loading结束。此前已完成的查询不能补证；未观测到新查询会超时BLOCKED。此方案没有改变页面请求，不使用Fetch拦截/重放。

关联依赖已审查的源分支和当前唯一查询；不是直接观测Vuex mutation的因果探针。版本profile漂移、其他并发查询或未知赋值均需保守失败，不能据此保证任何任意页面空值成功。SourcePin为既有来源指纹，不冒充现场脚本内容SHA。

本机已对实际assistant.main完成9项隔离集成检查，设备/传输替身阻断业务；3组真实子进程中断/重启分别覆盖DISPATCHING时SIGTERM/SIGKILL、SENT时SIGKILL。重启保留基线与UNKNOWN/SENT且不prepare/重放。SIGTERM有cleanup，SIGKILL没有执行finally，不能称完整手机恢复通过。原29项回归通过。观察器4个测试方法覆盖成功/隐私、13种失败、缺上下文和TERM传播；原始测试输出私存。

已向同一MUSE旁聊交付明确staging复测/通过后有限安装任务，另一次合并严格字段修正；原环境测试输出及有限安装16项哈希/状态索引已核对，15项与本机字节指纹一致，1项含私有连接参数仅远端证明。未导出实际安装文件字节，不能混同本机独立读回。未要求启动手机、补跑业务或更改09:00调度。

依据：[CDP Network事件及getResponseBody](https://chromedevtools.github.io/devtools-protocol/tot/Network/)、[Runtime.callFunctionOn](https://chromedevtools.github.io/devtools-protocol/tot/Runtime/#method-callFunctionOn)。

## 10月30日记录挂载就绪修复

实机诊断确认首页出现时有100个组件但0个records数组；同一页面约2秒后取得空记录SNAPSHOT，再次读取一致。`RECORDS_NOT_UNIQUE`新增纯数量/类型诊断，不输出组件名称、ID或正文。`baseline`仅对明确整数0候选等待真实挂载，截止20秒；多个候选、未知类型/缺诊断、传输错误立即失败，绝不制造空数组。取得后仍要求未选客户且idle。

28项组件检查、5项挂载/截止/歧义/状态/传输测试、4项传输元数据测试、原9项隔离集成通过；私有实际CDP客户程序两项测试覆盖握手和发送/接收超时清理，另验证枚举/列表错误阶段。修复后本机原准备→AI首页→baseline实测SNAPSHOT，cleanup PASS，未发问/选客/业务。MUSE原环境有限安装现已核对：12项证据清单通过，9项安装哈希与after索引一致，8项与本机字节相同；私有CDP文件只保留远端哈希。56项state及cron不变，今日SENT不重放。此为安装验收，不是回答/奖励正例。

`transport_diagnostics.py`仅保存受限阶段、TIMEOUT/FAILED及调用预算，移除命令/输出/端点；在私有CDP原调用点接入，不增加重试或放宽超时。预算不是本次实际耗时；历史截断错误不能由新代码追溯补造。
