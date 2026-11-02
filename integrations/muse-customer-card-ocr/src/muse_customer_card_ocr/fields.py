from __future__ import annotations

import re
import unicodedata
from dataclasses import dataclass, field
from datetime import date
from enum import Enum

from .models import OcrBlock, OcrResult


class ReviewReason(str, Enum):
    MAIN_CUSTOMER_IDENTITY_UNCLEAR = "main_customer_identity_unclear"
    MOBILE_MISSING = "mobile_missing"
    MOBILE_UNCERTAIN = "mobile_uncertain"
    MOBILE_CONFLICT = "mobile_conflict"
    BIRTHDAY_UNCERTAIN = "birthday_uncertain"
    BIRTHDAY_CONFLICT = "birthday_conflict"
    ADDRESS_CONFLICT = "address_conflict"
    GENDER_UNCERTAIN = "gender_uncertain"
    IDENTITY_NUMBER_UNCERTAIN = "identity_number_uncertain"
    IDENTITY_NUMBER_CONFLICT = "identity_number_conflict"


@dataclass(frozen=True, repr=False)
class CustomerCardFields:
    name: str | None = field(default=None, repr=False)
    mobile: str | None = field(default=None, repr=False)
    birthday: date | None = None
    address: str | None = field(default=None, repr=False)
    other_phones: tuple[str, ...] = field(default=(), repr=False)
    gender: str | None = None
    identity_number: str | None = field(default=None, repr=False)

    def __repr__(self) -> str:
        return "CustomerCardFields(<values redacted>)"


@dataclass(frozen=True, repr=False)
class FieldExtractionResult:
    status: str
    fields: CustomerCardFields
    review_reasons: tuple[ReviewReason, ...]

    @property
    def needs_manual_review(self) -> bool:
        return self.status == "needs_manual_review"

    def __repr__(self) -> str:
        return (
            "FieldExtractionResult("
            f"status={self.status!r}, fields=<redacted>, "
            f"review_reasons={self.review_reasons!r})"
        )


@dataclass(frozen=True)
class _Evidence:
    value: str
    block: OcrBlock


_FIELD_LABELS: dict[str, frozenset[str]] = {
    "name": frozenset({"主客户姓名", "客户姓名", "本人姓名", "被保险人姓名", "姓名"}),
    "mobile": frozenset({"主客户手机", "手机号码", "手机", "移动电话"}),
    "birthday": frozenset({"出生日期", "出生年月日", "生日"}),
    "address": frozenset({"联系地址", "居住地址", "地址"}),
    "other_phone": frozenset({"其他联系电话", "其他电话", "家庭电话", "宅电", "固定电话", "座机"}),
    "gender": frozenset({"性别"}),
    "identity_number": frozenset({"身份证号码", "身份证号", "身份证", "证件号码"}),
}
_LABEL_TO_FIELD = {
    label: field_name
    for field_name, labels in _FIELD_LABELS.items()
    for label in labels
}
_LABELED_LINE_RE = re.compile(r"^\s*([^:：]{1,32})\s*[:：]\s*(.*?)\s*$")
_FAMILY_HEADINGS = frozenset(
    {"家庭成员", "家庭成员资料", "家属", "家属亲友", "家属及亲友", "亲友资料", "亲友"}
)
_MOBILE_RE = re.compile(r"^1[3-9]\d{9}$")
_ID_RE = re.compile(r"^\d{17}[\dX]$")
_ID_WEIGHTS = (7, 9, 10, 5, 8, 4, 2, 1, 6, 3, 7, 9, 10, 5, 8, 4, 2)
_ID_CHECK_CHARS = "10X98765432"


