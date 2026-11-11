# R1-04 续跑回执（R1 PASS）

- **回执类型**: R1_04_RERUN_RECEIPT（脱敏）
- **判定**: **R1 PASS** —— 真实非空读取 ✓ / 字段匹配 ✓ / 合成事项零残留 ✓ / 服务恢复 ✓，全部有证据
- **授权**: 总控一次性批准续跑（沿用申请 v3 @ `a3f6f99` 的序列、脚本哈希与恢复方案）；范围外：重启、重登、新建列表、部署、Seoul 变更、R2
- **执行时间**: 2026-11-11 19:20–19:45 CST（S0 起）
- **脚本版本**: 全部为申请 v3 冻结集 @ `a3f6f99`（10 脚本服务器端哈希逐一比对一致；诊断工具未参与本次执行）

## 1. 逐步记录

| 步 | 时间(CST) | 动作 | 结果 | 恢复/验证 |
|---|---|---|---|---|
| S0 | 19:21 | 重部署 10 冻结脚本+哈希核对；产物核对；令牌提取（0600，摘要 `f17daa3bf3ff`） | 全部一致 | plist/config 双源 gate=false；二进制冻结匹配+签名 VALID；health OK |
| S2 | 19:23 | W0 发现窗（`discover-…T112240Z-r1-04-r1-w0`） | **DISCOVERED**（唯一候选、来源匹配） | restore VERIFIED；看门狗 DISARMED_BY_MAIN |
| S3 | 19:23 | 成对改绑：`9D9A****03F3` → `591B****6450`（源不变 `9BBB****CCB0`） | 验证 PASS（pre=GATE_AS_EXPECTED/403，post=GATE_RESTORED_CLOSED） | 服务重载 pid 12224→12426；plist 已备份（0600）；零旧列表条目读取 |
| S4 | 19:26 | W1 绑定可用性窗（新 ID） | **RESOLVED_IDENTITY_MATCH_EMPTY**（200/[]，绑定可用） | restore VERIFIED |
| S5 | 19:3x | 用户在现有测试列表创建恰 1 条合成事项（§1.3 规格） | 用户确认完成 | — |
| S6 | 19:34 | W2 非空验收窗（presence / --skip-metadata / passes 2） | capture COMPLETED（rcs 0 0） | **12/12 保真断言 PASS**；restore VERIFIED（pid 12779→13752） |
| S7 | 19:3x | 用户精准删除该事项（列表保留） | 用户确认完成 | — |
| S8 | 19:37 | W3 清理核验窗（absence / passes 1） | **CLEANUP_ASSERTED**（删除后列表为空，零残留） | restore VERIFIED（pid 13752→14249） |
| S9 | 19:4x | 收尾复核：`probe --phase post` → **GATE_RESTORED_CLOSED**；health OK；plist 与改绑前备份逐键比对——**仅改绑两键不同**（其余键与顶层结构逐字节一致，当前 gate=false）；看门狗 4/4 DISARMED_BY_MAIN 且无残留进程 | 全部 PASS | — |
| S9 清理 | 19:4x | 删除临时令牌与 10 个脚本 | 受控目录仅存 `work/` 证据树 | — |

**字段断言明细（W2，12/12 PASS）**：`synthetic_item_visible`、`unique_synthetic_item`、`title_exact_match`、`notes_exact_match`、`priority_5`（observed=5）、`is_completed_false`、`is_all_day_false`、`item_id_non_empty`、`list_attribution_match`、`due_date_present`、`due_date_contract_known`、`due_instant_exact`（observed=expected=2026-11-18T02:30:00Z，精确到秒）。

## 2. 请求账（按实际调用路径，与申请 §7 正常预算对照）

| 步 | 账户级枚举 | 条目请求（仅新列表） | health | 申请 §7 正常预算 |
|---|---:|---:|---:|---|
| S0 产物核对 | 0 | 0 | 1 | —（额外，只读） |
| W0 发现 | 3 | 0 | 1 | 3 / 0 / 3 |
| S3 改绑 | 1 | 1 | 1 | 1 / 1 / 1 |
| W1 可用性 | 0 | 3 | 1 | 0 / 3 / 3 |
| W2 验收 | 3 | 2 | 1 | 3 / 2 / 5 |
| W3 清理 | 3 | 1 | 1 | 3 / 1 / 4 |
| S9 收尾 | 0 | 1 | 1 | 0 / 1 / 1 |
| **合计** | **10** | **8** | **7** | 10 / 8 / 17 |

- 枚举 10、条目 8 **均落在正常预算内**；health 实际 7（无恢复路径触发，预算 17 含恢复余量）
- **恢复/重试：0 次**（无 close 重试、无回退、无超时恢复、无 UNKNOWN）
- 旧列表条目读取：**0**（构造性排除兑现）
- 合成事项：创建 1 条、删除 1 条、零残留；测试列表 `MUSE-R1-04-SYNTEST` **保留**（现为绑定目标）

## 3. 状态遗留

- 闸门关（gate=false）、服务健康、绑定指向新列表 `591B****6450`、看门狗全部退出
- 受控目录 `~/.muse-r1/r1-04-exec/work/` 保留全部证据（各窗 summary/receipt、改绑回执与 plist 备份、字段断言明细、终态探针/健康回执），目录 0700
- 临时令牌与脚本已按指令清理

## 4. 提交

- 申请与工具基线: `a3f6f99`
- 本回执提交: 见下方提交号
