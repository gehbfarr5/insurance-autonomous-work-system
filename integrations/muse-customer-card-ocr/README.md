# MUSE family-card OCR package

Version 0.11.0 candidate. This package carries the full-image OCR and iCloud parameter adapters, the WP6-C Bearer helper, the WP7 query-parameter Access Token helper, the WP11 table-layout parser, and strict runtime adapters for the existing Seoul OCR response. It does not implement an undocumented MUSE Secure Vault API and makes no Baidu API calls. Tests use Mock transports and synthetic OCR blocks only; no real MCP tool or iCloud operation is invoked.

## End-to-end architecture and release state

The target architecture remains: MUSE photo upload → Seoul Baidu OCR → table or legacy line parsing → primary-customer field review → iCloud name/mobile duplicate search → user confirmation → iCloud contact creation → readback verification. The parser package implements OCR transport ports, field extraction, draft mapping, and a create-argument adapter; the MUSE orchestration, duplicate-search workflow, chat confirmation, deployed package pin, and readback workflow are owned by the MUSE runtime.

As of 2026-11-03, WP8-B Seoul OCR and the WP9 synthetic duplicate/create/readback flow are reported as passing. WP10 created one real contact only after the user confirmed a manually reviewed draft; automatic table extraction failed. Isolated 0.7.0, 0.8.0, and 0.8.1 replays all returned `REVIEW_REQUIRED`. Version 0.8.1 passed 95/95 offline tests and seven synthetic regressions, but the protected replay mismatched the reviewed name, mobile, identity number, explicit birthday, and gender; address was intentionally omitted. The 0.9.0 candidate now wires structured OCR metadata into both local runtime callers and hardens create/search/readback control flow. The full local offline suite passes 117/117, but the protected replay of the existing WP10 result on exact commit `c1396a862404a55d8ebb94b015003c3a90c3eb0e` also returned `REVIEW_REQUIRED` with no extracted fields and rejected mapping. Production remains 0.5.0 and no deployment is recorded.

The production audit found a hard integration gap: the prior versions of `wp8-seoul-ocr-service/muse_adapter.py` and `wp10-real-card/wp10_ocr_dedup.py` discarded `location`, `probability`, and `chars`. Production 0.5.0's parser is line-oriented and does not use coordinates. The runtime callers and `carddav-mcp-client/mcp_client.py` were copied to a controlled source-only snapshot (`9b7feede68775b36b81ecf7336380fb80819a852`) and merged into this review branch; their original owner repository/ref/commit remain unknown. One private host value in the MCP client was redacted in the public snapshot and locally replaced by protected configuration. The live production code was not changed. Static source review also found missing create confirmation, permissive empty-search defaults, generic write retries, raw result output, and OAuth state beside source. The candidate patch addresses these local source paths; it is not deployed.

The reviewed candidate snapshot still does not implement the operator's field-level review UI. Its Seoul adapter calls `map_to_icloud_fields` but emits only status, reason codes, presence booleans, and a draft-status marker; it does not display/edit field values or submit a reviewed draft. The create/readback entry point separately accepts confirmed JSON on stdin. This is a static finding about the sanitized snapshot, not proof of the live MUSE UI; a working edit/confirm handoff remains unverified and is a release blocker.

The source-only snapshot is complete, but the source provenance remains incomplete: it is a review snapshot, not an identified production checkout. Production `fields.py` at commit `8336008d080387ab709d1e0ab9381683b1138e0f` was independently hash-matched locally. The geometry and sample-inventory diagnosis is in [`wp11d-followup-diagnostic-20261103.md`](../../planning/wp11d-followup-diagnostic-20261103.md); source provenance and the repaired code path are in [`wp11e-production-path-audit-20261103.md`](../../planning/wp11e-production-path-audit-20261103.md). The 30-card set is not ready: fewer than 30 samples, authorization unconfirmed, and required reference annotations incomplete. Do not describe any candidate as production-ready or v1.0 Stable.

The current OCR path is the existing Seoul OCR service with protected MUSE transport. Do not switch to the abandoned MUSE-cloud-direct-to-Baidu route described in earlier drafts.

## Full-image authorization

