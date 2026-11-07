# NEW_IMPLEMENTATION
# pyicloud_mock/contacts.py
#
# Mock Contact and ContactGroup interface
# Status: MOCK_ONLY — deterministic in-memory, no real CardDAV or iCloud access
#
# AG-01 | reconcile/icloud-source-baseline | 2026-11-07

"""
Mock implementation of pyicloud contacts service.

Mirrors the interface of pyicloud.services.contacts so downstream code
can inject MockContactsService in place of the real service without
modification.

No real Apple ID, CardDAV session, or network access is used.
All contact data is synthetic and contains no real PII.
"""

from __future__ import annotations

import uuid
from dataclasses import dataclass, field
from typing import Dict, Iterator, List, Optional


# ---------------------------------------------------------------------------
# Contact
# ---------------------------------------------------------------------------

@dataclass
class MockContact:
    """
    NEW_IMPLEMENTATION — mirrors a single Contact as returned by pyicloud.

    All fields are synthetic. No real personal data.
    """

    contact_id: str = field(default_factory=lambda: str(uuid.uuid4()))
    first_name: str = "Mock"
    last_name: str = "Contact"
    email: str = "mock@example.invalid"
    phone: str = "+00000000000"
    group_ids: List[str] = field(default_factory=list)
    etag: str = field(default_factory=lambda: f"etag-{uuid.uuid4().hex[:8]}")

    @property
    def full_name(self) -> str:
        return f"{self.first_name} {self.last_name}"

    def to_dict(self) -> dict:
        return {
            "contact_id": self.contact_id,
            "first_name": self.first_name,
            "last_name": self.last_name,
            "email": self.email,
            "phone": self.phone,
            "group_ids": self.group_ids,
            "etag": self.etag,
        }

    @classmethod
    def from_dict(cls, data: dict) -> "MockContact":
        return cls(
            contact_id=data.get("contact_id", str(uuid.uuid4())),
            first_name=data.get("first_name", "Mock"),
            last_name=data.get("last_name", "Contact"),
            email=data.get("email", "mock@example.invalid"),
            phone=data.get("phone", "+00000000000"),
            group_ids=data.get("group_ids", []),
            etag=data.get("etag", f"etag-{uuid.uuid4().hex[:8]}"),
        )

    def __repr__(self) -> str:
        return f"MockContact(id={self.contact_id!r}, name={self.full_name!r})"


# ---------------------------------------------------------------------------
# ContactGroup
# ---------------------------------------------------------------------------

class MockContactGroup:
    """
    NEW_IMPLEMENTATION — mirrors a ContactGroup (vCard group / Apple ID group).
    """

    def __init__(self, group_id: str, name: str):
        self.group_id: str = group_id
        self.name: str = name
        self._member_ids: List[str] = []

    def add_member(self, contact_id: str) -> None:
        if contact_id not in self._member_ids:
            self._member_ids.append(contact_id)

    def remove_member(self, contact_id: str) -> bool:
        if contact_id in self._member_ids:
            self._member_ids.remove(contact_id)
            return True
        return False

    @property
    def member_ids(self) -> List[str]:
        return list(self._member_ids)

    def __len__(self) -> int:
        return len(self._member_ids)

    def __repr__(self) -> str:
        return f"MockContactGroup(id={self.group_id!r}, name={self.name!r}, members={len(self)})"

    def to_dict(self) -> dict:
        return {
            "group_id": self.group_id,
            "name": self.name,
            "member_count": len(self),
            "member_ids": self.member_ids,
        }


# ---------------------------------------------------------------------------
# Seed data
# ---------------------------------------------------------------------------

_SEED_CONTACTS: List[dict] = [
    {"contact_id": "c-001", "first_name": "Alice",   "last_name": "Alpha",   "email": "alice@example.invalid",   "phone": "+10000000001", "group_ids": ["g-001"]},
    {"contact_id": "c-002", "first_name": "Bob",     "last_name": "Bravo",   "email": "bob@example.invalid",     "phone": "+10000000002", "group_ids": ["g-001", "g-002"]},
    {"contact_id": "c-003", "first_name": "Carol",   "last_name": "Charlie", "email": "carol@example.invalid",   "phone": "+10000000003", "group_ids": ["g-002"]},
    {"contact_id": "c-004", "first_name": "Dave",    "last_name": "Delta",   "email": "dave@example.invalid",    "phone": "+10000000004", "group_ids": []},
    {"contact_id": "c-005", "first_name": "Eve",     "last_name": "Echo",    "email": "eve@example.invalid",     "phone": "+10000000005", "group_ids": ["g-003"]},
]

