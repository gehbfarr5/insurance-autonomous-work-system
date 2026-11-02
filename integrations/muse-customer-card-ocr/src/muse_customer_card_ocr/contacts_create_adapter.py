from __future__ import annotations

from datetime import date, datetime
from typing import Literal, Protocol

from .icloud_mapping import ICloudContactDraft


class ContactsCreateArgumentsError(ValueError):
    """Invalid or incomplete input for the verified contacts_create schema."""

    code = "INVALID_CONTACTS_CREATE_ARGUMENTS"

    def __repr__(self) -> str:
        return f"{type(self).__name__}(<details redacted>)"

    def __str__(self) -> str:
        return self.code


class AddressBookRequiredError(ContactsCreateArgumentsError):
    """Require an explicit address book to avoid the MCP server's implicit default."""

    code = "ADDRESS_BOOK_ID_REQUIRED"


class McpToolCaller(Protocol):
    """Small injectable invocation seam; not a MUSE production bridge contract."""

    def __call__(
        self,
        tool_name: Literal["contacts_create"],
        arguments: dict[str, object],
        /,
    ) -> object: ...


def build_contacts_create_arguments(
    draft: ICloudContactDraft,
    *,
    session_id: str,
    address_book_id: str | None = None,
) -> dict[str, object]:
    """Project a canonical draft into the exposed contacts_create argument shape.

    The MCP tool selects its first writable address book when
    ``address_book_id`` is omitted. This adapter intentionally rejects that
    implicit behavior and requires the caller to pass a verified book ID.
    Values are not split, normalized, or logged here.
    """
    if not isinstance(draft, ICloudContactDraft):
        raise ContactsCreateArgumentsError()
    if not _is_nonblank(session_id):
        raise ContactsCreateArgumentsError()
    if not _is_nonblank(address_book_id):
        raise AddressBookRequiredError()
    if not _is_nonblank(draft.name_full) or not _is_nonblank(draft.phone_mobile):
        raise ContactsCreateArgumentsError()

    phones: list[dict[str, object]] = [
        {"value": draft.phone_mobile, "type": ["cell"], "primary": True}
    ]
    contact: dict[str, object] = {
        # Keep the source name whole; do not infer family/given name boundaries.
        "name": {"full": draft.name_full},
        "phones": phones,
    }

    if draft.birthday is not None:
        if not isinstance(draft.birthday, date) or isinstance(draft.birthday, datetime):
            raise ContactsCreateArgumentsError()
        contact["birthday"] = draft.birthday.isoformat()

    if draft.address is not None:
        if not isinstance(draft.address, str):
            raise ContactsCreateArgumentsError()
        if _is_nonblank(draft.address):
            # Keep the full source string in street; do not infer locality fields.
            contact["addresses"] = [{"street": draft.address}]

    if not isinstance(draft.phone_other, tuple):
        raise ContactsCreateArgumentsError()
    for phone in draft.phone_other:
        if not _is_nonblank(phone):
            raise ContactsCreateArgumentsError()
        phones.append({"value": phone, "type": ["other"], "primary": False})

    if draft.note is not None:
        if not isinstance(draft.note, str):
            raise ContactsCreateArgumentsError()
        if _is_nonblank(draft.note):
            # Gender / identity-number lines were formed upstream; preserve verbatim.
            contact["note"] = draft.note

    return {
        "session_id": session_id,
        "address_book_id": address_book_id,
        "contact": contact,
    }


def call_contacts_create(
    draft: ICloudContactDraft,
    *,
    session_id: str,
    address_book_id: str | None = None,
    call_tool: McpToolCaller,
) -> object:
    """Invoke only contacts_create through an injected caller (normally a Mock)."""
    arguments = build_contacts_create_arguments(
        draft,
        session_id=session_id,
        address_book_id=address_book_id,
    )
    return call_tool("contacts_create", arguments)


def _is_nonblank(value: object) -> bool:
    return isinstance(value, str) and bool(value.strip())
