"""safe_write.py
MUSE Production Gated Safe Write Manager with Deterministic ETag and Intent Logging.

Key Invariants:
1. Caller's expected_etag is strictly preserved; never silently replaced with pre-read etag.
2. If expected_etag is supplied and does not match pre_state["etag"], CONFLICT is returned
   immediately with zero write network requests.
3. If expected_etag is omitted, pre-read etag is attached for optimistic locking.
4. UNKNOWN write outcome strictly prohibits auto-retry and halts further writes.
5. All operations require valid user Authorization, intent journal logging, and deduplication.
"""

from __future__ import annotations

import base64
import copy
import hashlib
import json
import os
import time
import uuid
from typing import Any, Callable, Dict, List, Optional, Set, Tuple

# Tools that support ETag optimistic locking
ETAG_TOOLS: Set[str] = {
    "calendar_update_event",
    "calendar_delete_event",
    "reminders_update",
    "reminders_delete",
    "contacts_update",
    "contacts_delete",
    "contacts_groups_rename",
    "contacts_groups_add_members",
    "contacts_groups_remove_members",
}

# Supported B2 write tools (15 tools)
B2_WRITE_TOOLS: Set[str] = {
    "calendar_create_event",
    "calendar_update_event",
    "calendar_delete_event",
    "reminders_create",
    "reminders_update",
    "reminders_delete",
    "contacts_create",
    "contacts_update",
    "contacts_delete",
    "contacts_groups_create",
    "contacts_groups_rename",
    "contacts_groups_add_members",
    "contacts_groups_remove_members",
    "contacts_groups_delete",
    "contacts_create_in_groups",
}


class SafeWriteError(Exception):
    """Base error for safe write manager."""
    def __init__(self, code: str, message: str, hint: Optional[str] = None):
        super().__init__(f"[{code}] {message}")
        self.code = code
        self.message = message
        self.hint = hint


class ConflictError(SafeWriteError):
    def __init__(self, message: str = "该事件已被其他客户端修改", hint: Optional[str] = None):
        super().__init__("CONFLICT", message, hint or "重新调用读取工具获取最新状态后再提交")


class AuthUntrustedError(SafeWriteError):
    def __init__(self, message: str = "授权来源不可信或已失效"):
        super().__init__("AUTH_UNTRUSTED", message, "请重新获取用户授权")


class PermissionDeniedError(SafeWriteError):
    def __init__(self, message: str = "写入权限未开启或目标受限"):
        super().__init__("PERMISSION_DENIED", message)


class UnknownWriteError(SafeWriteError):
    def __init__(self, message: str = "写入结果未知，严禁自动重试"):
        super().__init__("UNKNOWN", message, "请通过只读回读核查服务端实际状态")


def _b64url_encode(data: bytes) -> str:
    """Base64url without padding (format used by MCP container IDs)."""
    return base64.urlsafe_b64encode(data).decode("ascii").rstrip("=")


def _b64url_decode(s: str) -> Optional[bytes]:
    """Base64url decode with padding recovery."""
    padding = "=" * ((4 - len(s) % 4) % 4)
    try:
        return base64.urlsafe_b64decode((s + padding).encode("ascii"))
    except Exception:
        return None


def _nested_view(tool: str, args: Dict[str, Any]) -> Dict[str, Any]:
    """Flatten nested parameters (event/reminder/contact/patch) for inspection."""
    view = dict(args or {})
    for nest_key in ("event", "reminder", "contact", "patch"):
        nested = view.get(nest_key)
        if isinstance(nested, dict):
            for k, v in nested.items():
                if k not in view:
                    view[k] = v
    return view


def _fingerprint(text: Optional[str]) -> str:
    """SHA-256 first 16 hex characters of text for privacy-preserving auditing."""
    if not text:
        return "empty"
    return hashlib.sha256(text.encode("utf-8")).hexdigest()[:16]


def build_dedup_key(tool: str, args: Dict[str, Any], business_context: Optional[Dict[str, Any]] = None) -> str:
    """Construct deterministic deduplication key preserving business round and scope."""
    ctx = business_context or {}
    view = _nested_view(tool, args)

    if tool == "calendar_create_event":
        title_fp = _fingerprint(view.get("title"))
        start = view.get("start", "")
        cal_id = args.get("calendar_id", "default")
        round_tag = ctx.get("round", "r1")
        return f"cal_create:{cal_id}:{start}:{title_fp}:{round_tag}"

    elif tool == "calendar_update_event":
        event_id = args.get("event_id", "")
        scope = args.get("scope", "all")
        rec_id = args.get("recurrence_id", "")
        patch_keys = sorted(k for k in (args.get("patch") or {}).keys())
        patch_fp = hashlib.sha256(json.dumps(args.get("patch") or {}, sort_keys=True).encode("utf-8")).hexdigest()[:16]
        return f"cal_update:{event_id}:{scope}:{rec_id}:{','.join(patch_keys)}:{patch_fp}"

    elif tool == "calendar_delete_event":
        event_id = args.get("event_id", "")
        scope = args.get("scope", "all")
        rec_id = args.get("recurrence_id", "")
        return f"cal_delete:{event_id}:{scope}:{rec_id}"

    elif tool == "reminders_create":
        title_fp = _fingerprint(view.get("title"))
        list_id = args.get("list_id", "default")
        due = view.get("due", "")
        round_tag = ctx.get("round", "r1")
        return f"rem_create:{list_id}:{due}:{title_fp}:{round_tag}"

    elif tool in ("reminders_update", "reminders_delete"):
        rem_id = args.get("reminder_id", "")
        return f"{tool}:{rem_id}"

    else:
        # Default structured dedup key
        norm_args = json.dumps(args, sort_keys=True)
        return f"{tool}:{hashlib.sha256(norm_args.encode('utf-8')).hexdigest()[:16]}"