The previous mandatory `PrivacyMaskResult` gate has been removed. A caller must pass `full_image_authorized=True` to `recognize_customer_card` for every OCR call. The flag is an explicit call-site attestation that the applicable user and organization authorization exists; it is not a legal authorization check or a MUSE permission mechanism.

When called, the package sends the complete image representation after EXIF orientation, size normalization, and JPEG encoding. It does not crop or mask regions. The tool therefore must only be called after the complete-image authorization applies. It accepts JPEG/PNG bytes or paths confined to `~/workspace/user/files` by default. HEIC remains unsupported.

## OCR authentication modes

The production integration target for this branch is Baidu's legacy `access_token` query authentication. Construct `BaiduOcrClient` with `auth_mode="query_param:access_token"` and inject a `SecureQueryParamAccessTokenConnector`. The request uses the fixed HTTPS handwriting endpoint without a query string; the connector supplies the single `access_token` query parameter from protected storage. Python never receives, reads, caches, or logs the token, and it never reads `BAIDU_OCR_AK`, `BAIDU_OCR_SK`, or any production credential.

`BaiduOcrClient` keeps `auth_mode="bearer"` as the backward-compatible default so WP6-C callers and tests continue to work. New MUSE production wiring should explicitly select `query_param:access_token`; no silent fallback between modes is implemented.

The package does not obtain or refresh the Access Token. MUSE's secured connector or another approved secure control plane must provide a valid token and own its expiry/refresh lifecycle. The existing historical AK/SK pair is not an Access Token and is never consumed by this package. A stale or unauthorized token surfaces as a classified authentication error.

### Backward-compatible Bearer example

```python
from muse_customer_card_ocr import (
    BaiduOcrClient,
    extract_primary_customer,
    map_to_icloud_fields,
    recognize_customer_card,
)

# `muse_secure_connector` must be a MUSE-provided adapter implementing the
# package port after its real helper contract has been confirmed.
client = BaiduOcrClient(connector=muse_secure_connector)
result = recognize_customer_card(
    image_bytes,
    mime_type="image/jpeg",
    full_image_authorized=True,
    client=client,
)
extraction = extract_primary_customer(result)
if extraction.needs_manual_review:
    # Present review reasons to the authorized operator; do not map or write.
    raise RuntimeError(extraction.review_reasons)
contact_draft = map_to_icloud_fields(extraction)
# `contact_draft` is a canonical projection only. No MCP write is performed.
```

### WP7 Access Token route

Use the dedicated adapter and mode explicitly:

```python
from muse_customer_card_ocr import (
    BaiduOcrClient,
    SecureQueryParamAccessTokenConnectorAdapter,
)

# `muse_query_transport` must be bound to MUSE's documented custom connector
# after its real helper contract and query-parameter credential behavior are verified.
muse_query_adapter = SecureQueryParamAccessTokenConnectorAdapter(muse_query_transport)
client = BaiduOcrClient(
    connector=muse_query_adapter,
    auth_mode="query_param:access_token",
)
```

The client retains Baidu's `recognize_granularity=small` and `probability=true` parameters, response blocks, available coordinates, line confidence, character candidates, and safe service/request IDs. Errors expose categories and status codes, not response bodies. It has no internal logger, and OCR text, request bodies, and response bodies are excluded from object `repr` output. MUSE must keep transport-level HTTP debug logs off because helper-level traces could expose request details.

## Fixed Baidu helper and Python connector adapters

`muse_baidu_helper.py` and `muse_secure_connector.py` add a testable package-owned boundary:

- Only the HTTPS handwriting endpoint is accepted; the stdio request envelope has no URL, host, path, method, headers, or credential fields.
- The helper constructs a fixed POST request with form content type, a bounded request body, an explicit timeout, and `allow_redirects=False`.
- The body crosses the helper boundary as base64 JSON on stdin. Stdout carries one structured response envelope; successful OCR response bytes are base64 encoded for IPC, while non-2xx bodies and transport error details are discarded. Neither helper nor adapter logs to stdout/stderr outside the protocol response.
- `SecureBearerConnectorAdapter` rejects any request that differs from the fixed URL, POST method, Bearer mode, content type, size, or timeout policy; it maps helper timeout/network failures to the package's safe connector exceptions.
- `BaiduSecureHttpTransport` and `StdioHelperInvoker` are local package protocols. `baidu_ocr_bearer` is a logical credential slot name, not a Vault placeholder syntax or secret. The Mock tests simulate replacement with a synthetic Bearer value entirely inside the mock transport.

