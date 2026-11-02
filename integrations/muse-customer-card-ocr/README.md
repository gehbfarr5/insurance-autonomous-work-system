# MUSE family-card OCR package

Version 0.4.0. This branch carries the full-image OCR and iCloud parameter adapters and adds a package-owned, fixed-endpoint stdio helper protocol plus a Python `SecureBearerConnector` adapter. It does not implement an undocumented MUSE Secure Vault API and makes no Baidu API calls. Tests use Mock transports only; no real MCP tool or iCloud operation is invoked.

## Full-image authorization

The previous mandatory `PrivacyMaskResult` gate has been removed. A caller must pass `full_image_authorized=True` to `recognize_customer_card` for every OCR call. The flag is an explicit call-site attestation that the applicable user and organization authorization exists; it is not a legal authorization check or a MUSE permission mechanism.

When called, the package sends the complete image representation after EXIF orientation, size normalization, and JPEG encoding. It does not crop or mask regions. The tool therefore must only be called after the complete-image authorization applies. It accepts JPEG/PNG bytes or paths confined to `~/workspace/user/files` by default. HEIC remains unsupported.

## Secure Bearer connector boundary

Python no longer reads `BAIDU_OCR_AK`, `BAIDU_OCR_SK`, or any production API key. It does not retrieve or cache a Baidu token. `BaiduOcrClient` builds one request and calls an injected `SecureBearerConnector` port. The request indicates `auth_scheme="bearer"` and has no token field or `Authorization` header. The connector implementation must attach the Bearer credential from its protected store outside this package.

`SecureBearerConnector.send(BearerOcrRequest) -> BearerOcrResponse` remains a package-internal interface. This branch adds a package-defined JSON stdin/stdout envelope and `SecureBearerConnectorAdapter`; it is not represented as MUSE's production helper API. The MUSE helper's actual invocation and Vault HTTP interface are still pending documentation.

The historic Baidu handwriting endpoint and form body remain in the request builder. Baidu's current [API Key authentication documentation](https://cloud.baidu.com/doc/AI_REFERENCE/s/Hm5us339w) describes Bearer authentication for public-cloud OCR interfaces; this package and MUSE binding have not been live-tested against that route. The older AK/SK pair is not interchangeable with the newer single API Key. Do not attach a production secret directly in Python to make the Mock pass.

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

The client retains Baidu's `recognize_granularity=small` and `probability=true` parameters, response blocks, available coordinates, line confidence, character candidates, and safe service/request IDs. Errors expose categories and status codes, not response bodies. It has no internal logger, and OCR text, request bodies, and response bodies are excluded from object `repr` output. MUSE must keep transport-level HTTP debug logs off because helper-level traces could expose request details.

## Fixed Baidu helper and Python connector adapter

`muse_baidu_helper.py` and `muse_secure_connector.py` add a testable package-owned boundary:

- Only the HTTPS handwriting endpoint is accepted; the stdio request envelope has no URL, host, path, method, headers, or credential fields.
- The helper constructs a fixed POST request with form content type, a bounded request body, an explicit timeout, and `allow_redirects=False`.
- The body crosses the helper boundary as base64 JSON on stdin. Stdout carries one structured response envelope; successful OCR response bytes are base64 encoded for IPC, while non-2xx bodies and transport error details are discarded. Neither helper nor adapter logs to stdout/stderr outside the protocol response.
- `SecureBearerConnectorAdapter` rejects any request that differs from the fixed URL, POST method, Bearer mode, content type, size, or timeout policy; it maps helper timeout/network failures to the package's safe connector exceptions.
- `BaiduSecureHttpTransport` and `StdioHelperInvoker` are local package protocols. `baidu_ocr_bearer` is a logical credential slot name, not a Vault placeholder syntax or secret. The Mock tests simulate replacement with a synthetic Bearer value entirely inside the mock transport.

No real MUSE helper interface or production connector is present in this branch. Before use in MUSE, its documented Secure Vault API must be mapped to `BaiduSecureHttpTransport` or the stdio invoker. The MUSE binding must inject the Bearer header outside this package, restrict the endpoint, disable redirects, and keep stdout/stderr and transport diagnostics from recording request or response data. The tests prove the package boundary only; they do not prove MUSE has those capabilities.

## Field extraction and review gates

`extract_primary_customer(result)` is deterministic and label-based. It reads only supported explicit labels, stops at recognized family/relative section headings, and does not infer gender, fill a missing value, or choose between conflicting values. An unrecognized or unlabelled layout can produce `needs_manual_review` rather than a guessed field set.

The parser requires a clear primary name, one valid mobile number, and a readable identity number for this target workflow. Ambiguous OCR candidates on name, mobile, birthday, gender, or ID lead to manual review. Uncertain optional address/other-phone values are omitted. It checks the ID's 18-character format, encoded date validity, checksum, duplicate conflicts, and any conflicting OCR character alternatives. Missing or invalid ID evidence produces `identity_number_uncertain` or `identity_number_conflict`; the parser never repairs OCR characters. The embedded identity-number date is used only to compare against an explicit card birthday. It is never copied into the birthday field. An explicit birthday that conflicts with the checked identity-number date produces manual review. The checksum is a transcription integrity check, not identity verification or a registry lookup.

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

Python 3.10 or later. Runtime dependency: Pillow. Requests and Baidu SDK are not used by this version. In an isolated environment:

```bash
python3 -m venv ~/workspace/.venvs/muse-customer-card-ocr
source ~/workspace/.venvs/muse-customer-card-ocr/bin/activate
python -m pip install "Pillow==10.2.0"
python -m pip install --no-deps -e /path/to/repo/integrations/muse-customer-card-ocr
cd /path/to/repo/integrations/muse-customer-card-ocr
PYTHONPATH=src python -m unittest discover -s tests -v
```

Tests use generated fictional images, OCR payloads, Mock Vault placeholder substitution, and a Mock `contacts_create` invoker. They cover the fixed helper endpoint, stdin body transfer, simulated Bearer injection, redirect prohibition, size/timeout bounds, safe error classification, no sensitive stdout/stderr, image processing, structure parsing, field extraction, ID/birthday review gates, iCloud field projection, explicit address-book selection, and omitted optional fields. They make no network calls.

## MUSE integration checklist

1. Check out branch `codex/wp6-muse-baidu-secure-connector-20261102`; run the offline suite in an isolated venv first.
2. Obtain MUSE's real Secure Vault helper documentation and map it to the package-owned `BaiduSecureHttpTransport` / `StdioHelperInvoker` seam. Do not infer a MUSE helper function name, stdin shape, placeholder syntax, or credential API from these local protocols.
3. The MUSE-side binding must attach Bearer credentials outside Python, restrict the allowed HTTPS host/path/method, disable redirects, enforce body and timeout bounds, return structured status/body data, and suppress request/response/error logs. Keep it mocked until these properties are documented and verified.
4. A real Baidu call would send a complete image. Perform none until the authorized MUSE workflow, connector, quota/cost, and separate API-test approval are ready. Any first API test must use a generated fictional image only.
5. The caller owns the attachment lifecycle. This package reads but does not delete or persist the MUSE attachment, OCR text, or temporary files. Keep OCR text transient and out of ordinary logs, traces, and long-term Agent memory.
6. Do not pass `full_image_authorized=True` based only on tool visibility. The calling workflow must ensure the complete-image authorization is applicable to the submitted photo.

## Rollback

Remove the isolated venv and this branch checkout/package. No credentials or connector configuration are created by this code. The package does not modify the MUSE SDK Bridge, attachments, iCloud MCP, or contacts.
