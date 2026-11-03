from __future__ import annotations

import re
import unicodedata
from dataclasses import dataclass, field
from datetime import date
from enum import Enum

from .models import OcrBlock, OcrResult


class ReviewReason(str, Enum):
    MAIN_CUSTOMER_IDENTITY_UNCLEAR = "main_customer_identity_unclear"
    TABLE_LAYOUT_UNCERTAIN = "table_layout_uncertain"
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
        return self.status != "ready" or bool(self.review_reasons)

    @property
    def decision(self) -> str:
        """Explicit workflow decision while preserving the legacy status field."""
        return (
            "READY"
            if self.status == "ready" and not self.review_reasons
            else "REVIEW_REQUIRED"
        )

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


@dataclass(frozen=True)
class _SpatialBlock:
    index: int
    block: OcrBlock
    field_name: str | None
    inline_value: str

    @property
    def left(self) -> int:
        assert self.block.location is not None
        return self.block.location.left

    @property
    def top(self) -> int:
        assert self.block.location is not None
        return self.block.location.top

    @property
    def right(self) -> int:
        assert self.block.location is not None
        return self.block.location.left + self.block.location.width

    @property
    def bottom(self) -> int:
        assert self.block.location is not None
        return self.block.location.top + self.block.location.height

    @property
    def center_y(self) -> float:
        assert self.block.location is not None
        return self.block.location.top + self.block.location.height / 2


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
    """Extract explicit top-level fields from line or positioned-table OCR.

    Parsing stops at a recognized family/relative section heading. It never
    derives a birthday from an identity number, resolves OCR alternatives,
    infers gender, or chooses between conflicting values. Positioned Baidu
    word blocks may pair a label with its immediate right-hand cell or the
    uniquely aligned cell in the next visual row. Missing or ambiguous geometry
    is surfaced for review rather than guessed.
    """
    evidence: dict[str, list[_Evidence]] = {key: [] for key in _FIELD_LABELS}
    in_family_section = False

    indexed_blocks = list(enumerate(result.blocks))
    if indexed_blocks and all(block.location is not None for _, block in indexed_blocks):
        indexed_blocks.sort(
            key=lambda pair: (
                pair[1].location.top,  # type: ignore[union-attr]
                pair[1].location.left,  # type: ignore[union-attr]
                pair[0],
            )
        )

    for _, block in indexed_blocks:
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

    spatial_evidence, spatial_uncertain_fields = _extract_spatial_evidence(result)
    for field_name, items in spatial_evidence.items():
        evidence[field_name].extend(items)

    reasons: list[ReviewReason] = []
    if spatial_uncertain_fields:
        reasons.append(ReviewReason.TABLE_LAYOUT_UNCERTAIN)
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


def _extract_spatial_evidence(
    result: OcrResult,
) -> tuple[dict[str, list[_Evidence]], set[str]]:
    """Read label/value adjacency from Baidu word-block coordinates.

    Baidu's handwriting response exposes one location per ``words_result``
    block, not table cells. This routine reconstructs visual rows from those
    boxes, then accepts only direct right-neighbours or uniquely aligned
    values immediately below a label. It intentionally does not invent empty
    cells or bridge arbitrary gaps/rows.
    """
    evidence: dict[str, list[_Evidence]] = {key: [] for key in _FIELD_LABELS}
    uncertain_fields: set[str] = set()
    family_index, family_top = _family_boundary(result)
    positioned: list[_SpatialBlock] = []

    for index, block in enumerate(result.blocks):
        location = block.location
        if (
            location is None
            or location.width <= 0
            or location.height <= 0
            or "\n" in block.text
            or "\r" in block.text
        ):
            continue
        if not _is_before_family(index, location.top, family_index, family_top):
            continue
        clean_text = _clean(block.text)
        if not clean_text:
            continue
        field_name, inline_value = _field_label_and_value(clean_text)
        positioned.append(
            _SpatialBlock(index, block, field_name, inline_value or "")
        )

    if not positioned:
        return evidence, uncertain_fields

    rows = _cluster_visual_rows(positioned)
    for row_index, row in enumerate(rows):
        for item_index, label in enumerate(row):
            if label.field_name is None or label.inline_value:
                continue
            if _has_ambiguous_character(label.block):
                uncertain_fields.add(label.field_name)
                continue

            candidates: list[_SpatialBlock] = []
            if item_index + 1 < len(row):
                right_neighbor = row[item_index + 1]
                gap = right_neighbor.left - label.right
                max_gap = max(
                    24,
                    3 * max(
                        label.block.location.height if label.block.location else 0,
                        right_neighbor.block.location.height
                        if right_neighbor.block.location
                        else 0,
                    ),
                )
                if (
                    right_neighbor.field_name is None
                    and gap <= max_gap
                ):
                    candidates.append(right_neighbor)

            if row_index + 1 < len(rows):
                below_row = rows[row_index + 1]
                aligned = [
                    candidate
                    for candidate in below_row
                    if candidate.field_name is None
                    and _same_visual_column(label, candidate)
                ]
                shared_candidates = [
                    candidate
                    for candidate in aligned
                    if sum(
                        1
                        for other_label in row
                        if other_label.field_name is not None
                        and not other_label.inline_value
                        and _same_visual_column(other_label, candidate)
                    )
                    > 1
                ]
                if shared_candidates:
                    uncertain_fields.add(label.field_name)
                    for candidate in shared_candidates:
                        aligned.remove(candidate)
                candidates.extend(aligned)

            for candidate in candidates:
                value = _clean(candidate.block.text)
                if value:
                    evidence[label.field_name].append(
                        _Evidence(value=value, block=candidate.block)
                    )

    return evidence, uncertain_fields


