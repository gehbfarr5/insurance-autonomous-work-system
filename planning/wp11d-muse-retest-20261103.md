# WP11-D MUSE isolated re-test

## Purpose and evidence boundary

Re-test package 0.8.1 after the protected 0.8.0 replay remained `REVIEW_REQUIRED`, with non-matching name, mobile, identity number, explicit birthday, and gender. This iteration widens the fail-closed margin for near-tied label columns. It does not broaden phone row search or infer a gender/checkmark signal that the structured OCR does not provide.

Use a separate MUSE worktree and virtual environment. Reuse only the existing WP10 structured result and reviewed reference in the already-authorized protected workspace. Do not repeat OCR, call Baidu, read or write iCloud contacts, export protected content, alter production, or include OCR/customer values, logs containing them, coordinates, screenshots, or credentials in the returned report. If the protected result is unavailable, report `BLOCKED`; do not reconstruct it from the prior report.

## Copyable MUSE task

Use this exact code commit. Do not substitute a later revision without updating this task and result.

```bash
set -eu

RETEST_BRANCH="codex/wp11-family-card-table-parser-20261103"
RETEST_COMMIT="1aeb7cb7b04c4e4853d750b181800fbbacf71fab"
REPO_DIR="$HOME/workspace/wp11-ocr-checkout"
RETEST_DIR="$HOME/workspace/wp11d-retest-20261103-0.8.1"
RETEST_VENV="$HOME/workspace/.venvs/muse-family-card-wp11d-0.8.1"

git -C "$REPO_DIR" fetch origin "$RETEST_BRANCH"
git -C "$REPO_DIR" worktree add --detach "$RETEST_DIR" "$RETEST_COMMIT"
python3.12 -m venv --system-site-packages "$RETEST_VENV"
source "$RETEST_VENV/bin/activate"

cd "$RETEST_DIR/integrations/muse-customer-card-ocr"
python --version
python -c 'import PIL; print(PIL.__version__)'
python -m pip install --no-deps -e .
PYTHONPATH=src python -m unittest discover -s tests
python -c 'import importlib.metadata as m; print(m.version("muse-customer-card-ocr"))'
```

Expected local package version is 0.8.1 and the offline suite contains 95 tests. Confirm the near-tied-column regression requires review; cross-column adjacency is rejected; tied/overlapping columns remain under review; checksum-valid adjacent identity fragments join while invalid/ambiguous fragments require review; short spatial address evidence requires review; and draft mapping remains local and fail-closed.

Replay the existing protected WP10 result with the pinned package and compare with the already-reviewed reference inside MUSE only. Return only `READY`/`REVIEW_REQUIRED`, field-match booleans, reason codes, and counts/statuses. Never print or return values, OCR text, blocks, coordinates, images, screenshots, or payload excerpts. Any `REVIEW_REQUIRED`, mismatched required field, unknown required field, or blocked draft mapping fails the v1.0 release gate. Do not relax the geometry rules without new evidence.

Read the current production package pin and relevant source/adapter revision using read-only inspection. Report the package version before/after and source revision/hash; use `UNKNOWN` if unavailable. Expected production pin remains 0.5.0. Keep the worktree and venv for review. Do not add protected customer data to GitHub or ordinary logs.

Return a completed copy of `wp11d-muse-result-template-20261103.json`. The separate 30-card acceptance gate remains outstanding and is not replaced by this one-record replay.

## Pass criteria

- The exact tested commit imports as 0.8.1 in an isolated venv and all 95 offline tests pass.
- Synthetic near-tied geometry and fail-closed regressions pass.
- The protected WP10 replay matches the reviewed reference for required fields and draft mapping is allowed. Any review decision, mismatched/unknown required field, or blocked mapping fails this release gate.
- Baidu calls, iCloud reads/writes, and production configuration changes are zero/false; production remains at 0.5.0.
- The returned report contains no customer values, OCR text, images, coordinates, or credentials.
