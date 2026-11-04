# WP11-Q3: protected reviewed-reference comparison for the same WP10 card

**Task state:** READY. Execute only in the existing Family Card MUSE conversation, 执行WP11离线验证任务.

## Explicit authorization and scope

On 2026-11-04 the user explicitly authorized MUSE to read the reviewed reference for the same existing WP10 Family Card record in MUSE's protected workspace and compare it with the previously authorized WP10 structured OCR result. The user authorized only a value-free result containing field-level `MATCH` / `MISMATCH` / `NOT_CHECKED` states. Do not return any field value, OCR text, image, geometry, screenshot, identifier, or free-text customer information, and do not copy the reference or OCR values into GitHub.

This approval does not include another card, sample inventory, the 30-card set, other workspaces, or contact/iCloud records. Look only for the reviewed reference associated with the same existing WP10 record. If it is absent, ambiguous, or not accessible in that protected record, report `BLOCKED`; do not search broader locations or reconstruct annotations.

## Exact candidate

- Repository: https://github.com/gehbfarr5/insurance-autonomous-work-system
- Branch: `codex/wp11-family-card-table-parser-20261103`
- Candidate commit: `0b162686fe6a8cfa29cda7dfcd224976339746f4`
- Package: `muse-customer-card-ocr` 0.13.2
- Parser SHA-256: `420a1b21d0df9d6f1f75460559d2fd8ee87cfec2805ca326928dd268b213d147`
- Prior exact-candidate offline evidence: WP11-P/Q, 148/148 pass with nine synthetic guard assertions true. Do not rerun the suite.

## Procedure

1. Fetch only the authorized branch once if the exact commit is not already available. Verify the exact commit, package version, parser hash, isolated import path, and use a clean detached worktree and isolated virtual environment. Reuse the prior environment pins (Ubuntu 24.04.5, Python 3.12.3, Pillow 12.3.0) if available; otherwise report `BLOCKED` rather than substituting an unverified runtime.
2. In the protected workspace, read at most once each: (a) the same WP10 structured OCR result used in WP11-Q2, and (b) its corresponding reviewed reference. Do not open the card image or call OCR/provider services.
3. Run only the exact 0.13.2 parser/extraction path once and compare its output to the same-record reviewed annotations. Use only normalization already performed by the candidate parser; do not fuzzy-match, infer values, use an ID checksum as a match, or infer gender. For multiple other-phone values, require exact set agreement after the parser's existing normalization. Mark a field `NOT_CHECKED` if its reviewed annotation is missing or ambiguous; `NOT_APPLICABLE` only when the reviewed annotation explicitly establishes that an optional field is absent. A missing parser candidate against a reviewed-present field is `MISMATCH`.
4. The WP10 candidate already maps to `REVIEW_REQUIRED` / rejected draft. This is field-comparison evidence only, not a released-draft accuracy pass and not production acceptance.
5. Return only JSON matching `wp11q3-muse-wp10-reviewed-reference-compare-result-template-20261104.json`. No raw values, text, geometry, screenshots, identifiers, or free-text notes.

## Boundaries

- No other card, image, sample inventory, reference, or workspace reads.
- No OCR, Seoul/Baidu/provider, MCP, iCloud, contact, login, or production calls.
- No source/config changes, tests, deployment, exports, MUSE commits, or pushes.
- Do not mark v1.0 accuracy acceptance from a one-card comparison; the 30-card authorization and metrics gates remain separate.
