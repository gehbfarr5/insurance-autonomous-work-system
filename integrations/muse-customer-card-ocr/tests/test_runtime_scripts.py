from __future__ import annotations

import contextlib
import importlib.util
import io
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from PIL import Image


PACKAGE_ROOT = Path(__file__).resolve().parents[1]
REPOSITORY_ROOT = PACKAGE_ROOT.parents[1]
CLIENT_PATH = REPOSITORY_ROOT / "carddav-mcp-client" / "mcp_client.py"
CREATE_PATH = REPOSITORY_ROOT / "wp10-real-card" / "wp10_create_readback.py"
DEDUP_PATH = REPOSITORY_ROOT / "wp10-real-card" / "wp10_ocr_dedup.py"
SEOUL_ADAPTER_PATH = REPOSITORY_ROOT / "wp8-seoul-ocr-service" / "muse_adapter.py"


def synthetic_identity_number() -> str:
    first_seventeen = "99999919900202001"
    weights = (7, 9, 10, 5, 8, 4, 2, 1, 6, 3, 7, 9, 10, 5, 8, 4, 2)
    check_chars = "10X98765432"
    total = sum(int(value) * weight for value, weight in zip(first_seventeen, weights))
    return first_seventeen + check_chars[total % 11]


def confirmed_draft() -> dict[str, object]:
    return {
        "extraction_status": "MANUALLY_REVIEWED",
        "review_status": "USER_CONFIRMED",
        "name": "Synthetic Person",
        "mobile": "13800138000",
        "gender": "女",
        "birthday": "1990-02-02",
        "identity_number": synthetic_identity_number(),
        "address": "Synthetic Street",
        "other_phones": ["05710000001"],
        "address_book_id": "synthetic-verified-address-book",
    }


def mcp_envelope(payload: dict[str, object]) -> dict[str, object]:
    return {"content": [{"type": "text", "text": json.dumps(payload, ensure_ascii=False)}]}


def complete_search(contacts: list[dict[str, object]]) -> dict[str, object]:
    return {"contacts": contacts, "truncated": False, "partial_failures": []}