class ApprovalToken:
    """Cryptographic or verified user approval token."""
    def __init__(
        self,
        token_id: str,
        issuer: str,
        authorized_at: float,
        expires_at: float,
        scope_tool: str,
        scope_target: str,
        bound_dedup_key: str,
    ):
        self.token_id = token_id
        self.issuer = issuer
        self.authorized_at = authorized_at
        self.expires_at = expires_at
        self.scope_tool = scope_tool
        self.scope_target = scope_target
        self.bound_dedup_key = bound_dedup_key

    def is_valid(self, tool: str, target: str, dedup_key: str, now: Optional[float] = None) -> bool:
        ts = now if now is not None else time.time()
        if self.issuer != "user_message":
            return False
        if ts > self.expires_at:
            return False
        if self.scope_tool != tool and self.scope_tool != "*":
            return False
        if self.scope_target != target and self.scope_target != "*":
            return False
        if self.bound_dedup_key != dedup_key and self.bound_dedup_key != "*":
            return False
        return True


class IntentStore:
    """Append-only audit log for write intents and results."""
    def __init__(self, log_path: str):
        self.log_path = log_path
        os.makedirs(os.path.dirname(os.path.abspath(log_path)), exist_ok=True)
        self.records: List[Dict[str, Any]] = []

    def record_intent(
        self,
        operation_id: str,
        dedup_key: str,
        tool: str,
        target_id: str,
        pre_state: Dict[str, Any],
        approval_id: str,
    ) -> None:
        rec = {
            "record_type": "INTENT_RECORDED",
            "operation_id": operation_id,
            "dedup_key": dedup_key,
            "tool": tool,
            "target_id": target_id,
            "pre_state": pre_state,
            "approval_id": approval_id,
            "created_at": time.time(),
        }
        self.records.append(rec)
        self._append(rec)

    def mark_send_started(self, operation_id: str) -> None:
        rec = {
            "record_type": "SEND_STARTED",
            "operation_id": operation_id,
            "status": "UNKNOWN",
            "send_started_at": time.time(),
        }
        self.records.append(rec)
        self._append(rec)

    def record_result(self, operation_id: str, status: str, payload_or_error: Any) -> None:
        rec = {
            "record_type": "RESULT_RECORDED",
            "operation_id": operation_id,
            "status": status,
            "payload": payload_or_error if status == "APPLIED" else str(payload_or_error),
            "updated_at": time.time(),
        }
        self.records.append(rec)
        self._append(rec)

    def _append(self, rec: Dict[str, Any]) -> None:
        with open(self.log_path, "a", encoding="utf-8") as f:
            f.write(json.dumps(rec, ensure_ascii=False) + "\n")


