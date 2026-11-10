"""test_safe_write_etag.py
Comprehensive isolated unit tests proving:
1. Stale expected_etag is NOT replaced with latest server ETag.
2. ETag conflict raises CONFLICT with 0 write requests sent.
3. Normal write preserves authorization, target restriction, and audit logging.
4. UNKNOWN write outcome triggers HALT and strictly prohibits auto-retry.
"""

import os
import shutil
import tempfile
import time
import unittest
from typing import Any, Dict, List

from isolated_adapter import IsolatedAdapter
from safe_write import (
    ApprovalToken,
    AuthUntrustedError,
    ConflictError,
    IntentStore,
    PermissionDeniedError,
    SafeWriteManager,
    UnknownWriteError,
    _b64url_encode,
    build_dedup_key,
)


class TestSafeWriteETagAndIsolation(unittest.TestCase):
    def setUp(self):
        self.tmp_dir = tempfile.mkdtemp(prefix="test_safe_write_")
        self.intent_log = os.path.join(self.tmp_dir, "intents.jsonl")
        self.store = IntentStore(self.intent_log)

        # Mock database
        self.mock_events: Dict[str, Dict[str, Any]] = {
            "evt-001": {
                "event_id": "evt-001",
                "etag": "mw9nlf7h",
                "title": "Test Event",
                "start": "2026-11-16T14:00:00+08:00",
                "end": "2026-11-16T15:00:00+08:00",
                "calendar_id": "test-cal-id",
            }
        }

        # Track network calls
        self.write_calls: List[Dict[str, Any]] = []
        self.read_calls: List[Dict[str, Any]] = []

    def tearDown(self):
        shutil.rmtree(self.tmp_dir, ignore_errors=True)

    def mock_read_fn(self, tool: str, args: Dict[str, Any]) -> Dict[str, Any]:
        self.read_calls.append({"tool": tool, "args": args})
        if tool == "calendar_list_events":
            return {"events": list(self.mock_events.values())}
        return {}

    def mock_write_fn(self, tool: str, args: Dict[str, Any]) -> Dict[str, Any]:
        self.write_calls.append({"tool": tool, "args": dict(args)})
        if tool == "calendar_update_event":
            eid = args.get("event_id")
            if eid in self.mock_events:
                # Update event etag in mock db
                self.mock_events[eid]["etag"] = "mw9nlf7i"
                return {"updated": True, "event_id": eid, "etag": "mw9nlf7i"}
        return {"ok": True}

    def _create_auth(self, tool: str = "calendar_update_event", target: str = "evt-001", dedup_key: str = "*") -> ApprovalToken:
        return ApprovalToken(
            token_id="tok-test-001",
            issuer="user_message",
            authorized_at=time.time(),
            expires_at=time.time() + 3600,
            scope_tool=tool,
            scope_target=target,
            bound_dedup_key=dedup_key,
        )

    # -------------------------------------------------------------
    # Test 1: Stale expected_etag is NOT replaced with latest ETag
    # -------------------------------------------------------------
    def test_stale_etag_is_not_replaced_and_raises_conflict(self):
        """Prove that caller's stale expected_etag is preserved and triggers CONFLICT."""
        manager = SafeWriteManager(
            writes_enabled=True,
            read_fn=self.mock_read_fn,
            transport_write_fn=self.mock_write_fn,
            intent_store=self.store,
        )
        adapter = IsolatedAdapter(manager)
        adapter.register_test_targets(calendars=["test-cal-id"])

        stale_etag = "mw9nlf7g"  # Old etag, server currently has "mw9nlf7h"
        args = {
            "event_id": "evt-001",
            "calendar_id": "test-cal-id",
            "patch": {"description": "[试图用旧 ETag 覆盖]"},
            "expected_etag": stale_etag,
        }
        auth = self._create_auth()

        with self.assertRaises(ConflictError) as ctx:
            adapter.submit("calendar_update_event", args, auth)

        # 1. Error must be CONFLICT
        self.assertIn("CONFLICT", str(ctx.exception))
        self.assertIn("mw9nlf7g", str(ctx.exception))
        self.assertIn("mw9nlf7h", str(ctx.exception))

        # 2. Network write MUST NOT have been called (0 writes)
        self.assertEqual(len(self.write_calls), 0, "No network write request should be sent on ETag conflict!")

        # 3. Server mock object must remain unchanged
        self.assertEqual(self.mock_events["evt-001"]["etag"], "mw9nlf7h")

        # 4. Audit ledger must record CONFLICT
        records = [r for r in self.store.records if r.get("operation_id")]
        self.assertTrue(any(r.get("status") == "CONFLICT" for r in records))

    # -------------------------------------------------------------
    # Test 2: Matching expected_etag succeeds without tampering
    # -------------------------------------------------------------
    def test_matching_expected_etag_succeeds(self):
        """Prove that matching expected_etag proceeds and forwards caller's etag."""
        manager = SafeWriteManager(
            writes_enabled=True,
            read_fn=self.mock_read_fn,
            transport_write_fn=self.mock_write_fn,
            intent_store=self.store,
        )
        adapter = IsolatedAdapter(manager)
        adapter.register_test_targets(calendars=["test-cal-id"])

        current_etag = "mw9nlf7h"
        args = {
            "event_id": "evt-001",
            "calendar_id": "test-cal-id",
            "patch": {"description": "[正常更新]"},
            "expected_etag": current_etag,
        }
        auth = self._create_auth()

        result = adapter.submit("calendar_update_event", args, auth)

        # 1. Status APPLIED
        self.assertEqual(result["status"], "APPLIED")
        self.assertEqual(result["sends"], 1)

        # 2. Write call received caller's expected_etag
        self.assertEqual(len(self.write_calls), 1)
        sent_args = self.write_calls[0]["args"]
        self.assertEqual(sent_args["expected_etag"], "mw9nlf7h")

        # 3. Intent store has APPLIED record
        records = [r for r in self.store.records if r.get("status") == "APPLIED"]
        self.assertEqual(len(records), 1)

    # -------------------------------------------------------------
    # Test 3: Target container restriction & authorization preservation
    # -------------------------------------------------------------
    def test_unregistered_calendar_rejected_with_zero_sends(self):
        """Prove that unregistered/production calendar is blocked at the gate."""
        manager = SafeWriteManager(
            writes_enabled=True,
            read_fn=self.mock_read_fn,
            transport_write_fn=self.mock_write_fn,
            intent_store=self.store,
        )
        adapter = IsolatedAdapter(manager)
        adapter.register_test_targets(calendars=["test-cal-id"])

        # Attempt to write to production calendar
        args = {
            "event_id": "evt-001",
            "calendar_id": "production-calendar-id",
            "patch": {"description": "Hacked"},
        }
        auth = self._create_auth(target="production-calendar-id")

        with self.assertRaises(PermissionDeniedError):
            adapter.submit("calendar_update_event", args, auth)

        self.assertEqual(len(self.write_calls), 0)

    def test_untrusted_authorization_rejected_with_zero_sends(self):
        """Prove that expired or invalid authorization is rejected."""
        manager = SafeWriteManager(
            writes_enabled=True,
            read_fn=self.mock_read_fn,
            transport_write_fn=self.mock_write_fn,
            intent_store=self.store,
        )
        adapter = IsolatedAdapter(manager)
        adapter.register_test_targets(calendars=["test-cal-id"])

        # Expired auth
        expired_auth = ApprovalToken(
            token_id="tok-expired",
            issuer="user_message",
            authorized_at=time.time() - 7200,
            expires_at=time.time() - 3600,
            scope_tool="calendar_update_event",
            scope_target="evt-001",
            bound_dedup_key="*",
        )
        args = {
            "event_id": "evt-001",
            "calendar_id": "test-cal-id",
            "patch": {"description": "Expired"},
        }

        with self.assertRaises(AuthUntrustedError):
            adapter.submit("calendar_update_event", args, expired_auth)

        self.assertEqual(len(self.write_calls), 0)

    # -------------------------------------------------------------
    # Test 4: UNKNOWN write halts adapter and forbids auto-retry
    # -------------------------------------------------------------
    def test_unknown_write_halts_adapter_and_forbids_auto_retry(self):
        """Prove that transport timeout/unknown failure halts adapter with 0 retry."""
        def failing_write(tool: str, args: Dict[str, Any]):
            self.write_calls.append({"tool": tool, "args": dict(args)})
            raise TimeoutError("Network timeout waiting for upstream response")

        manager = SafeWriteManager(
            writes_enabled=True,
            read_fn=self.mock_read_fn,
            transport_write_fn=failing_write,
            intent_store=self.store,
        )
        adapter = IsolatedAdapter(manager)
        adapter.register_test_targets(calendars=["test-cal-id"])

        args = {
            "event_id": "evt-001",
            "calendar_id": "test-cal-id",
            "patch": {"description": "Trigger Timeout"},
            "expected_etag": "mw9nlf7h",
        }
        auth = self._create_auth()

        with self.assertRaises(UnknownWriteError):
            adapter.submit("calendar_update_event", args, auth)

        # 1. Exactly 1 write attempt sent; NO AUTO-RETRY!
        self.assertEqual(len(self.write_calls), 1)

        # 2. Adapter MUST be in halted state
        self.assertTrue(adapter.halted)

        # 3. Subsequent write attempts MUST be immediately blocked by the halted adapter
        with self.assertRaises(PermissionDeniedError) as halt_ctx:
            adapter.submit("calendar_update_event", args, auth)
        self.assertIn("HALTED", str(halt_ctx.exception))

        # Write count remains 1 (0 duplicate writes)
        self.assertEqual(len(self.write_calls), 1)

        # 4. Ledger and intent store reflect UNKNOWN
        records = [r for r in self.store.records if r.get("status") == "UNKNOWN"]
        self.assertTrue(len(records) >= 1)


if __name__ == "__main__":
    unittest.main()
