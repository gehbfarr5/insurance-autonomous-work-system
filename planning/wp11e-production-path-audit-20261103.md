# WP11-E production path and source provenance audit

Date: 2026-11-03  
Scope: read-only MUSE source inspection and source provenance. No production code was executed or changed; no OCR, Baidu, iCloud, or contact operation was performed.

## Result

**Production integration blocker confirmed; do not deploy the parser package by itself.** MUSE reported that production is on package 0.5.0 at commit `8336008d080387ab709d1e0ab9381683b1138e0f`. The tracked `fields.py` blob at that commit was independently read from Git and its SHA-256 matches MUSE's reported `186200379b12f7bdd95d93dd3dc80afc6429704dfa1c02e65b9fd05757968001`.

The actual upload path enters `wp8-seoul-ocr-service/muse_adapter.py` and `wp10-real-card/wp10_ocr_dedup.py`; MUSE reports that both construct `OcrBlock` with text only. In the Seoul adapter, `main()` at line 57 reads the `words` key and does not pass `location`, `probability`, or `chars`. The OCR response still has those non-value keys on each `words_result` item, so geometry and character metadata are lost before field extraction. Production 0.5.0's parser is line-oriented and does not use coordinates. The 0.8.1 geometry parser therefore cannot fix the live path through a package-only upgrade; both caller wiring and parser adoption are required.

The four runtime scripts `wp8-seoul-ocr-service/muse_adapter.py`, `wp10-real-card/wp10_ocr_dedup.py`, `wp10-real-card/wp10_create_readback.py`, and `carddav-mcp-client/mcp_client.py` were reported as untracked and outside a Git working tree. Their owner repository, ref, commit, and source hashes are unknown. The production checkout cannot be compared to an untracked commit. A similarly named tracked CardDAV client is a different component. The runtime source itself is not available in this controlled repository, so no patch to those live callers was attempted.

## Additional control findings

- MUSE's static audit reports that chat confirmation is not enforced by a code-level create flag; a technical caller can reach the manual create script while extraction is `REVIEW_REQUIRED`.
- Duplicate search is required in the normal scripts but is pre-create only. There is no idempotency key; a successful create followed by a lost response or failed readback can leave a contact that needs manual cleanup.
- Readback checks created fields, but no update/delete path was found in the inspected WP10 flow.
- The production package checkout was reported clean at 0.5.0 before and after inspection. MUSE reported unchanged package/source hashes and no external operations. Seoul service deployment hash was not independently established.

## Repair options and selected MVP

1. **Adapt the existing Baidu word-block path (selected, pending source access).** Preserve `location`, `probability`, and `chars` when both OCR entry points create `OcrBlock`, and wire both callers to the reviewed parser. Add a code-enforced stop before contact creation for any `REVIEW_REQUIRED` result, with duplicate search and an explicit confirmation state in the same create path. This reuses the existing Seoul OCR service, `OcrBlock`/`BoundingBox` schema, conservative 0.8.1 parser, and existing duplicate/readback workflow. The main cost is recovering and reviewing the untracked runtime callers and testing their actual orchestration.
2. **Add a separate image/table-recognition pipeline.** This could extract layout before field matching, but it introduces another OCR/model runtime and another handling path for complete card images. Prior research found PaddleOCR, RapidTable, and Table Transformer are not drop-in parsers for the existing protected Baidu word blocks. It would also need fresh privacy/data authorization, dependency review, and acceptance evidence. Do not select this unless the existing path cannot expose usable geometry or evidence demonstrates the current parser cannot meet accuracy.

The selected MVP is limited to source recovery, caller wiring, code-level create gates, and synthetic adapter/parser regressions. Implementation order: (1) obtain the approved source-only snapshot or tracked source ref and verify hashes/secrets, (2) inspect and patch both entry points and the create gate on a dedicated branch, (3) add synthetic input-contract tests for geometry/character preservation and fail-closed mapping, (4) run the full offline suite and MUSE isolated review, then (5) use only an explicitly authorized and fully labeled acceptance set. No production deployment is included. Rollback is a branch revert and restoring the previous 0.5.0 pin/callers; no contact cleanup should be required because no contact write is part of these stages.

## Next controlled work

Before adapting the live path, obtain a read-only, source-only copy of the four untracked scripts with per-file hashes and a secret/data scan, or identify their owning tracked repository and exact commit. Review the copy before adding it to a dedicated repair branch. Then update both OCR entry points to preserve supported OCR metadata and route through the reviewed parser, and enforce the review/duplicate/confirmation gate in the create code path. Keep this in an isolated MUSE worktree and rerun synthetic plus authorized protected acceptance checks. The 30-card gate remains unmet: inventory is below 30, authorization is unconfirmed, and reference annotations are incomplete. No production deployment is authorized or recorded here.

## Evidence boundary

The entry-point behavior, line number, control-flow findings, and source provenance above are MUSE-reported from a read-only static audit. Locally, only the tracked 0.5.0 `fields.py` blob hash was independently verified. No adapter source, customer content, OCR value, contact data, credential, or private URL was copied into this record.
