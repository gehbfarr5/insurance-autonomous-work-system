# 只读 Vue 根组件元数据探针

`vue-root-metadata.js` 是待审查的 JavaScript 表达式，供既有受控 CDP 执行器读取。它不连接设备、不登录、不导航、不发送请求、不派发事件、不修改页面或持久状态。它不是日常任务执行器，也不作回答/奖励成功判定。

复用 Vue 官方 renderer 的容器 `_vnode` 与组件 `subTree/component/children` 结构，适配生产环境 `_instance` 可能为空的情况；同时明确列出每条实际入口。依据：[renderer.ts](https://github.com/vuejs/core/blob/main/packages/runtime-core/src/renderer.ts)、[apiCreateApp.ts](https://github.com/vuejs/core/blob/main/packages/runtime-core/src/apiCreateApp.ts)。这些属于内部结构，目标页面实际版本及暴露情况仍须实测，不保证所有 Vue 构建可用。没有复制 Vue 实现代码或增加依赖。

仅输出组件名、字段名/类型、数组长度和白名单布尔，不输出字符串值、记录 ID、客户值、回答正文或函数正文；非白名单 accessor 不调用。遍历有数量和深度边界，读取异常报告 `READ_ERROR`，超限报告 `TRUNCATED`，没有根入口报告 `ROOT_NOT_EXPOSED`，均不伪装成功。

离线验证：`node tools/test-vue-root-metadata.cjs`。覆盖生产式空 `_instance`、Fragment 子组件、循环/重复根、无根与读取异常，以及敏感字符串和非相关 getter 不泄漏。这里的合成测试不证明生产页面状态可读，`ROOTS_FOUND` 也不等于问答完成。
