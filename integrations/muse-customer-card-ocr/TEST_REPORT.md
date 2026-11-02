# WP4 code and regression report

- Date: 2026-11-02
- Package version: 0.2.0
- Branch: `codex/wp4-muse-full-image-ocr-20261102`
- Plan baseline: `origin/planning/customer-card-full-ocr-20261102` at `655f936`
- Test runtime: macOS, Python 3.14.7, Pillow 12.2.0; Requests absent from the isolated test venv
- Offline regression: PASS — 37 tests, 0 failures, 0 errors
- Editable package install: PASS — version 0.2.0 built and imported from the isolated venv
- Test data: generated fictional images, synthetic OCR text, and a Mock Bearer connector
- Network/provider: no connector beyond the Mock; no Baidu request or other network call from tests
- MUSE cloud: not available to Codex in this session; Python 3.12.3 not tested
- Not tested: real Secure Vault helper, real Bearer injection, Baidu auth compatibility/endpoint, real OCR, iCloud tool payload schema, or any contact operation

## Coverage summary

**OCR/connector (13 tests):** explicit full-image opt-in; missing connector; one Bearer-port request without an API key or Authorization header in Python; form parameters; structured OCR text/coordinates/line confidence/character candidates; HTTP 401/403/408/429/503 mapping; connector timeout/failure mapping; Baidu auth/rate/quota/permission/provider errors; invalid JSON/response; image and request-size rejection; independent per-image results; sensitive log/repr checks.

**Field extraction (12 tests):** primary fields and stop at family section; no DOB derivation from ID; absent, checksum-invalid, duplicate-conflicting, or OCR-ambiguous ID requires review; conflicting card DOB versus ID DOB; name/mobile candidate ambiguity; conflicting mobile; absent/conflicting primary name; invalid birthday and unknown gender; redacted repr.

**iCloud draft mapping (5 tests):** name/mobile/birthday/address/other phone mapping; gender and ID each on their own note line; optional fields omitted; mapping blocked for review or any non-ready status; redacted repr.

**Image preparation (7 tests):** JPEG/PNG, conversion, EXIF orientation, downscaling, path confinement, MIME/HEIC rejection, and byte-size limits.

## Commands

```bash
PYTHONPATH=src /tmp/insurance-wp4-venv/bin/python -m unittest discover -s tests -v
/tmp/insurance-wp4-venv/bin/python -m pip install --no-deps -e .
```

The tests verify only package logic against the internal Mock port. They do not validate the proposed package port against MUSE's real helper or the newer Baidu Bearer auth route.

## WP5-B iCloud contacts_create adapter

- Date: 2026-11-02
- Package version: 0.3.0
- Branch: `codex/wp5-icloud-create-adapter-20261102`
- Base: `codex/wp4-muse-full-image-ocr-20261102` at `f8dcd17ee96a6c70ab1bddecae9dac894e10891b`
- Schema evidence: read-only inspection of the active `mcp__icloud_carddav__contacts_create` tool declaration in this session. It specifies top-level `session_id`, optional `address_book_id`, and nested contact fields including `name`, `phones`, `birthday`, `addresses`, and `note`. Omitting `address_book_id` selects the server's first writable book; the adapter therefore requires an explicit ID.
- Test runtime: isolated local Python 3.14.7 environment with Pillow 12.2.0
- Complete package regression: PASS — 44 tests, 0 failures, 0 errors
- Editable package install: PASS — version 0.3.0 built and imported with the new adapter export
- WP5-B Mock coverage: full nested create arguments, name.full preserved without family/given guesses, mobile/other phone types, birthday ISO formatting, address kept only in `street`, two separate note lines, missing optional fields omitted, explicit address-book requirement, required session/name/mobile validation, and create-only dispatch.
- Test data: synthetic fictional contact values only; the dispatcher is a `unittest.mock.Mock`.
- Network/provider/iCloud: no MCP tools invoked, no Apple login performed, no contact created/modified/deleted, and no Baidu request made.
- Not tested: MUSE-side tool invocation wiring, a real apple_login session, real address-book selection, live MCP schema validation from inside MUSE, duplicate search, and post-create readback. Duplicate gating and readback remain future workflow responsibilities.

Command:

```bash
PYTHONPATH=src /tmp/insurance-wp4-venv/bin/python -m unittest discover -s tests -v
```
