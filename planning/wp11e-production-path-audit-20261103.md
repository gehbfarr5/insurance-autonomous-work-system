# WP11-E production path and source provenance audit

Date: 2026-11-03  
Scope: static MUSE source audit, controlled source-only handoff, and isolated local repair. No production code was executed or changed; no OCR, Baidu, iCloud, or contact operation was performed locally.

## Status

**Production remains blocked; do not deploy this branch.** MUSE reported a package source checkout at version 0.5.0, commit `8336008d080387ab709d1e0ab9381683b1138e0f`. A later provenance audit found no manifest or release record binding it to the active runtime, whose version/hash remain UNKNOWN. The reported package source's `fields.py` blob hash (`186200379b12f7bdd95d93dd3dc80afc6429704dfa1c02e65b9fd05757968001`) was independently verified locally.

The four runtime scripts were untracked in MUSE and had no verified owner repository/ref/commit. MUSE copied only those source files to isolated branch `muse/wp11-runtime-source-snapshot-20261103`, commit `9b7feede68775b36b81ecf7336380fb80819a852`, then the snapshot was merged into the WP11 repair branch at `36f7c5b`. The original source identity remains unknown, so this is a controlled review snapshot, not a production release or a provenance-complete source checkout.

The repository is public. The initial scan found one private host constant in `mcp_client.py`; the handoff stopped before commit. MUSE then redacted only that value in the isolated copy, rescanned it, and pushed the snapshot after the scan passed. MUSE reports the original MUSE file was not modified. No customer/OCR/contact data, logs, configuration, credentials, or other host values were copied.

| Snapshot path | SHA-256 | Handoff treatment |
|---|---|---|
| `wp8-seoul-ocr-service/muse_adapter.py` | `5b7f139b23268f9fef5d41d596db18b6b3ff392bb4c507b55d8cd949f919bae3` | byte-identical to reported source |
| `wp10-real-card/wp10_ocr_dedup.py` | `4c78025fc1e9b672049474493971b36a3e22d4627e8b29b994885d9379a82fbf` | byte-identical to reported source |
| `wp10-real-card/wp10_create_readback.py` | `b9260b429b8861d9f383ad255ee661241c0d23a0e5dae6cd73b81a75125e7411` | byte-identical to reported source |
| `carddav-mcp-client/mcp_client.py` | `52515dbde60e276f48d47d89a3dda575cd83c1e9891ed6796465c5257c055a6d` | one private host value redacted |

MUSE reported original `mcp_client.py` hash `e49d983eefcecff78c6bc12c484ff43fb518f7e9981816491c2a4ecc4e5d085e`; that unredacted source is MUSE-only and was not published. Local `git show` SHA-256 checks matched all four snapshot hashes. Local literal scans and `git diff --check` found no private IP/DNS, mobile/ID/email literals, credential assignments, or bearer tokens in the snapshot.

## Source-level findings

The following were found by static inspection of the four imported files; no file was executed during this review:

- Both OCR callers used the old absolute package path and made text-only `OcrBlock` objects. They silently treated missing `words_result` as empty and skipped malformed non-dict blocks, dropping `location`, `probability`, and `chars` before extraction.
- `muse_adapter.py` printed the full birthday and could write full contact fields to an arbitrary `--draft-out` path with a fictional-data label, even when input was real.
- The duplicate/create scripts treated a missing or malformed `contacts` list as an empty search result, which could lead to `ALLOW_CREATE`.
- The create script did not require a code-level confirmation state or validate required values. It could use a failed primary-phone readback as a pass and treated any returned address as a failure.
- `_mcp_call_resilient` could repeat generic `tools/call` operations after session errors, including non-idempotent creation. The client also printed raw MCP results and embedded response bodies in exceptions; OAuth state was stored beside the source file.
- No transaction/outcome journal existed. A lost create response or failed readback could leave a contact while a later run attempted another create.

## Selected repair and reuse decision

**Selected: adapt the existing Seoul Baidu word-block path.** Reuse `OcrBlock`/`BoundingBox`, the existing conservative parser, the current duplicate gate, and standard-library JSON/fsync/atomic-replace journal patterns already used in local `src/forest_policy/journal.py`. The new MUSE-specific journal narrows the state to a random operation ID, phase, and timestamps; it stays outside the Git repository and serializes create attempts with a file lock. No contact values or server contact IDs are stored.

