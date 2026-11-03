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

## WP6-C Secure Vault connector helper and adapter

- Date: 2026-11-02
- Package version: 0.4.0
- Branch: `codex/wp6-muse-baidu-secure-connector-20261102`
- Base: `codex/wp5-icloud-create-adapter-20261102` at `4cd6985c6a32227787f22301f50c451a8b96e6d8`
- Complete package regression: PASS — 56 tests, 0 failures, 0 errors (the prior 44 tests remain passing; 12 connector/helper tests added)
- Editable package install: PASS — version 0.4.0 built and imported with helper/adapter exports
- Mock coverage: bounded JSON stdin body transfer; test-only Secure Vault placeholder replacement; fixed HTTPS host/path and POST; no caller-controlled URL/method; no redirect; body and timeout limits; 401/403/408/429/5xx mapping; timeout/network classification; raw error-body suppression; no OCR text, image marker, or mock Bearer value in stdout/stderr; no shell and empty environment for the optional subprocess invoker.
- Test data: generated image and synthetic body/response markers; no customer data and no real credential.
- Network/provider/MUSE: no external network call, no MUSE Secure Vault call, no real helper invocation, no Baidu request, and no iCloud operation.
- MUSE integration status: pending. `BaiduSecureHttpTransport`, `StdioHelperInvoker`, and the JSON stdio envelope are package-owned interfaces, not a documented MUSE API. The MUSE-side binding must be implemented against its actual helper contract and independently verify credential injection, endpoint restrictions, redirect behavior, timeout, and log suppression.

Command:

```bash
PYTHONPATH=src /tmp/insurance-wp4-venv/bin/python -m unittest discover -s tests -v
```

## WP7-A Baidu Access Token query adapter

- Date: 2026-11-02
- Package version: 0.5.0
- Branch: `codex/wp7-muse-baidu-token-query-adapter-20261102`
- Base: `codex/wp6-muse-baidu-secure-connector-20261102` at `43a7f8732a1188047b8a6f6531600647a112baf6`
- Test runtime: macOS, Python 3.14.7, Pillow 12.2.0
- Complete package regression: PASS — 76 tests, 0 failures, 0 errors (all 56 WP6-C tests remain passing; 20 token-query tests added)
- Editable package install: PASS — version 0.5.0 built and imported; both token-query and WP6-C Bearer adapters exported
- WP7 Mock coverage: fixed HTTPS host/path and POST; exact `query_param:access_token` mode; one synthetic `access_token` query key injected only by the Mock Vault transport; no token in the Python request or stdio envelope; stdin form-body transfer; HTTP 200/401/429 and error-body suppression; 302 returned without following; transport and helper timeout; transport exceptions; request/response bounds; rejection of caller URL/method/query/auth/header and endpoint fields; structured stdout and empty stderr; 60-second helper timeout plus 5-second subprocess grace.
- Test data: generated fictional JPEG, synthetic OCR JSON, and Mock-only Access Token; no production credential or customer data.
- Network/provider/iCloud: no MUSE helper or Vault call, no Baidu API call, no iCloud MCP operation, and no contact mutation.
- MUSE binding: pending. `BaiduQueryParamHttpTransport`, `SecureQueryParamAccessTokenConnector`, and the token-query stdio envelope are package-owned ports. The MUSE custom connector's actual helper call contract, protected token source, expiry/refresh behavior, redirect behavior, and URL/query log redaction have not been verified. The package does not obtain or refresh an Access Token.

Commands:

```bash
PYTHONPATH=src /tmp/insurance-wp4-venv/bin/python -m unittest discover -s tests -v
/tmp/insurance-wp4-venv/bin/python -m pip install --no-deps -e .
```

These checks verify package logic and install metadata only. They do not establish live Baidu authentication or MUSE cloud acceptance.

## WP11 table-layout extraction

