from __future__ import annotations

import copy
import tempfile
import unittest
from pathlib import Path

from muse_customer_card_ocr.acceptance_metrics import (
    AcceptanceInputError,
    FIELD_NAMES,
    _load_json,
    aggregate_30_card_acceptance,
)


def sample(
    index=0,
    *,
    auto_usable=True,
    released=True,
    field_updates=None,
    reasons=None,
    diversity_updates=None,
):
    field_accuracy = {
        field: "PASS" if released else "NOT_APPLICABLE" for field in FIELD_NAMES
    }
    field_accuracy.update(field_updates or {})
    diversity = {
        "handwriting_code": "H1" if index % 2 == 0 else "H2",
        "clarity_code": "CLEAR" if index % 2 == 0 else "MODERATE",
        "table_layout_code": "L1" if index % 2 == 0 else "L2",
    }
    diversity.update(diversity_updates or {})
    return {
        "eligible": True,
        **diversity,
        "auto_usable_draft": auto_usable,
        "manual_review_required": not auto_usable,
        "released_for_confirmation": released,
        "field_accuracy": field_accuracy,
        "failure_reason_codes": reasons or ([] if auto_usable else ["NO_DRAFT"]),
    }


def payload(samples=None, **study_updates):
    study = {
        "authorization_confirmed": True,
        "distinct_real_cards_verified": True,
        "reference_annotations_reviewed": True,
    }
    study.update(study_updates)
    return {
        "schema_version": "1.1",
        "study": study,
        "sample_results": samples if samples is not None else [sample(i) for i in range(30)],
    }


