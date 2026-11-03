#!/usr/bin/env python3
"""Create one explicitly confirmed contact, then verify the complete readback.

Input is one JSON object on stdin with extraction_status READY or
MANUALLY_REVIEWED, review_status USER_CONFIRMED, and reviewed fields. An
uncertain create/readback leaves a minimal pending operation in protected
local state; a known contact ID is retained only until readback completes.
The next create is blocked until readback or manual reconciliation completes.
"""
from __future__ import annotations

import json
import os
import sys
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

import mcp_client  # noqa: E402
from muse_customer_card_ocr import (  # noqa: E402
    CreateAttemptError,
    CreateAttemptJournal,
    RuntimeContractError,
    decide_contact_duplicate,
    decode_mcp_tool_result,
    parse_confirmed_draft,
    validate_contacts_search_result,
    verify_contact_readback,
)


def mcp_call(tool: str, arguments: dict[str, Any], msg_id: int) -> dict[str, Any]:
    envelope = mcp_client._mcp_call_resilient(
        "tools/call", {"name": tool, "arguments": arguments}, msg_id
    )
    if envelope is None:
        raise RuntimeContractError("MCP_CALL_FAILED")
    return decode_mcp_tool_result(envelope)


def _contact_id(response: dict[str, Any]) -> str | None:
    raw = response.get("contact_id") or response.get("id")
    if raw is None and isinstance(response.get("contact"), dict):
        nested = response["contact"]
        raw = nested.get("contact_id") or nested.get("id")
    if isinstance(raw, str) and raw.strip():
        return raw
    if isinstance(raw, int) and not isinstance(raw, bool):
        return str(raw)
    return None


def _create_contact(draft: dict[str, Any], session_id: str) -> dict[str, Any]:
    phones: list[dict[str, Any]] = [
        {"value": draft["mobile"], "type": ["cell"], "primary": True}
    ]
    phones.extend(
        {"value": phone, "type": ["other"], "primary": False}
        for phone in draft["other_phones"]
    )
    contact: dict[str, Any] = {
        "name": {"full": draft["name"]},
        "phones": phones,
        "birthday": draft["birthday"],
        "note": f"性别：{draft['gender']}\n身份证号：{draft['identity_number']}",
    }
    if draft["address"] is not None:
        contact["addresses"] = [{"street": draft["address"]}]
    return {"session_id": session_id, "contact": contact}


def _resolve_pending(data: Any) -> int:
    if (
        not isinstance(data, dict)
        or data.get("manual_reconciliation_confirmed") is not True
        or not isinstance(data.get("operation_id"), str)
        or not isinstance(data.get("resolution"), str)
    ):
        raise RuntimeContractError("MANUAL_RECONCILIATION_CONFIRMATION_REQUIRED")
    with CreateAttemptJournal() as journal:
        journal.resolve_pending(data["operation_id"], data["resolution"])
    print("PENDING_CREATE_RESOLVED:", data["resolution"])
    return 0


def _resume_pending_readback(data: Any) -> int:
    if not isinstance(data, dict) or not isinstance(data.get("operation_id"), str):
        raise RuntimeContractError("PENDING_OPERATION_ID_REQUIRED")
    draft = parse_confirmed_draft(data)
    operation_id = data["operation_id"]
    with CreateAttemptJournal() as journal:
        pending = journal.pending
        if pending is None or pending["operation_id"] != operation_id:
            raise RuntimeContractError("PENDING_OPERATION_NOT_FOUND")
        if pending["phase"] != "CREATED_NEEDS_READBACK":
            raise RuntimeContractError("PENDING_CREATE_OUTCOME_UNKNOWN")
        contact_id = pending.get("contact_id")
        if not isinstance(contact_id, str) or not contact_id:
            raise RuntimeContractError("PENDING_CONTACT_ID_UNAVAILABLE")

        login = mcp_call("apple_login", {}, 70)
        session_id = login.get("session_id")
        capabilities = login.get("capabilities")
        if (
            not isinstance(session_id, str)
            or not session_id
            or not isinstance(capabilities, dict)
            or capabilities.get("contactsRead") is not True
        ):
            raise RuntimeContractError("CONTACT_READ_NOT_AVAILABLE")

        readback = mcp_call(
            "contacts_read",
            {"session_id": session_id, "contact_id": contact_id},
            75,
        )
        checks = verify_contact_readback(draft, readback)
        for field, matches in checks.items():
            print(f"READBACK_{field.upper()}_MATCH:", matches)
        if all(checks.values()):
            journal.complete(operation_id)
            print("FINAL_RESULT: RECOVERED_READBACK_PASS")
            return 0
        print("FINAL_RESULT: RECOVERY_REMAINS_PENDING")
        return 1