**Avoid: a second OCR/table-model pipeline.** Existing research recorded in the package README found PaddleOCR, RapidTable, and Table Transformer are not drop-in parsers for the already-protected Baidu word blocks; they would introduce another image-processing path without fixing confirmation, retry, or readback controls. No new runtime dependency was added.

The current patch adds a strict Seoul response adapter that preserves geometry, confidence, and character candidates; updates both OCR callers to use it; requires an explicit per-call full-image authorization flag; and removes OCR value printing/file output. It also makes search-result validation fail closed: pre-create searches require an explicit `truncated: false` and empty `partial_failures` list, reusing the completeness signals in the repository's existing CardDAV workflow. A different or undocumented live MUSE response shape therefore stops before create. The patch requires `READY` or `MANUALLY_REVIEWED` plus `USER_CONFIRMED` and valid required fields before create, verifies the primary phone and optional address/other phones on readback, and leaves a pending operation after any uncertain write/readback outcome. The MCP client never retries contact writes and requires a protected host configuration value; OAuth state moves to the user config directory. Errors and tool results no longer print raw response content.

The MCP protocol has no generally interoperable server-side write idempotency guarantee in the inspected tool-call schema. The Request Idempotency SEP PR was closed without merge, so it is not an available contract for this MUSE server. Therefore the patch uses a local pending-create stop and manual reconciliation instead of sending an unverified idempotency parameter. See the [closed MCP Request Idempotency proposal](https://github.com/modelcontextprotocol/modelcontextprotocol/pull/3182) and the [MCP tool annotations schema](https://github.com/modelcontextprotocol/modelcontextprotocol/blob/main/schema/2025-06-18/schema.ts). This journal prevents blind retries only on the runtime that shares its protected state directory; it does not claim server-side or multi-host exactly-once semantics.

## Verification and remaining gates

- Focused synthetic runtime tests: PASS — 22 tests, including geometry/candidate preservation, fail-closed response/search contracts, confirmation gates, no write retry, PII-free pending state, and mocked create/readback. No provider or MCP endpoint was called.
- Full offline suite: PASS — 117 tests, 0 failures, 0 errors, package 0.9.0 candidate.
- MUSE isolated replay: FAIL for exact commit `c1396a862404a55d8ebb94b015003c3a90c3eb0e`. MUSE used an independent clean worktree/venv (Python 3.12.3, Pillow 10.2.0), passed 117/117 offline tests, and replayed the existing 89-block WP10 result without OCR. It returned `REVIEW_REQUIRED` with `table_layout_uncertain`, `main_customer_identity_unclear`, `mobile_missing`, `address_uncertain`, and `identity_number_uncertain`; no fields were extracted and mapping was rejected. The name, mobile, birthday, gender, and identity number mismatched because the parser returned no fields. Address MATCH only reflected the reviewed draft's intentional omission.
- Replay input limitation: the protected JSON lacked top-level `ok` and `words_result_num`; MUSE constructed an `ok: true` envelope in memory from the existing `words_result`, and omitted the optional count. The source result remained unchanged. Thus the run exercised parsing/extraction of existing word blocks but did not validate a byte-for-byte live Seoul envelope.
- MUSE reported zero OCR reruns, Baidu calls, iCloud MCP calls, contacts operations, or production-code execution. The package/source metadata reported 0.5.0 at commit `8336008d080387ab709d1e0ab9381683b1138e0f`; this was not bound to the active runtime. The isolated worktree was clean; MUSE made no commit or push.
- Acceptance conclusion: this candidate is not v1.0 Stable and must not be deployed. The 0.8.1 value-free follow-up found no geometry-unique candidates, so there is no evidence to loosen geometry rules for this one sample. The 30-card set remains blocked by missing authorization and reference annotations.
- Geometry acceptance remains open. WP11-D's protected replay mismatched the reviewed name, mobile, ID, explicit birthday, and gender; there is still no evidence to loosen ties, overlap, or row-search gates.
- 30-card acceptance set remains gated: inventory below 30, authorization unconfirmed, and required reference annotations incomplete. Do not access new cards until separately authorized.
- MUSE reported package source remains 0.5.0. No deployment, Baidu call, iCloud operation, or contact write was performed as part of this repair; active runtime version remains UNKNOWN.

The branch repair is reversible by reverting its commits; no production rollback or contact cleanup is needed because no production change/write occurred. Before any future MUSE deployment, confirm the package/runtime path configuration, MCP host in protected configuration, OAuth state directory, persistent journal location, actual MUSE tool schemas, and the tested package pin. Keep deployment and 30-card validation as separate gated tasks.

## Follow-up MUSE workflow audit (2026-11-03)

MUSE completed a separate read-only static audit of workspace workflow copies and visible tool metadata. A later audit verified the 0.5.0 package source checkout at `8336008d080387ab709d1e0ab9381683b1138e0f`, but found no deployment record linking it to the active runtime. The audit was static only: no production code execution or change, OCR/Baidu request, iCloud MCP call, or contact operation was performed. The Seoul service's deployed version/hash and active runtime version remain UNKNOWN; tool schema metadata had no version/ref binding.

### Reported production findings

- The inspected workspace-copy upload path passed text-only blocks to a line-oriented parser and did not carry coordinates; this behavior is not confirmed for the active runtime.
- The inspected workspace copies had no dedicated operator UI for field-level review/editing or code-level confirmation. MUSE reported chat-level manual correction/reply, but no enforced handoff. Current runtime UI behavior is UNKNOWN.
- The inspected create/readback copy searched by name and mobile, appeared to permit caller-supplied `REVIEW_REQUIRED` values, and failed on missing required keys. Current runtime enforcement and server behavior for empty values are UNKNOWN.
- The inspected MCP client copy may retry `contacts_create` after an unknown/session/404 error and performs per-field readback without automatic rollback. Actual deployed retry/readback behavior is UNKNOWN; no server idempotency key was visible in tool request metadata, while server-side guarantees remain UNKNOWN.

### Candidate comparison and release decision

The local repair candidate differs: `parse_confirmed_draft` requires `READY` or `MANUALLY_REVIEWED` and `USER_CONFIRMED`; the pending-operation journal blocks a later create after an uncertain outcome; and the local MCP client's retry allowlist is limited to login, search, and read, with an existing regression test asserting a create session rejection is not retried. This is source-level candidate evidence, not proof of production deployment; the sanitized snapshot still lacks an operator review UI, and a complete live edit/confirm handoff has not been verified.

Two write-retry approaches were considered: rely on a server idempotency key, or disable automatic retries for non-idempotent create calls and retain a pending local journal for reconciliation. The server's idempotency support is unknown and the inspected tool schema supplies no verified key, so the candidate reuses the second approach. The local journal only protects runs sharing its protected state directory and does not provide cross-host exactly-once behavior.

**Release result: FAIL / blocked.** Before deployment, verify the production source owner/ref/commit, Seoul deployed hash, live `contacts_search/create/read` schema and version, server idempotency behavior, empty-field semantics, and a working field-level edit/confirm workflow. Then perform isolated end-to-end validation of fail-closed review, create retry suppression, duplicate search, and per-field readback. No new sample access is authorized by this audit; the 30-card gate remains closed.

## WP11-K provenance clarification (2026-11-03)

A later read-only MUSE metadata audit verified a clean source checkout reporting package `muse-customer-card-ocr` 0.5.0 at branch `codex/wp7-muse-baidu-token-query-adapter-20261102`, commit `8336008d080387ab709d1e0ab9381683b1138e0f`. The workspace contained no deployment manifest or release record that ties this checkout to the active MUSE runtime. The active runtime version and deployed MUSE client/tool-server ref/hash therefore remain UNKNOWN; the Seoul service's deployed version/hash is also UNKNOWN, and the OCR caller has no static version/hash pin.

The four runtime files used in the earlier workflow review are workspace copies absent from that 0.5.0 checkout and untracked there. Their MUSE-reported hashes are workspace hashes only, not production-source or deployment evidence (full values are recorded in the WP11-K section of [`TEST_REPORT.md`](../integrations/muse-customer-card-ocr/TEST_REPORT.md)). Consequently, the earlier static findings in this report describe the inspected copies and must not be presented as verified current production behavior. The prior `tools/list` response remains evidence of tool metadata visible at that time, but did not expose output schemas or deployment provenance.

Local Git inspection confirms commit `8336008d080387ab709d1e0ab9381683b1138e0f` declares package version 0.5.0 and does not contain the four workflow files. The audit made zero remote accesses, production calls/execution, contact/OCR operations, writes, or deployments. Release remains blocked pending verifiable source-to-runtime provenance and the other gates above.
