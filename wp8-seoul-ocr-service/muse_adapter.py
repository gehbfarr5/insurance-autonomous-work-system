#!/usr/bin/env python3
"""Run the existing Seoul OCR service and report only safe extraction status.

The caller must pass ``--full-image-authorized`` for every OCR run. This is an
explicit workflow attestation; it does not perform an authorization check.
OCR blocks are parsed by the package adapter so Baidu geometry, confidence,
and character candidates reach the table parser unchanged.
"""
from __future__ import annotations

import argparse
import os
import sys
import uuid
from pathlib import Path
from typing import Any


def _add_configured_package_path() -> None:
    source = os.environ.get("MUSE_CUSTOMER_CARD_OCR_SRC")
    if not source:
        return
    source_path = Path(source).expanduser().resolve()
    if not (source_path / "muse_customer_card_ocr" / "__init__.py").is_file():
        raise RuntimeError("OCR_PACKAGE_PATH_INVALID")
    sys.path.insert(0, str(source_path))


_add_configured_package_path()

from PIL import Image  # noqa: E402
from muse_customer_card_ocr import (  # noqa: E402
    ManualReviewRequiredError,
    OcrResult,
    extract_primary_customer,
    map_to_icloud_fields,
    parse_seoul_ocr_response,
    run_seoul_ocr,
)


def _safe_error_code(error: Exception) -> str:
    code = getattr(error, "code", None)
    if isinstance(code, str) and code.replace("_", "").isalnum():
        return code
    return type(error).__name__


def main(argv: list[str] | None = None, *, ocr_runner=run_seoul_ocr) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("image")
    parser.add_argument(
        "--full-image-authorized",
        action="store_true",
        help="attest that the current workflow is authorized to send the full image",
    )
    args = parser.parse_args(argv)
    if not args.full_image_authorized:
        print("OCR_STOP: FULL_IMAGE_AUTHORIZATION_REQUIRED")
        return 2

    try:
        image_path = Path(args.image)
        image_bytes = image_path.read_bytes()
        with Image.open(image_path) as image:
            width, height = image.size
            mime_type = "image/png" if image.format == "PNG" else "image/jpeg"
        payload = ocr_runner(image_bytes)
        if payload.get("ok") is not True:
            print("SEOUL_OCR_FAILED")
            return 1
        blocks = parse_seoul_ocr_response(payload, request_id=uuid.uuid4().hex)
        result = OcrResult(
            status="success",
            blocks=blocks,
            request_id=uuid.uuid4().hex,
            service_log_id=None,
            image_mime_type=mime_type,
            image_width=width,
            image_height=height,
            upload_mode="seoul_ocr_service_full_image_authorized",
        )
        extraction = extract_primary_customer(result)
        print("EXTRACTION_STATUS:", extraction.status)
        print("REVIEW_REASONS:", [reason.value for reason in extraction.review_reasons])
        fields = extraction.fields
        print("NAME_PRESENT:", bool(fields.name))
        print("MOBILE_PRESENT:", bool(fields.mobile))
        print("BIRTHDAY_PRESENT:", fields.birthday is not None)
        print("GENDER_PRESENT:", fields.gender is not None)
        print("ID_PRESENT:", bool(fields.identity_number))
        print("ADDRESS_PRESENT:", bool(fields.address))
        print("OTHER_PHONE_COUNT:", len(fields.other_phones))
        try:
            map_to_icloud_fields(extraction)
            print("CONTACT_DRAFT_STATUS: READY_FOR_USER_REVIEW")
        except ManualReviewRequiredError:
            print("CONTACT_DRAFT_STATUS: REVIEW_REQUIRED")
        return 0
    except Exception as exc:
        print("OCR_STOP:", _safe_error_code(exc))
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