def _run_create(data: Any) -> int:
    draft = parse_confirmed_draft(data)
    with CreateAttemptJournal() as journal:
        pending = journal.pending
        if pending is not None:
            print("CREATE_STOP: PRIOR_CREATE_REQUIRES_RECONCILIATION")
            print("PENDING_OPERATION_ID:", pending["operation_id"])
            print("PENDING_PHASE:", pending["phase"])
            return 1

        login = mcp_call("apple_login", {}, 70)
        session_id = login.get("session_id")
        capabilities = login.get("capabilities")
        if (
            not isinstance(session_id, str)
            or not session_id
            or not isinstance(capabilities, dict)
            or capabilities.get("contactsRead") is not True
            or capabilities.get("contactsWrite") is not True
        ):
            raise RuntimeContractError("CONTACT_READ_WRITE_NOT_AVAILABLE")

        name_results = validate_contacts_search_result(
            mcp_call(
                "contacts_search",
                {"session_id": session_id, "query": draft["name"], "limit": 50},
                71,
            )
        )
        mobile_results = validate_contacts_search_result(
            mcp_call(
                "contacts_search",
                {"session_id": session_id, "query": draft["mobile"], "limit": 50},
                72,
            )
        )
        decision, candidate_count = decide_contact_duplicate(
            draft["name"], draft["mobile"], name_results, mobile_results
        )
        print("PRE_NAME_COUNT:", len(name_results))
        print("PRE_MOBILE_COUNT:", len(mobile_results))
        print("PRE_UNIQUE_CANDIDATES:", candidate_count)
        print("DEDUP_DECISION:", decision)
        if decision == "EXISTS_SKIP":
            print("CREATE_RUN: False")
            print("FINAL_RESULT: EXISTS_SKIP")
            return 0
        if decision != "ALLOW_CREATE":
            print("CREATE_RUN: False")
            print("FINAL_RESULT: MANUAL_REVIEW")
            return 1

        operation_id = journal.begin()
        print("CREATE_ATTEMPT_STARTED: True")
        print("CREATE_OPERATION_ID:", operation_id)
        try:
            created = mcp_call("contacts_create", _create_contact(draft, session_id), 73)
        except Exception as exc:
            print("CREATE_OUTCOME: UNKNOWN")
            print("CREATE_FAILURE_CODE:", _safe_code(exc))
            print("PENDING_OPERATION_ID:", operation_id)
            return 1
        contact_id = _contact_id(created)
        if contact_id is None:
            print("CREATE_OUTCOME: UNKNOWN")
            print("PENDING_OPERATION_ID:", operation_id)
            return 1

        journal.mark_created(operation_id, contact_id)
        try:
            readback = mcp_call(
                "contacts_read",
                {"session_id": session_id, "contact_id": contact_id},
                74,
            )
        except Exception as exc:
            print("READBACK_OUTCOME: UNKNOWN")
            print("READBACK_FAILURE_CODE:", _safe_code(exc))
            print("PENDING_OPERATION_ID:", operation_id)
            return 1
        checks = verify_contact_readback(draft, readback)
        for field, matches in checks.items():
            print(f"READBACK_{field.upper()}_MATCH:", matches)
        readback_ok = all(checks.values())
        print("READBACK_OK:", readback_ok)
        if not readback_ok:
            print("FINAL_RESULT: READBACK_FAILED_RECONCILIATION_REQUIRED")
            print("PENDING_OPERATION_ID:", operation_id)
            return 1
        journal.complete(operation_id)
        print("FINAL_RESULT: PASS")
        return 0


def _safe_code(error: Exception) -> str:
    code = getattr(error, "code", None)
    if isinstance(code, str) and code.replace("_", "").isalnum():
        return code
    return type(error).__name__


def main(argv: list[str] | None = None) -> int:
    arguments = list(sys.argv[1:] if argv is None else argv)
    resolve_pending = arguments == ["--resolve-pending"]
    resume_pending = arguments == ["--resume-pending"]
    if arguments and not resolve_pending and not resume_pending:
        print("USAGE: wp10_create_readback.py [--resolve-pending|--resume-pending]")
        return 2
    try:
        data = json.load(sys.stdin)
        if resolve_pending:
            return _resolve_pending(data)
        if resume_pending:
            return _resume_pending_readback(data)
        return _run_create(data)
    except Exception as exc:
        print("CREATE_STOP:", _safe_code(exc))
        operation_id = getattr(exc, "operation_id", None)
        if isinstance(operation_id, str):
            print("PENDING_OPERATION_ID:", operation_id)
        if isinstance(exc, CreateAttemptError) and exc.code == "CREATE_WORKFLOW_ALREADY_RUNNING":
            return 1
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
