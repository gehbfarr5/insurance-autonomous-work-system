from __future__ import annotations

import unittest
from datetime import date

from muse_customer_card_ocr import (
    BoundingBox,
    CharacterCandidate,
    CustomerCardFields,
    FieldExtractionResult,
    OcrBlock,
    OcrCharacter,
    OcrResult,
    ReviewReason,
    extract_primary_customer,
)


def _synthetic_identity_number(birthday: str = "19900202") -> str:
    first_seventeen = "999999" + birthday + "001"
    weights = (7, 9, 10, 5, 8, 4, 2, 1, 6, 3, 7, 9, 10, 5, 8, 4, 2)
    check_chars = "10X98765432"
    total = sum(int(value) * weight for value, weight in zip(first_seventeen, weights))
    return first_seventeen + check_chars[total % 11]


def _block(
    text: str,
    left: int,
    top: int,
    width: int,
    *,
    height: int = 20,
    characters: tuple[OcrCharacter, ...] = (),
) -> OcrBlock:
    return OcrBlock(
        text=text,
        location=BoundingBox(left=left, top=top, width=width, height=height),
        characters=characters,
    )


def _result(*blocks: OcrBlock) -> OcrResult:
    return OcrResult(
        status="success",
        blocks=tuple(blocks),
        request_id="synthetic-table-request",
        service_log_id="54321",
        image_mime_type="image/jpeg",
        image_width=1200,
        image_height=1800,
        upload_mode="full_image_authorized",
    )


def _complete_table(*, identity_number: str | None = None) -> list[OcrBlock]:
    identity = identity_number or _synthetic_identity_number()
    return [
        # Column labels and their values on the next visual row.
        _block("姓名", 40, 20, 40),
        _block("性别", 230, 20, 40),
        _block("身份证号码", 430, 20, 100),
        _block("出生日期", 750, 20, 80),
        _block("虚构客户甲", 40, 50, 120),
        _block("女", 230, 50, 20),
        _block(identity, 430, 50, 190),
        _block("1990年2月2日", 750, 50, 110),
        # Multiple telephone types and an address across another row.
        _block("手机号码", 40, 90, 60),
        _block("联系地址", 230, 90, 80),
        _block("宅电", 460, 90, 40),
        _block("其他联系电话", 650, 90, 100),
        _block("19900000000", 40, 120, 110),
        _block("虚构地址 A", 230, 120, 100),
        _block("010-0000-0000", 460, 120, 120),
        _block("021-0000-0000", 650, 120, 120),
        _block("家属亲友", 40, 180, 100),
        _block("姓名", 40, 210, 40),
        _block("虚构家属乙", 40, 240, 100),
        _block("手机", 230, 210, 40),
        _block("19900000001", 230, 240, 110),
    ]


