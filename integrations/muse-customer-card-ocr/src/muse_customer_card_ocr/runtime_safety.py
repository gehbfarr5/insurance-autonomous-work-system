"""Strict, value-free validation helpers for the MUSE runtime scripts.

These helpers do not call OCR or MCP. Errors use fixed codes so callers can
report a failure without printing contact values or raw server responses.
"""
from __future__ import annotations

import json
import re
import unicodedata
from collections.abc import Mapping
from datetime import date
from typing import Any

from .fields import is_valid_identity_number, normalize_mobile_number


class RuntimeContractError(RuntimeError):
    """A malformed, incomplete, or unconfirmed runtime input/result."""

    def __init__(self, code: str = "RUNTIME_CONTRACT_INVALID") -> None:
        self.code = code
        super().__init__(code)


def parse_confirmed_draft(
    value: Any, *, require_address_book: bool = True
) -> dict[str, Any]:
    """Validate a confirmed draft; only create paths require an address book."""
    if not isinstance(value, Mapping):
        raise RuntimeContractError("DRAFT_INVALID")
    if value.get("extraction_status") not in {"READY", "MANUALLY_REVIEWED"}:
        raise RuntimeContractError("EXTRACTION_NOT_APPROVED")
    if value.get("review_status") != "USER_CONFIRMED":
        raise RuntimeContractError("USER_CONFIRMATION_REQUIRED")
    extraction_status = value["extraction_status"]

    address_book_id = value.get("address_book_id")
    if require_address_book or address_book_id is not None:
        if (
            not isinstance(address_book_id, str)
            or not address_book_id.strip()
            or _has_control(address_book_id)
        ):
            raise RuntimeContractError("ADDRESS_BOOK_ID_REQUIRED")

    required = ("name", "mobile", "gender", "birthday", "identity_number")
    if any(key not in value for key in required):
        raise RuntimeContractError("REQUIRED_FIELD_MISSING")

    name = _required_text(value["name"], "NAME_INVALID")
    if _has_control(name):
        raise RuntimeContractError("NAME_INVALID")

    mobile_text = _required_text(value["mobile"], "MOBILE_INVALID")
    mobile = normalize_mobile_number(mobile_text)
    if mobile is None:
        raise RuntimeContractError("MOBILE_INVALID")

    gender = _required_text(value["gender"], "GENDER_INVALID")
    if gender not in {"男", "女"}:
        raise RuntimeContractError("GENDER_INVALID")

    birthday_text = _required_text(value["birthday"], "BIRTHDAY_INVALID")
    try:
        birthday = date.fromisoformat(birthday_text)
    except ValueError as exc:
        raise RuntimeContractError("BIRTHDAY_INVALID") from exc
    if birthday.isoformat() != birthday_text:
        raise RuntimeContractError("BIRTHDAY_INVALID")

    identity = _required_text(value["identity_number"], "IDENTITY_NUMBER_INVALID")
    identity = re.sub(r"\s+", "", unicodedata.normalize("NFKC", identity)).upper()
    if not is_valid_identity_number(identity):
        raise RuntimeContractError("IDENTITY_NUMBER_INVALID")
    if extraction_status == "READY" and identity[6:14] != birthday.strftime("%Y%m%d"):
        raise RuntimeContractError("BIRTHDAY_IDENTITY_CONFLICT")

    address_value = value.get("address")
    if address_value is None or address_value == "":
        address = None
    else:
        address = _required_text(address_value, "ADDRESS_INVALID")
        if _has_control(address):
            raise RuntimeContractError("ADDRESS_INVALID")

    other_value = value.get("other_phones", [])
    if not isinstance(other_value, list):
        raise RuntimeContractError("OTHER_PHONES_INVALID")
    other_phones: list[str] = []
    phone_keys = {_normalize_phone_for_match(mobile)}
    for item in other_value:
        phone = _required_text(item, "OTHER_PHONES_INVALID")
        if _has_control(phone):
            raise RuntimeContractError("OTHER_PHONES_INVALID")
        key = _normalize_phone_for_match(phone)
        if not key or key in phone_keys:
            raise RuntimeContractError("OTHER_PHONES_INVALID")
        phone_keys.add(key)
        other_phones.append(phone)

    return {
        "name": name,
        "mobile": mobile,
        "gender": gender,
        "birthday": birthday_text,
        "identity_number": identity,
        "address": address,
        "other_phones": tuple(other_phones),
        "address_book_id": address_book_id,
    }