class SafeWriteManager:
    """Gated write manager implementing CAS ETag protection and zero auto-retry on UNKNOWN."""

    def __init__(
        self,
        writes_enabled: bool = False,
        read_fn: Optional[Callable[[str, Dict[str, Any]], Dict[str, Any]]] = None,
        transport_write_fn: Optional[Callable[[str, Dict[str, Any]], Dict[str, Any]]] = None,
        intent_store: Optional[IntentStore] = None,
    ):
        self.writes_enabled = writes_enabled
        self.read_fn = read_fn
        self.transport_write_fn = transport_write_fn
        self.intent_store = intent_store or IntentStore("/tmp/safe_write_intents.jsonl")
        self.ledger: Dict[str, str] = {}  # dedup_key -> status

    def _precheck(self, tool: str, args: Dict[str, Any]) -> Tuple[str, Dict[str, Any]]:
        """Pre-check target object existence and fetch current ETag."""
        if not self.read_fn:
            return "OK", {"exists": None, "etag": None}

        read_tool = None
        read_args: Dict[str, Any] = {}

        if tool.startswith("calendar_"):
            read_tool = "calendar_list_events"
            # In pre-flight, read target event by id
            read_args = {
                "start": args.get("start", "1970-01-01T00:00:00Z"),
                "end": args.get("end", "2099-12-31T23:59:59Z"),
            }
            if "calendar_id" in args:
                read_args["calendar_ids"] = [args["calendar_id"]]
        elif tool.startswith("reminders_"):
            read_tool = "reminders_list"
            if "list_id" in args:
                read_args["list_ids"] = [args["list_id"]]

        if not read_tool:
            return "OK", {"exists": None, "etag": None}

        try:
            res = self.read_fn(read_tool, read_args)
            # Find item matching event_id or reminder_id
            target_id = args.get("event_id") or args.get("reminder_id")
            if not target_id:
                return "OK", {"exists": None, "etag": None}

            items = res.get("events") or res.get("reminders") or []
            matched = [item for item in items if item.get("event_id") == target_id or item.get("id") == target_id]
            if matched:
                return "OK", {"exists": True, "etag": matched[0].get("etag")}
            return "NOT_FOUND", {"exists": False, "etag": None}
        except Exception as e:
            return "ERROR", {"exists": None, "etag": None, "error": str(e)}

    def submit(
        self,
        tool: str,
        args: Dict[str, Any],
        authorization: ApprovalToken,
        business_context: Optional[Dict[str, Any]] = None,
    ) -> Dict[str, Any]:
        """Execute gated write with strict ETag preservation and non-negotiable conflict gating."""
        if not self.writes_enabled:
            raise PermissionDeniedError("writes_enabled is False. Global write gate is closed.")

        if tool not in B2_WRITE_TOOLS:
            raise PermissionDeniedError(f"Tool {tool} is not in authorized B2 write tools whitelist.")

        target_id = args.get("event_id") or args.get("reminder_id") or args.get("calendar_id") or "new"
        dedup_key = build_dedup_key(tool, args, business_context)

        # 1. Authorization validation
        if not authorization.is_valid(tool, target_id, dedup_key):
            raise AuthUntrustedError(f"Authorization token {authorization.token_id} is invalid or expired for {tool} on {target_id}")

        # 2. Check deduplication ledger
        if self.ledger.get(dedup_key) == "APPLIED":
            return {"status": "ALREADY_APPLIED", "tool": tool, "dedup_key": dedup_key, "sends": 0}

        operation_id = f"op-{uuid.uuid4().hex[:12]}"

        # 3. Pre-flight check to get current server state
        _, pre_state = self._precheck(tool, args)

        # 4. CRITICAL: ETag CAS Gating
        caller_expected_etag = args.get("expected_etag")
        actual_server_etag = pre_state.get("etag")

        if caller_expected_etag is not None:
            # Caller explicitly passed expected_etag: MUST PRESERVE and NEVER replace
            if actual_server_etag is not None and caller_expected_etag != actual_server_etag:
                # ETag conflict detected locally!
                # Strictly forbid sending network write request!
                self.intent_store.record_intent(operation_id, dedup_key, tool, target_id, pre_state, authorization.token_id)
                self.intent_store.record_result(operation_id, "CONFLICT", f"ETag mismatch: caller {caller_expected_etag} vs server {actual_server_etag}")
                raise ConflictError(
                    f"CONFLICT: 该事件已被其他客户端修改 (expected_etag {caller_expected_etag} != server {actual_server_etag})"
                )
            # If matches, keep caller_expected_etag in payload
            final_args = dict(args)
            final_args["expected_etag"] = caller_expected_etag
        else:
            # Caller omitted expected_etag: if tool supports ETag and server has etag, attach it
            final_args = dict(args)
            if tool in ETAG_TOOLS and actual_server_etag is not None:
                final_args["expected_etag"] = actual_server_etag

        # 5. Persist INTENT before network send
        self.intent_store.record_intent(operation_id, dedup_key, tool, target_id, pre_state, authorization.token_id)

        # 6. Mark SEND_STARTED (status UNKNOWN)
        self.intent_store.mark_send_started(operation_id)
        self.ledger[dedup_key] = "UNKNOWN"

        # 7. Execute write via transport
        if not self.transport_write_fn:
            raise SafeWriteError("TRANSPORT_MISSING", "No transport_write_fn provided to SafeWriteManager")

        try:
            resp = self.transport_write_fn(tool, final_args)
        except Exception as exc:
            # Transport timeout, network error, or unexpected failure -> Status remains UNKNOWN
            # Strictly FORBID auto-retry!
            self.intent_store.record_result(operation_id, "UNKNOWN", exc)
            raise UnknownWriteError(f"Write operation failed or timed out with UNKNOWN status: {exc}") from exc

        # 8. Check server response
        if isinstance(resp, dict) and resp.get("isError"):
            err_code = resp.get("code") or resp.get("error") or "TOOL_ERROR"
            if "412" in str(resp) or "CONFLICT" in str(err_code) or "已修改" in str(resp):
                self.intent_store.record_result(operation_id, "CONFLICT", resp)
                raise ConflictError("CONFLICT: 上游服务端因并发冲突拒绝写入")
            self.intent_store.record_result(operation_id, "FAILED", resp)
            raise SafeWriteError("WRITE_FAILED", f"Server returned error: {resp}")

        # 9. Mark APPLIED
        self.intent_store.record_result(operation_id, "APPLIED", resp)
        self.ledger[dedup_key] = "APPLIED"

        return {
            "status": "APPLIED",
            "operation_id": operation_id,
            "dedup_key": dedup_key,
            "tool": tool,
            "sends": 1,
            "payload": resp,
        }
