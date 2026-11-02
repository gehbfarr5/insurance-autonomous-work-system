from __future__ import annotations

import unittest
from datetime import date

from muse_customer_card_ocr import (
    CustomerCardFields,
    FieldExtractionResult,
    ManualReviewRequiredError,
    ReviewReason,
    map_to_icloud_fields,
)


class ICloudFieldMappingTests(unittest.TestCase):
    def test_maps_native_fields_and_separate_note_lines(self):
        extraction = FieldExtractionResult(
            status="ready",
            fields=CustomerCardFields(
                name="虚构客户甲",
                mobile="19900000000",
                birthday=date(1990, 2, 2),
                address="虚构地址 A",
                other_phones=("010-00000000",),
                gender="女",
                identity_number="999999199002020013",
            ),
            review_reasons=(),
        )

        draft = map_to_icloud_fields(extraction)

        self.assertEqual(draft.name_full, "虚构客户甲")
        self.assertEqual(draft.phone_mobile, "19900000000")
        self.assertEqual(draft.phone_other, ("010-00000000",))
        self.assertEqual(draft.birthday, date(1990, 2, 2))
        self.assertEqual(draft.address, "虚构地址 A")
        self.assertEqual(
            draft.note,
            "性别：女\n身份证号：999999199002020013",
        )

    def test_omits_absent_optional_fields(self):
        extraction = FieldExtractionResult(
            status="ready",
            fields=CustomerCardFields(name="虚构客户甲", mobile="19900000000"),
            review_reasons=(),
        )

        draft = map_to_icloud_fields(extraction)

        self.assertIsNone(draft.birthday)
        self.assertIsNone(draft.address)
        self.assertEqual(draft.phone_other, ())
        self.assertIsNone(draft.note)

    def test_mapping_is_blocked_for_manual_review(self):
        extraction = FieldExtractionResult(
            status="needs_manual_review",
            fields=CustomerCardFields(name="虚构客户甲", mobile="19900000000"),
            review_reasons=(ReviewReason.IDENTITY_NUMBER_UNCERTAIN,),
        )

        with self.assertRaises(ManualReviewRequiredError):
            map_to_icloud_fields(extraction)

    def test_mapping_is_blocked_for_non_ready_status_even_without_reasons(self):
        extraction = FieldExtractionResult(
            status="pending",
            fields=CustomerCardFields(name="虚构客户甲", mobile="19900000000"),
            review_reasons=(),
        )

        with self.assertRaises(ManualReviewRequiredError):
            map_to_icloud_fields(extraction)

    def test_contact_draft_repr_redacts_customer_values(self):
        extraction = FieldExtractionResult(
            status="ready",
            fields=CustomerCardFields(name="VIRTUAL-CUSTOMER", mobile="19900000000"),
            review_reasons=(),
        )

        draft = map_to_icloud_fields(extraction)

        self.assertNotIn("VIRTUAL-CUSTOMER", repr(draft))
        self.assertNotIn("19900000000", repr(draft))


if __name__ == "__main__":
    unittest.main()
