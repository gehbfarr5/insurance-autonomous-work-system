# NEW_IMPLEMENTATION
# pyicloud_mock/reminders.py
#
# Mock RemindersList and Reminder interface
# Status: MOCK_ONLY — deterministic in-memory, no real EventKit or iCloud access
#
# AG-01 | reconcile/icloud-source-baseline | 2026-11-07

"""
Mock implementation of pyicloud reminders service.

Mirrors the interface of pyicloud.services.reminders so downstream code
can inject MockRemindersService in place of the real service without
modification.

No real Apple ID, iCloud session, TCC permission, or network access is used.
"""

from __future__ import annotations

import uuid
from dataclasses import dataclass, field
from datetime import datetime, timezone
from typing import Dict, Iterator, List, Optional


# ---------------------------------------------------------------------------
# Reminder item
# ---------------------------------------------------------------------------

@dataclass
class MockReminder:
    """
    NEW_IMPLEMENTATION — mirrors a single Reminder as returned by pyicloud.

    Fields intentionally limited to metadata + non-sensitive content for
    testing. In the real pyicloud interface these map to iCloud reminder
    properties.
    """

    guid: str = field(default_factory=lambda: str(uuid.uuid4()))
    title: str = "Untitled Reminder"
    due_date: Optional[datetime] = None
    completed: bool = False
    priority: int = 0  # 0=none, 1=high, 5=medium, 9=low
    list_id: str = ""
    description: str = ""
    created_at: datetime = field(default_factory=lambda: datetime.now(timezone.utc))

    # NEW_IMPLEMENTATION: content is accessible only within the mock layer
    # (not gated by TCC). Real implementations must gate on TCC + allowlist.

    def to_dict(self) -> dict:
        return {
            "guid": self.guid,
            "title": self.title,
            "due_date": self.due_date.isoformat() if self.due_date else None,
            "completed": self.completed,
            "priority": self.priority,
            "list_id": self.list_id,
            "description": self.description,
            "created_at": self.created_at.isoformat(),
        }

    @classmethod
    def from_dict(cls, data: dict) -> "MockReminder":
        due = data.get("due_date")
        return cls(
            guid=data.get("guid", str(uuid.uuid4())),
            title=data.get("title", "Untitled"),
            due_date=datetime.fromisoformat(due) if due else None,
            completed=data.get("completed", False),
            priority=data.get("priority", 0),
            list_id=data.get("list_id", ""),
            description=data.get("description", ""),
        )


# ---------------------------------------------------------------------------
# Reminders list
# ---------------------------------------------------------------------------

class MockRemindersList:
    """
    NEW_IMPLEMENTATION — mirrors a RemindersList (a named container of reminders).

    Corresponds to an EKCalendar of type Reminder in EventKit.
    """

    def __init__(
        self,
        list_id: str,
        title: str,
        source: str = "iCloud",
        color: str = "#FF2D55",
    ):
        self.list_id: str = list_id
        self.title: str = title
        self.source: str = source          # NEW_IMPLEMENTATION: source tag
        self.color: str = color
        self._reminders: Dict[str, MockReminder] = {}

    # -- CRUD (mock-layer only; real layer would gate these) -----------------

    def add_reminder(self, reminder: MockReminder) -> MockReminder:
        reminder.list_id = self.list_id
        self._reminders[reminder.guid] = reminder
        return reminder

    def get_reminder(self, guid: str) -> Optional[MockReminder]:
        return self._reminders.get(guid)

    def remove_reminder(self, guid: str) -> bool:
        if guid in self._reminders:
            del self._reminders[guid]
            return True
        return False

    def all_reminders(self) -> List[MockReminder]:
        return list(self._reminders.values())

    def __len__(self) -> int:
        return len(self._reminders)

    def __iter__(self) -> Iterator[MockReminder]:
        return iter(self._reminders.values())

    def __repr__(self) -> str:
        return f"MockRemindersList(id={self.list_id!r}, title={self.title!r}, count={len(self)})"

    def to_dict(self) -> dict:
        return {
            "list_id": self.list_id,
            "title": self.title,
            "source": self.source,
            "color": self.color,
            "reminder_count": len(self),
        }