def _family_boundary(result: OcrResult) -> tuple[int | None, int | None]:
    headings: list[tuple[int, int | None]] = []
    for index, block in enumerate(result.blocks):
        if any(_is_family_heading(_clean(line)) for line in block.text.splitlines()):
            headings.append(
                (index, block.location.top if block.location is not None else None)
            )
    if not headings:
        return None, None
    positioned_tops = [top for _, top in headings if top is not None]
    return min(index for index, _ in headings), (
        min(positioned_tops) if positioned_tops else None
    )


def _is_before_family(
    index: int,
    top: int,
    family_index: int | None,
    family_top: int | None,
) -> bool:
    if family_top is not None:
        return top < family_top
    return family_index is None or index < family_index


def _field_label_and_value(value: str) -> tuple[str | None, str | None]:
    match = _LABELED_LINE_RE.fullmatch(value)
    if match is not None:
        field_name = _LABEL_TO_FIELD.get(_normalize_label(match.group(1)))
        if field_name is not None:
            return field_name, _clean(match.group(2))
    field_name = _LABEL_TO_FIELD.get(_normalize_label(value))
    return (field_name, "") if field_name is not None else (None, None)


def _cluster_visual_rows(blocks: list[_SpatialBlock]) -> list[list[_SpatialBlock]]:
    rows: list[list[_SpatialBlock]] = []
    for block in sorted(blocks, key=lambda item: (item.center_y, item.left, item.index)):
        matching_rows: list[tuple[float, list[_SpatialBlock]]] = []
        for row in rows:
            top = min(item.top for item in row)
            bottom = max(item.bottom for item in row)
            row_center = (top + bottom) / 2
            row_height = max(
                item.block.location.height
                for item in row
                if item.block.location is not None
            )
            block_height = block.block.location.height  # always positioned here
            overlap = max(0, min(bottom, block.bottom) - max(top, block.top))
            min_height = min(row_height, block_height)
            same_row = overlap >= 0.25 * min_height or abs(
                block.center_y - row_center
            ) <= max(4, 0.45 * max(row_height, block_height))
            if same_row:
                matching_rows.append((abs(block.center_y - row_center), row))
        if matching_rows:
            min(matching_rows, key=lambda item: item[0])[1].append(block)
        else:
            rows.append([block])
    return [
        sorted(row, key=lambda item: (item.left, item.index))
        for row in sorted(rows, key=lambda group: min(item.top for item in group))
    ]


def _same_visual_column(label: _SpatialBlock, candidate: _SpatialBlock) -> bool:
    label_box = label.block.location
    candidate_box = candidate.block.location
    if label_box is None or candidate_box is None:
        return False
    overlap = max(
        0,
        min(label_box.left + label_box.width, candidate_box.left + candidate_box.width)
        - max(label_box.left, candidate_box.left),
    )
    min_width = min(label_box.width, candidate_box.width)
    overlap_ratio = overlap / min_width if min_width > 0 else 0.0
    same_left = abs(label_box.left - candidate_box.left) <= max(
        8, 0.9 * max(label_box.height, candidate_box.height)
    )
    return overlap_ratio >= 0.25 or same_left


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
