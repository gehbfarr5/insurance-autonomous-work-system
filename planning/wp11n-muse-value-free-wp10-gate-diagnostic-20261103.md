# WP11-N MUSE value-free WP10 parser-gate diagnostic

**Task state:** `COMPLETE`. **Parser acceptance:** `FAIL`; **diagnostic status:** complete. MUSE counted value-free parser gates at exact commit `0c97938342d77ab23b5f061ad472529d3999918e` using the same authorized WP10 result. Name, mobile, and birthday had no geometry-passing candidate; address candidates failed field validation; gender had no structured checked-state signal. The reason histogram is too coarse to identify a specific geometry failure, so no parser change is justified yet. See [`wp11n-muse-value-free-wp10-gate-diagnostic-result-20261103.json`](wp11n-muse-value-free-wp10-gate-diagnostic-result-20261103.json) and [`TEST_REPORT.md`](../integrations/muse-customer-card-ocr/TEST_REPORT.md#wp11-n-value-free-wp10-parser-gate-diagnostic-2026-11-03). This diagnostic does not authorize a source change.

## Authorization and exact scope

- Use only the same previously authorized WP10 structured OCR result. Do not access the reviewed reference, any new sample, inventory, card image, or the separate 30-card set.
- Resolve and record the full pushed branch HEAD for `codex/wp11-family-card-table-parser-20261103`, verify package version 0.12.0, and use a clean detached worktree with an isolated virtual environment.
- Run only the parser on that existing structured result if the existing WP11-M in-memory state cannot provide the requested counts. Do not call Seoul OCR, Baidu, or another OCR provider. Do not read images or reconstruct missing payloads.
- Return counts only for field labels, candidate sources, geometry, field validation, ambiguity/unique-assignment gates, family-boundary exclusions, and structured gender signals. Do not return OCR text, field values, identifiers, coordinates, bounding boxes, screenshots, raw payloads, logs containing data, or code excerpts.
- If a count is not available from the existing output or a value-free in-memory observation, mark it `null` and explain only with a fixed reason code such as `NOT_INSTRUMENTED`; do not modify repository source or weaken a parser gate to obtain it.
- No iCloud login or contact search/read/create/update/delete. No production execution or writes, configuration changes, deployment, raw export, commit, or push by MUSE.

## Procedure

1. Verify the exact current branch HEAD, package version, clean detached worktree, isolated imports, and Python/Pillow versions. Run no offline suite; the WP11-M exact-candidate suite already passed 144/144 and no code changed.
2. Confirm the same WP10 structured result is available. Do not inspect a reviewed reference. If the structured result is unavailable, mark the diagnostic `BLOCKED`; do not search for another artifact.
3. Reuse the current WP11-M parser state if it is tied to the exact tested commit. Otherwise run the current parser offline against only the same WP10 result. Count stages without materializing field values in output.
4. For each field, report pure-label count; distinct candidate blocks by mutually exclusive source (`direct_right`, `same_row_nonadjacent`, `next_visual_row`); candidates evaluated/passed/rejected or ambiguous at geometry, field-validation, and unique-assignment gates; and blocks excluded by the family/relative boundary. A candidate may be counted once per field and stage. Preserve zero as a measured count; use `null` only when not instrumented.
5. For gender, separately count pure labels, text blocks, and independently structured checked-state signals. Do not infer a selection from blank boxes, nearby text, or layout.
6. Return only the JSON structure in [`wp11n-muse-value-free-wp10-gate-diagnostic-result-template-20261103.json`](wp11n-muse-value-free-wp10-gate-diagnostic-result-template-20261103.json), with observed operation counts. Keep all data values out.

## Decision and rollback

Candidate approaches were: rely on the already recorded WP11-H aggregate (no new protected artifact access, but it describes package 0.11.0), or obtain value-free counts from the same authorized WP10 structured result under the current package 0.12.0 candidate (one bounded parser-only replay, no OCR or external side effects). The second path is selected because it tests the current parser gates. No parser fix is authorized by this task. If no uniquely assignable candidate passes current gates, preserve fail-closed behavior. Any later source change requires a separate narrow fix, synthetic regression, local suite, and exact-commit MUSE replay; revert that candidate commit before deployment if acceptance regresses. Production remains untouched.
