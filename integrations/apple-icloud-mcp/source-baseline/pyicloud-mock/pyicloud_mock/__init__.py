# NEW_IMPLEMENTATION
# pyicloud_mock/__init__.py
#
# PyiCloud Mock Candidate
# Status: MOCK_ONLY — no real Apple ID, iCloud session, or network access
# Purpose: Provide a deterministic, in-memory implementation of the pyicloud
#          interface contract for use in offline testing and integration scaffolding.
#
# AG-01 | reconcile/icloud-source-baseline | 2026-11-07

"""
pyicloud_mock — deterministic in-memory mock of the pyicloud library interface.

This package provides drop-in replacements for the pyicloud service objects so that
downstream code can be tested without any real Apple credentials or network access.

Usage:
    from pyicloud_mock import MockPyiCloudService

    api = MockPyiCloudService()
    reminders = api.reminders  # → MockRemindersService
    contacts  = api.contacts   # → MockContactsService
"""

__version__ = "0.1.0"
__author__ = "AG-01 Engineering Agent"
__status__ = "MOCK_ONLY"

from .reminders import MockRemindersService, MockRemindersList, MockReminder
from .contacts import MockContactsService, MockContact, MockContactGroup

__all__ = [
    "MockPyiCloudService",
    "MockRemindersService",
    "MockRemindersList",
    "MockReminder",
    "MockContactsService",
    "MockContact",
    "MockContactGroup",
]


class MockPyiCloudService:
    """
    Top-level mock mirroring pyicloud.PyiCloudService.

    Does NOT accept or require any Apple ID credentials. All data is
    populated from in-memory seed data.

    >>> api = MockPyiCloudService()
    >>> isinstance(api.reminders, MockRemindersService)
    True
    >>> isinstance(api.contacts, MockContactsService)
    True
    """

    def __init__(self, apple_id: str = "<MOCK_APPLE_ID>", password: str = "<MOCK_PASSWORD>"):
        # Credentials are accepted for interface compatibility but are never used.
        # NEW_IMPLEMENTATION: no real auth, no network call.
        self._apple_id = "<REDACTED>"
        self._password = "<REDACTED>"
        self._authenticated = True

        self.reminders = MockRemindersService()
        self.contacts = MockContactsService()

    @property
    def is_trusted_session(self) -> bool:
        return True

    def authenticate(self, force_refresh: bool = False) -> None:
        """No-op: mock is always authenticated."""
        pass

    def __repr__(self) -> str:
        return "MockPyiCloudService(apple_id='<REDACTED>')"