def decode_mcp_tool_result(envelope: Any) -> dict[str, Any]:
    """Decode the runtime's single JSON text result, rejecting partial errors."""
    if not isinstance(envelope, dict) or envelope.get("isError") is True:
        raise RuntimeContractError("MCP_TOOL_CALL_FAILED")
    content = envelope.get("content")
    if not isinstance(content, list) or len(content) != 1:
        raise RuntimeContractError("MCP_TOOL_RESULT_INVALID")
    item = content[0]
    if not isinstance(item, dict) or item.get("type") != "text":
        raise RuntimeContractError("MCP_TOOL_RESULT_INVALID")
    text = item.get("text")
    if not isinstance(text, str):
        raise RuntimeContractError("MCP_TOOL_RESULT_INVALID")
    try:
        payload = json.loads(text)
    except (TypeError, ValueError) as exc:
        raise RuntimeContractError("MCP_TOOL_RESULT_INVALID") from exc
    if not isinstance(payload, dict):
        raise RuntimeContractError("MCP_TOOL_RESULT_INVALID")
    return payload


def validate_contacts_search_result(value: Any) -> tuple[dict[str, Any], ...]:
    """Require contacts plus explicit no-truncation/no-partial-failure markers."""
    if not isinstance(value, dict) or value.get("isError") is True:
        raise RuntimeContractError("CONTACTS_SEARCH_FAILED")
    if "error" in value and value["error"] not in (None, "", False):
        raise RuntimeContractError("CONTACTS_SEARCH_FAILED")
    contacts = value.get("contacts")
    if not isinstance(contacts, list):
        raise RuntimeContractError("CONTACTS_SEARCH_RESULT_INCOMPLETE")
    if value.get("truncated") is not False:
        raise RuntimeContractError("CONTACTS_SEARCH_RESULT_INCOMPLETE")
    partial_failures = value.get("partial_failures")
    if not isinstance(partial_failures, list) or partial_failures:
        raise RuntimeContractError("CONTACTS_SEARCH_RESULT_INCOMPLETE")
    if "total" in value:
        total = value["total"]
        if isinstance(total, bool) or not isinstance(total, int) or total != len(contacts):
            raise RuntimeContractError("CONTACTS_SEARCH_RESULT_INCOMPLETE")
    for key in ("has_more", "hasMore"):
        if key in value and not isinstance(value[key], bool):
            raise RuntimeContractError("CONTACTS_SEARCH_RESULT_INCOMPLETE")
        if value.get(key) is True:
            raise RuntimeContractError("CONTACTS_SEARCH_RESULT_INCOMPLETE")
    validated: list[dict[str, Any]] = []
    for contact in contacts:
        if not isinstance(contact, dict):
            raise RuntimeContractError("CONTACTS_SEARCH_RESULT_INCOMPLETE")
        if not _contact_name(contact, required=True).strip():
            raise RuntimeContractError("CONTACTS_SEARCH_RESULT_INCOMPLETE")
        _contact_phones(contact, required=True)
        for key in ("contact_id", "id"):
            if key in contact and contact[key] is not None:
                value_id = contact[key]
                if isinstance(value_id, bool) or not isinstance(value_id, (str, int)):
                    raise RuntimeContractError("CONTACTS_SEARCH_RESULT_INCOMPLETE")
        validated.append(contact)
    return tuple(validated)


def contact_dedup_key(contact: Mapping[str, Any]) -> tuple[Any, ...]:
    """Build a stable, non-value-logging key for merging two search results."""
    contact_id = contact.get("contact_id") or contact.get("id")
    if contact_id is not None:
        return ("id", str(contact_id))
    return (
        "fields",
        _contact_name(contact, required=True).strip(),
        tuple(sorted(_normalize_phone_for_match(item) for item in _contact_phones(contact, required=True))),
    )


def contact_name(contact: Mapping[str, Any]) -> str:
    return _contact_name(contact, required=True)


def contact_phones(contact: Mapping[str, Any]) -> tuple[str, ...]:
    return tuple(_contact_phones(contact, required=True))


def decide_contact_duplicate(
    name: str,
    mobile: str,
    name_results: tuple[dict[str, Any], ...],
    mobile_results: tuple[dict[str, Any], ...],
    *,
    result_limit: int = 50,
) -> tuple[str, int]:
    """Return ALLOW_CREATE only after two complete, bounded searches."""
    if len(name_results) >= result_limit or len(mobile_results) >= result_limit:
        raise RuntimeContractError("CONTACTS_SEARCH_LIMIT_REACHED")
    candidates: dict[tuple[Any, ...], dict[str, Any]] = {}
    for contact in (*name_results, *mobile_results):
        key = contact_dedup_key(contact)
        previous = candidates.get(key)
        if previous is not None and _contact_signature(previous) != _contact_signature(contact):
            raise RuntimeContractError("CONTACTS_SEARCH_RESULT_CONFLICT")
        candidates[key] = contact
    wanted_mobile = normalize_mobile_number(mobile)
    if wanted_mobile is None:
        raise RuntimeContractError("MOBILE_INVALID")
    matching: list[tuple[dict[str, Any], bool, bool]] = []
    for contact in candidates.values():
        exact_name = contact_name(contact).strip() == name.strip()
        number_matches = wanted_mobile in {
            normalize_mobile_number(phone) for phone in contact_phones(contact)
        }
        if exact_name or number_matches:
            matching.append((contact, exact_name, number_matches))
    if not matching:
        return "ALLOW_CREATE", len(candidates)
    if len(matching) == 1 and matching[0][1] and matching[0][2]:
        return "EXISTS_SKIP", len(candidates)
    return "MANUAL_REVIEW", len(candidates)


