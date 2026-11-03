# WP11-L MUSE handoff: 30-card OCR acceptance

**Current state:** `VALIDATION_PENDING`. The request for authorization to use the real-card set has not been answered. This handoff is prepared only; it has not been sent to MUSE or executed. No sample inventory, image, or reference label was accessed for this task.

Copy the task below to MUSE only after the user has explicitly authorized the real-card work. If it is forwarded before authorization, MUSE may run the isolated, data-free checks and must stop before inspecting any real-data inventory.

```text
Task: WP11-L MUSE 30-card OCR acceptance preparation and gated validation

Candidate:
- Repository: https://github.com/gehbfarr5/insurance-autonomous-work-system
- Branch: codex/wp11-family-card-table-parser-20261103
- Package: muse-customer-card-ocr 0.12.0
- At execution, resolve the branch's current full HEAD SHA, record it, and use that exact SHA in a clean detached worktree.

Safety boundary:
- The user has not yet authorized access to the 30-card set in the current handoff. Do not inspect, enumerate, open, hash, classify, OCR, or read any real card or reference label unless an explicit affirmative authorization is available for this work.
- If authorization is absent, perform only the isolated offline checks below, then return the result wrapper with real_card_validation.status = "BLOCKED", reason code REAL_DATA_AUTHORIZATION_NOT_CONFIRMED, and all real-data operation counts at 0. Do not check whether the set exists or how many cards it contains.
- Even after authorization, do not use iCloud login or contact tools, search/create/read/delete contacts, change production, deploy, or export images, OCR text, reviewed labels, per-card values, identifiers, or populated input files. Only the existing Seoul OCR path is in scope if a fresh OCR pass is needed and included in the authorization. Never call Baidu directly from MUSE.
- Keep the source images, OCR response, and reviewed reference labels inside the protected MUSE validation workspace. Do not print their values or include them in stdout/stderr, ordinary logs, GitHub, or the returned result.

Data-free isolated checks (may be performed without real-data authorization):
1. Fetch only the authorized feature branch, verify the exact commit above, and create a clean detached worktree and isolated virtual environment. Do not import the production environment or modify a MUSE production checkout.
2. Record the Python and Pillow versions. Run the complete package suite from integrations/muse-customer-card-ocr:
   PYTHONPATH=src python3 -m unittest discover -s tests -q
   Expected at this commit: 143 tests. Report actual counts; do not substitute the expected count for the observed result.
3. Run the aggregator against the blank template:
   PYTHONPATH=src python3 -m muse_customer_card_ocr.acceptance_metrics ../../planning/wp11-30-card-acceptance-input-template-20261103.json
   Expected: exit 0, real_card_ocr_result = BLOCKED, authorization/distinctness/reference gates false, and all sample counts null. This must make zero OCR/provider/contact calls.

Real-card validation (do not start unless explicitly authorized):
1. Before opening any sample, confirm the authorization covers the existing set, comparison against reviewed labels, and one Seoul/Baidu OCR pass per image only where no matching authorized OCR result already exists. If authorization is absent or ambiguous, stop with BLOCKED and no data access.
2. In the protected workspace, confirm at least 30 different authorized in-scope cards and complete, human-reviewed reference annotations. If either condition fails, stop before OCR and return BLOCKED. Do not exclude a difficult or failed OCR sample after seeing its output; decide eligibility before OCR. Count all in-scope cards, including low-quality or parser-failing examples, as eligible. Exclude only duplicate, out-of-scope, or corrupt-before-OCR items using the fixed reason codes.
3. Reuse a matching, previously authorized Seoul OCR response when available. Otherwise make one OCR request for that sample through the existing Seoul service path. Preserve the structured coordinates/confidence/character metadata and run the exact candidate parser from this branch. Do not change parser rules, add a line-text fallback, infer birthday from identity number, infer gender, or relax ambiguity gates during this validation.
4. Compare output only with reviewed labels inside the protected workspace. For each eligible card, record only the booleans `auto_usable_draft`, `manual_review_required`, and `released_for_confirmation`; field accuracy states for main_customer, name, mobile, identity_number, gender, explicit_birthday, address, and other_phone; and closed failure codes from `acceptance_metrics.py`. Do not include sample IDs or field values. For a draft classified as ready for ordinary confirmation, compare its final candidate values with the reviewed labels; this classification does not claim that a live MUSE review UI was exercised. A missing optional value is PASS only when the reviewed label confirms it should be absent. Use NOT_TESTED when comparison was not made. The evaluation does not submit confirmation or create a contact.
5. Save the populated boolean/status input only in the protected MUSE workspace. Run the aggregator from the package directory:
   PYTHONPATH=src python3 -m muse_customer_card_ocr.acceptance_metrics /protected/path/30-card-results.json
   Return its aggregate JSON in the result wrapper. Do not export the populated input.

Acceptance interpretation:
- Require at least 30 eligible distinct cards plus all authorization, distinctness, and reference-review gates.
- Auto-usable draft rate = auto_usable_draft true / eligible samples; target >= 90%.
- Manual-review-required rate = manual_review_required true / eligible samples; report exact numerator and denominator.
- Main-customer selection, name, mobile, and identity-number accuracy each use every released-for-confirmation draft as the denominator; target 100%. NOT_TESTED stays in the denominator and cannot be counted correct.
- The aggregator's PASS is only for this OCR/label metric scope. Duplicate misses, unconfirmed creation, overwrite/delete, readback, live MUSE UI, production provenance, deployment, and rollback are separate gates and must remain NOT_TESTED here. Overall product status remains VALIDATION_PENDING.

Return only the JSON object in planning/wp11-30-card-muse-result-template-20261103.json, updated with the observed offline evidence, operation counts, and (only if authorized and run) aggregate output. Do not add free-text notes containing customer data.
```
