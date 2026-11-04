# WP11-R MUSE 0.13.3 candidate retest and draft pipeline verification

**Task identity:** `WP11R-MUSE-0.13.3-CANDIDATE-RETEST-AND-DRAFT-PIPELINE-20261104`  
**Target conversation:** Existing Family Card MUSE side chat, `执行WP11离线验证任务`

## Background and scope

Commit `f7ec775` introduces package `muse-customer-card-ocr` 0.13.3. It implements `build_review_draft` in `runtime_safety.py` and `--review-draft-out` in `wp10_ocr_dedup.py` to allow `REVIEW_REQUIRED` extractions to generate an unconfirmed review draft (`review_status: PENDING_USER_CONFIRMATION`) without leaking PII to stdout.

This task has MUSE execute the offline suite and smoke verification on the exact 0.13.3 candidate in its isolated environment.

## Exact candidate

- Repository: `https://github.com/gehbfarr5/insurance-autonomous-work-system`
- Branch: `codex/wp11-family-card-table-parser-20261103`
- Candidate commit: `f7ec7759c22ce43580fde1907e028ee2f6288f18`
- Package: `muse-customer-card-ocr` 0.13.3
- Expected file hashes:
  - `fields.py`: `420a1b21d0df9d6f1f75460559d2fd8ee87cfec2805ca326928dd268b213d147`
  - `runtime_safety.py`: `f0de7d031f0b96532badfbe65060dcb5d72b541c6f71e72850f3656d376e27e0`
  - `acceptance_metrics.py`: `45d7b265858acd67f15a32f25414f8b1d2f391808db4b48563418cbb3f0fc2ba`
  - `wp10_ocr_dedup.py`: `fd2f5ad1457ca84e3a8d6efe96566da90790bd8b94f2e37d8f7abaf1f789dd04`

## Procedure

1. Fetch authorized branch once. Verify exact commit, package version, file hashes, detached worktree, isolated virtual environment, and import path.
2. In the isolated virtual environment (Ubuntu 24.04.5 LTS / Python 3.12.3 / Pillow 12.3.0), run full offline unit test suite:
   ```bash
   PYTHONPATH=src python3 -m unittest discover -s tests -v
   ```
   Assert 150 tests pass, 0 failures, 0 errors.
3. Verify blank-template acceptance metrics CLI output is `BLOCKED`:
   ```bash
   PYTHONPATH=src python3 -m muse_customer_card_ocr.acceptance_metrics ../../planning/wp11-30-card-acceptance-input-template-20261103.json
   ```
4. Check whether reviewed reference for the same WP10 record is available. If unavailable, report `BLOCKED` and all fields `NOT_CHECKED`; do not search other locations or widen scope.
5. Populate and return `planning/wp11r-muse-candidate-retest-and-draft-pipeline-result-template-20261104.json`.

## Safety boundaries

- No new sample, image, inventory, or unverified 30-card-set reads.
- No live OCR calls (Baidu/Seoul), no iCloud/CardDAV/contact writes.
- Do not print customer values or PII to stdout or logs.
