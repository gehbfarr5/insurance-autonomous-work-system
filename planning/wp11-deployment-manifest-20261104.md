# 家庭卡 OCR 生产部署清单与不可变绑定记录（2026-11-04）

**版本标签：** `v1.0-candidate-0.13.3`  
**代码提交：** `25ff0f0` on branch `codex/wp11-family-card-table-parser-20261103`  
**审核状态：** `DEPLOYMENT_PROVENANCE_PINNED`

---

## 一、首尔端 OCR 服务目标绑定（Server Provenance）

- **目标主机：** 腾讯云 Lighthouse `seoul-forge-01`
- **实例 ID：** `lhins-84gffkd8`
- **地域/可用区：** `ap-seoul-2`
- **IP 地址：**
  - 公网 IP: `43.155.232.185`
  - Tailscale 内部 IP: `100.82.240.43`
- **操作系统：** Ubuntu Server 24.04 LTS 64bit
- **服务执行脚本：** `/home/ubuntu/baidu-ocr-service/baidu_ocr_service.py`
- **不可变哈希校验（SHA-256）：**
  `804565db206a905c92380ebc266bf00d80e85b2f144ca7d30de4eaaa4ca0638e`
  *(经 2026-11-04 实测核验，与仓库 WP11-O 记录完全一致)*
- **调用协议与命令：**
  ```bash
  python3 /home/ubuntu/baidu-ocr-service/baidu_ocr_service.py --stdin-image
  ```
- **运行特征：** 按需 SSH 标准输入/输出流 CLI，非系统常驻守护进程（解释了此前 systemd/Docker 盘点无 OCR 服务的架构事实）。
- **保留输出结构：** 严格输出包含 `words`、`location` (left, top, width, height)、`probability` 及 `chars` (char, location, candidates) 的完整结构化 JSON，支持几何与手写表格解析。

---

## 二、MUSE 运行端与调用适配器绑定（Client Provenance）

- **调用脚本：** `/home/hatch/workspace/server/ssh-seoul.sh`
- **模块适配器：** `integrations/muse-customer-card-ocr/src/muse_customer_card_ocr/runtime_seoul.py`
- **适配器安全门禁：**
  - 要求显式非空图像字节流输入；
  - 120 秒硬超时限制；
  - 严格校验返回 JSON，非 `ok: true` 或格式异常立即 fail-closed 抛出 `SeoulCliError`；
  - 绝不向普通日志打印图像原始数据或识别明文。
- **依赖版本固化：**
  - Python: `>=3.10`（测试通过环境：`Python 3.12.14` / `Python 3.14.7`）
  - Pillow: `Pillow>=10.0,<13`（测试固化版本：`12.3.0`）

---

## 三、安全通道与人工复核闭环规范（Operator Review & Confirmation）

- **自动提取分支：** 仅当提取判定为 `READY` 且无任何 `review_reasons` 时，允许通过 `map_to_icloud_fields` 生成待建草稿；
- **人工复核分支：**
  1. 遇到几何重叠、手写歧义或置信不足时，状态标记为 `REVIEW_REQUIRED`；
  2. 严禁生成自动可用草稿（`map_to_icloud_fields` 抛出 `ManualReviewRequiredError` 阻断）；
  3. 通过 `build_review_draft` 导出结构化未确认草稿（`review_status: PENDING_USER_CONFIRMATION`）；
  4. 支持通过 `--review-draft-out` 安全落地受保护文件（权限 `0600`，终端仅回显 `REVIEW_DRAFT_WRITTEN: True`，无 PII 输出）；
  5. 审核员在受控 UI/本地编辑补全必填信息，显式确认（`review_status: USER_CONFIRMED`）；
  6. 仅在显式确认后，`parse_confirmed_draft` 放行，交由 `wp10_create_readback.py` 进行查重、单次创建、回读比对与账本清理。

---

## 四、回滚与应急恢复规范（Rollback & Reconciliation）

1. **代码与配置回滚：**
   - 若候选版在生产出现未预期异常，直接 `git revert` 对应发布 Commit，重新部署已验证的上一稳定版；
2. **写入中断与幂等对账：**
   - 写入前启动 `CreateAttemptJournal`（记录 operation_id，锁定单次创建）；
   - 若遇到网络中断或超时，状态标记为 `OUTCOME_UNKNOWN` 或 `CREATED_NEEDS_READBACK`，禁止盲目重试；
   - 运行 `--resume-pending` 以精确 operation_id 执行只读回读恢复；若仍不一致，由审核员执行人工对账（`--resolve-pending`）。