class TableLayoutExtractionTests(unittest.TestCase):
    def test_public_decision_is_fail_closed_for_pending_or_reviewed_result(self):
        pending = FieldExtractionResult(
            status="pending",
            fields=CustomerCardFields(name="虚构客户庚", mobile="19900000007"),
            review_reasons=(),
        )
        marked_review = FieldExtractionResult(
            status="ready",
            fields=CustomerCardFields(name="虚构客户辛", mobile="19900000008"),
            review_reasons=(ReviewReason.TABLE_LAYOUT_UNCERTAIN,),
        )

        self.assertEqual(pending.decision, "REVIEW_REQUIRED")
        self.assertTrue(pending.needs_manual_review)
        self.assertEqual(marked_review.decision, "REVIEW_REQUIRED")
        self.assertTrue(marked_review.needs_manual_review)

    def test_extracts_cross_row_and_cross_column_customer_fields(self):
        extraction = extract_primary_customer(_result(*_complete_table()))

        self.assertEqual(extraction.status, "ready")
        self.assertEqual(extraction.decision, "READY")
        self.assertEqual(extraction.fields.name, "虚构客户甲")
        self.assertEqual(extraction.fields.gender, "女")
        self.assertEqual(extraction.fields.identity_number, _synthetic_identity_number())
        self.assertEqual(extraction.fields.birthday, date(1990, 2, 2))
        self.assertEqual(extraction.fields.mobile, "19900000000")
        self.assertEqual(extraction.fields.address, "虚构地址 A")
        self.assertEqual(
            extraction.fields.other_phones,
            ("010-0000-0000", "021-0000-0000"),
        )

    def test_pairs_horizontal_label_value_cells(self):
        blocks = [
            _block("姓名", 20, 20, 40),
            _block("虚构客户乙", 75, 20, 100),
            _block("性别", 230, 20, 40),
            _block("男", 280, 20, 20),
            _block("身份证号", 350, 20, 80),
            _block(_synthetic_identity_number(), 445, 20, 190),
            _block("手机", 20, 60, 40),
            _block("19900000002", 75, 60, 110),
            _block("家属亲友", 20, 110, 100),
        ]

        extraction = extract_primary_customer(_result(*blocks))

        self.assertEqual(extraction.status, "ready")
        self.assertEqual(extraction.fields.name, "虚构客户乙")
        self.assertEqual(extraction.fields.gender, "男")
        self.assertEqual(extraction.fields.mobile, "19900000002")
        self.assertIsNone(extraction.fields.birthday)

    def test_blank_name_cell_is_not_filled_from_adjacent_phone_column(self):
        blocks = [
            _block("姓名", 20, 20, 40),
            _block("手机", 300, 20, 40),
            _block("身份证号", 600, 20, 80),
            _block("19900000003", 300, 50, 110),
            _block(_synthetic_identity_number(), 600, 50, 190),
            _block("家属亲友", 20, 100, 100),
        ]

        extraction = extract_primary_customer(_result(*blocks))

        self.assertEqual(extraction.decision, "REVIEW_REQUIRED")
        self.assertIsNone(extraction.fields.name)
        self.assertEqual(extraction.fields.mobile, "19900000003")
        self.assertIn(
            ReviewReason.MAIN_CUSTOMER_IDENTITY_UNCLEAR,
            extraction.review_reasons,
        )

    def test_family_section_fields_do_not_replace_primary_customer(self):
        extraction = extract_primary_customer(_result(*_complete_table()))

        self.assertEqual(extraction.fields.name, "虚构客户甲")
        self.assertEqual(extraction.fields.mobile, "19900000000")
        self.assertNotIn("19900000001", extraction.fields.other_phones)
        self.assertFalse(extraction.needs_manual_review)

    def test_multiple_primary_name_candidates_require_review(self):
        blocks = _complete_table()
        blocks.extend(
            [
                _block("姓名", 40, 155, 40),
                _block("虚构客户丙", 40, 175, 100),
                _block("家属亲友", 40, 230, 100),
            ]
        )

        extraction = extract_primary_customer(_result(*blocks))

        self.assertEqual(extraction.decision, "REVIEW_REQUIRED")
        self.assertIsNone(extraction.fields.name)
        self.assertIn(
            ReviewReason.MAIN_CUSTOMER_IDENTITY_UNCLEAR,
            extraction.review_reasons,
        )

    def test_ambiguous_handwritten_mobile_candidate_requires_review(self):
        blocks = _complete_table()
        mobile_index = next(i for i, block in enumerate(blocks) if block.text == "19900000000")
        blocks[mobile_index] = _block(
            "19900000000",
            40,
            120,
            110,
            characters=(
                OcrCharacter(
                    text="9",
                    candidates=(CharacterCandidate(text="9"), CharacterCandidate(text="8")),
                ),
            ),
        )

        extraction = extract_primary_customer(_result(*blocks))

        self.assertEqual(extraction.decision, "REVIEW_REQUIRED")
        self.assertIsNone(extraction.fields.mobile)
        self.assertIn(ReviewReason.MOBILE_UNCERTAIN, extraction.review_reasons)

    def test_ambiguous_handwritten_label_requires_review(self):
        blocks = _complete_table()
        name_label_index = next(i for i, block in enumerate(blocks) if block.text == "姓名")
        blocks[name_label_index] = _block(
            "姓名",
            40,
            20,
            40,
            characters=(
                OcrCharacter(
                    text="姓",
                    candidates=(CharacterCandidate(text="姓"), CharacterCandidate(text="性")),
                ),
            ),
        )

        extraction = extract_primary_customer(_result(*blocks))

        self.assertEqual(extraction.decision, "REVIEW_REQUIRED")
        self.assertIsNone(extraction.fields.name)
        self.assertIn(ReviewReason.TABLE_LAYOUT_UNCERTAIN, extraction.review_reasons)

    def test_invalid_identity_checksum_in_table_requires_review(self):
        valid = _synthetic_identity_number()
        invalid = valid[:-1] + ("0" if valid[-1] != "0" else "1")

        extraction = extract_primary_customer(
            _result(*_complete_table(identity_number=invalid))
        )

        self.assertEqual(extraction.decision, "REVIEW_REQUIRED")
        self.assertIn(
            ReviewReason.IDENTITY_NUMBER_UNCERTAIN,
            extraction.review_reasons,
        )

    def test_table_layout_does_not_derive_birthday_from_identity_number(self):
        blocks = [
            _block("姓名", 20, 20, 40),
            _block("身份证号", 350, 20, 80),
            _block("虚构客户丁", 20, 50, 100),
            _block(_synthetic_identity_number("19880709"), 350, 50, 190),
            _block("手机", 20, 90, 40),
            _block("19900000004", 75, 90, 110),
            _block("家属亲友", 20, 130, 100),
        ]

        extraction = extract_primary_customer(_result(*blocks))

        self.assertEqual(extraction.status, "ready")
        self.assertIsNone(extraction.fields.birthday)

    def test_overlapping_column_candidates_are_not_assigned_by_guess(self):
        blocks = [
            _block("姓名", 20, 20, 90),
            _block("性别", 85, 20, 60),
            _block("身份证号", 400, 20, 80),
            _block("虚构客户戊", 45, 50, 100),
            _block("女", 400, 50, 20),
            _block(_synthetic_identity_number(), 550, 50, 190),
            _block("手机", 20, 90, 40),
            _block("19900000005", 75, 90, 110),
            _block("家属亲友", 20, 130, 100),
        ]

        extraction = extract_primary_customer(_result(*blocks))

        self.assertEqual(extraction.decision, "REVIEW_REQUIRED")
        self.assertIn(ReviewReason.TABLE_LAYOUT_UNCERTAIN, extraction.review_reasons)
        self.assertIsNone(extraction.fields.name)

    def test_positioned_blocks_are_sorted_geometrically_before_family_cutoff(self):
        blocks = list(reversed(_complete_table()))

        extraction = extract_primary_customer(_result(*blocks))

        self.assertEqual(extraction.status, "ready")
        self.assertEqual(extraction.fields.name, "虚构客户甲")
        self.assertEqual(extraction.fields.mobile, "19900000000")

    def test_table_only_payload_without_coordinates_does_not_guess(self):
        extraction = extract_primary_customer(
            OcrResult(
                status="success",
                blocks=(
                    OcrBlock(text="姓名"),
                    OcrBlock(text="虚构客户己"),
                    OcrBlock(text="手机"),
                    OcrBlock(text="19900000006"),
                    OcrBlock(text="身份证号"),
                    OcrBlock(text=_synthetic_identity_number()),
                ),
                request_id="synthetic-no-coordinates",
                service_log_id=None,
                image_mime_type="image/jpeg",
                image_width=1200,
                image_height=1800,
                upload_mode="full_image_authorized",
            )
        )

        self.assertEqual(extraction.decision, "REVIEW_REQUIRED")
        self.assertIsNone(extraction.fields.name)
        self.assertIsNone(extraction.fields.mobile)
        self.assertIn(
            ReviewReason.MAIN_CUSTOMER_IDENTITY_UNCLEAR,
            extraction.review_reasons,
        )


if __name__ == "__main__":
    unittest.main()
