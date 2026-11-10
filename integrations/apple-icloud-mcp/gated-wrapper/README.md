# MUSE Gated Safe Write Wrapper (`gated-wrapper`)

## 1. 概述与核心安全不变量

本模块是 MUSE 前台日常写入入口的门控包装层（Gated Write Wrapper），由 `IsolatedAdapter`（第一道默认拒绝的防御边界）与 `SafeWriteManager`（CAS 乐观锁门控与审计账本）两层构成，用于受限测试与日常写入。

### 核心安全不变量
1. **严格保留调用方传入的 `expected_etag`**：
   - 严禁将其静默替换为即时读取的最新 ETag；
   - 当调用方显式传入 `expected_etag` 时，与当前状态比对；若不匹配立即在本地阻断，直接返回 `CONFLICT`（"该事件已被其他客户端修改"），**网络写请求发送次数为 0**；
   - 严禁自动重新提交或无条件覆盖。
2. **缺省附加乐观锁**：
   - 仅当调用方未传 `expected_etag` 且工具支持 ETag 时，将预读获取的当前 ETag 附发，实现乐观锁保护。
3. **写入结果 `UNKNOWN` 严禁自动重试**：
   - 网络超时、连接中断或模糊响应时，状态标记为 `UNKNOWN`，**严禁自动重试**；
   - `IsolatedAdapter` 立即触发停机状态（`halted = True`），阻断后续所有写入请求，直到获得人工可信授权重置。
4. **两阶段意向账本先行**：
   - 先持久化 `INTENT_RECORDED`，再落盘 `SEND_STARTED`，最后才允许调用网络传输层发送。
5. **容器白名单与权限边界**：
   - 仅放行已注册的受限测试容器（如测试日历）；
   - 生产目标容器、`mail_*` 及 `work_done` 严禁调用（提交即拒绝，0 发送）。

---

## 2. 核心组件与文件

- [`safe_write.py`](./safe_write.py): `SafeWriteManager` 实现，处理 ETag CAS 校验、用户授权令牌验证、两阶段意向账本持久化与去重判定。
- [`isolated_adapter.py`](./isolated_adapter.py): `IsolatedAdapter` 实现，默认拒绝外围网关，执行白名单核验、容器一致性解析（`resolve_calendar_container`）以及 `UNKNOWN` 熔断停机控制。
- [`test_safe_write_etag.py`](./test_safe_write_etag.py): 隔离单元测试套件，全面验证旧 ETag 拒绝、0 发送冲突阻断、正常更新乐观锁放行、白名单目标拦截与 UNKNOWN 零重试停机。

---

## 3. 隔离单元测试验证

运行命令：
```bash
python3 test_safe_write_etag.py -v
```

测试覆盖清单：
1. `test_stale_etag_is_not_replaced_and_raises_conflict`: 验证旧 ETag 不会被静默替换，精确返回 `CONFLICT` 且发送次数为 0；
2. `test_matching_expected_etag_succeeds`: 验证匹配的 `expected_etag` 正常放行并附发，状态置为 `APPLIED`；
3. `test_unregistered_calendar_rejected_with_zero_sends`: 验证未登记日历被拒，0 发送；
4. `test_untrusted_authorization_rejected_with_zero_sends`: 验证无效/过期授权令牌被拒，0 发送；
5. `test_unknown_write_halts_adapter_and_forbids_auto_retry`: 验证超时引发 `UNKNOWN` 时绝不重试，适配器置入 `halted` 状态阻断后续请求。
