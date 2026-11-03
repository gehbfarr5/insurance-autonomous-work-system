# MUSE family-card OCR package

Version 0.7.0. This package carries the full-image OCR and iCloud parameter adapters, the WP6-C Bearer helper, the WP7 query-parameter Access Token helper, WP11 table-layout field extraction, and the WP11-B Baidu character-candidate fix. It does not implement an undocumented MUSE Secure Vault API and makes no Baidu API calls. Tests use Mock transports and synthetic OCR blocks only; no real MCP tool or iCloud operation is invoked.

## End-to-end architecture and release state

The verified project flow remains: MUSE photo upload → Seoul Baidu OCR → table or legacy line parsing → primary-customer field review → iCloud name/mobile duplicate search → user confirmation → iCloud contact creation → readback verification. The parser package implements OCR transport ports, field extraction, draft mapping, and a create-argument adapter; the MUSE orchestration, duplicate-search workflow, confirmation screen, deployed package pin, and readback workflow are owned by the MUSE runtime and must be verified there.

As of 2026-11-03, the recorded WP8-B Seoul OCR route and WP9 synthetic duplicate/create/readback flow are reported as passing. WP10 created one real contact only after the user confirmed a manually reviewed draft; its table parser did not extract fields automatically. MUSE's 0.6.0 WP11 real-template rerun then returned `REVIEW_REQUIRED` and was not deployed. MUSE reported production remained on 0.5.0; Codex has not independently inspected the live MUSE checkout or runtime pin. This branch now contains 0.7.0 and passes 90 offline tests, but MUSE isolation retest and protected WP10 payload replay are still pending. Do not describe this as a production fix until the MUSE result is returned and verified.

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

WP11 changes extraction only. It does not require a new connector, OCR call, or iCloud MCP call. In MUSE, create a separate checkout and venv so the current runtime stays pinned:

```bash
git fetch origin codex/wp11-family-card-table-parser-20261103
git worktree add ~/workspace/wp11-family-card-ocr origin/codex/wp11-family-card-table-parser-20261103
python3.12 -m venv ~/workspace/.venvs/muse-customer-card-ocr-wp11
source ~/workspace/.venvs/muse-customer-card-ocr-wp11/bin/activate
python -m pip install --no-deps -e ~/workspace/wp11-family-card-ocr/integrations/muse-customer-card-ocr
cd ~/workspace/wp11-family-card-ocr/integrations/muse-customer-card-ocr
PYTHONPATH=src python -m unittest discover -s tests -v
```

The MUSE VM's existing Pillow 10.2.0 satisfies the package requirement. Confirm `decision == "READY"` for a unique, valid table fixture and `decision == "REVIEW_REQUIRED"` for blank/overlapping cells, a first-character-candidate mismatch, conflicting values, a checksum-invalid identity number, or unavailable geometry. Differing lower-ranked character alternatives alone must not force review. If an approved WP10 structural payload already exists in MUSE's protected workspace, replay that existing OCR result locally and compare only the resulting field decisions there; do not request or copy the payload into the repository or ordinary logs. Verify `map_to_icloud_fields` still rejects review results and returns the same draft schema for ready results. Do not call Baidu or any iCloud tool during this parser re-test.

Rollback in MUSE by restoring the previously pinned package version 0.5.0 or the WP7 checkout, then rerun that version's offline suite. This rollback affects only the isolated MUSE package environment and does not touch attachments, connectors, or contacts.

## WP11-B isolated retest handoff

The first MUSE real-template rerun (2026-11-03) returned `REVIEW_REQUIRED` because the 0.6.0 parser treated every lower-ranked Baidu character alternative as an ambiguity. The evidence and synthetic reproduction are recorded in [`wp11b-ambiguous-char-handoff-20261103.md`](../../planning/wp11b-ambiguous-char-handoff-20261103.md). Version 0.7.0 includes the candidate-order fix and a synthetic regression test. The exact copyable isolated retest and redacted machine-readable response template are in [`wp11b-muse-retest-20261103.md`](../../planning/wp11b-muse-retest-20261103.md) and [`wp11b-muse-result-template-20261103.json`](../../planning/wp11b-muse-result-template-20261103.json).

## Rollback

Remove the isolated venv and this branch checkout/package. No credentials or connector configuration are created by this code. The package does not modify the MUSE SDK Bridge, attachments, iCloud MCP, or contacts.
