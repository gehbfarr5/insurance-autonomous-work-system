# WP11-M MUSE isolated current-candidate replay

**State:** `IN_PROGRESS`. WP11-B was executed and failed on package 0.7.0; its result and later 0.8–0.12 replay evidence are summarized in [`TEST_REPORT.md`](../integrations/muse-customer-card-ocr/TEST_REPORT.md). The current 0.12.0 candidate still has a recorded WP10 replay failure at commit `e9814eaee6b16d677ab06f0857fa2a5bd1f6a586`. This follow-up pins the current branch candidate, confirms whether the original authorized WP10 artifacts remain accessible, and records a fresh isolated replay without repeating OCR or touching contacts.

## Authorization and exact scope

- Use only the previously authorized WP10 structured OCR result and, if still present, its already-reviewed reference in MUSE's protected workspace. This authorization does not cover any new card, image, inventory, or the separate 30-card set.
- Do not call Seoul OCR, Baidu, or any OCR provider. Do not read a card image or reconstruct a missing payload/reference from earlier reports.
- Do not log in to iCloud or search, create, read, update, or delete contacts. Do not execute production code, change configuration, deploy, or export OCR blocks, coordinates, values, screenshots, references, logs containing data, or identifiers.
- The package candidate is version 0.12.0 on branch `codex/wp11-family-card-table-parser-20261103`. At task execution, resolve the full branch HEAD, verify it against the intended commit, and use a clean detached worktree and isolated virtual environment. Never modify the production checkout.

## Procedure

1. Verify the exact commit, package version, clean detached worktree, isolated imports, and Python/Pillow versions.
2. Run `PYTHONPATH=src python3 -m unittest discover -s tests -q` in `integrations/muse-customer-card-ocr`; report observed counts.
3. Confirm the exact previously authorized WP10 structured result and reviewed reference are available in the protected workspace. If either required artifact is unavailable, stop the replay and report `BLOCKED`; do not search other samples, reconstruct content, or reacquire the reference.
4. If available, run the exact current candidate parser on that structured result. Compare with the existing reviewed reference only inside the protected workspace. Record only `READY`/`REVIEW_REQUIRED`, draft-mapping status, reason codes, field-presence booleans, and per-field `MATCH`/`MISMATCH`/`NOT_CHECKED`. Never return field values or OCR text. Do not claim byte-for-byte source-envelope validation if the stored structured result lacks optional envelope fields.
5. Read production deployment/version/source-binding metadata only if available through a read-only authorized path. Report unknown values as `UNKNOWN`; do not execute production code. In particular, distinguish a package source checkout from evidence that it is deployed in the active runtime.
6. Return only the JSON structure in [`wp11m-muse-current-candidate-result-template-20261103.json`](wp11m-muse-current-candidate-result-template-20261103.json). Preserve all operation counts, including artifact reads, and keep unlisted data out of the result.

## Acceptance interpretation

- Offline tests must pass, but that alone is not OCR acceptance.
- Any `REVIEW_REQUIRED`, missing required field, mismatched required field, or rejected draft mapping is a replay `FAIL` for the v1.0 release gate. Do not loosen parser rules to force `READY`.
- If the existing result or reviewed reference is unavailable, report `BLOCKED`, with the specific missing prerequisite and zero OCR/contact/production operations.
- Even a successful single-card replay does not meet the 30-card, duplicate-safety, user-confirmation, production-provenance, end-to-end, or rollback gates. Overall status remains `VALIDATION_PENDING` until all objective criteria are met.

## Decision and rollback

Two paths were considered: rely on historical reports (no new protected-data read, but no evidence for the current HEAD), or replay the exact current candidate against the same previously authorized WP10 structured result (a bounded protected read, no OCR/provider/contact side effects, and current parser evidence). The second path is selected because it directly tests the current code against the existing authorized regression artifact.

No code change is authorized by this diagnostic task itself. If the replay supplies a reproducible parser defect, prepare a separate narrowly scoped code/test change; preserve fail-closed behavior, verify locally, and rerun MUSE against the new exact commit. Roll back any candidate-only fix with a Git revert before deployment if it regresses the synthetic suite or protected replay. Production remains untouched.
