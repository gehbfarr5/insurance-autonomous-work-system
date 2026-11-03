# WP11-C MUSE isolated re-test

## Purpose and evidence boundary

Re-test package 0.8.0 after the protected WP10 replay of 0.7.0 found cross-column pairing errors and split identity-number blocks. The local change uses unique label-column attribution, rejects tied/overlapping geometry, and joins adjacent ID fragments only when the complete result passes the existing checksum.

Use a separate MUSE worktree and virtual environment. Do not change the production package, call Baidu, read/write iCloud contacts, export the protected OCR result, or include OCR/customer values in logs or the returned report. Reuse the saved WP10 structured result only if it remains in the authorized protected workspace; if it is unavailable, do not repeat OCR.

## Copyable MUSE task

The tested commit is pinned after the 0.8.0 code commit below. Do not substitute a later code revision without updating this task and result.

```bash
set -eu

RETEST_BRANCH="codex/wp11-family-card-table-parser-20261103"
RETEST_COMMIT="ccc9d17abfe27919c93ef3feba97a6aa3082d016"
REPO_DIR="$HOME/workspace/wp11-ocr-checkout"
RETEST_DIR="$HOME/workspace/wp11c-retest-20261103-0.8.0"
RETEST_VENV="$HOME/workspace/.venvs/muse-family-card-wp11c-0.8.0"

git -C "$REPO_DIR" fetch origin "$RETEST_BRANCH"
git -C "$REPO_DIR" worktree add --detach "$RETEST_DIR" "$RETEST_COMMIT"
python3.12 -m venv --system-site-packages "$RETEST_VENV"
source "$RETEST_VENV/bin/activate"

cd "$RETEST_DIR/integrations/muse-customer-card-ocr"
python --version
python -c 'import PIL; print(PIL.__version__)'
python -m pip install --no-deps -e .
PYTHONPATH=src python -m unittest discover -s tests -v
python -c 'import importlib.metadata as m; print(m.version("muse-customer-card-ocr"))'
```

Expected local package version is 0.8.0 and the offline suite contains 94 tests. Confirm the synthetic cross-column case does not select an adjacent block from another field, overlapping/tied columns remain `REVIEW_REQUIRED`, valid adjacent ID fragments join only after checksum validation, short/ambiguous address fragments require review, and pure draft mapping remains local and fail-closed.

If the saved WP10 structured result is available, run the parser locally against it without making a provider call. Compare extracted fields to the already-reviewed reference inside MUSE only. Return the parser decision, field-match booleans, and review-reason codes; never return values, OCR text, blocks, coordinates, images, or screenshots. A replay that remains `REVIEW_REQUIRED` is a failed release gate even if the offline suite passes. Do not deploy production as part of this task.

Read the current production package pin and relevant source/adapter revision without running or modifying production code. Report the package version before/after and source revision/hash; report `UNKNOWN` if exact readback is unavailable. The expected production pin remains 0.5.0.

Return a completed copy of `wp11c-muse-result-template-20261103.json`. Keep the worktree and venv for review. Do not add customer data to GitHub or ordinary logs.

## Pass criteria

- Exact tested commit imports as 0.8.0 in an isolated venv and all 94 offline tests pass.
- Synthetic nearest-column and ID-fragment regressions pass; fail-closed behavior remains intact.
- Protected WP10 replay matches the reviewed reference for required fields and draft mapping is allowed. Any `REVIEW_REQUIRED`, mismatched field, or unknown required field is a failure of the v1.0 release gate, not a reason to loosen geometry without evidence.
- Baidu calls, iCloud reads/writes, and production configuration changes are all zero/false.
- The report contains no customer values, OCR text, images, coordinates, or credentials.
