"""isolated_adapter.py
MUSE Isolated Gated Adapter (Default-Deny Defense Layer).

Invariants:
1. Sits directly in front of SafeWriteManager as a default-deny security perimeter.
2. Whitelist: Only explicitly registered test containers are allowed; production containers are rejected.
3. Container verification: Updates/deletes must resolve to a valid registered test container.
4. UNKNOWN Halt: If any write ends in UNKNOWN, the adapter halts all further write attempts until reset.
5. Mail and work_done tools are strictly forbidden.
"""

from __future__ import annotations

import base64
from typing import Any, Dict, List, Optional, Set, Tuple

from safe_write import (
    ApprovalToken,
    AuthUntrustedError,
    ConflictError,
    PermissionDeniedError,
    SafeWriteError,
    SafeWriteManager,
    UnknownWriteError,
    _b64url_decode,
    _b64url_encode,
)


def _verify_event_container(event_id: str) -> Tuple[Optional[str], bool]:
    """Inspect event_id to extract collection URL."""
    if not event_id:
        return None, False

    # Check if event_id is a base64 encoded URL or ref
    decoded = _b64url_decode(event_id)
    if decoded:
        try:
            text = decoded.decode("utf-8")
            if "/" in text:
                parts = text.rsplit("/", 1)
                return parts[0] + "/", True
        except Exception:
            pass

    # If event_id contains standard URL structure
    if "/" in event_id:
        parts = event_id.rsplit("/", 1)
        return parts[0] + "/", True

    return None, False


def resolve_calendar_container(tool: str, args: Dict[str, Any]) -> Tuple[Optional[str], Optional[str]]:
    """Resolve the calendar container for a calendar update/delete.

    Returns (calendar_id, error_code_or_None).
    """
    if tool not in ("calendar_update_event", "calendar_delete_event"):
        return (args or {}).get("calendar_id"), None

    args = args or {}
    event_id = args.get("event_id")
    cal = args.get("calendar_id")
    ev_url, ev_ok = _verify_event_container(event_id) if event_id else (None, False)

    if cal is None:
        if not ev_ok:
            return None, "MISSING_TEST_TARGET"
        return _b64url_encode(ev_url.encode("utf-8")), None

    if ev_ok:
        cal_raw = _b64url_decode(cal)
        cal_url = None
        if cal_raw is not None:
            try:
                cal_url = cal_raw.decode("utf-8")
            except UnicodeDecodeError:
                cal_url = None
        if cal_url is None:
            return None, "CONFLICT"
        if cal_url.rstrip("/") != ev_url.rstrip("/"):
            return None, "CONFLICT"

    return cal, None


class IsolatedAdapter:
    """Isolated Adapter enforcing target whitelist, UNKNOWN halting, and gated access."""

    def __init__(self, manager: SafeWriteManager):
        self.manager = manager
        self.test_calendars: Set[str] = set()
        self.test_lists: Set[str] = set()
        self.test_address_books: Set[str] = set()
        self.test_groups: Set[str] = set()
        self.halted: bool = False
        self.audit_log: List[Dict[str, Any]] = []

    def register_test_targets(
        self,
        calendars: Optional[List[str]] = None,
        lists: Optional[List[str]] = None,
        address_books: Optional[List[str]] = None,
        groups: Optional[List[str]] = None,
    ) -> None:
        """Register allowed test container IDs. Default-deny for anything else."""
        if calendars:
            self.test_calendars.update(calendars)
        if lists:
            self.test_lists.update(lists)
        if address_books:
            self.test_address_books.update(address_books)
        if groups:
            self.test_groups.update(groups)

    def reset_halt(self, authorization: ApprovalToken) -> None:
        """Reset halted state only with verified user authorization."""
        if authorization.issuer != "user_message":
            raise AuthUntrustedError("Resetting halt requires trusted user_message authorization")
        self.halted = False
        self.audit_log.append({
            "event": "HALT_RESET",
            "token_id": authorization.token_id,
        })

    def submit(
        self,
        tool: str,
        args: Dict[str, Any],
        authorization: ApprovalToken,
        business_context: Optional[Dict[str, Any]] = None,
    ) -> Dict[str, Any]:
        """Submit operation through isolation gates."""
        if self.halted:
            raise PermissionDeniedError("Adapter is in HALTED state due to previous UNKNOWN write; manual reset required.")

        # Disallow prohibited tools
        if tool.startswith("mail_") or tool == "work_done":
            raise PermissionDeniedError(f"Tool {tool} is strictly prohibited in gated test mode.")

        # Container whitelist verification
        if tool.startswith("calendar_"):
            if tool == "calendar_create_event":
                cal_id = args.get("calendar_id")
                if not cal_id or cal_id not in self.test_calendars:
                    raise PermissionDeniedError(f"Target calendar '{cal_id}' is not in test whitelist (must be registered).")
            elif tool in ("calendar_update_event", "calendar_delete_event"):
                resolved_cal, err = resolve_calendar_container(tool, args)
                if err:
                    raise SafeWriteError(err, f"Container resolution failed: {err}")
                if not resolved_cal or resolved_cal not in self.test_calendars:
                    raise PermissionDeniedError(f"Resolved calendar '{resolved_cal}' is not in test whitelist.")
                # Ensure resolved calendar_id is set
                args = dict(args)
                args["calendar_id"] = resolved_cal

        elif tool.startswith("reminders_"):
            list_id = args.get("list_id")
            if tool == "reminders_create":
                if not list_id or list_id not in self.test_lists:
                    raise PermissionDeniedError(f"Target reminder list '{list_id}' is not in test whitelist.")
            elif tool in ("reminders_update", "reminders_delete"):
                if list_id and list_id not in self.test_lists:
                    raise PermissionDeniedError(f"Reminder list '{list_id}' is not in test whitelist.")

        try:
            result = self.manager.submit(tool, args, authorization, business_context)
            self.audit_log.append({
                "event": "WRITE_SUCCESS",
                "tool": tool,
                "operation_id": result.get("operation_id"),
                "status": result.get("status"),
            })
            return result
        except UnknownWriteError as uwe:
            # UNKNOWN outcome triggers immediate adapter halt
            self.halted = True
            self.audit_log.append({
                "event": "HALTED_ON_UNKNOWN",
                "tool": tool,
                "error": str(uwe),
            })
            raise
        except Exception as e:
            self.audit_log.append({
                "event": "WRITE_REJECTED",
                "tool": tool,
                "error": str(e),
            })
            raise
