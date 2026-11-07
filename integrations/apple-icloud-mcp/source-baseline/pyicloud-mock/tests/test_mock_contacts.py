# NEW_IMPLEMENTATION
# tests/test_mock_contacts.py
#
# Full test suite for MockContactsService / MockContact / MockContactGroup
# Status: MOCK_ONLY — no real Apple ID, CardDAV, or iCloud access
#
# AG-01 | reconcile/icloud-source-baseline | 2026-11-07
#
# Run: python3 -m pytest tests/test_mock_contacts.py -v

import sys
import os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

import uuid
import pytest

from pyicloud_mock import MockPyiCloudService, MockContactsService, MockContact, MockContactGroup


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

@pytest.fixture
def service() -> MockContactsService:
    return MockContactsService()


@pytest.fixture
def api() -> MockPyiCloudService:
    return MockPyiCloudService()


# ---------------------------------------------------------------------------
# Test 1: Service initialization returns seed contacts
# ---------------------------------------------------------------------------
def test_service_has_seed_contacts(service):
    """MockContactsService must initialize with at least 4 seed contacts."""
    contacts = service.all()
    assert len(contacts) >= 4, f"Expected ≥4 seed contacts, got {len(contacts)}"


# ---------------------------------------------------------------------------
# Test 2: Service initialization returns seed groups
# ---------------------------------------------------------------------------
def test_service_has_seed_groups(service):
    """MockContactsService must initialize with at least 2 seed groups."""
    groups = service.groups()
    assert len(groups) >= 2, f"Expected ≥2 seed groups, got {len(groups)}"


# ---------------------------------------------------------------------------
# Test 3: get contact by ID
# ---------------------------------------------------------------------------
def test_get_contact_by_id(service):
    """service.get must return the correct contact for a known ID."""
    contact = service.get("c-001")
    assert contact is not None
    assert contact.contact_id == "c-001"
    assert contact.first_name == "Alice"


# ---------------------------------------------------------------------------
# Test 4: get returns None for unknown ID
# ---------------------------------------------------------------------------
def test_get_contact_unknown_id(service):
    """service.get must return None (not raise) for an unknown contact ID."""
    result = service.get("does-not-exist")
    assert result is None


# ---------------------------------------------------------------------------
# Test 5: search by name
# ---------------------------------------------------------------------------
def test_search_by_first_name(service):
    """service.search must find contacts by first name substring (case-insensitive)."""
    results = service.search("alice")
    assert len(results) == 1
    assert results[0].contact_id == "c-001"


# ---------------------------------------------------------------------------
# Test 6: add and retrieve new contact
# ---------------------------------------------------------------------------
def test_add_and_retrieve_contact(service):
    """Adding a new contact must make it retrievable by ID."""
    new_contact = MockContact(
        contact_id="c-new-001",
        first_name="Zara",
        last_name="Zulu",
        email="zara@example.invalid",
    )
    service.add(new_contact)
    fetched = service.get("c-new-001")
    assert fetched is not None
    assert fetched.full_name == "Zara Zulu"


# ---------------------------------------------------------------------------
# Test 7: update contact fields
# ---------------------------------------------------------------------------
def test_update_contact(service):
    """service.update must modify specified fields and refresh etag."""
    original = service.get("c-002")
    original_etag = original.etag

    updated = service.update("c-002", first_name="Bobby")
    assert updated is not None
    assert updated.first_name == "Bobby"
    # ETag must change on update
    assert updated.etag != original_etag


# ---------------------------------------------------------------------------
# Test 8: delete contact
# ---------------------------------------------------------------------------
def test_delete_contact(service):
    """service.delete must remove the contact and return True; subsequent get returns None."""
    added = MockContact(contact_id="c-del-001", first_name="Delete", last_name="Me")
    service.add(added)
    assert service.get("c-del-001") is not None

    result = service.delete("c-del-001")
    assert result is True
    assert service.get("c-del-001") is None


# ---------------------------------------------------------------------------
# Test 9: delete non-existent contact returns False
# ---------------------------------------------------------------------------
def test_delete_nonexistent_contact(service):
    """service.delete must return False for a contact ID that does not exist."""
    result = service.delete("ghost-contact-xyz")
    assert result is False


# ---------------------------------------------------------------------------
# Test 10: group membership
# ---------------------------------------------------------------------------
def test_group_members_returned(service):
    """group_members must return the contacts belonging to the specified group."""
    members = service.group_members("g-001")
    assert len(members) >= 1
    ids = [m.contact_id for m in members]
    assert "c-001" in ids  # Alice is in Family group


# ---------------------------------------------------------------------------
# Test 11: add contact to group
# ---------------------------------------------------------------------------
def test_add_to_group(service):
    """add_to_group must add the contact to the group and update contact's group_ids."""
    # c-004 (Dave) has no group initially
    dave = service.get("c-004")
    assert "g-003" not in dave.group_ids

    success = service.add_to_group("c-004", "g-003")
    assert success is True

    members = service.group_members("g-003")
    ids = [m.contact_id for m in members]
    assert "c-004" in ids
    assert "g-003" in service.get("c-004").group_ids


# ---------------------------------------------------------------------------
# Test 12: remove contact from group
# ---------------------------------------------------------------------------
def test_remove_from_group(service):
    """remove_from_group must remove the contact from the group."""
    service.add_to_group("c-004", "g-002")
    result = service.remove_from_group("c-004", "g-002")
    assert result is True

    members = service.group_members("g-002")
    ids = [m.contact_id for m in members]
    assert "c-004" not in ids


# ---------------------------------------------------------------------------
# Test 13: MockContact serialization round-trip
# ---------------------------------------------------------------------------
def test_contact_serialization_roundtrip():
    """MockContact to_dict → from_dict must produce an identical contact."""
    original = MockContact(
        contact_id="rt-001",
        first_name="Round",
        last_name="Trip",
        email="rt@example.invalid",
        phone="+19990000001",
        group_ids=["g-001", "g-002"],
        etag="etag-abc123",
    )
    data = original.to_dict()
    restored = MockContact.from_dict(data)

    assert restored.contact_id == original.contact_id
    assert restored.first_name == original.first_name
    assert restored.last_name == original.last_name
    assert restored.email == original.email
    assert restored.phone == original.phone
    assert restored.group_ids == original.group_ids
    assert restored.etag == original.etag


# ---------------------------------------------------------------------------
# Test 14: MockContactsService accessible via top-level API
# ---------------------------------------------------------------------------
def test_api_contacts_service_accessible(api):
    """MockPyiCloudService.contacts must return a MockContactsService."""
    assert isinstance(api.contacts, MockContactsService)
    contacts = api.contacts.all()
    assert len(contacts) >= 4


# ---------------------------------------------------------------------------
# Test 15: add_to_group returns False for unknown group
# ---------------------------------------------------------------------------
def test_add_to_nonexistent_group(service):
    """add_to_group must return False when the group does not exist."""
    result = service.add_to_group("c-001", "g-nonexistent")
    assert result is False


# ---------------------------------------------------------------------------
# Test 16: group to_dict has required keys
# ---------------------------------------------------------------------------
def test_group_to_dict_keys():
    """MockContactGroup.to_dict must include group_id, name, member_count, member_ids."""
    grp = MockContactGroup(group_id="g-test", name="Test Group")
    grp.add_member("c-001")
    d = grp.to_dict()
    for key in ("group_id", "name", "member_count", "member_ids"):
        assert key in d, f"Missing key: {key}"
    assert d["member_count"] == 1
    assert "c-001" in d["member_ids"]