def extract_primary_customer(result: OcrResult) -> FieldExtractionResult:
    """Extract only explicitly labelled top-level customer fields.

    Parsing stops at a recognized family/relative section heading. It never
    derives a birthday from an identity number, resolves OCR alternatives,
    infers gender, or chooses between conflicting values.
    """
    evidence: dict[str, list[_Evidence]] = {key: [] for key in _FIELD_LABELS}
    in_family_section = False

    for block in result.blocks:
        for line in block.text.splitlines():
            clean_line = _clean(line)
            if not clean_line:
                continue
            if _is_family_heading(clean_line):
                in_family_section = True
                break
            if in_family_section:
                break
            match = _LABELED_LINE_RE.fullmatch(line)
            if match is None:
                continue
            label = _normalize_label(match.group(1))
            field_name = _LABEL_TO_FIELD.get(label)
            if field_name is None:
                continue
            evidence[field_name].append(_Evidence(_clean(match.group(2)), block))
        if in_family_section:
            break

    reasons: list[ReviewReason] = []
    name = _one_value(evidence["name"])
    name_uncertain = any(_has_ambiguous_character(item.block) for item in evidence["name"])
    if (
        name is None
        or name_uncertain
        or (evidence["name"] and any(not item.value for item in evidence["name"]))
    ):
        reasons.append(ReviewReason.MAIN_CUSTOMER_IDENTITY_UNCLEAR)
        name = None

    mobile_values = _unique(
        normalized
        for item in evidence["mobile"]
        if (normalized := _normalize_mobile(item.value)) is not None
    )
    if not evidence["mobile"] or not any(item.value for item in evidence["mobile"]):
        reasons.append(ReviewReason.MOBILE_MISSING)
        mobile = None
    elif (
        any(not item.value for item in evidence["mobile"])
        or any(
            _normalize_mobile(item.value) is None
            for item in evidence["mobile"]
            if item.value
        )
        or any(_has_ambiguous_character(item.block) for item in evidence["mobile"])
    ):
        reasons.append(ReviewReason.MOBILE_UNCERTAIN)
        mobile = None
    elif len(mobile_values) != 1:
        reasons.append(ReviewReason.MOBILE_CONFLICT)
        mobile = None
    else:
        mobile = mobile_values[0]

    birthday, birthday_invalid = _extract_birthday(evidence["birthday"])
    if birthday_invalid:
        reasons.append(ReviewReason.BIRTHDAY_UNCERTAIN)
    if len(_unique(item.value for item in evidence["birthday"] if item.value)) > 1:
        reasons.append(ReviewReason.BIRTHDAY_CONFLICT)

    all_address_values = _unique(item.value for item in evidence["address"] if item.value)
    address_values = _unique(
        item.value
        for item in evidence["address"]
        if item.value and not _has_ambiguous_character(item.block)
    )
    if len(all_address_values) > 1:
        reasons.append(ReviewReason.ADDRESS_CONFLICT)
        address = None
    else:
        address = address_values[0] if address_values else None

    gender, gender_invalid = _extract_gender(evidence["gender"])
    if gender_invalid:
        reasons.append(ReviewReason.GENDER_UNCERTAIN)

    other_phones = _unique(
        item.value
        for item in evidence["other_phone"]
        if item.value and not _has_ambiguous_character(item.block)
    )
    if mobile is not None:
        mobile_digits = re.sub(r"\D", "", mobile)
        other_phones = tuple(
            value for value in other_phones
            if re.sub(r"\D", "", value) != mobile_digits
        )

    identity_number, identity_uncertain, identity_conflict = _extract_identity_number(
        evidence["identity_number"]
    )
    if identity_conflict:
        reasons.append(ReviewReason.IDENTITY_NUMBER_CONFLICT)
    if identity_uncertain:
        reasons.append(ReviewReason.IDENTITY_NUMBER_UNCERTAIN)

    if (
        birthday is not None
        and identity_number is not None
        and _is_checksum_valid_identity_number(identity_number)
    ):
        id_birthday = _identity_birthday(identity_number)
        if id_birthday is not None and id_birthday != birthday:
            reasons.append(ReviewReason.BIRTHDAY_CONFLICT)

    reasons = list(dict.fromkeys(reasons))
    fields = CustomerCardFields(
        name=name,
        mobile=mobile,
        birthday=birthday,
        address=address,
        other_phones=other_phones,
        gender=gender,
        identity_number=identity_number,
    )
    status = "needs_manual_review" if reasons else "ready"
    return FieldExtractionResult(status, fields, tuple(reasons))


