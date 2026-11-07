# NEW_IMPLEMENTATION
# tests/test_mock_reminders.py
#
# Full test suite for MockRemindersService / MockRemindersList / MockReminder
# Status: MOCK_ONLY — no real Apple ID, iCloud, or EventKit access
#
# AG-01 | reconcile/icloud-source-baseline | 2026-11-07
#
# Run: python3 -m pytest tests/test_mock_reminders.py -v

import sys
import os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

import uuid
from datetime import datetime, timezone

import pytest

from pyicloud_mock import MockPyiCloudService, MockRemindersService, MockRemindersList, MockReminder


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

@pytest.fixture
def service() -> MockRemindersService:
    svc = MockRemindersService()
    svc.reset_counters()
    return svc


@pytest.fixture
def api() -> MockPyiCloudService:
    return MockPyiCloudService()


# ---------------------------------------------------------------------------
# Test 1: Service initialization returns seed lists
# ---------------------------------------------------------------------------
def test_service_has_seed_lists(service):
    """MockRemindersService must initialize with at least 3 seed reminder lists."""
    lists = service.lists()
    assert len(lists) >= 3, f"Expected ≥3 seed lists, got {len(lists)}"


# ---------------------------------------------------------------------------
# Test 2: List metadata does not trigger content access counter
# ---------------------------------------------------------------------------
def test_list_metadata_no_content_access(service):
    """
    FIX-R4A-01 equivalent: Fetching list metadata (titles, IDs) must NOT
    increment the content access counter. Only reminder content access does.
    """
    service.reset_counters()
    lists = service.lists()
    for lst in lists:
        # Access only metadata fields
        _ = lst.list_id
        _ = lst.title
        _ = lst.source
        _ = lst.color
        _ = lst.to_dict()

    assert service.content_access_count == 0, (
        f"Metadata-only access incremented content counter to {service.content_access_count}"
    )


# ---------------------------------------------------------------------------
# Test 3: get_reminders increments content access counter
# ---------------------------------------------------------------------------
def test_content_access_counted_when_getting_reminders(service):
    """Content access counter must be incremented when reminder items are fetched."""
    service.reset_counters()
    lists = service.lists()
    assert len(lists) > 0
    service.get_reminders(lists[0].list_id)
    assert service.content_access_count == 1


# ---------------------------------------------------------------------------
# Test 4: Seed reminder count is non-zero
# ---------------------------------------------------------------------------
def test_seed_reminders_populated(service):
    """At least one list must contain at least one seed reminder."""
    all_found = False
    for lst in service.lists():
        # Using internal _reminders to avoid incrementing counter at service level
        if len(lst) > 0:
            all_found = True
            break
    assert all_found, "No seed reminders were populated in any list"


# ---------------------------------------------------------------------------
# Test 5: get_list returns correct list by ID
# ---------------------------------------------------------------------------
def test_get_list_by_id(service):
    """get_list must return the correct MockRemindersList for a valid ID."""
    lst = service.get_list("mock-list-001")
    assert lst is not None
    assert lst.list_id == "mock-list-001"
    assert lst.title == "Personal"


# ---------------------------------------------------------------------------
# Test 6: get_list returns None for unknown ID
# ---------------------------------------------------------------------------
def test_get_list_unknown_id_returns_none(service):
    """get_list must return None (not raise) for an unknown list ID."""
    result = service.get_list("does-not-exist-xyz")
    assert result is None


# ---------------------------------------------------------------------------
# Test 7: MockReminder from_dict / to_dict round-trip
# ---------------------------------------------------------------------------
def test_reminder_serialization_roundtrip():
    """MockReminder must survive a to_dict → from_dict round-trip with identical field values."""
    original = MockReminder(
        guid="test-guid-001",
        title="Round-trip test",
        completed=False,
        priority=5,
        list_id="mock-list-001",
        description="Test description",
        due_date=datetime(2026, 12, 31, 12, 0, 0, tzinfo=timezone.utc),
    )
    data = original.to_dict()
    restored = MockReminder.from_dict(data)

    assert restored.guid == original.guid
    assert restored.title == original.title
    assert restored.completed == original.completed
    assert restored.priority == original.priority
    assert restored.list_id == original.list_id
    assert restored.description == original.description
    assert restored.due_date == original.due_date


