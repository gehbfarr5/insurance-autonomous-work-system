"""A minimal protected journal for preventing blind contact-create retries."""
from __future__ import annotations

import fcntl
import json
import os
import uuid
from contextlib import AbstractContextManager
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


class CreateAttemptError(RuntimeError):
    """Safe journal failure with no customer values in its message."""

    def __init__(self, code: str, operation_id: str | None = None) -> None:
        self.code = code
        self.operation_id = operation_id
        super().__init__(code)


def default_state_dir() -> Path:
    configured = os.environ.get("MUSE_FAMILY_CARD_STATE_DIR")
    if configured:
        path = Path(configured).expanduser()
    else:
        base = os.environ.get("XDG_STATE_HOME")
        path = Path(base).expanduser() if base else Path.home() / ".local" / "state"
        path = path / "muse-family-card"
    resolved = path.resolve()
    _reject_repository_path(resolved)
    return resolved


class CreateAttemptJournal(AbstractContextManager["CreateAttemptJournal"]):
    """Serialize create attempts and persist unknown outcomes outside the repo.

    The journal stores a random operation ID, phase, timestamps, and the
    opaque contact ID only while a known create still needs readback. It never
    stores contact fields, OCR output, or MCP sessions.
    """

    def __init__(self, folder: Path | str | None = None) -> None:
        self.folder = Path(folder).expanduser().resolve() if folder else default_state_dir()
        _reject_repository_path(self.folder)
        self.path = self.folder / "contact-create-state.json"
        self.lock_path = self.folder / "contact-create.lock"
        self._lock_fd: int | None = None

    def __enter__(self) -> "CreateAttemptJournal":
        self.folder.mkdir(mode=0o700, parents=True, exist_ok=True)
        os.chmod(self.folder, 0o700)
        flags = os.O_CREAT | os.O_RDWR
        if hasattr(os, "O_NOFOLLOW"):
            flags |= os.O_NOFOLLOW
        self._lock_fd = os.open(self.lock_path, flags, 0o600)
        try:
            fcntl.flock(self._lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as exc:
            os.close(self._lock_fd)
            self._lock_fd = None
            raise CreateAttemptError("CREATE_WORKFLOW_ALREADY_RUNNING") from exc
        os.chmod(self.lock_path, 0o600)
        return self

    def __exit__(self, exc_type: Any, exc: Any, traceback: Any) -> None:
        if self._lock_fd is not None:
            fcntl.flock(self._lock_fd, fcntl.LOCK_UN)
            os.close(self._lock_fd)
            self._lock_fd = None

    @property
    def pending(self) -> dict[str, str] | None:
        state = self._load()
        pending = state.get("pending")
        if pending is None:
            return None
        if (
            not isinstance(pending, dict)
            or not isinstance(pending.get("operation_id"), str)
            or pending.get("phase") not in {"OUTCOME_UNKNOWN", "CREATED_NEEDS_READBACK"}
            or not isinstance(pending.get("started_at"), str)
        ):
            raise CreateAttemptError("CREATE_JOURNAL_INVALID")
        contact_id = pending.get("contact_id")
        if contact_id is not None and (
            not isinstance(contact_id, str)
            or not contact_id.strip()
            or any(ord(char) < 32 or ord(char) == 127 for char in contact_id)
            or pending.get("phase") != "CREATED_NEEDS_READBACK"
        ):
            raise CreateAttemptError("CREATE_JOURNAL_INVALID")
        return pending

    def begin(self) -> str:
        pending = self.pending
        if pending is not None:
            raise CreateAttemptError("PRIOR_CREATE_REQUIRES_RECONCILIATION", pending["operation_id"])
        operation_id = uuid.uuid4().hex
        self._write(
            {
                "version": 1,
                "pending": {
                    "operation_id": operation_id,
                    "phase": "OUTCOME_UNKNOWN",
                    "started_at": _now(),
                },
            }
        )
        return operation_id

    def mark_created(self, operation_id: str, contact_id: str) -> None:
        if (
            not isinstance(contact_id, str)
            or not contact_id.strip()
            or any(ord(char) < 32 or ord(char) == 127 for char in contact_id)
        ):
            raise CreateAttemptError("CREATE_CONTACT_ID_INVALID")
        pending = self.pending
        if pending is None or pending["operation_id"] != operation_id:
            raise CreateAttemptError("CREATE_JOURNAL_STATE_MISMATCH")
        pending["phase"] = "CREATED_NEEDS_READBACK"
        pending["contact_id"] = contact_id
        self._write({"version": 1, "pending": pending})

    def complete(self, operation_id: str) -> None:
        pending = self.pending
        if pending is None or pending["operation_id"] != operation_id:
            raise CreateAttemptError("CREATE_JOURNAL_STATE_MISMATCH")
        self._write({"version": 1, "pending": None})

    def resolve_pending(self, operation_id: str, resolution: str) -> None:
        """Clear an attempt only after an operator manually reconciles it."""
        if resolution not in {"CONTACT_CONFIRMED", "NO_CONTACT_AFTER_MANUAL_CHECK"}:
            raise CreateAttemptError("CREATE_RESOLUTION_INVALID")
        pending = self.pending
        if pending is None or pending["operation_id"] != operation_id:
            raise CreateAttemptError("CREATE_JOURNAL_STATE_MISMATCH")
        self._write(
            {
                "version": 1,
                "pending": None,
                "last_resolution": {"result": resolution, "recorded_at": _now()},
            }
        )

    def _load(self) -> dict[str, Any]:
        if not self.path.exists():
            return {"version": 1, "pending": None}
        if self.path.is_symlink():
            raise CreateAttemptError("CREATE_JOURNAL_UNREADABLE")
        try:
            if os.stat(self.path).st_mode & 0o077:
                raise CreateAttemptError("CREATE_JOURNAL_PERMISSIONS_INVALID")
            state = json.loads(self.path.read_text(encoding="utf-8"))
        except (OSError, UnicodeError, json.JSONDecodeError) as exc:
            raise CreateAttemptError("CREATE_JOURNAL_UNREADABLE") from exc
        if not isinstance(state, dict) or state.get("version") != 1 or "pending" not in state:
            raise CreateAttemptError("CREATE_JOURNAL_INVALID")
        return state

    def _write(self, state: dict[str, Any]) -> None:
        self.folder.mkdir(mode=0o700, parents=True, exist_ok=True)
        temp = self.folder / (".contact-create-state-" + uuid.uuid4().hex + ".pending")
        flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
        if hasattr(os, "O_NOFOLLOW"):
            flags |= os.O_NOFOLLOW
        fd = os.open(temp, flags, 0o600)
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as output:
                json.dump(state, output, separators=(",", ":"), sort_keys=True)
                output.flush()
                os.fsync(output.fileno())
            os.replace(temp, self.path)
            os.chmod(self.path, 0o600)
            directory_fd = os.open(self.folder, os.O_RDONLY)
            try:
                os.fsync(directory_fd)
            finally:
                os.close(directory_fd)
        finally:
            try:
                temp.unlink()
            except FileNotFoundError:
                pass


def _reject_repository_path(path: Path) -> None:
    for candidate in Path(__file__).resolve().parents:
        marker = candidate / ".git"
        if marker.exists() and (path == candidate or candidate in path.parents):
            raise CreateAttemptError("CREATE_STATE_DIR_MUST_BE_OUTSIDE_REPOSITORY")


def _now() -> str:
    return datetime.now(timezone.utc).isoformat()
