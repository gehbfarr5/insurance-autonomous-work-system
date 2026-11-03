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
- MUSE acceptance: FAIL. The isolated retest pinned code commit `29771eb33b07bd43150dec0a236c2711b290c165`, passed 90/90 offline tests and the synthetic candidate regression, but the protected WP10 replay remained `REVIEW_REQUIRED`; the extracted name mismatched the reviewed reference, required mobile, birthday, identity number, and gender were not correctly extracted, and draft mapping was rejected. MUSE reported no Baidu/iCloud operation or production change; production remained 0.5.0. The follow-up evidence is summarized under WP11-C and WP11-D below. The original protected payload remains in MUSE.

Commands:

```bash
python -m pip install --no-deps -e integrations/muse-customer-card-ocr
cd integrations/muse-customer-card-ocr
python -m unittest discover -s tests -p 'test_wp11b*.py' -v
python -m unittest discover -s tests -v
```

## WP11-C conservative column matching

- Date: 2026-11-03
- Package version: 0.8.0
- Development branch: `codex/wp11-family-card-table-parser-20261103`
- MUSE 0.7.0 replay: FAIL — isolated environment used Python 3.12.3 / Pillow 10.2.0 and passed 90/90 offline tests, but the protected WP10 structured-result replay remained `REVIEW_REQUIRED`. Aggregate diagnosis found cross-column name/birthday pairing, a phone outside the immediate next-row window with non-unique column geometry, an identity number split across OCR blocks, partial address evidence, and no structured gender/checkbox signal. The raw payload and field values remain in MUSE and are not copied here.
- Production and external-operation readback reported by MUSE: package remained 0.5.0 before/after; Baidu calls 0, iCloud reads/writes 0, production configuration unchanged.
- Reuse/adapt/avoid decision: reuse the existing `OcrBlock`/`BoundingBox` schema, row clustering, checksum validator, and manual-review gate; adapt column assignment so same-row values must be nearest to one field label and tied/overlapping labels require review; reassemble adjacent identity-number blocks only when the complete value passes the existing checksum. Avoid a new image-model pipeline for this branch change. Public candidates reviewed: [PaddleOCR](https://github.com/PaddlePaddle/PaddleOCR) (Apache-2.0; release v3.7.0, June 2026), [RapidTable](https://github.com/RapidAI/RapidTable) (Apache-2.0; v3.0.2, April 2026), and [Microsoft Table Transformer](https://github.com/microsoft/table-transformer) (MIT; v1.0.0 release, 2023). They process document images and do not directly replace parsing of the existing protected Baidu word boxes; adding one would create a second OCR/model route and heavier runtime/deployment work. No new dependency was added.
- Local verification: Python 3.14.7, Pillow 12.2.0; targeted table-layout tests PASS — 17/17; full offline suite PASS — 94 tests, 0 failures, 0 errors.
- Added synthetic coverage: a right-adjacent block in another field column is not accepted as the name; adjacent numeric fragments are joined only into a checksum-valid identity number; invalid fragments remain under review; a short address fragment is withheld and requires manual review. Existing overlapping-column and fail-closed tests remain passing.
- Test data: synthetic fields, ID-shaped checksum values, and synthetic coordinates only. No real OCR payload, image, customer values, or credentials were read locally.
- MUSE acceptance: FAIL for 0.8.0. The protected replay returned `REVIEW_REQUIRED`; name, mobile, identity number, explicit birthday, and gender mismatched the reviewed reference. Address was omitted as in the reviewed draft. MUSE reported no external operations and production remained 0.5.0. The sanitized result is `../../planning/wp11c-muse-result-20261103.json`; no production deployment was part of the re-test.

## WP11-D near-tied column review margin

- Date: 2026-11-03
- Package version: 0.8.1
- Development branch: `codex/wp11-family-card-table-parser-20261103`
- Trigger: WP11-C's isolated 0.8.0 run passed 94/94 offline tests but the protected replay still returned `REVIEW_REQUIRED`. Its aggregate diagnosis showed the name's adjacent block could not be distinguished from the next field column; phone and ID column geometry also remained non-unique.
- Change: scale the column tie margin by the candidate block width so visually broad/near-tied candidates are withheld for review. This iteration does not extend the phone search beyond the next visual row or infer missing gender/checkmark state.
- Local verification: Python 3.14.7, Pillow 12.2.0; editable package install 0.8.1 PASS; targeted table-layout tests PASS — 18/18; full offline suite PASS — 95 tests, 0 failures, 0 errors.
- Added synthetic coverage: near-tied column centers require `REVIEW_REQUIRED`.
- MUSE re-test: FAIL for exact code commit `1aeb7cb7b04c4e4853d750b181800fbbacf71fab`. Its isolated Linux/Python 3.12.3/Pillow 10.2.0 run passed 95/95 offline tests and all seven synthetic regressions. The protected WP10 replay remained `REVIEW_REQUIRED`; name, mobile, identity number, explicit birthday, and gender did not match the reviewed reference, and automatic draft mapping was rejected. Address MATCH reflects the reviewed draft's intentional omission only. The wider margin rejects the prior wrong name candidate, but does not establish a correct name match. MUSE reported zero Baidu/iCloud operations, no production changes, production at 0.5.0, and a passing read-only source hash check. Full redacted result: `../../planning/wp11d-muse-result-20261103.json`.
- The task and result template are `../../planning/wp11d-muse-retest-20261103.md` and `../../planning/wp11d-muse-result-template-20261103.json`. The separate 30-card acceptance gate remains open.
- MUSE's value-free follow-up confirmed no evidence to relax the tie/overlap gate. One full ID-shaped block passed an internal checksum but competed with another field label; a separate composite's column remained non-unique. The unique address candidate was rejected as shorter than the minimum length. See `../../planning/wp11d-followup-diagnostic-20261103.md` for aggregate categories only.
- Acceptance-set inventory: fewer than 30 protected samples, authorization not confirmed, and required reference annotations incomplete. MUSE inspected only inventory metadata; no sample contents were opened or processed.
- Data boundary: all local inputs are synthetic. No real OCR payload, customer values, credentials, Baidu call, iCloud operation, or production change was used.

## WP11-E production path and source provenance audit

- MUSE static audit (2026-11-03): production remains package 0.5.0 at commit `8336008d080387ab709d1e0ab9381683b1138e0f`. The production `fields.py` SHA-256 reported by MUSE was independently verified against that Git blob: `186200379b12f7bdd95d93dd3dc80afc6429704dfa1c02e65b9fd05757968001`.
- The live OCR entry points are reported as `wp8-seoul-ocr-service/muse_adapter.py` and `wp10-real-card/wp10_ocr_dedup.py`. They construct `OcrBlock` from text only. The Seoul adapter's `main()` line 57 receives per-block `words`, `location`, `probability`, and `chars`, but passes only text. Production 0.5.0 is line-oriented and does not consume coordinates, so installing 0.8.1 alone cannot repair this production path.
- The two OCR entry points, `wp10-real-card/wp10_create_readback.py`, and `carddav-mcp-client/mcp_client.py` were reported as untracked, outside a Git working tree, and have no known owner repository/ref/commit. Their source is not available in this repository; no runtime patch was attempted. A tracked file with the same CardDAV client basename is a different component.
- Additional static findings: chat-level confirmation is not a code-level gate for manual contact creation; duplicate search is pre-create only; no idempotency token is used; a create followed by a lost response/readback failure can require manual cleanup. These findings are MUSE-reported and have not been independently reproduced.
- The production checkout was reported clean and unchanged; MUSE reported unchanged hashes and zero OCR, Baidu, iCloud, or contact operations. The Seoul service deployment hash remains unverified.
- Result: production-path acceptance FAIL. Obtain a hashed, read-only source snapshot or tracked source commit before implementing caller changes. The 30-card data gate remains BLOCKED (fewer than 30 samples, authorization unconfirmed, incomplete references). No deployment was performed.
- Full redacted audit and evidence boundaries: [`wp11e-production-path-audit-20261103.md`](../../planning/wp11e-production-path-audit-20261103.md).

## WP11-E source snapshot and runtime repair candidate

- Date: 2026-11-03
- Package candidate: 0.9.0
- Branch: `codex/wp11-family-card-table-parser-20261103`
- Source snapshot: MUSE branch `muse/wp11-runtime-source-snapshot-20261103`, commit `9b7feede68775b36b81ecf7336380fb80819a852`, merged into this review branch at `36f7c5b`. Its original MUSE owner repository/ref/commit remain unknown. The MCP private host value was redacted in the public snapshot; MUSE reported its post-redaction scan passed, and local hashes matched all four snapshot files.
- Change: both OCR callers now use the strict Seoul response adapter and retain geometry, probability, and character candidates. Create requires explicit confirmation and validated required fields; name/mobile searches require explicit `truncated: false` and an empty `partial_failures` list before being treated as complete; writes are not retried; uncertain create/readback outcomes persist a PII-free pending operation outside the repository; readback verifies primary phone, birthday, note, and optional address/other phones. MCP OAuth state now uses a protected config directory, and raw result/error output is suppressed. Live MUSE search-result schema remains unverified and must match this contract before create can proceed.
- Local runtime: macOS, Python 3.14.7, Pillow 12.2.0.
- Full offline suite: PASS — 117 tests, 0 failures, 0 errors. This includes 22 new synthetic/mocked tests for Seoul response metadata, runtime contract validation, strict search/create/readback behavior, retry suppression, and protected journal/OAuth state.
- Data boundary: tests use synthetic OCR/contact data and Mock MCP calls only. No real image or customer payload was read; no OCR, Baidu, iCloud, or contact operation was performed locally.
- MUSE isolated replay of the already-authorized WP10 structured result: FAIL for exact commit `c1396a862404a55d8ebb94b015003c3a90c3eb0e`. In a separate worktree/venv (Python 3.12.3, Pillow 10.2.0), MUSE passed 117/117 tests, then replayed the existing 89-block result without OCR. It returned `REVIEW_REQUIRED` with `table_layout_uncertain`, `main_customer_identity_unclear`, `mobile_missing`, `address_uncertain`, and `identity_number_uncertain`; no fields were extracted and draft mapping was rejected. Address MATCH was only because the reviewed draft had no address. The saved WP10 result lacked `ok` and `words_result_num`, so MUSE wrapped its existing `words_result` in memory with `ok: true` and omitted the optional count; the saved file was unchanged. MUSE reported zero OCR reruns, Baidu calls, iCloud MCP calls, contacts operations, production-code execution, or production changes. Production remained 0.5.0 at the same commit and source hashes before/after; the isolated worktree was clean and no MUSE commit/push was made.
- 30-card acceptance: BLOCKED; fewer than 30 samples, authorization remains unconfirmed, and reference annotations are incomplete. Do not access new samples.
- Production: MUSE reported package 0.5.0; no package pin, production file, or configuration was changed. This 0.9.0 candidate is not v1.0 Stable and is not approved for deployment.
- Acceptance: the protected replay still fails. Earlier WP11-D aggregate geometry diagnosis found no unique field candidate to support loosening the current geometry rules. The 30-card set remains separately blocked pending explicit authorization and complete reference annotations.

## WP11-F same-row identity candidate repair

- Date: 2026-11-03
- Package candidate: 0.10.0
- Development branch: `codex/wp11-family-card-table-parser-20261103`
- Evidence: MUSE's value-free diagnosis on the same authorized WP10 result and exact 0.9.0 worktree found one complete ID-shaped candidate before the family boundary; it passed the existing checksum/date validation, had no invalid full-shaped competitor, shared the unique explicit ID label's visual row, and was not its immediate right neighbor. No distinct checksum-valid multi-block candidate or ambiguous-character composite was found. The candidate competed with another field label, which is why the generic geometry matcher rejected it.
- Reuse/adapt/avoid: reuse the existing OCR block/box model, row clustering, checksum validator, and review gate; adapt only the ID field with an exact-one-block, exact-one-pure-label, same-row, valid-checksum, unambiguous-character condition. Explicit ID evidence disables the fallback. Full ID-shaped blocks are excluded from other fields' spatial candidates. Avoid generic column-margin changes, larger search windows for other fields, a second OCR/table model, and new dependencies. GitHub code search returned no relevant maintained parser and only unrelated content; this is weak reuse evidence, so the repair remains local.
- Added synthetic cases: unique same-row non-neighbor ID is accepted; two complete ID blocks, invalid checksum, multiple ID labels, or ambiguous OCR characters remain under review; short address fragments on separate rows are not combined.
- Local verification: Python 3.14.7 / Pillow 12.2.0; targeted table-layout suite PASS — 24/24; full offline suite PASS — 123/123; `git diff --check` PASS.
- MUSE exact-commit retest: PASS for the isolated offline and synthetic suites at code commit `e129c80e2d8b35ed667a5b4f2335007543a2c4d0` (package 0.10.0). MUSE used a new detached worktree and venv with Python 3.12.3 / Pillow 10.2.0; all 123/123 tests passed and the synthetic suite passed. MUSE fetched only the target branch once to obtain the exact commit, verified its SHA, then completed checks offline.
- Protected WP10 replay: FAIL acceptance. Using only the same existing 89-block structured result and reviewed reference, the replay returned `REVIEW_REQUIRED` with `table_layout_uncertain`, `main_customer_identity_unclear`, `mobile_missing`, and `address_uncertain`; draft mapping was rejected. Name, mobile, birthday, and gender were absent and MISMATCH. The identity number was present, but MUSE's value-free follow-up confirmed the reviewed ID reference was unavailable in the authorized workspace, so exact comparison remains UNKNOWN; the reference was not reacquired. Its prior uncertainty reason is no longer reported. Address was absent and MATCH only because the reviewed draft also omitted it; this does not establish extraction of the card address.
- Replay adaptation and integrity: the stored WP10 JSON lacks `ok` and `words_result_num`; MUSE added `ok: true` only in an in-memory wrapper and skipped the absent optional count. This was structured-block replay, not byte-for-byte response-envelope validation. The original payload was unchanged; the isolated worktree was clean at the tested commit.
- Isolation checks: MUSE reported one narrow fetch of the authorized target branch; zero other network access, OCR reruns, Baidu calls, iCloud/contacts operations, production-code execution, production changes, commits, or pushes. Production remained package 0.5.0 at commit `8336008d080387ab709d1e0ab9381683b1138e0f`; production source hashes matched before/after.
- Production and acceptance: production remains 0.5.0 and unchanged. The 30-card gate remains blocked by unconfirmed authorization and incomplete reference annotations. Candidate 0.10.0 is not v1.0 Stable and must not be deployed.

## WP11-G same-row address candidate repair

- Date: 2026-11-03
- Package candidate: 0.11.0
- Development branch: `codex/wp11-family-card-table-parser-20261103`
- Reuse / adapt / avoid: reuse the existing Baidu `OcrBlock`/`BoundingBox` model, visual-row clustering, nearest-column gate, address minimum-length and character-ambiguity checks, and review decision. Adapt only the address field with a same-row search beyond the immediate right block, requiring one pure address label and exactly one distinct candidate that passes both column and address checks. The path rejects mobile-shaped and identity-shaped strings and never searches another visual row. If current parsed evidence consists of short, unambiguous fragments, the single valid candidate replaces those fragments. Ambiguous candidates, ties, multiple distinct valid candidates, or conflicting existing values remain under review. Generic same-row expansion for all fields was avoided because the WP10 evidence supports no safe candidate for name, mobile, birthday, other phone, or gender. GitHub searches for coordinate-based OCR label/value parsing returned unrelated matches; no mature compatible parser was found, so this remains a dependency-free local adaptation.
- MUSE value-free diagnostic: using only the existing 0.10.0 worktree and the same WP10 structured result, MUSE corrected its earlier inconsistent aggregate. In the parser's current direct-right/next-row candidate set, 2+ candidates passed the column gate, none passed the address length threshold, no OCR-character ambiguity was counted, and the values entered spatial evidence but were rejected by the minimum-length gate. In the same-row set beyond the immediate right block, 2+ candidates passed the column gate and exactly one distinct candidate passed both length and character checks; it was absent from final evidence because that search is not yet implemented. No reviewed reference was accessed; the prior draft omitted address, so address correctness remains unknown. No files, production state, samples, or external services were accessed or changed by this diagnostic.
- Local change: implement the bounded address-only rescue. Name, mobile, birthday, other-phone, gender, and ID search behavior is unchanged. Address stays optional; this change cannot make a draft READY while required fields are missing.
- Synthetic regressions: one valid unique same-row non-neighbor address is accepted; multiple distinct valid values, ambiguous characters, and a value assigned to another field's column are rejected.
- Local verification: Python 3.14.7 / Pillow 12.2.0; package metadata 0.11.0; targeted table-layout tests PASS — 28/28; full offline suite PASS — 127 tests, 0 failures, 0 errors; `git diff --check` PASS.
- Test data and external boundary: fictional strings and synthetic coordinates only; no real OCR/contact payload or reference used locally. MUSE later replayed only the already-authorized structured result. No local OCR, Baidu, iCloud, contacts, production execution, or production change occurred.
- MUSE exact-commit retest: PASS for offline verification at commit `180f6333046b830010d60338edb580b23c03927c` (package 0.11.0). In a fresh detached worktree/venv (Python 3.12.3, Pillow 10.2.0), MUSE passed 127/127 tests. It fetched only the authorized target branch once to obtain the exact commit, verified the SHA, then performed all checks offline. The replay used only the same authorized 89-block WP10 structured result; the stored JSON lacked `ok` and `words_result_num`, so MUSE supplied `ok: true` only in an in-memory wrapper and skipped the absent optional count. This does not validate the original response envelope byte-for-byte.
- Protected WP10 replay: FAIL acceptance. The decision remained `REVIEW_REQUIRED` with `table_layout_uncertain`, `main_customer_identity_unclear`, `mobile_missing`, `address_conflict`, and `address_uncertain`; draft mapping was rejected. Name, mobile, birthday, gender, address, and other-phone fields were absent; the ID field was present. MUSE did not read the reviewed reference or compare field values in this run. The detailed follow-up below shows why the address rescue correctly remained uncertain; no address correctness or reference match is established.
- Isolation and integrity: MUSE reported one narrow target-branch fetch, then zero other network access, OCR reruns, Baidu calls, reference reads, iCloud/contacts operations, production-code execution, production changes, commits, or pushes. The original payload's size, permissions, and hash comparison were unchanged; the isolated worktree was clean at the tested commit. Production remained package 0.5.0 at `8336008d080387ab709d1e0ab9381683b1138e0f`; read-only source hashes matched before and after.
- MUSE same-input address diagnostic: `allow_address_rescue=true`; line-format address evidence count was zero; exactly one pure address label existed and the rescue ran. The expanded scan considered seven blocks; five remained after field-label exclusion, and two remained after length and phone/identity-shape checks. One candidate passed column assignment and address content checks. A second distinct candidate passed the address length and character checks, but its column center was near-tied and it was closer to another field label; existing geometry still could not assign it uniquely to that field. This ambiguity set the rescue uncertainty flag and prevented the valid representative from being appended. Existing direct/next-row evidence contained two distinct address candidates, so the final address stayed absent with `address_conflict` and `address_uncertain`. The actual first rescue gate was `address_candidate_uncertain`.
- MUSE classified the second candidate's ambiguity as a near tie, not label-box overlap. It was distinct from the accepted representative and independently address-valid. Filtering it by proximity would choose between two valid distinct candidates without unique geometry; that would weaken the current correctness gate. Decision: keep the fail-closed review behavior and make no parser change from this sample. The diagnostic did not access a reference, new sample, network, OCR, Baidu, iCloud/contacts, production code, or production state; the existing payload and 0.11.0 worktree remained unchanged and clean.
- 0.11.0 is not v1.0 Stable and must not be deployed. The 30-card set remains gated by unconfirmed authorization and incomplete reference annotations.
