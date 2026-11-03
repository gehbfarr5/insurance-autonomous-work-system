# WP11-M MUSE isolated current-candidate replay

**Task state:** `COMPLETE`. **Parser acceptance:** `FAIL`. MUSE replayed the same authorized WP10 structured result at exact commit `6d5e7d4b8bbf29e8e5b4b1bc9bf43fa2d344cb6b`, package 0.12.0, in an isolated environment. The offline suite passed 144/144, but parsing remained `REVIEW_REQUIRED` and mapping was rejected; the reviewed reference was unavailable. The sanitized result is [`wp11m-muse-current-candidate-result-20261103.json`](wp11m-muse-current-candidate-result-20261103.json), with details in [`TEST_REPORT.md`](../integrations/muse-customer-card-ocr/TEST_REPORT.md#wp11m-current-candidate-replay-2026-11-03). This records failed acceptance; it does not authorize a parser change.

## Authorization and exact scope

- Use only the previously authorized WP10 structured OCR result and, if still present, its already-reviewed reference in MUSE's protected workspace. This authorization does not cover any new card, image, inventory, or the separate 30-card set.
- Do not call Seoul OCR, Baidu, or any OCR provider. Do not read a card image or reconstruct a missing payload/reference from earlier reports.
- Do not log in to iCloud or search, create, read, update, or delete contacts. Do not execute production code, change configuration, deploy, or export OCR blocks, coordinates, values, screenshots, references, logs containing data, or identifiers.
- The package candidate is version 0.12.0 on branch `codex/wp11-family-card-table-parser-20261103`. At task execution, resolve the full branch HEAD, verify it against the intended commit, and use a clean detached worktree and isolated virtual environment. Never modify the production checkout.

## Procedure

1. Verify the exact commit, package version, clean detached worktree, isolated imports, and Python/Pillow versions.
2. Run `PYTHONPATH=src python3 -m unittest discover -s tests -q` in `integrations/muse-customer-card-ocr`; report observed counts.
3. Confirm the exact previously authorized WP10 structured result is available in the protected workspace. If it is unavailable, stop and report parser replay `BLOCKED`; do not search other samples or reconstruct content. Check the existing reviewed reference separately. If the reference is unavailable, continue the parser replay but mark all reference comparisons `NOT_CHECKED` and accuracy comparison `BLOCKED`; do not reacquire the reference.
4. If the structured result is available, run the exact current candidate parser on it. Record only `READY`/`REVIEW_REQUIRED`, draft-mapping status, reason codes, field-presence booleans, and (only if the original reviewed reference is available) per-field `MATCH`/`MISMATCH`. Never return field values or OCR text. Do not claim byte-for-byte source-envelope validation if the stored structured result lacks optional envelope fields.
5. Read production deployment/version/source-binding metadata only if available through a read-only authorized path. Report unknown values as `UNKNOWN`; do not execute production code. In particular, distinguish a package source checkout from evidence that it is deployed in the active runtime.
6. Return only the JSON structure in [`wp11m-muse-current-candidate-result-template-20261103.json`](wp11m-muse-current-candidate-result-template-20261103.json). Preserve all operation counts, including artifact reads, and keep unlisted data out of the result.

## Acceptance interpretation

- Offline tests must pass, but that alone is not OCR acceptance.
- Any `REVIEW_REQUIRED`, missing required field, mismatched required field, or rejected draft mapping is a parser replay `FAIL` for the v1.0 release gate. Do not loosen parser rules to force `READY`.
- If the structured result is unavailable, report parser replay `BLOCKED`, with the specific missing prerequisite. If only the reference is unavailable, still report parser decision/presence/reasons and separately mark reference accuracy `BLOCKED`/`NOT_CHECKED`.
- Even a successful single-card replay does not meet the 30-card, duplicate-safety, user-confirmation, production-provenance, end-to-end, or rollback gates. Overall status remains `VALIDATION_PENDING` until all objective criteria are met.

## Decision and rollback

Two paths were considered: rely on historical reports (no new protected-data read, but no evidence for the current HEAD), or replay the exact current candidate against the same previously authorized WP10 structured result (a bounded protected read, no OCR/provider/contact side effects, and current parser evidence). The second path is selected because it directly tests the current code against the existing authorized regression artifact.

No code change is authorized by this diagnostic task itself. If the replay supplies a reproducible parser defect, prepare a separate narrowly scoped code/test change; preserve fail-closed behavior, verify locally, and rerun MUSE against the new exact commit. Roll back any candidate-only fix with a Git revert before deployment if it regresses the synthetic suite or protected replay. Production remains untouched.