`muse_baidu_token_helper.py` and `muse_token_query_connector.py` add the separate `query_param:access_token` path:

- The client request type has no token or query-parameter value. It allows only the fixed HTTPS host/path, POST, form content type, bounded body and timeout.
- The helper passes the fixed endpoint and logical credential slot `baidu_ocr_access_token` to the injected transport with redirects disabled. The transport contract permits only `query_param:access_token`; the stdio envelope has no URL, method, query, header, or credential field.
- The MUSE connector is expected to inject exactly one `access_token` query parameter outside Python. The Mock constructs a synthetic final URL and verifies the single query key; it does not validate MUSE's production behavior.
- HTTP error/redirect bodies are discarded. Timeouts map to the package timeout class; transport exceptions map to a safe network failure. Stdio remains bounded and carries only the form body and structured response envelope.
- Each OCR request timeout is capped at 60 seconds; the optional subprocess wrapper allows a separate 5-second exit grace without increasing the provider request timeout.

`BaiduSecureHttpTransport`, `BaiduQueryParamHttpTransport`, `StdioHelperInvoker`, and both JSON stdio envelopes are package-owned interfaces, not documented MUSE helper APIs. Before MUSE use, bind the documented custom connector to `BaiduQueryParamHttpTransport` or the stdio adapter and verify the MUSE side enforces the fixed endpoint, exact query key, redirect prohibition, limits, token expiry behavior, and log redaction. WP6-C Bearer remains available as a compatibility path. Tests prove local package behavior only; they do not prove MUSE has these capabilities.

## Field extraction and review gates

`extract_primary_customer(result)` supports both the original `label: value` line format and the Baidu handwriting response's positioned `words_result` blocks. For positioned tables it groups blocks into visual rows using their returned bounding boxes, then pairs an exact supported label with its immediate right-hand block or a uniquely aligned value block in the next row. It stops at recognized family/relative section headings and uses the returned coordinates to place that boundary even when OCR blocks arrive out of reading order. It does not synthesize empty cells, search arbitrary distant rows, infer gender, fill a missing value, or choose between conflicting candidates.

The parser requires a clear primary name, one valid mobile number, and a readable identity number for this target workflow. For each Baidu character result, the first candidate is treated as the provider's recognized character; differing later alternatives alone do not trigger review. A missing recognized character or disagreement between its recognized text and first candidate does trigger review. Overlapping table columns, conflicting values, and checksum-invalid identity numbers also produce a review decision. Table-only text without usable coordinates is not guessed; the legacy line parser still handles explicit `label: value` text. `FieldExtractionResult.status` keeps its previous values (`ready` / `needs_manual_review`) for compatibility, while `FieldExtractionResult.decision` exposes `READY` / `REVIEW_REQUIRED` to callers.

Baidu's `probability=true` response supplies per-line `average`, `variance`, and `min`, and `recognize_granularity=small` can return per-character candidates. Version 0.7.0 does not apply a numerical probability threshold: one template's aggregate confidence is insufficient to calibrate a general threshold. Confidence-only review remains unimplemented pending a representative, authorized calibration set.

The existing extraction gate still requires a clear primary name, one valid mobile number, and a readable identity number. It validates the ID's 18-character format, encoded date and checksum; conflicting or invalid ID evidence requires review, and OCR characters are never repaired. The embedded ID date is used only to compare with an explicit card birthday and is never copied to the birthday field. Conflicting dates require review. A first-candidate mismatch in name, mobile, birthday, gender or ID requires review; uncertain optional address/other-phone values are omitted. The checksum is a transcription-integrity check, not identity verification or a registry lookup.

`map_to_icloud_fields(extraction)` raises `MANUAL_REVIEW_REQUIRED` for a pending result. For a ready result, it returns a non-writing `ICloudContactDraft` with:

