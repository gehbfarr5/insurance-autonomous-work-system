# WP11-P MUSE value-free first-rejection reason histogram

**State:** `READY_FOR_MUSE_HANDOFF`. WP11-N completed aggregate gate counts but grouped all geometry failures as `rejected_or_ambiguous`; it did not identify whether they came from column mismatch, overlap/tie, invalid geometry, or another verified condition. No parser change is supported without this distinction.

## Candidate and evidence

- Target branch: `codex/wp11-family-card-table-parser-20261103`
- Exact pushed candidate commit: `e08e7f7b2748cd3a3c60e2769063dc2d26e1112b`
- Package: `muse-customer-card-ocr` 0.12.0
- Candidate parser file: `integrations/muse-customer-card-ocr/src/muse_customer_card_ocr/fields.py`
- Candidate parser SHA-256: `420a1b21d0df9d6f1f75460559d2fd8ee87cfec2805ca326928dd268b213d147`
- The package source and tests are unchanged from WP11-M's exact-commit 144/144 MUSE test; commits since then are documentation/merge updates.
- Prior count-only result: [`WP11-N result`](wp11n-muse-value-free-wp10-gate-diagnostic-result-20261103.json).

## Options and choice

1. Keep only WP11-N's aggregate counts. This avoids another read of the protected structured result, but cannot identify a specific parser failure or support a narrow correction.
2. Classify the first terminal gate for the same already-authorized WP10 structured result under the exact current parser. This uses one bounded parser-only diagnostic and returns counts/reason codes only.

Use option 2. It is a diagnosis only; do not modify parser code, relax a gate, or claim accuracy. Do not reread the WP11-N output as a substitute for the original data if the same protected result is unavailable.

## MUSE task

1. Verify the full branch commit, package version, clean detached worktree, parser file hash, and isolated import path against the values above. Stop with `BLOCKED` if the exact commit or source hash cannot be confirmed.
2. Reuse the existing WP11-N in-memory result if it contains enough information. Otherwise, use only the same previously authorized WP10 structured OCR result, at most once. If it is unavailable, stop; do not search for, reconstruct, or export another artifact.
3. Run no OCR/provider, images, reference comparison, sample inventory, or 30-card access. Do not log in, call iCloud/contact tools, execute production code, write production state, deploy, or modify source/tests/configuration.
4. For each WP11-N candidate block, identify the first terminal outcome in the current code path. Report counts by field and candidate source; count each distinct block once per field/source and do not double-count a block across terminal outcomes. If source/control flow does not expose a reason, classify it as `NOT_INSTRUMENTED` rather than inferring one.
5. Use only the fixed reporting buckets in [`WP11-P result template`](wp11p-muse-wp10-rejection-reason-histogram-result-template-20261103.json). No OCR text, field values, coordinates, bounding boxes, screenshots, raw payloads, or free-form findings may be returned.
6. Return only the JSON result object. Record operation counts and confirm that all protected values remained unreported.

## Decision rule

A verified, localized cause may support a narrowly scoped candidate with a synthetic regression, local full offline suite, and exact-commit MUSE replay. An uninstrumented or ambiguous cause supports no relaxation. In either case, the 30-card and production provenance gates remain open.