# ---------------------------------------------------------------------------
# Reminders service
# ---------------------------------------------------------------------------

_SEED_LISTS: List[dict] = [
    {"list_id": "mock-list-001", "title": "Personal",    "source": "iCloud", "color": "#FF2D55"},
    {"list_id": "mock-list-002", "title": "Work",        "source": "iCloud", "color": "#007AFF"},
    {"list_id": "mock-list-003", "title": "Shopping",    "source": "iCloud", "color": "#34C759"},
    {"list_id": "mock-list-004", "title": "On My Mac",   "source": "Local",  "color": "#FF9500"},
]

_SEED_REMINDERS: List[dict] = [
    {"guid": "r-001", "title": "Buy groceries",     "list_id": "mock-list-003", "completed": False, "priority": 5},
    {"guid": "r-002", "title": "Call dentist",      "list_id": "mock-list-001", "completed": False, "priority": 1},
    {"guid": "r-003", "title": "Submit report",     "list_id": "mock-list-002", "completed": False, "priority": 1},
    {"guid": "r-004", "title": "Review PR",         "list_id": "mock-list-002", "completed": True,  "priority": 5},
    {"guid": "r-005", "title": "Pick up dry clean", "list_id": "mock-list-001", "completed": False, "priority": 9},
]


class MockRemindersService:
    """
    NEW_IMPLEMENTATION — mirrors pyicloud.services.reminders.RemindersService.

    Provides deterministic in-memory reminder lists and reminders populated from
    _SEED_LISTS and _SEED_REMINDERS at construction time.

    Usage:
        svc = MockRemindersService()
        for lst in svc.lists():
            print(lst.title, len(lst))
    """

    def __init__(self):
        # NEW_IMPLEMENTATION: build from seed data, no network/TCC calls
        self._lists: Dict[str, MockRemindersList] = {}
        self._refresh_count: int = 0
        self._content_access_count: int = 0  # Tracks content field reads (must be 0 in metadata-only tests)

        for ld in _SEED_LISTS:
            lst = MockRemindersList(**ld)
            self._lists[lst.list_id] = lst

        for rd in _SEED_REMINDERS:
            reminder = MockReminder.from_dict(rd)
            if reminder.list_id in self._lists:
                self._lists[reminder.list_id].add_reminder(reminder)

    # -- Interface (mirrors pyicloud) ----------------------------------------

    def lists(self) -> List[MockRemindersList]:
        """Return all reminder lists (metadata only — does not increment content counter)."""
        return list(self._lists.values())

    def get_list(self, list_id: str) -> Optional[MockRemindersList]:
        """Return a specific list by ID, or None if not found."""
        return self._lists.get(list_id)

    def get_reminders(self, list_id: str) -> List[MockReminder]:
        """
        Return reminders for a list.
        NOTE: This increments _content_access_count. Metadata-only paths
        must NOT call this method.
        """
        self._content_access_count += 1
        lst = self._lists.get(list_id)
        return lst.all_reminders() if lst else []

    def refresh(self) -> None:
        """Simulate a refresh call. No-op in mock."""
        self._refresh_count += 1

    # -- Diagnostic helpers (for test assertions) ----------------------------

    @property
    def content_access_count(self) -> int:
        """
        Number of times reminder content was accessed.
        Metadata-only tests must assert this is 0.
        """
        return self._content_access_count

    def reset_counters(self) -> None:
        """Reset all diagnostic counters (call between test cases)."""
        self._content_access_count = 0
        self._refresh_count = 0

    def __repr__(self) -> str:
        return f"MockRemindersService(lists={len(self._lists)}, content_accesses={self._content_access_count})"
