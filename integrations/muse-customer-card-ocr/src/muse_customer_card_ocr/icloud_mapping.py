from __future__ import annotations

from dataclasses import dataclass, field
from datetime import date

from .errors import ManualReviewRequiredError
from .fields import FieldExtractionResult


@dataclass(frozen=True, repr=False)
class ICloudContactDraft:
    """Canonical, non-writing projection into native contact concepts.

    The local contacts_create serializer maps this draft to the repository's
    documented MCP argument shape. This does not establish that the live MUSE
    schema is current or bound to the active runtime.
    """

    name_full: str = field(repr=False)
    phone_mobile: str = field(repr=False)
    birthday: date | None = None
    address: str | None = field(default=None, repr=False)
    phone_other: tuple[str, ...] = field(default=(), repr=False)
    note: str | None = field(default=None, repr=False)

    def __repr__(self) -> str:
        return "ICloudContactDraft(<values redacted>)"


def map_to_icloud_fields(extraction: FieldExtractionResult) -> ICloudContactDraft:
    """Map only an unambiguous extraction; refuse any pending review result."""
    if extraction.status != "ready" or extraction.review_reasons:
        raise ManualReviewRequiredError()

    fields = extraction.fields
    if not fields.name or not fields.mobile:
        raise ManualReviewRequiredError()

    note_lines: list[str] = []
    if fields.gender is not None:
        note_lines.append(f"性别：{fields.gender}")
    if fields.identity_number is not None:
        note_lines.append(f"身份证号：{fields.identity_number}")

    return ICloudContactDraft(
        name_full=fields.name,
        phone_mobile=fields.mobile,
        birthday=fields.birthday,
        address=fields.address,
        phone_other=fields.other_phones,
        note="\n".join(note_lines) if note_lines else None,
    )
