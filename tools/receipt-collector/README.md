# 实际组件快照采集与对账候选

本机实现，未部署、未接入日常运行器、尚未实机验证。与旧纯布尔校验不同，`ai-snapshot.js`从已有根容器遍历组件、读取实际props/setupState/provides，将记录、会话、最后回答、结束和解析状态关联后输出最小快照。此处“实际”指实现的输入接口是真实组件树，不表示已在生产取得正例。错误/未知字段明确REVIEW。

复用Vue既有组件/provides结构和当前CDP的Runtime.evaluate（awaitPromise/returnByValue），不新增依赖或服务。原组件提供记录、回答列表和已核实的结束字段；源码及来源资源路径私存。相比增加网络观测，此路径范围小、可离线验证；成功空查询暂不接入，因为现有快照没有同周期响应与赋值证据。不会直接请求业务接口或替换网络函数。

- `collectAiSnapshot(root, options, digest)`：读取已有根；options需要每个持久意图独立的随机salt（至少32字符）、已选通用问题、明确versionBinding。不得将salt或含问题的表达式公开。所有记录/会话/问题用同一salt作SHA256关联，只输出指纹和必要布尔，不输出正文/客户/ID值。客户状态未知、根/记录/提供者不唯一、截断、读取错误均显式REVIEW。已知Vue computed/ref的值是需要读取的状态；不保证不执行这些已知计算getter，不枚举任意字段值或调用set函数。
- `buildExpression(context)`：构造现有CDP可执行的异步表达式；严格origin/path及必需已加载资源文件名，绑定采集代码和版本profile。只构造不连接，不导航/发问/选客户/写存储。资源文件名匹配**不是资源内容SHA验证**；上线前仍须绑定真实APP/模块/运行器版本及来源profile，并核对漂移。WebCrypto缺失会失败，不用弱哈希替代。
- `reconcile(before, after)`：允许确认取得的空基线，不制造前一记录占位ID；拒绝已有记录、问题/会话错配、状态不明或未结束。ACCEPT只表示结构化回答完成，不代表奖励到账/每日五项或长期运行通过。

拟接入位置：现有assistant.py持久DISPATCHING前采基线并私存salt/profile/指纹；原DOM动作后采快照并对账，替换当前文字增长轮询。UNKNOWN的意图保持不可重放；恢复缺基线时REVIEW。接入还须补备份/漂移/原状态保护及恢复集成测试，本目录没有修改这些生产状态逻辑。现有60秒CDP总截止继续保留。

```sh
node tools/receipt-collector/test-collector.cjs
node tools/receipt-collector/test-expression.cjs
```

覆盖首次空基线、组件树采集、隐私、继承、重放、缺字段、错误/停止/暂停、上下文变化、错误目标和缺资源等。合成组件测试不是实机/业务正例。当前设备APP未运行，本轮未启动补证；09:00自然结果未到时不判漏跑。

依据：[Vue组件实例源码](https://github.com/vuejs/core/blob/main/packages/runtime-core/src/component.ts)、[Vue provide/inject](https://vuejs.org/guide/components/provide-inject)、[CDP Runtime.evaluate](https://chromedevtools.github.io/devtools-protocol/tot/Runtime/#method-evaluate)。复用官方现有机制，适配项目字段；避免引入第三方Agent/网络拦截框架。官方main仅解释机制，不证明生产Vue具体版本相同。