- `name_full` from the primary customer name;
- `phone_mobile` and `phone_other` from the labelled phone fields;
- `birthday` as the explicit date only;
- `address` as the original labelled address;
- `note` lines in stable order: `性别：...`, then `身份证号：...`.

The active iCloud MCP tool declaration exposes `contacts_create` as `{session_id, address_book_id?, contact}`. `contact` accepts `name.full`, `phones[]` (`value`, `type`, `primary`), `birthday`, `addresses[]` (including `street`), and `note`. The adapter in `contacts_create_adapter.py` maps the draft to that argument shape. Its tests use synthetic values and a Mock caller; no MCP tool was invoked.

`build_contacts_create_arguments(draft, session_id=..., address_book_id=...)` is a pure serializer. The server's schema says omitting `address_book_id` selects the first writable book, so the serializer rejects a missing/blank ID and always requires an explicit, previously verified target. It passes `session_id` supplied by the caller from the existing `apple_login` session. It keeps the name in `name.full` without guessing family/given boundaries, maps the mobile as `type=["cell"], primary=true`, other numbers as `type=["other"]`, birthday as `YYYY-MM-DD`, the complete address only to `addresses[].street`, and the draft note verbatim. Missing optional fields are omitted. Any text in the resulting argument object is sensitive and must not be logged.

`call_contacts_create(..., call_tool=...)` is an injectable test seam that dispatches only the `contacts_create` tool name. `McpToolCaller` is a local package protocol, not a documented MUSE Python bridge API. No update operation exists in this adapter; it cannot overwrite a contact. It also does not perform duplicate search, so the future workflow must complete its duplicate gate before using it. This package does not connect to the MCP or perform any contact operation by itself.

## Install and offline regression

Python 3.10 or later. Runtime dependency: Pillow. Requests and Baidu SDK are not used by this package. In an isolated environment:

```bash
python3 -m venv ~/workspace/.venvs/muse-customer-card-ocr
source ~/workspace/.venvs/muse-customer-card-ocr/bin/activate
python -m pip install "Pillow==10.2.0"
python -m pip install --no-deps -e /path/to/repo/integrations/muse-customer-card-ocr
cd /path/to/repo/integrations/muse-customer-card-ocr
PYTHONPATH=src python -m unittest discover -s tests -v
```

Tests use generated fictional images, OCR payloads, Mock Vault placeholder substitution, and a Mock `contacts_create` invoker. They cover both authentication adapters, the single mock `access_token` query parameter, fixed helper endpoint, stdin body transfer, redirect prohibition, size/timeout bounds, safe error classification, no sensitive stdout/stderr, image processing, structure parsing, field extraction, ID/birthday review gates, iCloud field projection, explicit address-book selection, and omitted optional fields. They make no network calls.

## MUSE integration checklist

1. Check out `codex/wp11-family-card-table-parser-20261103` and run the complete offline suite in an isolated venv first.
2. Obtain MUSE's real Secure Vault/custom connector documentation and map it to the package-owned `BaiduQueryParamHttpTransport` / `StdioHelperInvoker` seam. Do not infer a MUSE helper function name, stdin shape, placeholder syntax, or credential API from these local protocols.
3. Configure the MUSE-side connector for `query_param:access_token`; it must add only the `access_token` parameter outside Python, restrict the allowed HTTPS host/path/method, disable redirects, enforce body and timeout bounds, return structured status/body data, and suppress URL/query/token and OCR request/response logs. Confirm how the connector obtains and refreshes the Access Token. Keep it mocked until these properties are documented and verified.
4. A real Baidu call would send a complete image. Perform none until the authorized MUSE workflow, connector, quota/cost, token lifecycle, and separate API-test approval are ready. Any first API test must use a generated fictional image only.
5. The caller owns the attachment lifecycle. This package reads but does not delete or persist the MUSE attachment, OCR text, or temporary files. Keep OCR text transient and out of ordinary logs, traces, and long-term Agent memory.
6. Do not pass `full_image_authorized=True` based only on tool visibility. The calling workflow must ensure the complete-image authorization is applicable to the submitted photo.

## WP11 MUSE staging and re-test