class RuntimeSourceTests(unittest.TestCase):
    def setUp(self):
        self.env_before = os.environ.copy()
        self.path_before = list(sys.path)
        self.original_mcp_client = sys.modules.get("mcp_client")
        os.environ["MUSE_CUSTOMER_CARD_OCR_SRC"] = str(PACKAGE_ROOT / "src")
        os.environ["MUSE_CARD_DAV_MCP_CLIENT_SRC"] = str(CLIENT_PATH.parent)
        self.temporary = tempfile.TemporaryDirectory()
        os.environ["MUSE_FAMILY_CARD_STATE_DIR"] = self.temporary.name

        sys.path.insert(0, str(CLIENT_PATH.parent))
        spec = importlib.util.spec_from_file_location("mcp_client", CLIENT_PATH)
        self.mcp_client = importlib.util.module_from_spec(spec)
        sys.modules["mcp_client"] = self.mcp_client
        assert spec.loader is not None
        spec.loader.exec_module(self.mcp_client)
        self.create = self._load_script("wp11_test_create", CREATE_PATH)
        self.dedup = self._load_script("wp11_test_dedup", DEDUP_PATH)
        self.seoul_adapter = self._load_script("wp11_test_seoul_adapter", SEOUL_ADAPTER_PATH)

    def tearDown(self):
        os.environ.clear()
        os.environ.update(self.env_before)
        sys.path[:] = self.path_before
        if self.original_mcp_client is None:
            sys.modules.pop("mcp_client", None)
        else:
            sys.modules["mcp_client"] = self.original_mcp_client
        sys.modules.pop("wp11_test_create", None)
        sys.modules.pop("wp11_test_dedup", None)
        sys.modules.pop("wp11_test_seoul_adapter", None)
        self.temporary.cleanup()

    @staticmethod
    def _load_script(name: str, path: Path):
        spec = importlib.util.spec_from_file_location(name, path)
        module = importlib.util.module_from_spec(spec)
        sys.modules[name] = module
        assert spec.loader is not None
        spec.loader.exec_module(module)
        return module

    @staticmethod
    def _run_main(module, value: dict[str, object], argv=None):
        output = io.StringIO()
        with mock.patch.object(sys, "stdin", io.StringIO(json.dumps(value))), contextlib.redirect_stdout(output):
            status = module.main(argv if argv is not None else [])
        return status, output.getvalue()

    def test_create_requires_confirmation_without_any_mcp_call(self):
        calls = []
        self.mcp_client._mcp_call_resilient = lambda *args: calls.append(args)
        payload = confirmed_draft()
        payload["review_status"] = "NOT_CONFIRMED"
        status, output = self._run_main(self.create, payload)
        self.assertNotEqual(status, 0)
        self.assertIn("USER_CONFIRMATION_REQUIRED", output)
        self.assertEqual(calls, [])

    def test_seoul_ocr_entry_requires_full_image_authorization_before_read(self):
        image_path = Path(self.temporary.name) / "synthetic.png"
        Image.new("RGB", (8, 8), "white").save(image_path)
        calls = []

        def runner(_image_bytes):
            calls.append(True)
            return {"ok": True, "words_result_num": 0, "words_result": []}

        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            status = self.seoul_adapter.main([str(image_path)], ocr_runner=runner)
        self.assertEqual(status, 2)
        self.assertIn("FULL_IMAGE_AUTHORIZATION_REQUIRED", output.getvalue())
        self.assertEqual(calls, [])

    def test_wp10_ocr_entry_stops_before_mcp_when_parser_requires_review(self):
        image_path = Path(self.temporary.name) / "synthetic.png"
        Image.new("RGB", (8, 8), "white").save(image_path)
        calls = []
        self.mcp_client._mcp_call_resilient = lambda *args: calls.append(args)
        payload = {"ok": True, "words_result_num": 0, "words_result": []}
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            status = self.dedup.main(
                [str(image_path), "--full-image-authorized"],
                ocr_runner=lambda _image_bytes: payload,
            )
        self.assertEqual(status, 0)
        self.assertIn("DEDUP_DECISION: MANUAL_REVIEW", output.getvalue())
        self.assertEqual(calls, [])

    def test_incomplete_search_metadata_stops_before_create(self):
        for result in ({"status": "ok"}, {"contacts": []}):
            with self.subTest(result=result):
                calls = []

                def fake(method, params, msg_id):
                    tool = params["name"]
                    calls.append(tool)
                    if tool == "apple_login":
                        return mcp_envelope({"session_id": "synthetic-session", "capabilities": {"contactsRead": True, "contactsWrite": True}})
                    if tool == "contacts_search":
                        return mcp_envelope(result)
                    raise AssertionError("unexpected write")

                self.mcp_client._mcp_call_resilient = fake
                status, output = self._run_main(self.create, confirmed_draft())
                self.assertNotEqual(status, 0)
                self.assertIn("CONTACTS_SEARCH_RESULT_INCOMPLETE", output)
                self.assertEqual(calls, ["apple_login", "contacts_search"])
                self.assertNotIn("Synthetic Person", output)
                self.assertNotIn("13800138000", output)

    def test_create_readback_success_is_confirmed_and_values_stay_out_of_stdout(self):
        calls = []
        expected = confirmed_draft()

        def fake(method, params, msg_id):
            tool = params["name"]
            calls.append((tool, params["arguments"]))
            if tool == "apple_login":
                return mcp_envelope({"session_id": "synthetic-session", "capabilities": {"contactsRead": True, "contactsWrite": True}})
            if tool == "contacts_search":
                return mcp_envelope(complete_search([]))
            if tool == "contacts_create":
                return mcp_envelope({"contact_id": "synthetic-contact-id"})
            if tool == "contacts_read":
                return mcp_envelope(
                    {
                        "contact": {
                            "name": {"full": expected["name"]},
                            "phones": [
                                {"value": expected["mobile"], "primary": True},
                                {"value": expected["other_phones"][0], "primary": False},
                            ],
                            "birthday": expected["birthday"],
                            "note": f"性别：女\n身份证号：{expected['identity_number']}",
                            "addresses": [{"street": expected["address"]}],
                        }
                    }
                )
            raise AssertionError("unexpected MCP tool")

        self.mcp_client._mcp_call_resilient = fake
        status, output = self._run_main(self.create, expected)
        self.assertEqual(status, 0, output)
        self.assertIn("FINAL_RESULT: PASS", output)
        self.assertEqual(sum(tool == "contacts_create" for tool, _ in calls), 1)
        create_args = next(args for tool, args in calls if tool == "contacts_create")
        self.assertEqual(create_args["address_book_id"], "synthetic-verified-address-book")
        contact = create_args["contact"]
        self.assertEqual(len(contact["phones"]), 2)
        self.assertEqual(contact["addresses"][0]["street"], "Synthetic Street")
        self.assertNotIn("Synthetic Person", output)
        self.assertNotIn("13800138000", output)
        state = json.loads((Path(self.temporary.name) / "contact-create-state.json").read_text())
        self.assertIsNone(state["pending"])

    def test_create_requires_explicit_address_book_before_any_mcp_call(self):
        calls = []
        self.mcp_client._mcp_call_resilient = lambda *args: calls.append(args)
        data = confirmed_draft()
        del data["address_book_id"]
        status, output = self._run_main(self.create, data)
        self.assertNotEqual(status, 0)
        self.assertIn("ADDRESS_BOOK_ID_REQUIRED", output)
        self.assertEqual(calls, [])

    def test_pending_readback_can_resume_by_operation_id_without_recreating(self):
        calls = []
        expected = confirmed_draft()
        read_count = 0

        def fake(method, params, msg_id):
            nonlocal read_count
            tool = params["name"]
            calls.append((tool, params["arguments"]))
            if tool == "apple_login":
                return mcp_envelope(
                    {"session_id": "synthetic-session", "capabilities": {"contactsRead": True, "contactsWrite": True}}
                )
            if tool == "contacts_search":
                return mcp_envelope(complete_search([]))
            if tool == "contacts_create":
                return mcp_envelope({"contact_id": "synthetic-contact-id"})
            if tool == "contacts_read":
                read_count += 1
                if read_count == 1:
                    raise RuntimeError("Synthetic readback transport failure")
                return mcp_envelope(
                    {
                        "contact": {
                            "name": {"full": expected["name"]},
                            "phones": [
                                {"value": expected["mobile"], "primary": True},
                                {"value": expected["other_phones"][0], "primary": False},
                            ],
                            "birthday": expected["birthday"],
                            "note": f"性别：女\n身份证号：{expected['identity_number']}",
                            "addresses": [{"street": expected["address"]}],
                        }
                    }
                )
            raise AssertionError("unexpected MCP tool")

        self.mcp_client._mcp_call_resilient = fake
        status, first_output = self._run_main(self.create, expected)
        self.assertNotEqual(status, 0)
        self.assertIn("READBACK_OUTCOME: UNKNOWN", first_output)
        self.assertNotIn("Synthetic Person", first_output)
        self.assertNotIn(expected["mobile"], first_output)
        state_path = Path(self.temporary.name) / "contact-create-state.json"
        stored = json.loads(state_path.read_text())
        pending = stored["pending"]
        self.assertEqual(pending["phase"], "CREATED_NEEDS_READBACK")
        self.assertEqual(pending["contact_id"], "synthetic-contact-id")
        operation_id = pending["operation_id"]

        resume_input = confirmed_draft()
        resume_input.pop("address_book_id")
        resume_input["operation_id"] = operation_id
        self.assertNotIn("address_book_id", resume_input)
        status, resume_output = self._run_main(
            self.create, resume_input, ["--resume-pending"]
        )
        self.assertEqual(status, 0, resume_output)
        self.assertIn("FINAL_RESULT: RECOVERED_READBACK_PASS", resume_output)
        self.assertNotIn("synthetic-contact-id", resume_output)
        self.assertNotIn("Synthetic Person", resume_output)
        self.assertNotIn(expected["mobile"], resume_output)
        self.assertEqual(sum(tool == "contacts_create" for tool, _ in calls), 1)
        self.assertEqual(sum(tool == "contacts_read" for tool, _ in calls), 2)
        self.assertIsNone(json.loads(state_path.read_text())["pending"])

    def test_pending_readback_mismatch_keeps_operation_pending(self):
        expected = confirmed_draft()
        calls = []

        def fake(method, params, msg_id):
            tool = params["name"]
            calls.append(tool)
            if tool == "apple_login":
                return mcp_envelope(
                    {"session_id": "synthetic-session", "capabilities": {"contactsRead": True, "contactsWrite": True}}
                )
            if tool == "contacts_search":
                return mcp_envelope(complete_search([]))
            if tool == "contacts_create":
                return mcp_envelope({"contact_id": "synthetic-contact-id"})
            if tool == "contacts_read":
                if calls.count("contacts_read") == 1:
                    raise RuntimeError("Synthetic readback transport failure")
                return mcp_envelope({"contact": {"name": {"full": "Different Synthetic Person"}}})
            raise AssertionError("unexpected MCP tool")

        self.mcp_client._mcp_call_resilient = fake
        status, _ = self._run_main(self.create, expected)
        self.assertNotEqual(status, 0)
        operation_id = json.loads(
            (Path(self.temporary.name) / "contact-create-state.json").read_text()
        )["pending"]["operation_id"]

        resume_input = confirmed_draft()
        resume_input["operation_id"] = operation_id
        status, output = self._run_main(self.create, resume_input, ["--resume-pending"])
        self.assertNotEqual(status, 0)
        self.assertIn("FINAL_RESULT: RECOVERY_REMAINS_PENDING", output)
        self.assertNotIn("Different Synthetic Person", output)
        self.assertEqual(calls.count("contacts_create"), 1)
        self.assertEqual(
            json.loads((Path(self.temporary.name) / "contact-create-state.json").read_text())["pending"]["phase"],
            "CREATED_NEEDS_READBACK",
        )

    def test_pending_readback_without_matching_operation_id_stops_before_mcp(self):
        calls = []

        def fake(method, params, msg_id):
            tool = params["name"]
            calls.append(tool)
            if tool == "apple_login":
                return mcp_envelope(
                    {"session_id": "synthetic-session", "capabilities": {"contactsRead": True, "contactsWrite": True}}
                )
            if tool == "contacts_search":
                return mcp_envelope(complete_search([]))
            if tool == "contacts_create":
                return mcp_envelope({"contact_id": "synthetic-contact-id"})
            if tool == "contacts_read":
                raise RuntimeError("Synthetic readback transport failure")
            raise AssertionError("unexpected MCP tool")

        self.mcp_client._mcp_call_resilient = fake
        status, _ = self._run_main(self.create, confirmed_draft())
        self.assertNotEqual(status, 0)
        resume_input = confirmed_draft()
        resume_input["operation_id"] = "not-the-pending-id"
        count_before = len(calls)
        status, output = self._run_main(self.create, resume_input, ["--resume-pending"])
        self.assertNotEqual(status, 0)
        self.assertIn("PENDING_OPERATION_NOT_FOUND", output)
        self.assertEqual(calls[count_before:], [])

    def test_legacy_pending_readback_without_contact_id_stops_before_mcp(self):
        state_path = Path(self.temporary.name) / "contact-create-state.json"
        state_path.write_text(
            json.dumps(
                {
                    "version": 1,
                    "pending": {
                        "operation_id": "legacy-operation",
                        "phase": "CREATED_NEEDS_READBACK",
                        "started_at": "2026-11-03T00:00:00+00:00",
                    },
                }
            ),
            encoding="utf-8",
        )
        os.chmod(state_path, 0o600)
        calls = []
        self.mcp_client._mcp_call_resilient = lambda *args: calls.append(args)
        resume_input = confirmed_draft()
        resume_input["operation_id"] = "legacy-operation"
        status, output = self._run_main(self.create, resume_input, ["--resume-pending"])
        self.assertNotEqual(status, 0)
        self.assertIn("PENDING_CONTACT_ID_UNAVAILABLE", output)
        self.assertEqual(calls, [])

    def test_uncertain_create_persists_pending_state_and_blocks_next_create(self):
        calls = []

        def fake(method, params, msg_id):
            tool = params["name"]
            calls.append(tool)
            if tool == "apple_login":
                return mcp_envelope({"session_id": "synthetic-session", "capabilities": {"contactsRead": True, "contactsWrite": True}})
            if tool == "contacts_search":
                return mcp_envelope(complete_search([]))
            if tool == "contacts_create":
                raise RuntimeError("Synthetic Person 13800138000 server body")
            raise AssertionError("unexpected MCP tool")

        self.mcp_client._mcp_call_resilient = fake
        status, output = self._run_main(self.create, confirmed_draft())
        self.assertNotEqual(status, 0)
        self.assertIn("CREATE_OUTCOME: UNKNOWN", output)
        self.assertIn("PENDING_OPERATION_ID:", output)
        self.assertNotIn("Synthetic Person", output)
        self.assertNotIn("13800138000", output)
        state_path = Path(self.temporary.name) / "contact-create-state.json"
        stored = json.loads(state_path.read_text())
        self.assertEqual(stored["pending"]["phase"], "OUTCOME_UNKNOWN")

        count_before = len(calls)
        status, next_output = self._run_main(self.create, confirmed_draft())
        self.assertNotEqual(status, 0)
        self.assertIn("PRIOR_CREATE_REQUIRES_RECONCILIATION", next_output)
        self.assertEqual(len(calls), count_before)

    def test_session_rejection_never_retries_contact_create(self):
        session_error = self.mcp_client.McpSessionError("Synthetic server detail")
        call = mock.Mock(side_effect=session_error)
        self.mcp_client._load_state = mock.Mock(return_value={"access_token": "synthetic", "mcp_session_id": "session"})
        self.mcp_client._mcp_call = call
        self.mcp_client._session = mock.Mock()
        self.mcp_client._save_state = mock.Mock()
        with self.assertRaises(self.mcp_client.McpSessionError):
            self.mcp_client._mcp_call_resilient(
                "tools/call", {"name": "contacts_create", "arguments": {}}, 1
            )
        call.assert_called_once()
        self.mcp_client._session.assert_not_called()
        self.mcp_client._save_state.assert_not_called()

    def test_mcp_cli_does_not_print_tool_result_values(self):
        self.mcp_client._mcp_call_resilient = mock.Mock(
            return_value={"sensitive": "Synthetic Person 13800138000"}
        )
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            status = self.mcp_client.cmd_call("contacts_search", "{}")
        self.assertEqual(status, 0)
        self.assertIn("CALL_COMPLETE: True", output.getvalue())
        self.assertNotIn("Synthetic Person", output.getvalue())
        self.assertNotIn("13800138000", output.getvalue())

    def test_oauth_state_is_private_and_symlink_targets_are_rejected(self):
        state_dir = Path(self.temporary.name) / "oauth"
        state_path = state_dir / "oauth.json"
        with mock.patch.object(self.mcp_client, "STATE_DIR", str(state_dir)), mock.patch.object(
            self.mcp_client, "STATE", str(state_path)
        ):
            self.mcp_client._save_state({"access_token": "synthetic-token"})
            self.assertEqual(state_dir.stat().st_mode & 0o777, 0o700)
            self.assertEqual(state_path.stat().st_mode & 0o777, 0o600)
            self.assertEqual(self.mcp_client._load_state()["access_token"], "synthetic-token")

            target = Path(self.temporary.name) / "target.json"
            target.write_text("keep", encoding="utf-8")
            state_path.unlink()
            state_path.symlink_to(target)
            with self.assertRaises(RuntimeError):
                self.mcp_client._save_state({"access_token": "replacement"})
            self.assertEqual(target.read_text(encoding="utf-8"), "keep")

    def test_dedup_writes_unconfirmed_review_draft_safely(self):
        image_path = Path(self.temporary.name) / "synthetic.png"
        Image.new("RGB", (8, 8), "white").save(image_path)
        draft_out = Path(self.temporary.name) / "review_draft.json"

        def fake_runner(_bytes):
            return {
                "ok": True,
                "words_result_num": 1,
                "words_result": [
                    {
                        "words": "身份证号码：999999199002020013",
                        "location": {"left": 0, "top": 0, "width": 100, "height": 20},
                    }
                ],
            }

        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            status = self.dedup.main(
                [
                    str(image_path),
                    "--full-image-authorized",
                    "--review-draft-out",
                    str(draft_out),
                ],
                ocr_runner=fake_runner,
            )
        self.assertEqual(status, 0)
        self.assertIn("REVIEW_DRAFT_WRITTEN: True", output.getvalue())
        self.assertTrue(draft_out.is_file())
        self.assertEqual(draft_out.stat().st_mode & 0o777, 0o600)

        written_data = json.loads(draft_out.read_text(encoding="utf-8"))
        self.assertEqual(written_data["extraction_status"], "MANUALLY_REVIEWED")
        self.assertEqual(written_data["review_status"], "PENDING_USER_CONFIRMATION")
        self.assertEqual(written_data["identity_number"], "999999199002020013")

        # Feeding unconfirmed review draft to create script fails before any MCP call
        create_status, create_output = self._run_main(self.create, written_data)
        self.assertNotEqual(create_status, 0)
        self.assertIn("USER_CONFIRMATION_REQUIRED", create_output)


if __name__ == "__main__":
    unittest.main()
