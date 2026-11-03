#!/usr/bin/env python3
"""Seoul OCR -> field parsing -> complete iCloud duplicate search only.

This entry point never creates, updates, or deletes a contact. It requires an
explicit full-image authorization attestation and keeps OCR/contact values out
of stdout. A search response that is absent, malformed, or possibly truncated
stops before any create decision.
"""
from __future__ import annotations

import argparse
import os
import sys
import uuid
from pathlib import Path
from typing import Any


def _add_configured_source() -> None:
    source = os.environ.get("MUSE_CUSTOMER_CARD_OCR_SRC")
    if source:
        source_path = Path(source).expanduser().resolve()
        if not (source_path / "muse_customer_card_ocr" / "__init__.py").is_file():
            raise RuntimeError("OCR_PACKAGE_PATH_INVALID")
        sys.path.insert(0, str(source_path))
    client_source = os.environ.get("MUSE_CARD_DAV_MCP_CLIENT_SRC")
    if client_source:
        client_path = Path(client_source).expanduser().resolve()
        if not (client_path / "mcp_client.py").is_file():
            raise RuntimeError("MCP_CLIENT_PATH_INVALID")
        sys.path.insert(0, str(client_path))


_add_configured_source()

from PIL import Image  # noqa: E402
import mcp_client  # noqa: E402
from muse_customer_card_ocr import (  # noqa: E402
    OcrResult,
    RuntimeContractError,
    decide_contact_duplicate,
    decode_mcp_tool_result,
    extract_primary_customer,
    normalize_mobile_number,
    parse_seoul_ocr_response,
    run_seoul_ocr,
    validate_contacts_search_result,
)


def mcp_call(tool: str, arguments: dict[str, Any], msg_id: int) -> dict[str, Any]:
    envelope = mcp_client._mcp_call_resilient(
        "tools/call", {"name": tool, "arguments": arguments}, msg_id
    )
    if envelope is None:
        raise RuntimeContractError("MCP_CALL_FAILED")
    return decode_mcp_tool_result(envelope)


def dedup_decision(
    name: str,
    mobile: str,
    name_results: tuple[dict[str, Any], ...],
    mobile_results: tuple[dict[str, Any], ...],
) -> tuple[str, int]:
    return decide_contact_duplicate(name, mobile, name_results, mobile_results)


def _safe_code(error: Exception) -> str:
    code = getattr(error, "code", None)
    if isinstance(code, str) and code.replace("_", "").isalnum():
        return code
    return type(error).__name__


def main(argv: list[str] | None = None, *, ocr_runner=run_seoul_ocr) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("image")
    parser.add_argument("--full-image-authorized", action="store_true")
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
            print("OCR_STOP: SEOUL_OCR_FAILED")
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
        print("OCR_BLOCK_COUNT:", len(blocks))
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
        if extraction.status != "ready" or extraction.review_reasons:
            print("DEDUP_DECISION: MANUAL_REVIEW")
            print("ICLOUD_SEARCH_RUN: False")
            return 0

        login = mcp_call("apple_login", {}, 60)
        session_id = login.get("session_id")
        capabilities = login.get("capabilities")
        if (
            not isinstance(session_id, str)
            or not session_id
            or not isinstance(capabilities, dict)
            or capabilities.get("contactsRead") is not True
        ):
            raise RuntimeContractError("CONTACTS_READ_NOT_AVAILABLE")

        name_results = validate_contacts_search_result(
            mcp_call(
                "contacts_search",
                {"session_id": session_id, "query": fields.name, "limit": 50},
                61,
            )
        )
        mobile_results = validate_contacts_search_result(
            mcp_call(
                "contacts_search",
                {"session_id": session_id, "query": fields.mobile, "limit": 50},
                62,
            )
        )
        decision, candidate_count = dedup_decision(
            fields.name, fields.mobile, name_results, mobile_results
        )
        print("PRE_NAME_COUNT:", len(name_results))
        print("PRE_MOBILE_COUNT:", len(mobile_results))
        print("PRE_UNIQUE_CANDIDATES:", candidate_count)
        print("DEDUP_DECISION:", decision)
        print("ICLOUD_SEARCH_RUN: True")
        return 0
    except Exception as exc:
        print("WP10_STOP:", _safe_code(exc))
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
