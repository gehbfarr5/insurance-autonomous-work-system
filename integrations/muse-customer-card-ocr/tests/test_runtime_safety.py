from __future__ import annotations

import json
import unittest

from muse_customer_card_ocr import (
    BoundingBox,
    CharacterCandidate,
    OcrCharacter,
    OcrBlock,
    RuntimeContractError,
    decide_contact_duplicate,
    decode_mcp_tool_result,
    is_valid_identity_number,
    normalize_mobile_number,
    parse_confirmed_draft,
    parse_seoul_ocr_response,
    validate_contacts_search_result,
    verify_contact_readback,
)


def synthetic_identity_number(birthday: str = "19900202") -> str:
    first_seventeen = "999999" + birthday + "001"
    weights = (7, 9, 10, 5, 8, 4, 2, 1, 6, 3, 7, 9, 10, 5, 8, 4, 2)
    check_chars = "10X98765432"
    total = sum(int(value) * weight for value, weight in zip(first_seventeen, weights))
    return first_seventeen + check_chars[total % 11]


def draft(**updates):
    value = {
        "extraction_status": "MANUALLY_REVIEWED",
        "review_status": "USER_CONFIRMED",
        "name": "Synthetic Person",
        "mobile": "13800138000",
        "gender": "女",
        "birthday": "1990-02-02",
        "identity_number": synthetic_identity_number(),
        "address": "Synthetic Street",
        "other_phones": ["05710000001"],
    }
    value.update(updates)
    return value


def contact(name="Synthetic Person", mobile="13800138000"):
    return {"name": {"full": name}, "phones": [{"value": mobile}]}


def complete_search(*contacts):
    return {"contacts": list(contacts), "truncated": False, "partial_failures": []}


def readback(**updates):
    value = {
        "name": {"full": "Synthetic Person"},
        "phones": [
            {"value": "13800138000", "primary": True},
            {"value": "05710000001", "primary": False},
        ],
        "birthday": "1990-02-02",
        "note": f"性别：女\n身份证号：{synthetic_identity_number()}",
        "addresses": [{"street": "Synthetic Street"}],
    }
    value.update(updates)
    return value


class SeoulPayloadAdapterTests(unittest.TestCase):
    def test_preserves_geometry_probability_and_character_candidates(self):
        parsed = parse_seoul_ocr_response(
            {
                "ok": True,
                "words_result_num": 1,
                "words_result": [
                    {
                        "words": "SYNTHETIC",
                        "location": {"left": 4, "top": 5, "width": 30, "height": 9},
                        "probability": {"average": 0.96, "variance": 0.02, "min": 0.9},
                        "chars": [
                            {
                                "char": "S",
                                "location": {"left": 4, "top": 5, "width": 6, "height": 9},
                                "candidates": [{"word": "S", "prob": 0.99}],
                            }
                        ],
                    }
                ],
            }
        )
        self.assertEqual(len(parsed), 1)
        self.assertEqual(parsed[0].location, BoundingBox(4, 5, 30, 9))
        self.assertEqual(parsed[0].probability.average, 0.96)
        self.assertEqual(parsed[0].characters[0].text, "S")
        self.assertEqual(parsed[0].characters[0].candidates[0], CharacterCandidate("S", 0.99))

    def test_rejects_missing_or_malformed_words_instead_of_empty_default(self):
        cases = (
            {"ok": True},
            {"ok": True, "words_result": None},
            {"ok": False, "words_result": []},
            {"ok": True, "words_result_num": 2, "words_result": [{"words": "X"}]},
            {"ok": True, "words_result": [None]},
            {"ok": True, "words_result": [{"words": 42}]},
        )
        for payload in cases:
            with self.subTest(payload=payload):
                with self.assertRaises(RuntimeError):
                    parse_seoul_ocr_response(payload)