def _extract_identity_number(
    items: list[_Evidence],
) -> tuple[str | None, bool, bool]:
    values = _unique(_normalize_identity_number(item.value) for item in items if item.value)
    conflict = len(values) > 1
    if not items:
        return None, True, False
    if not values:
        return None, True, False
    if conflict:
        return None, False, True

    value = values[0]
    uncertain = not _is_checksum_valid_identity_number(value)
    uncertain = uncertain or any(_has_ambiguous_character(item.block) for item in items)
    uncertain = uncertain or any(not item.value for item in items)
    return value, uncertain, False


def _extract_birthday(items: list[_Evidence]) -> tuple[date | None, bool]:
    if not items:
        return None, False
    values: list[date] = []
    invalid = any(not item.value for item in items) and any(item.value for item in items)
    invalid = invalid or any(
        _has_ambiguous_character(item.block) for item in items if item.value
    )
    for item in items:
        if not item.value:
            continue
        parsed = _parse_explicit_date(item.value)
        if parsed is None:
            invalid = True
        else:
            values.append(parsed)
    unique_values = tuple(dict.fromkeys(values))
    if len(unique_values) > 1:
        return None, True
    return (unique_values[0] if unique_values else None), invalid


def _extract_gender(items: list[_Evidence]) -> tuple[str | None, bool]:
    if not items:
        return None, False
    normalized: list[str] = []
    invalid = any(not item.value for item in items) and any(item.value for item in items)
    invalid = invalid or any(
        _has_ambiguous_character(item.block) for item in items if item.value
    )
    for item in items:
        if not item.value:
            continue
        value = _clean(item.value)
        if value in {"男", "男性"}:
            normalized.append("男")
        elif value in {"女", "女性"}:
            normalized.append("女")
        else:
            invalid = True
    unique_values = tuple(dict.fromkeys(normalized))
    if len(unique_values) > 1:
        return None, True
    return (unique_values[0] if unique_values else None), invalid


def _parse_explicit_date(value: str) -> date | None:
    normalized = unicodedata.normalize("NFKC", value).strip()
    iso_match = re.fullmatch(r"(\d{4})-(\d{2})-(\d{2})", normalized)
    chinese_match = re.fullmatch(
        r"(\d{4})年(\d{1,2})月(\d{1,2})日?", normalized
    )
    match = iso_match or chinese_match
    if match is None:
        return None
    try:
        return date(*(int(part) for part in match.groups()))
    except ValueError:
        return None


def _normalize_mobile(value: str) -> str | None:
    compact = unicodedata.normalize("NFKC", value).strip()
    compact = re.sub(r"[\s()（）-]", "", compact)
    if compact.startswith("+86"):
        compact = compact[3:]
    if _MOBILE_RE.fullmatch(compact) is None:
        return None
    return compact


def _normalize_identity_number(value: str) -> str:
    normalized = unicodedata.normalize("NFKC", value)
    return re.sub(r"\s+", "", normalized).upper()


def _is_checksum_valid_identity_number(value: str) -> bool:
    if _ID_RE.fullmatch(value) is None:
        return False
    try:
        _identity_birthday(value)
    except ValueError:
        return False
    weighted_sum = sum(int(digit) * weight for digit, weight in zip(value[:17], _ID_WEIGHTS))
    return _ID_CHECK_CHARS[weighted_sum % 11] == value[-1]


def _identity_birthday(value: str) -> date:
    return date(
        int(value[6:10]),
        int(value[10:12]),
        int(value[12:14]),
    )


def _has_ambiguous_character(block: OcrBlock) -> bool:
    for character in block.characters:
        if character.text is None:
            return True
        if any(candidate.text != character.text for candidate in character.candidates):
            return True
    return False


def _one_value(items: list[_Evidence]) -> str | None:
    values = _unique(item.value for item in items if item.value)
    return values[0] if len(values) == 1 else None


def _unique(values):
    return tuple(dict.fromkeys(value for value in values if value))


def _normalize_label(value: str) -> str:
    return re.sub(r"[\s:：]", "", unicodedata.normalize("NFKC", value))


def _clean(value: str) -> str:
    return " ".join(unicodedata.normalize("NFKC", value).split())


def _is_family_heading(value: str) -> bool:
    normalized = _normalize_label(value)
    return normalized in _FAMILY_HEADINGS or normalized.startswith(
        ("家庭成员", "家属亲友", "家属及亲友")
    )
