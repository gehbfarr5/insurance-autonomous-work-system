# MUSE customer-card Baidu OCR tool

Status: version 0.1.0. Offline Mock tests are the only verification completed here. MUSE cloud and a real Baidu API call have not been tested. This package does not implement Agent field extraction, batch state, contact lookup, or iCloud writes.

## Reuse and implementation choice

- Reuse the historical ocr_baidu.py Baidu handwriting endpoint, Requests form request, small character granularity, line confidence request, and AK/SK-to-token flow.
- Adapt the input from file paths to JPEG/PNG bytes or a constrained local attachment path. Preserve returned text blocks, coordinates, character candidates, and confidence. Keep the token only in the client process.
- Reuse and tighten the old Pillow EXIF correction, max-side resize, and JPEG encoding. HEIC is rejected; this package does not silently tolerate missing HEIF support.
- Avoid a Baidu SDK, DeepSeek, web server, database, or MCP server. The direct HTTP call is a small, already-used integration. Requests and Pillow are the only runtime dependencies.
- Baidu's current handwriting API documentation specifies a 4096px maximum side and an 8 MiB maximum URL-encoded image request body. It also documents character candidates/confidence for small and line confidence for probability=true. The package checks the minimum side as 15px. [Baidu handwriting OCR API](https://ai.baidu.com/ai-doc/OCR/hk3h7y2qq)
- Baidu's OAuth documentation requires AK/SK as token-request URL parameters, and the OCR API requires access_token as a URL parameter. The client follows those protocol requirements; it never logs request URLs, bodies, headers, or provider responses. Keep HTTP debug logging disabled in the MUSE runtime because transport-level debug traces can include request query strings. [Baidu OAuth access token](https://ai.baidu.com/ai-doc/REFERENCE/Lkru0zoz4)

## Privacy gate

This package does not include a family-card template detector or masking algorithm. Existing evidence does not prove that the identity-number field and lower family/policy sections can be excluded for every rotation, skew, scale, and table offset.

The recognize_customer_card function therefore requires a PrivacyMaskResult with an image derived from the exact source SHA-256, a reviewed policy ID, and redaction declarations for identity number, family-member data, policy data, and premium data. An absent, unverified, mismatched, or incomplete mask raises PRIVACY_MASK_UNVERIFIED before token retrieval or OCR.

There is currently no family-card masker that can produce a production VERIFIED result. Unit tests use generated blank JPEG/PNG images and a synthetic mask contract to test the API guard. This is not a real-template privacy test and does not make real family cards production-ready.

## Input and output

    from pathlib import Path
    from muse_customer_card_ocr import recognize_customer_card

    result = recognize_customer_card(
        Path.home() / "workspace/user/files/attachment.jpg",
        mime_type="image/jpeg",
        privacy_mask=reviewed_mask_result,
    )
    payload = result.to_dict()  # Contains OCR text; keep it transient for Agent use.

Paths must resolve under ~/workspace/user/files by default. Tests may pass an explicit allowed_root. The package reads but does not delete attachment files, create image copies, write OCR JSON, or persist results.

The result retains actual Baidu line text, coordinates, confidence, and optional character/candidate details. Coordinates are relative to the normalized JPEG sent to Baidu; the result includes that JPEG's dimensions. Missing provider fields stay absent; the client does not invent coordinates or scores.

Errors are classified in OcrError.code and OcrError.as_dict(). They do not expose provider response bodies, image paths, OCR text, tokens, or AK/SK. The to_dict method intentionally returns OCR text; do not write it to ordinary logs, traces, or long-lived task state.

## Offline install and tests

Python 3.10+. Runtime dependencies: Pillow and Requests. Tests use unittest and Mock responses only:

    cd integrations/muse-customer-card-ocr
    python3 -m venv .venv
    source .venv/bin/activate
    python -m pip install -e .
    python -m unittest discover -s tests -v

## MUSE cloud handoff

Codex has not established a MUSE shell session. This turn does not modify the MUSE VM, SDK Bridge, or automations. MUSE should perform these steps in its own environment:

1. Fetch branch codex/wp2-muse-customer-card-ocr and locate integrations/muse-customer-card-ocr. Confirm Python 3.12.x. Use an isolated venv so the existing Pillow installation is not upgraded:

       python3 -m venv ~/workspace/.venvs/muse-customer-card-ocr
       source ~/workspace/.venvs/muse-customer-card-ocr/bin/activate
       python -m pip install "Pillow==10.2.0" "requests>=2.31,<3"
       python -m pip install --no-deps -e /path/to/repo/integrations/muse-customer-card-ocr

2. Run the offline tests first. Confirm imports, attachment-root checks, and that PRIVACY_MASK_UNVERIFIED sends no HTTP request.
3. Only after the organization approves Baidu processing, confirms quota/cost, and separately authorizes a call, add BAIDU_OCR_AK and BAIDU_OCR_SK through MUSE's protected environment-variable facility. Do not put values in shell history, the repository, ordinary config files, or logs. The exact MUSE secret-management surface was not available to Codex. The client disables ambient Requests proxy inheritance so customer images cannot silently route through an unreviewed proxy.
4. For a real API smoke call, MUSE must generate a fully synthetic image that contains no real personal data, construct a synthetic-only mask result for that image, and perform one call. Verify token acquisition, one handwriting OCR request, result parsing, and error classification. Never label a real customer image synthetic-only.
5. The package creates no image copies or persistent OCR files. Close the client after use. Do not delete MUSE's original attachment; if MUSE creates a temporary copy, the calling workflow owns its cleanup.
6. A successful synthetic API call verifies MUSE network, credentials, and Baidu API use. It does not verify family-card field accuracy or the privacy mask.

For the one-call smoke, this snippet creates a blank synthetic PNG in memory and prints only status and counts. Run it only after separate authorization for a billed Baidu test and secure credential configuration:

    import io
    from PIL import Image
    from muse_customer_card_ocr import (
        MaskStatus,
        PrivacyMaskResult,
        REQUIRED_REDACTED_REGIONS,
        recognize_customer_card,
        source_sha256,
    )

    buffer = io.BytesIO()
    Image.new("RGB", (320, 120), "white").save(buffer, format="PNG")
    synthetic_image = buffer.getvalue()
    synthetic_mask = PrivacyMaskResult(
        status=MaskStatus.VERIFIED,
        source_sha256=source_sha256(synthetic_image),
        masked_image_bytes=synthetic_image,
        masked_mime_type="image/png",
        policy_id="synthetic-smoke-only",
        redacted_regions=REQUIRED_REDACTED_REGIONS,
    )
    result = recognize_customer_card(
        synthetic_image,
        mime_type="image/png",
        privacy_mask=synthetic_mask,
    )
    print({"status": result.status, "block_count": len(result.blocks)})

## Rollback

Remove the isolated venv and this package directory, then remove only this tool's dedicated Baidu variables from MUSE's protected environment. This does not change SDK Bridge, iCloud credentials, user attachments, or the Seoul MCP. The package has no background process, database, or service.