class AcceptanceMetricsTests(unittest.TestCase):
    def test_exact_denominators_and_thresholds(self):
        samples = [sample(i) for i in range(27)]
        samples.extend(
            sample(
                index,
                auto_usable=False,
                field_updates={"main_customer": "PASS"},
                reasons=["MANUAL_CORRECTION_REQUIRED"],
            )
            for index in range(27, 30)
        )

        result = aggregate_30_card_acceptance(payload(samples))

        self.assertEqual(result["real_card_ocr_result"], "PASS")
        self.assertEqual(result["sample_gate"]["eligible_samples"], 30)
        self.assertEqual(result["auto_usable_drafts"]["numerator"], 27)
        self.assertEqual(result["auto_usable_drafts"]["denominator"], 30)
        self.assertEqual(result["auto_usable_drafts"]["rate_percent"], 90.0)
        self.assertEqual(result["manual_review_required"]["numerator"], 3)
        self.assertEqual(result["manual_review_required"]["denominator"], 30)
        self.assertEqual(result["released_draft_accuracy"]["name"]["denominator"], 30)
        self.assertEqual(result["released_draft_accuracy"]["name"]["status"], "PASS")
        self.assertEqual(result["sample_diversity"]["status"], "PASS")
        self.assertEqual(
            result["sample_diversity"]["dimensions"]["handwriting_code"]["distinct_category_count"],
            2,
        )
        self.assertEqual(
            sum(
                result["sample_diversity"]["dimensions"]["clarity_code"]["category_counts"].values()
            ),
            30,
        )
        self.assertEqual(result["contact_safety"]["duplicate_miss"]["status"], "NOT_TESTED")
        self.assertEqual(result["v1_0_stable_status"], "VALIDATION_PENDING")
        self.assertNotIn("sample_results", result)

    def test_core_accuracy_failure_fails_ocr_acceptance(self):
        samples = [sample(i) for i in range(29)]
        samples.append(sample(29, field_updates={"mobile": "FAIL"}))

        result = aggregate_30_card_acceptance(payload(samples))

        self.assertEqual(result["real_card_ocr_result"], "FAIL")
        self.assertEqual(result["released_draft_accuracy"]["mobile"]["incorrect"], 1)
        self.assertEqual(result["released_draft_accuracy"]["mobile"]["accuracy_percent"], 96.6667)

    def test_unverified_core_field_is_not_counted_as_pass(self):
        samples = [sample(i) for i in range(29)]
        samples.append(sample(29, field_updates={"identity_number": "NOT_TESTED"}))

        result = aggregate_30_card_acceptance(payload(samples))

        self.assertEqual(result["released_draft_accuracy"]["identity_number"]["not_tested"], 1)
        self.assertEqual(result["released_draft_accuracy"]["identity_number"]["status"], "NOT_TESTED")
        self.assertEqual(result["real_card_ocr_result"], "NOT_TESTED")

    def test_blocked_study_attestations_skip_sample_counting(self):
        result = aggregate_30_card_acceptance(
            payload(
                samples=[{"not_a_valid_record": "private"}],
                authorization_confirmed=False,
            )
        )

        self.assertEqual(result["real_card_ocr_result"], "BLOCKED")
        self.assertEqual(result["sample_diversity"]["status"], "NOT_TESTED")
        self.assertIsNone(result["sample_gate"]["total_records"])
        self.assertIn(
            "REAL_DATA_AUTHORIZATION_NOT_CONFIRMED",
            result["sample_gate"]["blocking_reasons"],
        )

    def test_fewer_than_30_eligible_samples_blocks_the_threshold(self):
        result = aggregate_30_card_acceptance(payload([sample(i) for i in range(29)]))

        self.assertEqual(result["sample_gate"]["eligible_samples"], 29)
        self.assertEqual(result["sample_gate"]["status"], "BLOCKED")
        self.assertEqual(result["real_card_ocr_result"], "BLOCKED")
        self.assertEqual(result["auto_usable_drafts"]["status"], "BLOCKED")

    def test_excluded_rows_are_reported_but_never_enter_denominators(self):
        samples = [sample(i) for i in range(30)]
        samples.append(
            {
                "eligible": False,
                "handwriting_code": "NOT_APPLICABLE",
                "clarity_code": "NOT_APPLICABLE",
                "table_layout_code": "NOT_APPLICABLE",
                "auto_usable_draft": None,
                "manual_review_required": None,
                "released_for_confirmation": False,
                "field_accuracy": {field: "NOT_APPLICABLE" for field in FIELD_NAMES},
                "failure_reason_codes": ["OUT_OF_SCOPE_SAMPLE"],
            }
        )

        result = aggregate_30_card_acceptance(payload(samples))

        self.assertEqual(result["sample_gate"]["total_records"], 31)
        self.assertEqual(result["sample_gate"]["eligible_samples"], 30)
        self.assertEqual(result["sample_gate"]["excluded_samples"], 1)
        self.assertEqual(result["auto_usable_drafts"]["denominator"], 30)
        self.assertEqual(result["failure_reason_counts"]["OUT_OF_SCOPE_SAMPLE"], 1)
        self.assertEqual(
            sum(
                result["sample_diversity"]["dimensions"]["table_layout_code"]["category_counts"].values()
            ),
            30,
        )

    def test_thirty_same_category_samples_are_blocked(self):
        samples = [
            sample(
                i,
                diversity_updates={
                    "handwriting_code": "H1",
                    "clarity_code": "CLEAR",
                    "table_layout_code": "L1",
                },
            )
            for i in range(30)
        ]

        result = aggregate_30_card_acceptance(payload(samples))

        self.assertEqual(result["sample_gate"]["status"], "BLOCKED")
        self.assertEqual(result["sample_gate"]["eligible_samples"], 30)
        self.assertEqual(result["real_card_ocr_result"], "BLOCKED")
        self.assertEqual(result["auto_usable_drafts"]["status"], "BLOCKED")
        self.assertEqual(result["sample_diversity"]["status"], "BLOCKED")
        self.assertEqual(
            result["sample_diversity"]["dimensions"]["handwriting_code"]["distinct_category_count"],
            1,
        )
        self.assertIn(
            "INSUFFICIENT_HANDWRITING_CODE_DIVERSITY",
            result["sample_gate"]["blocking_reasons"],
        )

    def test_rejects_free_text_extra_fields_without_echoing_values(self):
        candidate = payload()
        candidate["sample_results"][0]["name"] = "Sensitive customer name"

        with self.assertRaises(AcceptanceInputError) as raised:
            aggregate_30_card_acceptance(candidate)

        self.assertNotIn("Sensitive customer name", str(raised.exception))

    def test_rejects_inconsistent_and_unrecognized_codes(self):
        candidate = payload()
        candidate["sample_results"][0]["manual_review_required"] = True
        with self.assertRaises(AcceptanceInputError):
            aggregate_30_card_acceptance(candidate)

        candidate = payload()
        candidate["sample_results"][0]["failure_reason_codes"] = ["raw OCR text"]
        with self.assertRaises(AcceptanceInputError):
            aggregate_30_card_acceptance(candidate)

    def test_auto_usable_sample_rejects_failure_reason_codes(self):
        candidate = payload()
        candidate["sample_results"][0]["failure_reason_codes"] = ["NAME_MISSING"]

        with self.assertRaises(AcceptanceInputError):
            aggregate_30_card_acceptance(candidate)

    def test_manual_review_sample_requires_a_failure_reason_code(self):
        candidate = payload()
        sample_result = candidate["sample_results"][0]
        sample_result["auto_usable_draft"] = False
        sample_result["manual_review_required"] = True
        sample_result["failure_reason_codes"] = []

        with self.assertRaises(AcceptanceInputError):
            aggregate_30_card_acceptance(candidate)

        candidate = payload()
        candidate["sample_results"][0]["clarity_code"] = "clear enough"
        with self.assertRaises(AcceptanceInputError):
            aggregate_30_card_acceptance(candidate)

    def test_aggregate_does_not_mutate_input(self):
        candidate = payload()
        original = copy.deepcopy(candidate)

        aggregate_30_card_acceptance(candidate)

        self.assertEqual(candidate, original)

    def test_json_loader_rejects_duplicate_object_keys(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "duplicate-keys.json"
            path.write_text('{"schema_version":"1.0","schema_version":"1.0"}', encoding="utf-8")
            with self.assertRaises(AcceptanceInputError):
                _load_json(path)


if __name__ == "__main__":
    unittest.main()
