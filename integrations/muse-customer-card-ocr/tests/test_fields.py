from __future__ import annotations

import unittest
from datetime import date

from muse_customer_card_ocr import (
    CharacterCandidate,
    OcrBlock,
    OcrCharacter,
    OcrResult,
    ReviewReason,
    extract_primary_customer,
)


def synthetic_identity_number(birthday: str = "19900202") -> str:
    first_seventeen = "999999" + birthday + "001"
    weights = (7, 9, 10, 5, 8, 4, 2, 1, 6, 3, 7, 9, 10, 5, 8, 4, 2)
    check_chars = "10X98765432"
    total = sum(int(value) * weight for value, weight in zip(first_seventeen, weights))
    return first_seventeen + check_chars[total % 11]


def make_result(*lines: str, special_blocks=()) -> OcrResult:
    blocks = tuple(OcrBlock(text=line) for line in lines) + tuple(special_blocks)
    return OcrResult(
        status="success",
        blocks=blocks,
        request_id="synthetic-request",
        service_log_id="12345",
        image_mime_type="image/jpeg",
        image_width=100,
        image_height=100,
        upload_mode="full_image_authorized",
    )


class CustomerFieldExtractionTests(unittest.TestCase):
    def test_extracts_explicit_customer_fields_before_family_section(self):
        identity_number = synthetic_identity_number()
        result = make_result(
            "客户姓名：虚构客户甲",
            "手机号码：+86 199-0000-0000",
            "出生日期：1990年2月2日",
            "联系地址：虚构地址 A",
            "宅电：010-00000000",
            "性别：女",
            f"身份证号码：{identity_number}",
            "家属亲友",
            "姓名：虚构家属乙",
            "手机：19900000001",
        )

        extraction = extract_primary_customer(result)

        self.assertEqual(extraction.status, "ready")
        self.assertEqual(extraction.fields.name, "虚构客户甲")
        self.assertEqual(extraction.fields.mobile, "19900000000")
        self.assertEqual(extraction.fields.birthday, date(1990, 2, 2))
        self.assertEqual(extraction.fields.address, "虚构地址 A")
        self.assertEqual(extraction.fields.other_phones, ("010-00000000",))
        self.assertEqual(extraction.fields.gender, "女")
        self.assertEqual(extraction.fields.identity_number, identity_number)
        self.assertFalse(extraction.needs_manual_review)

    def test_does_not_infer_birthday_from_identity_number(self):
        result = make_result(
            "客户姓名：虚构客户甲",
            "手机：19900000000",
            f"身份证号：{synthetic_identity_number()}",
        )

        extraction = extract_primary_customer(result)

        self.assertEqual(extraction.status, "ready")
        self.assertIsNone(extraction.fields.birthday)

    def test_identity_number_checksum_failure_requires_review(self):
        valid = synthetic_identity_number()
        invalid = valid[:-1] + ("0" if valid[-1] != "0" else "1")
        result = make_result(
            "客户姓名：虚构客户甲",
            "手机：19900000000",
            f"身份证号：{invalid}",
        )

        extraction = extract_primary_customer(result)

        self.assertTrue(extraction.needs_manual_review)
        self.assertIn(ReviewReason.IDENTITY_NUMBER_UNCERTAIN, extraction.review_reasons)

    def test_missing_identity_number_requires_review(self):
        result = make_result("客户姓名：虚构客户甲", "手机：19900000000")

        extraction = extract_primary_customer(result)

        self.assertTrue(extraction.needs_manual_review)
        self.assertIn(ReviewReason.IDENTITY_NUMBER_UNCERTAIN, extraction.review_reasons)

    def test_conflicting_identity_numbers_require_review(self):
        result = make_result(
            "客户姓名：虚构客户甲",
            "手机：19900000000",
            f"身份证号：{synthetic_identity_number('19900202')}",
            f"身份证号：{synthetic_identity_number('19900203')}",
        )

        extraction = extract_primary_customer(result)

        self.assertTrue(extraction.needs_manual_review)
        self.assertIn(ReviewReason.IDENTITY_NUMBER_CONFLICT, extraction.review_reasons)
        self.assertIsNone(extraction.fields.identity_number)

    def test_ambiguous_ocr_character_in_identity_number_requires_review(self):
        identity_number = synthetic_identity_number()
        block = OcrBlock(
            text=f"身份证号：{identity_number}",
            characters=(
                OcrCharacter(
                    text="9",
                    candidates=(CharacterCandidate(text="0"), CharacterCandidate(text="9")),
                ),
            ),
        )
        result = make_result("客户姓名：虚构客户甲", "手机：19900000000", special_blocks=(block,))

        extraction = extract_primary_customer(result)

        self.assertTrue(extraction.needs_manual_review)
        self.assertIn(ReviewReason.IDENTITY_NUMBER_UNCERTAIN, extraction.review_reasons)

    def test_ambiguous_primary_name_or_mobile_requires_review(self):
        ambiguous_name = OcrBlock(
            text="客户姓名：虚构客户甲",
            characters=(
                OcrCharacter(
                    text="甲",
                    candidates=(CharacterCandidate(text="乙"), CharacterCandidate(text="甲")),
                ),
            ),
        )
        ambiguous_mobile = OcrBlock(
            text="手机：19900000000",
            characters=(
                OcrCharacter(
                    text="9",
                    candidates=(CharacterCandidate(text="8"), CharacterCandidate(text="9")),
                ),
            ),
        )
        identity = f"身份证号：{synthetic_identity_number()}"

        name_result = make_result("手机：19900000000", identity, special_blocks=(ambiguous_name,))
        mobile_result = make_result("客户姓名：虚构客户甲", identity, special_blocks=(ambiguous_mobile,))

        name_extraction = extract_primary_customer(name_result)
        mobile_extraction = extract_primary_customer(mobile_result)

        self.assertIn(
            ReviewReason.MAIN_CUSTOMER_IDENTITY_UNCLEAR,
            name_extraction.review_reasons,
        )
        self.assertIn(ReviewReason.MOBILE_UNCERTAIN, mobile_extraction.review_reasons)
        self.assertTrue(name_extraction.needs_manual_review)
        self.assertTrue(mobile_extraction.needs_manual_review)

    def test_birthday_conflict_with_identity_number_requires_review(self):
        result = make_result(
            "客户姓名：虚构客户甲",
            "手机：19900000000",
            "生日：1990-02-03",
            f"身份证号：{synthetic_identity_number('19900202')}",
        )

        extraction = extract_primary_customer(result)

        self.assertTrue(extraction.needs_manual_review)
        self.assertIn(ReviewReason.BIRTHDAY_CONFLICT, extraction.review_reasons)
        self.assertEqual(extraction.fields.birthday, date(1990, 2, 3))

    def test_conflicting_mobile_numbers_require_review(self):
        result = make_result(
            "姓名：虚构客户甲",
            "手机：19900000000",
            "手机号码：19900000001",
        )

        extraction = extract_primary_customer(result)

        self.assertTrue(extraction.needs_manual_review)
        self.assertIn(ReviewReason.MOBILE_CONFLICT, extraction.review_reasons)

    def test_missing_or_ambiguous_primary_customer_requires_review(self):
        no_primary_name = make_result(
            "家属亲友",
            "姓名：虚构家属甲",
            "手机：19900000000",
        )
        conflicting_names = make_result(
            "姓名：虚构客户甲",
            "姓名：虚构客户乙",
            "手机：19900000000",
        )

        for result in (no_primary_name, conflicting_names):
            with self.subTest(result=result.request_id, blocks=len(result.blocks)):
                extraction = extract_primary_customer(result)
                self.assertTrue(extraction.needs_manual_review)
                self.assertIn(
                    ReviewReason.MAIN_CUSTOMER_IDENTITY_UNCLEAR,
                    extraction.review_reasons,
                )

    def test_unknown_gender_and_invalid_birthday_are_not_guessed(self):
        result = make_result(
            "客户姓名：虚构客户甲",
            "手机：19900000000",
            "生日：1990/02/02",
            "性别：未知",
        )

        extraction = extract_primary_customer(result)

        self.assertTrue(extraction.needs_manual_review)
        self.assertIsNone(extraction.fields.birthday)
        self.assertIsNone(extraction.fields.gender)
        self.assertIn(ReviewReason.BIRTHDAY_UNCERTAIN, extraction.review_reasons)
        self.assertIn(ReviewReason.GENDER_UNCERTAIN, extraction.review_reasons)

    def test_extraction_and_fields_repr_redact_customer_values(self):
        result = make_result("客户姓名：VIRTUAL-CUSTOMER", "手机：19900000000")

        extraction = extract_primary_customer(result)

        self.assertNotIn("VIRTUAL-CUSTOMER", repr(extraction))
        self.assertNotIn("VIRTUAL-CUSTOMER", repr(extraction.fields))


if __name__ == "__main__":
    unittest.main()
