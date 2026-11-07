# PYTHON_TEST_EVIDENCE.md
<!-- AG-01-A | PyiCloud Mock Candidate | 2026-11-07 -->
<!-- REAL EXECUTION EVIDENCE — commands and output are actual, not synthesized -->

## Environment

| Item | Value |
|------|-------|
| Date | 2026-11-07 |
| Python version | 3.14.7 |
| pytest version | 9.2.0 |
| pluggy version | 1.7.0 |
| Platform | darwin (macOS arm64) |
| Virtual env | `.venv/` (created with `python3 -m venv .venv`) |
| Working directory | `integrations/apple-icloud-mcp/source-baseline/pyicloud-mock/` |

---

## Setup Commands

```bash
cd integrations/apple-icloud-mcp/source-baseline/pyicloud-mock
python3 -m venv .venv
.venv/bin/pip install pytest
```

---

## Test Execution Command

```bash
.venv/bin/python -m pytest tests/ -v 2>&1
```

**Result:** ✅ Exit code 0

---

## Full Test Output

```
============================= test session starts ==============================
platform darwin -- Python 3.14.7, pytest-9.2.0, pluggy-1.7.0
cachedir: .pytest_cache
rootdir: integrations/apple-icloud-mcp/source-baseline/pyicloud-mock
collecting ... collected 30 items

tests/test_mock_contacts.py::test_service_has_seed_contacts PASSED       [  3%]
tests/test_mock_contacts.py::test_service_has_seed_groups PASSED         [  6%]
tests/test_mock_contacts.py::test_get_contact_by_id PASSED               [ 10%]
tests/test_mock_contacts.py::test_get_contact_unknown_id PASSED          [ 13%]
tests/test_mock_contacts.py::test_search_by_first_name PASSED            [ 16%]
tests/test_mock_contacts.py::test_add_and_retrieve_contact PASSED        [ 20%]
tests/test_mock_contacts.py::test_update_contact PASSED                  [ 23%]
tests/test_mock_contacts.py::test_delete_contact PASSED                  [ 26%]
tests/test_mock_contacts.py::test_delete_nonexistent_contact PASSED      [ 30%]
tests/test_mock_contacts.py::test_group_members_returned PASSED          [ 33%]
tests/test_mock_contacts.py::test_add_to_group PASSED                    [ 36%]
tests/test_mock_contacts.py::test_remove_from_group PASSED               [ 40%]
tests/test_mock_contacts.py::test_contact_serialization_roundtrip PASSED [ 43%]
tests/test_mock_contacts.py::test_api_contacts_service_accessible PASSED [ 46%]
tests/test_mock_contacts.py::test_add_to_nonexistent_group PASSED        [ 50%]
tests/test_mock_contacts.py::test_group_to_dict_keys PASSED              [ 53%]
tests/test_mock_reminders.py::test_service_has_seed_lists PASSED         [ 56%]
tests/test_mock_reminders.py::test_list_metadata_no_content_access PASSED [ 60%]
tests/test_mock_reminders.py::test_content_access_counted_when_getting_reminders PASSED [ 63%]
tests/test_mock_reminders.py::test_seed_reminders_populated PASSED       [ 66%]
tests/test_mock_reminders.py::test_get_list_by_id PASSED                 [ 70%]
tests/test_mock_reminders.py::test_get_list_unknown_id_returns_none PASSED [ 73%]
tests/test_mock_reminders.py::test_reminder_serialization_roundtrip PASSED [ 76%]
tests/test_mock_reminders.py::test_reminders_list_add_get_remove PASSED  [ 80%]
tests/test_mock_reminders.py::test_reset_counters PASSED                 [ 83%]
tests/test_mock_reminders.py::test_api_credentials_redacted PASSED       [ 86%]
tests/test_mock_reminders.py::test_api_reminders_service_accessible PASSED [ 90%]
tests/test_mock_reminders.py::test_reminders_list_iteration PASSED       [ 93%]
tests/test_mock_reminders.py::test_multiple_content_access_counted PASSED [ 96%]
tests/test_mock_reminders.py::test_reminders_list_to_dict_keys PASSED    [100%]

============================== 30 passed in 0.02s ==============================
```

---

## Test Summary

| Module | Tests | Passed | Failed |
|--------|-------|--------|--------|
| test_mock_contacts.py | 16 | 16 | 0 |
| test_mock_reminders.py | 14 | 14 | 0 |
| **TOTAL** | **30** | **30** | **0** |

---

## Desensitization Confirmation

- All email addresses use `@example.invalid` (RFC 2606 reserved).
- All phone numbers use `+1000000000X` (non-routable).
- Credential redaction verified: `test_api_credentials_redacted` PASSED.
- No Apple ID, iCloud credential, or real user data was accessed.

---

*Python test evidence recorded by AG-01 Engineering Agent | 2026-11-07*