_SEED_GROUPS: List[dict] = [
    {"group_id": "g-001", "name": "Family"},
    {"group_id": "g-002", "name": "Work"},
    {"group_id": "g-003", "name": "VIP"},
]


# ---------------------------------------------------------------------------
# Contacts service
# ---------------------------------------------------------------------------

class MockContactsService:
    """
    NEW_IMPLEMENTATION — mirrors pyicloud.services.contacts.ContactsService.

    Provides deterministic in-memory contacts and groups populated from
    seed data at construction time.

    Usage:
        svc = MockContactsService()
        for contact in svc.all():
            print(contact.full_name)
    """

    def __init__(self):
        # NEW_IMPLEMENTATION: build from seed data, no network/CardDAV calls
        self._contacts: Dict[str, MockContact] = {}
        self._groups: Dict[str, MockContactGroup] = {}

        for gd in _SEED_GROUPS:
            grp = MockContactGroup(group_id=gd["group_id"], name=gd["name"])
            self._groups[grp.group_id] = grp

        for cd in _SEED_CONTACTS:
            contact = MockContact.from_dict(cd)
            self._contacts[contact.contact_id] = contact
            for gid in contact.group_ids:
                if gid in self._groups:
                    self._groups[gid].add_member(contact.contact_id)

    # -- Contact interface (mirrors pyicloud) --------------------------------

    def all(self) -> List[MockContact]:
        """Return all contacts."""
        return list(self._contacts.values())

    def get(self, contact_id: str) -> Optional[MockContact]:
        """Return a contact by ID, or None."""
        return self._contacts.get(contact_id)

    def search(self, query: str) -> List[MockContact]:
        """Case-insensitive search over first name, last name, and email."""
        q = query.lower()
        return [
            c for c in self._contacts.values()
            if q in c.first_name.lower()
            or q in c.last_name.lower()
            or q in c.email.lower()
        ]

    def add(self, contact: MockContact) -> MockContact:
        """Add a contact to the mock store."""
        self._contacts[contact.contact_id] = contact
        return contact

    def update(self, contact_id: str, **kwargs) -> Optional[MockContact]:
        """Update fields on an existing contact."""
        contact = self._contacts.get(contact_id)
        if contact is None:
            return None
        for k, v in kwargs.items():
            if hasattr(contact, k):
                setattr(contact, k, v)
        contact.etag = f"etag-{uuid.uuid4().hex[:8]}"
        return contact

    def delete(self, contact_id: str) -> bool:
        """Remove a contact from the mock store."""
        if contact_id in self._contacts:
            # Also remove from groups
            for grp in self._groups.values():
                grp.remove_member(contact_id)
            del self._contacts[contact_id]
            return True
        return False

    # -- Group interface (mirrors pyicloud) ----------------------------------

    def groups(self) -> List[MockContactGroup]:
        """Return all contact groups."""
        return list(self._groups.values())

    def get_group(self, group_id: str) -> Optional[MockContactGroup]:
        """Return a group by ID, or None."""
        return self._groups.get(group_id)

    def group_members(self, group_id: str) -> List[MockContact]:
        """Return contacts belonging to a group."""
        grp = self._groups.get(group_id)
        if grp is None:
            return []
        return [self._contacts[mid] for mid in grp.member_ids if mid in self._contacts]

    def add_to_group(self, contact_id: str, group_id: str) -> bool:
        """Add a contact to a group. Returns True on success."""
        if contact_id not in self._contacts or group_id not in self._groups:
            return False
        self._groups[group_id].add_member(contact_id)
        if group_id not in self._contacts[contact_id].group_ids:
            self._contacts[contact_id].group_ids.append(group_id)
        return True

    def remove_from_group(self, contact_id: str, group_id: str) -> bool:
        """Remove a contact from a group. Returns True on success."""
        if contact_id not in self._contacts or group_id not in self._groups:
            return False
        self._groups[group_id].remove_member(contact_id)
        if group_id in self._contacts[contact_id].group_ids:
            self._contacts[contact_id].group_ids.remove(group_id)
        return True

    def __repr__(self) -> str:
        return f"MockContactsService(contacts={len(self._contacts)}, groups={len(self._groups)})"
