# WP11-B MUSE isolation retest task

## Purpose and evidence boundary

Retest the 0.7.0 parser fix after MUSE's 2026-11-03 real-template run found that 0.6.0 treated every lower-ranked Baidu character candidate as an ambiguity. The first candidate matched the recognized character in all 250 characters that had candidate lists; the old rule blocked the table extraction. The original aggregate evidence and synthetic reproduction are in `wp11b-ambiguous-char-handoff-20261103.md`.

This task only installs and evaluates the parser in a separate worktree and virtual environment. It must not alter MUSE's pinned production package, call Baidu, read/write iCloud contacts, or print real OCR/customer values. The expected production package version remains 0.5.0 until a separate deployment decision. Codex cannot call MUSE directly in this session, so return the JSON object from `wp11b-muse-result-template-20261103.json` with aggregate results only.

## Copyable MUSE task

Run in MUSE's terminal. Replace the worktree suffix if this task is repeated. Stop and report a `BLOCKED` result if the repository checkout, Python 3.12, or existing Pillow 10.2.0 is unavailable; do not install from the network to work around it.

```bash
set -eu

RETEST_BRANCH="codex/wp11-family-card-table-parser-20261103"
RETEST_COMMIT="29771eb33b07bd43150dec0a236c2711b290c165"
REPO_DIR="$HOME/workspace/wp11-ocr-checkout"
RETEST_DIR="$HOME/workspace/wp11b-retest-20261103-0.7.0"
RETEST_VENV="$HOME/workspace/.venvs/muse-family-card-wp11b-0.7.0"

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

Expected local package version is `0.7.0`. The full offline suite includes the synthetic Baidu-candidate reproduction: it must return `READY`, expose name/mobile/explicit birthday/identity number, and allow pure iCloud draft mapping. A first-candidate mismatch must remain `REVIEW_REQUIRED`; lower-ranked candidates that differ while the first equals the OCR character must not block extraction. Preserve all other review and privacy gates.

### Optional protected WP10 replay

If the already-authorized WP10 structured OCR result is still available in MUSE's protected workspace and can be replayed without another provider call, use it locally after the offline suite. Do not search unrelated storage, request the payload from the user, or copy it to this repository. If unavailable, set `wp10_existing_payload.replay` to `SKIPPED` and `reason` to `WP10_STRUCTURED_PAYLOAD_UNAVAILABLE`; this does not invalidate the synthetic regression result but leaves real-template confirmation pending. For a replay, report only whether each field matches its already-reviewed WP10 reference, never the field values, OCR text, or payload.

No Baidu request is needed. Do not call any iCloud search, create, update, or delete tool. Pure draft mapping is local only.

## Result return format

Also read the current production package pin and relevant source/adapter revision using the existing documented production environment, without running or modifying production code. Include only the version and commit or a source hash in the result; report `UNKNOWN` if the exact deployed source cannot be read. Return a completed copy of `wp11b-muse-result-template-20261103.json` with the exact tested commit, Python/Pillow/package versions, test totals and failure IDs, replay availability, per-field match results if a protected replay was possible, and before/after production package versions. Do not attach screenshots, OCR blocks, customer values, images, tokens, URLs containing credentials, or logs with request/response data.

After the result is returned, the isolated worktree and venv may be removed. The production runtime should still report 0.5.0; no promotion is part of this retest task.

## Pass criteria

- 0.7.0 imports from the isolated venv and the complete offline suite passes.
- Synthetic Baidu candidate reproduction is `READY` with all required fields present and pure draft mapping allowed.
- A first-candidate mismatch still requires review.
- If the protected WP10 payload is available, its extracted primary-customer fields match the already-reviewed reference; otherwise the result explicitly records the missing evidence.
- Baidu calls, iCloud reads/writes, production changes, and customer data in the returned report are all zero/false.
