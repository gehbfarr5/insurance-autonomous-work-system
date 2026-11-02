from __future__ import annotations

import unittest
from datetime import date, datetime
from unittest.mock import Mock

from muse_customer_card_ocr import (
    AddressBookRequiredError,
    ContactsCreateArgumentsError,
    CustomerCardFields,
    FieldExtractionResult,
    ICloudContactDraft,
    call_contacts_create,
    map_to_icloud_fields,
)
from muse_customer_card_ocr.contacts_create_adapter import build_contacts_create_arguments


def ready_draft(*, include_optional: bool = True) -> ICloudContactDraft:
    fields = CustomerCardFields(
        name="欧阳虚构甲",
        mobile="19900000000",
        birthday=date(1990, 2, 2) if include_optional else None,
        address="虚构地址 A，原文完整保留" if include_optional else None,
        other_phones=("010-00000000", "021-00000000") if include_optional else (),
        gender="女" if include_optional else None,
        identity_number="999999199002020013" if include_optional else None,
    )
    extraction = FieldExtractionResult(status="ready", fields=fields, review_reasons=())
    return map_to_icloud_fields(extraction)


class ContactsCreateAdapterTests(unittest.TestCase):
    def test_mock_receives_complete_verified_contacts_create_shape(self):
        mock_tool = Mock(return_value={"contact_id": "synthetic-contact-id"})
        draft = ready_draft()

        result = call_contacts_create(
            draft,
            session_id="synthetic-apple-login-session",
            address_book_id="synthetic-verified-address-book",
            call_tool=mock_tool,
        )

        self.assertEqual(result, {"contact_id": "synthetic-contact-id"})
        mock_tool.assert_called_once_with(
            "contacts_create",
            {
                "session_id": "synthetic-apple-login-session",
                "address_book_id": "synthetic-verified-address-book",
                "contact": {
                    "name": {"full": "欧阳虚构甲"},
                    "phones": [
                        {"value": "19900000000", "type": ["cell"], "primary": True},
                        {"value": "010-00000000", "type": ["other"], "primary": False},
                        {"value": "021-00000000", "type": ["other"], "primary": False},
                    ],
                    "birthday": "1990-02-02",
                    "addresses": [{"street": "虚构地址 A，原文完整保留"}],
                    "note": "性别：女\n身份证号：999999199002020013",
                },
            },
        )

    def test_missing_optional_fields_are_omitted_not_sent_as_null_or_empty(self):
        arguments = build_contacts_create_arguments(
            ready_draft(include_optional=False),
            session_id="synthetic-session",
            address_book_id="synthetic-book",
        )

        self.assertEqual(
            arguments,
            {
                "session_id": "synthetic-session",
                "address_book_id": "synthetic-book",
                "contact": {
                    "name": {"full": "欧阳虚构甲"},
                    "phones": [
                        {"value": "19900000000", "type": ["cell"], "primary": True}
                    ],
                },
            },
        )

    def test_missing_address_book_fails_before_tool_call(self):
        mock_tool = Mock()

        with self.assertRaises(AddressBookRequiredError):
            call_contacts_create(
                ready_draft(),
                session_id="synthetic-session",
                call_tool=mock_tool,
            )

        mock_tool.assert_not_called()

    def test_missing_or_blank_session_is_rejected_before_tool_call(self):
        mock_tool = Mock()
        for session_id in ("", "   "):
            with self.subTest(session_id="blank"):
                with self.assertRaises(ContactsCreateArgumentsError):
                    call_contacts_create(
                        ready_draft(),
                        session_id=session_id,
                        address_book_id="synthetic-book",
                        call_tool=mock_tool,
                    )
        mock_tool.assert_not_called()

    def test_missing_required_name_or_mobile_is_rejected(self):
        for draft in (
            ICloudContactDraft(name_full="", phone_mobile="19900000000"),
            ICloudContactDraft(name_full="虚构客户", phone_mobile=" "),
        ):
            with self.subTest(missing="required field"):
                with self.assertRaises(ContactsCreateArgumentsError):
                    build_contacts_create_arguments(
                        draft,
                        session_id="synthetic-session",
                        address_book_id="synthetic-book",
                    )

    def test_datetime_is_rejected_as_birthday_instead_of_serializing_time(self):
        draft = ICloudContactDraft(
            name_full="虚构客户", phone_mobile="19900000000", birthday=datetime(1990, 2, 2)
        )
        with self.assertRaises(ContactsCreateArgumentsError):
            build_contacts_create_arguments(
                draft,
                session_id="synthetic-session",
                address_book_id="synthetic-book",
            )

    def test_adapter_only_calls_create_and_preserves_full_name(self):
        mock_tool = Mock(return_value={"ok": True})
        call_contacts_create(
            ready_draft(include_optional=False),
            session_id="synthetic-session",
            address_book_id="synthetic-book",
            call_tool=mock_tool,
        )

        self.assertEqual(mock_tool.call_count, 1)
        self.assertEqual(mock_tool.call_args.args[0], "contacts_create")
        name = mock_tool.call_args.args[1]["contact"]["name"]
        self.assertEqual(name, {"full": "欧阳虚构甲"})
        self.assertNotIn("family", name)
        self.assertNotIn("given", name)


if __name__ == "__main__":
    unittest.main()