def verify_contact_readback(
    expected: Mapping[str, Any],
    response: Any,
) -> dict[str, bool]:
    """Return field-level booleans; malformed readback values fail closed."""
    readback = response
    if isinstance(response, dict) and "contact" in response:
        readback = response["contact"]
    if not isinstance(readback, dict):
        return {key: False for key in _READBACK_KEYS}

    try:
        name_ok = _contact_name(readback, required=True) == expected["name"]
        phones = _contact_phones(readback, required=True)
        phone_keys = [_normalize_phone_for_match(phone) for phone in phones]
        expected_phone_keys = [
            _normalize_phone_for_match(expected["mobile"]),
            *(_normalize_phone_for_match(phone) for phone in expected["other_phones"]),
        ]
        phones_ok = sorted(phone_keys) == sorted(expected_phone_keys)
        primary_ok = False
        for item in readback["phones"]:
            if isinstance(item, dict) and item.get("primary") is True:
                candidate = item.get("value")
                if isinstance(candidate, str) and normalize_mobile_number(candidate) == expected["mobile"]:
                    primary_ok = True
        birthday_ok = readback.get("birthday") == expected["birthday"]
        expected_note = f"性别：{expected['gender']}\n身份证号：{expected['identity_number']}"
        note_ok = readback.get("note") == expected_note
        addresses = readback.get("addresses", [])
        if not isinstance(addresses, list):
            address_ok = False
        elif expected["address"] is None:
            address_ok = len(addresses) == 0
        else:
            address_ok = (
                len(addresses) == 1
                and isinstance(addresses[0], dict)
                and addresses[0].get("street") == expected["address"]
            )
    except (KeyError, RuntimeContractError, TypeError):
        return {key: False for key in _READBACK_KEYS}

    return {
        "name": name_ok,
        "phones": phones_ok,
        "primary_phone": primary_ok,
        "birthday": birthday_ok,
        "note": note_ok,
        "address": address_ok,
    }


_READBACK_KEYS = ("name", "phones", "primary_phone", "birthday", "note", "address")


def _contact_name(contact: Mapping[str, Any], *, required: bool) -> str:
    if "name" not in contact:
        if required:
            raise RuntimeContractError("CONTACT_RECORD_INCOMPLETE")
        return ""
    raw = contact["name"]
    if isinstance(raw, str):
        name = raw
    elif isinstance(raw, dict) and isinstance(raw.get("full"), str):
        name = raw["full"]
    else:
        raise RuntimeContractError("CONTACT_RECORD_INCOMPLETE")
    if _has_control(name):
        raise RuntimeContractError("CONTACT_RECORD_INCOMPLETE")
    return name


def _contact_phones(contact: Mapping[str, Any], *, required: bool) -> list[str]:
    if "phones" not in contact:
        if required:
            raise RuntimeContractError("CONTACT_RECORD_INCOMPLETE")
        return []
    raw = contact["phones"]
    if not isinstance(raw, list):
        raise RuntimeContractError("CONTACT_RECORD_INCOMPLETE")
    result: list[str] = []
    for item in raw:
        if isinstance(item, str):
            phone = item
        elif isinstance(item, dict) and isinstance(item.get("value"), str):
            phone = item["value"]
        else:
            raise RuntimeContractError("CONTACT_RECORD_INCOMPLETE")
        if not phone.strip() or _has_control(phone) or not _normalize_phone_for_match(phone):
            raise RuntimeContractError("CONTACT_RECORD_INCOMPLETE")
        result.append(phone)
    if not _contact_name(contact, required=False).strip() and not result:
        raise RuntimeContractError("CONTACT_RECORD_INCOMPLETE")
    return result


def _required_text(value: Any, code: str) -> str:
    if not isinstance(value, str) or not value.strip():
        raise RuntimeContractError(code)
    return value.strip()


def _has_control(value: str) -> bool:
    return any(unicodedata.category(char) == "Cc" for char in value)


def _normalize_phone_for_match(value: str) -> str:
    mobile = normalize_mobile_number(value)
    if mobile is not None:
        return mobile
    normalized = unicodedata.normalize("NFKC", value).strip()
    compact = re.sub(r"[\s+()（）-]", "", normalized)
    return compact if any(char.isdigit() for char in compact) else ""


def _contact_signature(contact: Mapping[str, Any]) -> tuple[str, tuple[str, ...]]:
    return (
        _contact_name(contact, required=True).strip(),
        tuple(sorted(_normalize_phone_for_match(phone) for phone in _contact_phones(contact, required=True))),
    )
