# MUSE family-card OCR package

Version 0.2.0. This branch updates WP2 for the 2026-11-02 full-image plan. It contains no production MUSE Secure Vault adapter, makes no Baidu API calls, and performs no iCloud operations.

## Full-image authorization

The previous mandatory `PrivacyMaskResult` gate has been removed. A caller must pass `full_image_authorized=True` to `recognize_customer_card` for every OCR call. The flag is an explicit call-site attestation that the applicable user and organization authorization exists; it is not a legal authorization check or a MUSE permission mechanism.

When called, the package sends the complete image representation after EXIF orientation, size normalization, and JPEG encoding. It does not crop or mask regions. The tool therefore must only be called after the complete-image authorization applies. It accepts JPEG/PNG bytes or paths confined to `~/workspace/user/files` by default. HEIC remains unsupported.

## Secure Bearer connector boundary

Python no longer reads `BAIDU_OCR_AK`, `BAIDU_OCR_SK`, or any production API key. It does not retrieve or cache a Baidu token. `BaiduOcrClient` builds one request and calls an injected `SecureBearerConnector` port. The request indicates `auth_scheme="bearer"` and has no token field or `Authorization` header. The connector implementation must attach the Bearer credential from its protected store outside this package.

`SecureBearerConnector.send(BearerOcrRequest) -> BearerOcrResponse` is a package-internal adapter contract used by tests. It is **not** represented as the actual MUSE Secure Vault helper interface. No helper interface, stdin format, or production HTTP behavior is inferred here. MUSE must provide the real helper specification before a concrete adapter can be implemented.

The historic Baidu handwriting endpoint and form body remain in the request builder. The newer single-key Bearer route for that endpoint is not verified. The adapter Mock tests validate package behavior only; they do not prove that MUSE or Baidu accepts this auth route. Do not attach a production secret directly in Python to make the Mock pass.

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

## Field extraction and review gates

`extract_primary_customer(result)` is deterministic and label-based. It reads only supported explicit labels, stops at recognized family/relative section headings, and does not infer gender, fill a missing value, or choose between conflicting values. An unrecognized or unlabelled layout can produce `needs_manual_review` rather than a guessed field set.

The parser requires a clear primary name, one valid mobile number, and a readable identity number for this target workflow. Ambiguous OCR candidates on name, mobile, birthday, gender, or ID lead to manual review. Uncertain optional address/other-phone values are omitted. It checks the ID's 18-character format, encoded date validity, checksum, duplicate conflicts, and any conflicting OCR character alternatives. Missing or invalid ID evidence produces `identity_number_uncertain` or `identity_number_conflict`; the parser never repairs OCR characters. The embedded identity-number date is used only to compare against an explicit card birthday. It is never copied into the birthday field. An explicit birthday that conflicts with the checked identity-number date produces manual review. The checksum is a transcription integrity check, not identity verification or a registry lookup.

`map_to_icloud_fields(extraction)` raises `MANUAL_REVIEW_REQUIRED` for a pending result. For a ready result, it returns a non-writing `ICloudContactDraft` with:

- `name_full` from the primary customer name;
- `phone_mobile` and `phone_other` from the labelled phone fields;
- `birthday` as the explicit date only;
- `address` as the original labelled address;
- `note` lines in stable order: `性别：...`, then `身份证号：...`.

This draft is a canonical field projection, not a serialized `contacts_create` payload. Repository evidence currently shows the MCP contact name and note shape, but does not define the production phone, birthday, and address input schema. A later MCP adapter must verify that schema. This package does not query, create, modify, or delete contacts.

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

Tests use generated fictional images, OCR payloads, and a Mock Bearer connector. They cover explicit opt-in, no API-key fields in the Python request, auth/rate/timeout/error handling, image validation/preprocessing, structure parsing, field extraction, ID/birthday review gates, native-field projection, and sensitive `repr`/logging behavior. They make no network calls.

## MUSE integration checklist

1. Check out branch `codex/wp4-muse-full-image-ocr-20261102`; run the offline suite in an isolated venv first.
2. Obtain MUSE's real Secure Vault helper documentation and confirm how it attaches Bearer auth, restricts host/path/method, accepts binary or encoded form data, returns status/body, and maps timeouts. Implement only a thin adapter from that documented interface to `SecureBearerConnector`; map helper timeout/transport failures to `SecureConnectorTimeout` or `SecureConnectorFailure`, do not pass a production key to this package or its Python process, and do not log the helper's raw request or response.
3. Keep the adapter mocked until the real helper contract and credential isolation are independently verified. No helper is present in this branch.
4. A real Baidu call would send a complete image. Perform none until the authorized MUSE workflow, connector, quota/cost, and separate API-test approval are ready. Any first API test must use a generated fictional image only.
5. The caller owns the attachment lifecycle. This package reads but does not delete or persist the MUSE attachment, OCR text, or temporary files. Keep OCR text transient and out of ordinary logs, traces, and long-term Agent memory.
6. Do not pass `full_image_authorized=True` based only on tool visibility. The calling workflow must ensure the complete-image authorization is applicable to the submitted photo.

## Rollback

Remove the isolated venv and this branch checkout/package. No credentials or connector configuration are created by this code. The package does not modify the MUSE SDK Bridge, attachments, iCloud MCP, or contacts.
