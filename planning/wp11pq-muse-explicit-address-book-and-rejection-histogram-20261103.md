# WP11-P/Q: exact-candidate MUSE offline retest and first-rejection histogram

**State:** `READY_FOR_USER_TRANSFER`. Transfer this packet once, manually, into the correct Family Card MUSE workspace. Do not paste it into the Forest conversation. A previous desktop UI attempt was misrouted there, stopped, and canceled; no WP11-P execution or result was observed. Codex will not send this packet through that ambiguous UI.

## Purpose and pinned revisions

This packet combines two independent read-only checks so they can be handled in one correct workspace transfer:

- **WP11-Q** verifies the local create safety contract, readback-only recovery contract, acceptance-record consistency invariants, and full offline suite at package 0.13.2.
- **WP11-P** performs the already-authorized value-free first-terminal-gate histogram on the same prior WP10 structured OCR result, using the earlier parser candidate. It does not authorize a parser change.

Candidate Q:

- Branch: `codex/wp11-family-card-table-parser-20261103`
- Exact commit: `0b162686fe6a8cfa29cda7dfcd224976339746f4`
- Package: `muse-customer-card-ocr` 0.13.2
- SHA-256 `integrations/muse-customer-card-ocr/src/muse_customer_card_ocr/runtime_safety.py`: `09d8482839dd02002eb3f26456910de9ebaaf7cf1441c09143dd6a9c5922071f`
- SHA-256 `wp10-real-card/wp10_create_readback.py`: `a85f6de5f7a3a758db1897bcb8bba724830771f13b46bd2573127f09a48cf3e7`
- SHA-256 `integrations/muse-customer-card-ocr/src/muse_customer_card_ocr/contacts_create_adapter.py`: `0aa33bb802b301ccb4b10269c2eb22214f82e8e1f232b8def45b84a4678b0c1b`
- SHA-256 `integrations/muse-customer-card-ocr/src/muse_customer_card_ocr/acceptance_metrics.py`: `45d7b265858acd67f15a32f25414f8b1d2f391808db4b48563418cbb3f0fc2ba`

Candidate P:

- Exact commit: `e08e7f7b2748cd3a3c60e2769063dc2d26e1112b`
- Package: 0.12.0
- Parser: `integrations/muse-customer-card-ocr/src/muse_customer_card_ocr/fields.py`
- Parser SHA-256: `420a1b21d0df9d6f1f75460559d2fd8ee87cfec2805ca326928dd268b213d147`

## Run order

1. Fetch the authorized feature branch once. Verify both exact commit IDs and all file hashes above. Stop the affected phase as `BLOCKED` if an immutable pin does not match; do not substitute HEAD.
2. **WP11-Q:** create a clean detached worktree at the exact Q commit and an isolated virtual environment. Use Python 3.12.3 and Pillow 12.3.0 if already available. Confirm package version 0.13.2 and isolated imports. Install only offline, without dependency resolution (for example, `python -m pip install --no-index --no-build-isolation --no-deps -e .`). If a needed build/test dependency is absent, stop as `BLOCKED`; do not access PyPI or another package index. From `integrations/muse-customer-card-ocr`, run `PYTHONPATH=src python -m unittest discover -s tests -v`. Expected result: 148 tests, zero failures/errors. All test transports must remain synthetic or mocked; do not call an MCP tool.
3. Confirm that the full suite covers the nine `synthetic_guard_checks` in the response template: missing, blank, and control-character address-book IDs are rejected; a valid explicit ID reaches the shared serializer; a missing ID stops before any MCP call; readback-only recovery succeeds without an address-book ID without issuing a second create; an auto-usable row with failure reasons is rejected; and a manual-review row without a failure reason is rejected. Report booleans only; do not return synthetic values.
4. **WP11-P:** verify the exact P commit and parser hash in a separate clean detached worktree. Reuse the WP11-N in-memory state if it contains enough information. Otherwise, use only the same previously authorized WP10 structured OCR result, at most once. If it is unavailable, stop P as `BLOCKED`; do not search for, reconstruct, or export another artifact. Count each distinct block once per field/source, classify only the first terminal gate, and use only the closed reason buckets in the template. If the source does not expose a reason, report `NOT_INSTRUMENTED` rather than infer one.
5. Return one JSON object matching [`wp11pq-muse-explicit-address-book-and-rejection-histogram-result-template-20261103.json`](wp11pq-muse-explicit-address-book-and-rejection-histogram-result-template-20261103.json). Return no prose outside the JSON.

## Boundaries

- Do not read any reviewed reference, new sample inventory, card image, or the 30-card set.
- Do not run OCR, Seoul/Baidu providers, log in, call MCP/iCloud/contact tools, execute production code, read or write production state, deploy, or modify source/tests/configuration.
- Return only test status/counts, closed diagnostic reasons, environment/version pins, and operation counts. No OCR text, names, phone numbers, identity numbers, birthdays, addresses, coordinates, screenshots, payloads, contact IDs, free-text findings, or protected values.
- Report all operation counts, including branch fetches and any structured-result reads. Keep `raw_values_returned` false.

A localized, verified P diagnosis may justify a separate narrow parser candidate with synthetic regression and exact-commit replay. It does not authorize changing parser code during this task. A P result that is ambiguous or uninstrumented supports no parser relaxation. Q only verifies this local fail-closed create contract. Both results leave production binding, live MUSE wiring, and the 30-card release gate unresolved.