# ---------------------------------------------------------------------------
# Test 8: RemindersList add / get / remove
# ---------------------------------------------------------------------------
def test_reminders_list_add_get_remove():
    """MockRemindersList must correctly add, retrieve, and remove reminders."""
    lst = MockRemindersList(list_id="test-list", title="Test List")
    reminder = MockReminder(guid="r-test-001", title="Buy milk", list_id="test-list")

    lst.add_reminder(reminder)
    assert len(lst) == 1

    fetched = lst.get_reminder("r-test-001")
    assert fetched is not None
    assert fetched.title == "Buy milk"

    removed = lst.remove_reminder("r-test-001")
    assert removed is True
    assert len(lst) == 0

    # Removing again returns False
    assert lst.remove_reminder("r-test-001") is False


# ---------------------------------------------------------------------------
# Test 9: reset_counters resets to zero
# ---------------------------------------------------------------------------
def test_reset_counters(service):
    """reset_counters must zero all diagnostic counters."""
    service.get_reminders("mock-list-001")
    service.get_reminders("mock-list-002")
    assert service.content_access_count == 2

    service.reset_counters()
    assert service.content_access_count == 0


# ---------------------------------------------------------------------------
# Test 10: MockPyiCloudService does not expose credentials
# ---------------------------------------------------------------------------
def test_api_credentials_redacted(api):
    """MockPyiCloudService must never expose real credentials in repr or attributes."""
    r = repr(api)
    assert "REDACTED" in r or "<" in r
    # Internal attributes must be redacted strings, not real values
    assert api._apple_id == "<REDACTED>"
    assert api._password == "<REDACTED>"


# ---------------------------------------------------------------------------
# Test 11: MockRemindersService is accessible via top-level API
# ---------------------------------------------------------------------------
def test_api_reminders_service_accessible(api):
    """MockPyiCloudService.reminders must return a MockRemindersService."""
    assert isinstance(api.reminders, MockRemindersService)
    lists = api.reminders.lists()
    assert len(lists) >= 3


# ---------------------------------------------------------------------------
# Test 12: RemindersList iteration
# ---------------------------------------------------------------------------
def test_reminders_list_iteration():
    """MockRemindersList must be iterable and yield MockReminder objects."""
    lst = MockRemindersList(list_id="iter-list", title="Iter Test")
    for i in range(3):
        lst.add_reminder(MockReminder(guid=f"r-iter-{i:03d}", title=f"Item {i}"))

    items = list(lst)
    assert len(items) == 3
    for item in items:
        assert isinstance(item, MockReminder)


# ---------------------------------------------------------------------------
# Test 13: Multiple content accesses are counted cumulatively
# ---------------------------------------------------------------------------
def test_multiple_content_access_counted(service):
    """Each call to get_reminders must increment the counter by 1."""
    service.reset_counters()
    lists = service.lists()
    for lst in lists[:3]:
        service.get_reminders(lst.list_id)
    assert service.content_access_count == 3


# ---------------------------------------------------------------------------
# Test 14: RemindersList to_dict has required keys
# ---------------------------------------------------------------------------
def test_reminders_list_to_dict_keys():
    """MockRemindersList.to_dict must include list_id, title, source, color, reminder_count."""
    lst = MockRemindersList(list_id="d-001", title="Dict Test", source="iCloud", color="#34C759")
    d = lst.to_dict()
    for key in ("list_id", "title", "source", "color", "reminder_count"):
        assert key in d, f"Missing key: {key}"
    assert d["reminder_count"] == 0