WP11 changes extraction only. It does not require a new connector, OCR call, or iCloud MCP call. The last exact-tested code commit is `180f6333046b830010d60338edb580b23c03927c` (package 0.11.0); its MUSE offline suite passed 127/127, but the protected replay remained `REVIEW_REQUIRED`. Do not repeat that passing run without a relevant code, dependency, or test change. For a new candidate, use a fresh checkout/worktree and venv, and pin the exact candidate SHA rather than the moving branch tip. Keep the current runtime pinned:

```bash
git fetch --no-tags origin codex/wp11-family-card-table-parser-20261103
git cat-file -e '180f6333046b830010d60338edb580b23c03927c^{commit}'
git worktree add ~/workspace/wp11-family-card-ocr-0.11.0 180f6333046b830010d60338edb580b23c03927c
test "$(git -C ~/workspace/wp11-family-card-ocr-0.11.0 rev-parse HEAD)" = "180f6333046b830010d60338edb580b23c03927c"
python3.12 -m venv ~/workspace/.venvs/muse-customer-card-ocr-wp11-0.11.0
source ~/workspace/.venvs/muse-customer-card-ocr-wp11-0.11.0/bin/activate
python -c 'import sys, PIL, setuptools; print(sys.version.split()[0], PIL.__version__, setuptools.__version__)'
python -m pip install --no-index --no-build-isolation --no-deps -e ~/workspace/wp11-family-card-ocr-0.11.0/integrations/muse-customer-card-ocr
cd ~/workspace/wp11-family-card-ocr-0.11.0/integrations/muse-customer-card-ocr
python -c 'from importlib.metadata import version; assert version("muse-customer-card-ocr") == "0.11.0"'
python -c 'import PIL, sys; assert sys.version_info[:3] == (3, 12, 3); assert PIL.__version__ == "10.2.0"'
PYTHONPATH=src python -m unittest discover -s tests -v
```

The example is pinned to the already-tested commit for reproducibility; for a changed candidate, replace the SHA, path suffix, expected package version, and expected test count with the new task's exact values. Confirm Python 3.12.3 / Pillow 10.2.0 and the local build backend are available before installation. If any dependency would require another network fetch, stop instead of accessing PyPI. After the single authorized branch fetch, complete package install, tests, and any replay offline. Do not call Baidu or iCloud during parser re-tests.

For synthetic fixtures, confirm `decision == "READY"` for a unique valid table and `decision == "REVIEW_REQUIRED"` for blank/overlapping cells, a first-character-candidate mismatch, conflicting values, a checksum-invalid identity number, or unavailable geometry. Differing lower-ranked character alternatives alone must not force review. For the protected WP10 result, reuse only the already-authorized structured payload, do not read/find a reference unless the task explicitly authorizes it, and return only field-presence booleans, decisions, reason codes, and aggregate counters. Never copy OCR data into the repository, ordinary logs, screenshots, or task reports.

The current 0.11.0 candidate is not deployed, so no production rollback is needed. If a future isolated experiment changes only an isolated package pin, restore that isolated environment's recorded prior version and rerun its pinned offline suite. Production rollback requires a separate authorized deployment task; this section does not authorize it.

## WP11-B isolated retest handoff

The first MUSE real-template rerun (2026-11-03) returned `REVIEW_REQUIRED` because the 0.6.0 parser treated every lower-ranked Baidu character alternative as an ambiguity. The evidence and synthetic reproduction are recorded in [`wp11b-ambiguous-char-handoff-20261103.md`](../../planning/wp11b-ambiguous-char-handoff-20261103.md). Version 0.7.0 includes the candidate-order fix and a synthetic regression test. The exact copyable isolated retest and redacted machine-readable response template are in [`wp11b-muse-retest-20261103.md`](../../planning/wp11b-muse-retest-20261103.md) and [`wp11b-muse-result-template-20261103.json`](../../planning/wp11b-muse-result-template-20261103.json).

## WP11-C conservative column matching

The 0.7.0 MUSE replay showed that direct row adjacency could cross a field column, while the protected OCR response contained a valid identity number split across neighboring word blocks. Version 0.8.0 reuses the existing `OcrBlock`/`BoundingBox` model, visual-row clustering, checksum validator, and manual-review gate. It assigns same-row values only when their horizontal center is uniquely attributable to one field label, treats overlapping/tied columns as uncertain, and joins ID fragments only when adjacent blocks form one complete checksum-valid value in the same visual cell. It still searches only the immediate next row; MUSE could not establish a unique farther-row phone column, so the parser does not widen that search. It never infers checkbox gender from OCR structure without a signal.

