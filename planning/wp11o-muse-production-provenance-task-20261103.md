# WP11-O MUSE production source and deployment provenance audit

**State:** `IN_PROGRESS`. WP11-M/N confirmed that the 0.12.0 parser candidate still returns `REVIEW_REQUIRED`. The local package README says the active MUSE runtime and deployment binding are unknown. WP11-K previously found a package 0.5.0 source checkout and four untracked workspace copies, but did not bind those copies to a running runtime. This task refreshes that evidence with a read-only source/provenance audit; it is not a deployment or production acceptance run.

## Scope and boundaries

- Inspect only read-only package metadata, Git provenance, source files, deployment/release manifests, process metadata, and existing runtime-binding metadata that are available through the authorized MUSE workspace.
- Identify whether the inspected source is the actual active MUSE runtime, a package checkout, a local workspace copy, or an unbound snapshot. Distinguish source files from installed package metadata and from a live deployment. Bind claims to an explicit manifest, image/release digest, commit, or runtime metadata; otherwise return `UNKNOWN`.
- Verify whether the bound production path is configured for the existing Seoul OCR service, preserves OCR text/geometry/probability/character candidates into the parser, separates primary customer from family sections, and implements duplicate search, field-level edit/review UI, explicit pre-create confirmation, create/retry handling, readback, recovery, rollback, and privacy-safe logging.
- Report only component statuses, relative file paths, file SHA-256 digests, versions/commits/hashes, fixed reason codes, and short sanitized findings. Do not include code excerpts, private hostnames/IPs, URLs with credentials, API keys, tokens, passwords, contact/customer values, OCR text, images, logs, or configuration values.
- Do not inspect contact records, the WP10 artifact/reference, new samples, the 30-card inventory, images, OCR results, or account credentials. Do not log in, call OCR/Baidu, call iCloud/contact tools, execute production code, alter configuration, write production state, deploy, commit, push, or export source/data.
- If no read-only path can establish active source binding, stop that component at `UNKNOWN`; do not infer production behavior from the candidate branch or from earlier untracked workspace copies.

## Procedure

1. Resolve the current pushed branch HEAD and package version for task identity. In MUSE, record the audit timestamp and environment without reading secrets.
2. Locate the MUSE package source checkout and any installed-package metadata. Record version, commit, worktree state, and relevant file hashes.
3. Locate actual runtime/deployment identity and source binding. Inspect only read-only manifests or metadata. If the running runtime cannot be tied to a source tree or immutable release hash, mark the binding and runtime findings `UNKNOWN`.
4. For each required workflow component in the result template, inspect the smallest source surface needed and record whether it is verified in the bound runtime, present only in an unbound source copy, absent from inspected source, or unknown.
5. Verify the OCR route as `SEOUL_SERVICE`, `DIRECT_BAIDU`, `MUSE_VAULT`, or `UNKNOWN`; do not invoke any route. Do not reproduce secrets or endpoint values.
6. Return only the JSON structure in [`wp11o-muse-production-provenance-result-template-20261103.json`](wp11o-muse-production-provenance-result-template-20261103.json). Record observed reads and zero-side-effect operation counts.

## Decision and rollback

Two evidence paths were considered: carry forward the earlier WP11-K package/workspace inventory (no new access, but potentially stale and still unbound), or repeat the smallest available read-only source and deployment inspection (bounded metadata/code reads, no runtime execution or user-data access). The second is selected because the goal requires current production evidence. This audit makes no deployment or source change. Rollback is not applicable; if a read path requests authentication, user data, or a write, stop and record that specific component as `UNKNOWN`.
