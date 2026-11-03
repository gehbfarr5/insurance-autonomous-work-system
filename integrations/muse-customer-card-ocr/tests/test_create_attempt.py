from __future__ import annotations

import json
import os
import tempfile
import unittest
from pathlib import Path

from muse_customer_card_ocr import CreateAttemptError, CreateAttemptJournal


class CreateAttemptJournalTests(unittest.TestCase):
    def test_pending_create_blocks_another_attempt_and_contains_no_customer_data(self):
        with tempfile.TemporaryDirectory() as temporary:
            folder = Path(temporary) / "private-state"
            with CreateAttemptJournal(folder) as journal:
                operation_id = journal.begin()
                self.assertEqual(journal.pending["operation_id"], operation_id)
                with self.assertRaises(CreateAttemptError) as caught:
                    journal.begin()
                self.assertEqual(caught.exception.code, "PRIOR_CREATE_REQUIRES_RECONCILIATION")
                state_text = journal.path.read_text(encoding="utf-8")
                self.assertNotIn("Synthetic Person", state_text)
                self.assertNotIn("13800138000", state_text)
                self.assertEqual(os.stat(journal.path).st_mode & 0o777, 0o600)
                self.assertEqual(os.stat(folder).st_mode & 0o777, 0o700)

    def test_created_readback_state_stays_pending_until_verified_complete(self):
        with tempfile.TemporaryDirectory() as temporary:
            with CreateAttemptJournal(temporary) as journal:
                operation_id = journal.begin()
                journal.mark_created(operation_id, "synthetic-contact-id")
                self.assertEqual(journal.pending["phase"], "CREATED_NEEDS_READBACK")
                self.assertEqual(journal.pending["contact_id"], "synthetic-contact-id")
                self.assertEqual(os.stat(journal.path).st_mode & 0o777, 0o600)
                self.assertEqual(os.stat(temporary).st_mode & 0o777, 0o700)
                journal.complete(operation_id)
                self.assertIsNone(journal.pending)
                state = json.loads(journal.path.read_text())
                self.assertIsNone(state["pending"])
                self.assertNotIn("synthetic-contact-id", json.dumps(state))

    def test_created_readback_state_rejects_invalid_contact_id(self):
        with tempfile.TemporaryDirectory() as temporary:
            with CreateAttemptJournal(temporary) as journal:
                operation_id = journal.begin()
                with self.assertRaises(CreateAttemptError) as caught:
                    journal.mark_created(operation_id, "bad\nid")
                self.assertEqual(caught.exception.code, "CREATE_CONTACT_ID_INVALID")
                self.assertEqual(journal.pending["phase"], "OUTCOME_UNKNOWN")

    def test_legacy_created_pending_state_without_contact_id_remains_manual(self):
        with tempfile.TemporaryDirectory() as temporary:
            folder = Path(temporary)
            path = folder / "contact-create-state.json"
            path.write_text(
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
            os.chmod(path, 0o600)
            with CreateAttemptJournal(folder) as journal:
                self.assertEqual(journal.pending["operation_id"], "legacy-operation")
                self.assertNotIn("contact_id", journal.pending)

    def test_manual_resolution_requires_the_exact_pending_operation(self):
        with tempfile.TemporaryDirectory() as temporary:
            with CreateAttemptJournal(temporary) as journal:
                operation_id = journal.begin()
                with self.assertRaises(CreateAttemptError):
                    journal.resolve_pending("wrong-id", "CONTACT_CONFIRMED")
                with self.assertRaises(CreateAttemptError):
                    journal.resolve_pending(operation_id, "MAYBE")
                journal.resolve_pending(operation_id, "NO_CONTACT_AFTER_MANUAL_CHECK")
                self.assertIsNone(journal.pending)
                stored = json.loads(journal.path.read_text())
                self.assertEqual(stored["last_resolution"]["result"], "NO_CONTACT_AFTER_MANUAL_CHECK")


if __name__ == "__main__":
    unittest.main()