- Date: 2026-11-03
- Package version: 0.6.0
- Development branch: `codex/wp11-family-card-table-parser-20261103`
- Base: `codex/wp7-muse-baidu-token-query-adapter-20261102` at `8336008d080387ab709d1e0ab9381683b1138e0f`
- Runtime: macOS, Python 3.14.7, Pillow 12.2.0
- Baseline before changes: PASS — all 76 WP7 tests
- Complete regression after changes: PASS — 89 tests, 0 failures, 0 errors (all 76 existing tests plus 13 new WP11 tests)
- Targeted WP11 tests: PASS — 13/13 (12 geometry/OCR cases plus fail-closed decision semantics)
- Synthetic table acceptance: 5/5 valid layout fixtures produced `READY`; 7/7 blank, ambiguous, or invalid fixtures produced `REVIEW_REQUIRED`
- Changed behavior: retains `FieldExtractionResult.status` values for compatibility and adds `decision` (`READY` / `REVIEW_REQUIRED`); parser uses Baidu block coordinates for row clustering and direct-right/next-row same-column pairing; no arbitrary cell or row inference is performed.
- Test data: synthetic field strings, synthetic ID-shaped checksum values, generated OCR blocks and coordinates only. No real customer OCR response, image, or personal information was read or added.
- Network/MUSE/iCloud: no Baidu request, no MUSE deployment, no MCP tool call, and no iCloud contact read/write/delete.
- Confidence limitation: character candidate disagreement is reviewed. Baidu line `average` / `variance` / `min` values are preserved by the existing client, but no numeric review threshold was introduced because this template has no calibrated threshold evidence.

Command:

```bash
PYTHONPATH=src python3 -m unittest discover -s tests -v
```

MUSE staging and re-test steps are documented in `README.md`; they install the package in an isolated environment, run the offline suite, verify extraction decisions and draft mapping, and do not invoke iCloud.

## WP11-B candidate interpretation fix

- Date: 2026-11-03
- Package version: 0.7.0
- Development branch: `codex/wp11-family-card-table-parser-20261103`
- MUSE evidence source: `muse/wp11b-ambiguous-char-handoff-20261103` at `fd85f3b8ac69236e76aa67ba80de0d4365274355`; the original real OCR payload remains in MUSE's protected workspace and is not included here.
- Confirmed baseline: the MUSE-provided synthetic table reproduction failed on 0.6.0 with `REVIEW_REQUIRED` (expected `READY`), reproducing the real-template aggregate failure.
- Selected fix: use Baidu's first character candidate as its recognized character. Later alternatives alone no longer force review. Missing character text, disagreement between recognized text and the first candidate, geometry/layout uncertainty, value conflicts, and identity-number validation continue to fail closed. No confidence threshold was introduced because the available aggregate distribution is not a representative calibration set.
- Regression coverage: the MUSE synthetic table reproduction now passes; existing identity/name/mobile/label ambiguity tests now place the disagreeing candidate first, so a genuine first-candidate mismatch still requires review.
- Local runtime: macOS, Python 3.14.7, Pillow 12.2.0. The package installed editable as 0.7.0 in a temporary venv with `--no-deps`; pip's isolated build environment supplied the declared build backend.
- Targeted regression: PASS — 1/1 WP11-B reproduction tests.
- Complete offline regression: PASS — 90 tests, 0 failures, 0 errors (the previous 89 plus the WP11-B reproduction).
- Test data: fictional table and values only. No real OCR payload, image, customer value, or credential was read or added.
- External services and contacts: no MUSE runtime/deployment was changed, no Baidu call was made, and no iCloud read/write/delete call was made.
- MUSE acceptance: PENDING. MUSE's earlier production status was reported as package 0.5.0; Codex has not independently inspected the live MUSE runtime. An isolated retest task and redacted JSON result template are provided in `../../planning/wp11b-muse-retest-20261103.md` and `../../planning/wp11b-muse-result-template-20261103.json`. The retest must report its actual runtime and production readback.

Commands:

```bash
python -m pip install --no-deps -e integrations/muse-customer-card-ocr
cd integrations/muse-customer-card-ocr
python -m unittest discover -s tests -p 'test_wp11b*.py' -v
python -m unittest discover -s tests -v
```