class RuntimeContractTests(unittest.TestCase):
    def test_confirmation_required_and_review_required_is_rejected(self):
        with self.assertRaises(RuntimeContractError) as caught:
            parse_confirmed_draft(draft(review_status="NOT_CONFIRMED"))
        self.assertEqual(caught.exception.code, "USER_CONFIRMATION_REQUIRED")
        with self.assertRaises(RuntimeContractError) as caught:
            parse_confirmed_draft(draft(extraction_status="REVIEW_REQUIRED"))
        self.assertEqual(caught.exception.code, "EXTRACTION_NOT_APPROVED")

    def test_confirmed_draft_validates_required_values(self):
        parsed = parse_confirmed_draft(draft(mobile="+86 138-0013-8000"))
        self.assertEqual(parsed["mobile"], "13800138000")
        self.assertEqual(parsed["other_phones"], ("05710000001",))
        self.assertTrue(is_valid_identity_number(parsed["identity_number"]))
        self.assertEqual(normalize_mobile_number("+86 138-0013-8000"), "13800138000")

    def test_ready_status_cannot_hide_birthday_identity_conflict(self):
        with self.assertRaises(RuntimeContractError) as caught:
            parse_confirmed_draft(draft(extraction_status="READY", birthday="1991-02-02"))
        self.assertEqual(caught.exception.code, "BIRTHDAY_IDENTITY_CONFLICT")

    def test_invalid_required_field_stops_before_any_mcp_decision(self):
        for changes in (
            {"mobile": "not-a-phone"},
            {"birthday": "1990-02-30"},
            {"identity_number": "000000000000000000"},
            {"gender": "未知"},
            {"name": "\n"},
        ):
            with self.subTest(changes=changes):
                with self.assertRaises(RuntimeContractError):
                    parse_confirmed_draft(draft(**changes))

    def test_mcp_result_decoder_rejects_partial_and_error_envelopes(self):
        for envelope in (
            None,
            {"isError": True, "content": [{"type": "text", "text": "private"}]},
            {"content": []},
            {"content": [{"type": "text", "text": "not-json"}]},
            {"content": [{"type": "text", "text": "[]"}]},
        ):
            with self.subTest(envelope=envelope):
                with self.assertRaises(RuntimeContractError):
                    decode_mcp_tool_result(envelope)

    def test_search_result_never_defaults_missing_contacts_to_empty(self):
        with self.assertRaises(RuntimeContractError) as caught:
            validate_contacts_search_result({"status": "ok"})
        self.assertEqual(caught.exception.code, "CONTACTS_SEARCH_RESULT_INCOMPLETE")
        with self.assertRaises(RuntimeContractError):
            validate_contacts_search_result({"contacts": []})
        with self.assertRaises(RuntimeContractError):
            validate_contacts_search_result({"contacts": [], "truncated": False})
        with self.assertRaises(RuntimeContractError):
            validate_contacts_search_result({"contacts": [], "truncated": True, "partial_failures": []})
        with self.assertRaises(RuntimeContractError):
            validate_contacts_search_result({"contacts": [], "truncated": False, "partial_failures": ["incomplete"]})
        with self.assertRaises(RuntimeContractError):
            validate_contacts_search_result(
                complete_search({"name": {"full": "Synthetic Person"}})
            )
        self.assertEqual(validate_contacts_search_result(complete_search()), ())

    def test_duplicate_decision_is_fail_closed_and_exact(self):
        empty = validate_contacts_search_result(complete_search())
        self.assertEqual(decide_contact_duplicate("Synthetic Person", "13800138000", empty, empty), ("ALLOW_CREATE", 0))
        exact = validate_contacts_search_result(complete_search(contact()))
        self.assertEqual(decide_contact_duplicate("Synthetic Person", "13800138000", exact, empty)[0], "EXISTS_SKIP")
        other = validate_contacts_search_result(complete_search(contact(name="Other Person", mobile="13800138000")))
        self.assertEqual(decide_contact_duplicate("Synthetic Person", "13800138000", empty, other)[0], "MANUAL_REVIEW")
        first = contact()
        first["contact_id"] = "same-id"
        conflicting = contact(mobile="13800138001")
        conflicting["contact_id"] = "same-id"
        with self.assertRaises(RuntimeContractError) as caught:
            decide_contact_duplicate(
                "Synthetic Person",
                "13800138000",
                validate_contacts_search_result(complete_search(first)),
                validate_contacts_search_result(complete_search(conflicting)),
            )
        self.assertEqual(caught.exception.code, "CONTACTS_SEARCH_RESULT_CONFLICT")
        many = tuple(contact(name=f"Person {index}", mobile=f"1380013{index:04d}") for index in range(50))
        with self.assertRaises(RuntimeContractError) as caught:
            decide_contact_duplicate("Synthetic Person", "13800138000", many, empty)
        self.assertEqual(caught.exception.code, "CONTACTS_SEARCH_LIMIT_REACHED")

    def test_readback_requires_primary_and_matches_optional_fields(self):
        expected = parse_confirmed_draft(draft())
        checks = verify_contact_readback(expected, readback())
        self.assertTrue(all(checks.values()))
        no_primary = readback(phones=[{"value": "13800138000"}, {"value": "05710000001"}])
        self.assertFalse(verify_contact_readback(expected, no_primary)["primary_phone"])
        extra_address = readback(addresses=[{"street": "Synthetic Street"}, {"street": "Other"}])
        self.assertFalse(verify_contact_readback(expected, extra_address)["address"])
        wrong_other = readback(phones=[{"value": "13800138000", "primary": True}])
        self.assertFalse(verify_contact_readback(expected, wrong_other)["phones"])


if __name__ == "__main__":
    unittest.main()