**Reuse / adapt / avoid decision:** reuse the existing Baidu word-box schema and fail-closed review contract; adapt the local geometry matcher and add a narrowly constrained checksum-validated ID join; avoid a new image-model pipeline for this package change. Public candidates reviewed were [PaddleOCR](https://github.com/PaddlePaddle/PaddleOCR) (Apache-2.0, active project, latest release v3.7.0 in June 2026), [RapidTable](https://github.com/RapidAI/RapidTable) (Apache-2.0, v3.0.2 in April 2026), and [Microsoft Table Transformer](https://github.com/microsoft/table-transformer) (MIT, last release v1.0.0 in 2023). They consume document images and would introduce a separate model/OCR pipeline; none is a drop-in parser for the already-protected Baidu word blocks. No package dependency was added.

Spatial address evidence shorter than four characters or carrying ambiguous OCR is withheld and requires manual review; an absent optional address remains omitted. Near-tied label columns also remain under review using a margin scaled to the candidate block width. Local offline regression is 95/95 passing on synthetic data. MUSE's 0.8.0 and 0.8.1 results are recorded in [`wp11c-muse-result-20261103.json`](../../planning/wp11c-muse-result-20261103.json) and [`wp11d-muse-result-20261103.json`](../../planning/wp11d-muse-result-20261103.json). The 0.8.1 run passed its isolated suite and seven synthetic regressions, but its protected replay remained `REVIEW_REQUIRED`; the follow-up diagnostic found no evidence to relax geometry and confirmed the 30-card set is not ready. See [`wp11d-followup-diagnostic-20261103.md`](../../planning/wp11d-followup-diagnostic-20261103.md) for the redacted categories. The separate acceptance gate remains open. Follow [`wp11d-muse-retest-20261103.md`](../../planning/wp11d-muse-retest-20261103.md) for the exact tested commit and evidence boundary. No production deployment, Baidu call, iCloud operation, or real customer payload was used locally.

## WP11-E runtime repair candidate (0.9.0)

The isolated repair now routes both OCR callers through `parse_seoul_ocr_response`, preserving word geometry, probability, and character candidates. The Seoul and WP10 OCR commands require `--full-image-authorized` on each run. They print only statuses, reason codes, counts, and presence booleans; the former arbitrary `--draft-out` file path was removed.

Before any isolated MUSE use, install the candidate package in a separate venv and configure the source locations explicitly when the runtime does not install them as packages:

- `MUSE_CUSTOMER_CARD_OCR_SRC`: package `src` directory.
- `MUSE_CARD_DAV_MCP_CLIENT_SRC`: directory containing the reviewed `mcp_client.py`.
- `MUSE_PERSONAL_MCP_ORIGIN`: the private MCP HTTPS origin, stored in protected MUSE configuration. No host value belongs in Git.
- OAuth state defaults to `${XDG_CONFIG_HOME:-~/.config}/muse-personal/oauth.json` with directory/file permissions 0700/0600.
- Create-attempt state defaults to `${XDG_STATE_HOME:-~/.local/state}/muse-family-card/contact-create-state.json`; set `MUSE_FAMILY_CARD_STATE_DIR` only to another protected directory outside the repository. The state file holds a random operation ID, phase, and timestamp only.

`wp10_create_readback.py` accepts one reviewed JSON object on stdin. It requires `extraction_status` to be `READY` or `MANUALLY_REVIEWED`, `review_status` to be `USER_CONFIRMED`, and valid non-empty name, mainland mobile, gender, explicit ISO birthday, and checksum-valid identity number. `address` and `other_phones` are optional. The create script performs a fresh name and mobile search; it requires a contacts array, explicit `truncated: false`, and an explicit empty `partial_failures` list before treating either result as complete. Missing or malformed metadata, partial failures, conflicting matches, or reaching the limit stop without creating. These completeness fields reuse the local CardDAV workflow's existing search contract; the live MUSE schema remains unverified, so a different response shape stays blocked until documented. It creates at most one contact and checks name, primary mobile, all phone numbers, birthday, exact note, and optional address on readback.

`contacts_create` is never retried automatically. The protected local journal records a pending operation before the call and blocks later creates if the response or readback is uncertain. Inspect iCloud manually before resolving it. The operator-only resolution input is `operation_id`, `resolution` (`CONTACT_CONFIRMED` or `NO_CONTACT_AFTER_MANUAL_CHECK`), and `manual_reconciliation_confirmed: true`, supplied to `wp10_create_readback.py --resolve-pending`. The journal is scoped to one runtime state directory and is not a server idempotency key; it does not provide cross-host exactly-once behavior. Do not clear a pending attempt without manual reconciliation.

MCP writes were not run during local verification. Before any later MUSE create/readback test or deployment, confirm the live `contacts_create` and `contacts_read` schemas, especially address/other-phone encoding, primary-phone readback, and the protected host/OAuth configuration. The local candidate uses the repository's existing contacts field mapping and intentionally fails readback if the live schema does not preserve those fields.

The MUSE replay used an isolated worktree/venv at commit `c1396a862404a55d8ebb94b015003c3a90c3eb0e` (Python 3.12.3, Pillow 10.2.0) and passed 117/117 offline tests. Against the existing 89-block WP10 structured result it returned `REVIEW_REQUIRED` with `table_layout_uncertain`, `main_customer_identity_unclear`, `mobile_missing`, `address_uncertain`, and `identity_number_uncertain`; draft mapping was rejected. Name, mobile, birthday, gender, and identity number were mismatches because no fields were returned. Address MATCH only reflects that the reviewed draft omitted address; it does not show that the card address was extracted. The saved result lacked the Seoul envelope's `ok` and `words_result_num` keys, so MUSE supplied `ok: true` in memory and left the optional count absent; it did not modify the saved result.

MUSE reported zero OCR reruns, Baidu calls, iCloud MCP calls, contact reads/writes, production-code execution, or production changes. Production remained package 0.5.0 at commit `8336008d080387ab709d1e0ab9381683b1138e0f`; the read-only source hashes matched before and after. The isolated worktree was clean and no MUSE commit/push was made. The 0.9.0 candidate is not v1.0 Stable. The separately authorized 30-card acceptance gate remains blocked; no production package pin or runtime was changed.

## WP11-F same-row identity candidate repair (0.10.0)

MUSE's value-free diagnosis of the already-authorized WP10 result found exactly one complete ID-shaped block before the family boundary, checksum valid, with no invalid full-shaped competitor. It shares the unique explicit ID label's visual row and is not the immediate right neighbor; no different checksum-valid multi-block candidate or ambiguous-character composite was found. Generic column geometry still rejected it because it competed with another field label.

The 0.10.0 candidate reuses the current OCR block schema, visual-row clustering, and ID checksum/date validator. It adapts only the ID path: a fallback is allowed only for exactly one complete ID-shaped block in the primary-customer region, exactly one pure ID label, same-row placement, a passing checksum, and no ambiguous OCR characters. It is disabled when explicit ID evidence already exists and does not lower generic tie margins or widen other fields' search radius. A complete ID-shaped token is not considered as another field's value. No dependency or OCR route was added. A generic geometry relaxation was avoided because it could assign values across fields without evidence.

Synthetic regressions cover the same-row non-neighbor positive case, multiple complete ID candidates, invalid checksum, multiple ID labels, ambiguous OCR characters, and a short multi-row address guard. Targeted table-layout tests pass 24/24 and the full local offline suite passes 123/123 on Python 3.14.7 / Pillow 12.2.0. A GitHub search did not find a directly applicable maintained parser for these existing Baidu word boxes; the result was unrelated and is weak evidence, so the change stays local and dependency-free.

MUSE retested the exact code commit `e129c80e2d8b35ed667a5b4f2335007543a2c4d0` in a fresh worktree/venv (Python 3.12.3, Pillow 10.2.0): 123/123 offline tests and the synthetic suite passed. The protected WP10 replay remained `REVIEW_REQUIRED` and draft mapping was rejected. Name, mobile, birthday, and gender were absent; the ID was present, but the reviewed ID reference was unavailable in the authorized workspace, so exact match remains UNKNOWN; address MATCH reflects omission on both sides only. See the detailed evidence in [`TEST_REPORT.md`](TEST_REPORT.md). Production remains 0.5.0 and unchanged; this candidate is not v1.0 Stable. The 30-card set remains inaccessible until its authorization and reference-annotation gates are satisfied.

## WP11-G same-row address candidate repair (0.11.0)

MUSE's follow-up on the same authorized WP10 structured result resolved an inconsistent aggregate report. The current parser's direct-right/next-row search produced multiple address candidates but none passed the minimum-length check. In the same-row region beyond the immediate right block, multiple candidates passed the existing column rule, but exactly one distinct candidate also passed the address length and character checks. This candidate is not in the reviewed reference; the prior draft intentionally omitted address, so no address accuracy claim is possible.

The 0.11.0 candidate reuses the existing OCR block schema, row clustering, nearest-column rule, address length check, OCR-character ambiguity check, and review gate. Only a sole, pure address label can use the same-row extension; it scans that row only, rejects phone/identity-shaped values, and uses the rescue only when exactly one distinct candidate passes both geometry and field checks. Invalid short fragments may be replaced only when they are unambiguous; ambiguous candidates, multiple valid values, conflicting existing values, or ties remain under review. Name, mobile, birthday, other-phone, gender, and ID search behavior is unchanged. No new dependency or OCR path was added. Generic same-row expansion was avoided because the existing result provides no unique candidate evidence for those fields. GitHub code search found only unrelated matches for coordinate-based label/value parsing; this is weak reuse evidence, so the implementation remains a local adapter to the existing Baidu blocks.

Local tests use fictional OCR values and generated coordinates. The exact commit `180f6333046b830010d60338edb580b23c03927c` was retested by MUSE in a fresh detached worktree and venv (Python 3.12.3, Pillow 10.2.0); the offline suite passed 127/127. On the same authorized 89-block WP10 structured result, the replay returned `REVIEW_REQUIRED` with `table_layout_uncertain`, `main_customer_identity_unclear`, `mobile_missing`, `address_conflict`, and `address_uncertain`; draft mapping was rejected. Name, mobile, birthday, gender, address, and other-phone fields were absent; the ID field was present, but this run did not read the reviewed reference or compare values. The stored JSON lacked `ok` and `words_result_num`; MUSE supplied `ok: true` only in an in-memory wrapper and skipped the absent optional count. This was structured-block replay, not byte-for-byte envelope validation; the stored payload was unchanged.

MUSE reported one narrow fetch of the authorized target branch to obtain the exact commit, then offline checks; zero OCR reruns, Baidu calls, reference reads, other network access, iCloud/contacts operations, production-code execution, production changes, commits, or pushes. Production remained package 0.5.0 at commit `8336008d080387ab709d1e0ab9381683b1138e0f`; source hashes matched before and after. The replay worktree and original payload were reported unchanged. The 0.11.0 candidate is not v1.0 Stable and must not be deployed. Address remains optional and this change cannot turn missing required name/mobile fields into `READY`; the 30-card authorization and reference-annotation gates remain open.

The same-input value-free diagnostic and its follow-up classification are complete. It confirmed that line-format address evidence was absent, `allow_address_rescue` was true, and the unique address label triggered the same-row rescue. Of the expanded candidates, one distinct value passed column assignment and address checks. A second distinct value also passed the address length and character checks, but its column center was near-tied and it was closer to another field label; existing geometry still could not assign it uniquely to that field. This kept the rescue uncertain, so it did not append the otherwise valid representative. The direct/next-row evidence contained two distinct values and remained in conflict; the final address stayed absent with `address_conflict` and `address_uncertain`. Payload, isolated worktree, and production state were reported unchanged; no reference was read. The rejection is supported by the current geometry, not by the line-evidence precondition. No safe parser change is justified; keep the result under manual review.

## Rollback

Remove the isolated venv and this branch checkout/package. No credentials or connector configuration are created by this code. The package does not modify the MUSE SDK Bridge, attachments, iCloud MCP, or contacts.
