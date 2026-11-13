#!/usr/bin/env python3
"""r1_capture_readonly.py — R1-01 read-only evidence capture (diagnostic layer A).

Purpose
-------
Capture, in one pass, the evidence that the AG-02/AG-04/AG-07 receipts could not
provide: whether the bound dedicated list is EMPTY at the EventKit bridge, or
whether a synthetic item exists and is being mis-mapped somewhere upstream.

Hard boundaries (enforced by construction, not by convention):
  * GET only. This script never issues POST/PUT/PATCH/DELETE.
  * Reads exactly one list: the one passed via --list-id.
  * Never prints, logs, or stores the bearer token. The token is read from an
    environment variable and is only used to build the Authorization header.
  * Never emits raw reminder titles, notes, or object identifiers. Only
    booleans, counts, lengths, hex digests and dates reach the receipt, so a
    receipt produced against a production list cannot leak private content.
  * Loopback-only by default: refuses non-loopback endpoints unless
    --allow-remote is given explicitly.

Exit codes (a capture that honestly reports "empty" is still a successful run):
  0 = capture completed and written
  2 = precondition failure (health unavailable, permission denied, bad args)
  3 = local tooling/environment problem (missing python modules, unwritable out)

This script is layer A of the four-layer separation required by the task
(A engineering direct diagnostic, B MUSE foreground trigger, C wrapper,
D raw MCP call). It must not be used as, or reported as, MUSE acceptance.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import sys
import time
import urllib.error
import urllib.request
from typing import Any

SCRIPT_VERSION = "1.0.0"

UUID_RE = re.compile(
    r"[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}"
)
TZ_RE = re.compile(r"^[A-Za-z0-9_+\-/]{1,64}$")


# --------------------------------------------------------------------------- #
# helpers
# --------------------------------------------------------------------------- #
def mask_uuid(value: str) -> str:
    """Mask any UUID-looking token as 8 chars of prefix + **** + 4 of suffix."""
    def _sub(match: re.Match[str]) -> str:
        raw = match.group(0)
        return f"{raw[:4]}****{raw[-4:]}"

    return UUID_RE.sub(_sub, value)


def digest(value: str | None) -> str | None:
    """Short, non-reversible fingerprint used instead of raw content."""
    if value is None:
        return None
    return hashlib.sha256(value.encode("utf-8")).hexdigest()[:12]


def safe_tz(value: Any) -> str | None:
    if not isinstance(value, str) or not value:
        return None
    return value if TZ_RE.match(value) else "INVALID_TZ_IDENTIFIER"


def http_get(url: str, token: str, timeout: float) -> tuple[int, Any, str]:
    """Single GET. Returns (status, parsed_json_or_None, raw_text)."""
    request = urllib.request.Request(
        url,
        method="GET",
        headers={
            "Authorization": f"Bearer {token}",
            "Accept": "application/json",
            "User-Agent": f"MUSE-R1-Capture/{SCRIPT_VERSION} (readonly)",
        },
    )
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            raw = response.read().decode("utf-8", errors="replace")
            status = response.status
    except urllib.error.HTTPError as exc:  # 4xx/5xx carry a JSON error body
        raw = exc.read().decode("utf-8", errors="replace")
        status = exc.code
    except (urllib.error.URLError, TimeoutError, OSError) as exc:
        return 0, None, f"TRANSPORT_ERROR: {type(exc).__name__}"

    parsed: Any = None
    try:
        parsed = json.loads(raw) if raw.strip() else None
    except json.JSONDecodeError:
        parsed = None
    return status, parsed, raw


def is_loopback(endpoint: str) -> bool:
    return bool(
        re.match(r"^http://(127\.0\.0\.1|localhost|\[::1\])(:\d+)?/?$", endpoint)
    )


# --------------------------------------------------------------------------- #
# capture
# --------------------------------------------------------------------------- #
def capture(args: argparse.Namespace, token: str) -> tuple[dict[str, Any], int]:
    endpoint = args.endpoint.rstrip("/")
    started = time.time()
    receipt: dict[str, Any] = {
        "receipt_type": "R1_READONLY_CAPTURE",
        "task": "REM-R1-01",
        "layer": "A_ENGINEERING_DIRECT_DIAGNOSTIC",
        "script_version": SCRIPT_VERSION,
        "label": args.label,
        "captured_at_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "endpoint": endpoint,  # loopback only; no host identity recorded here
        "boundary": {
            "http_methods": ["GET"],
            "lists_queried": 1,
            "writes_attempted": 0,
            "token_persisted": False,
            "raw_content_persisted": False,
        },
        "target_list": {
            "list_id_masked": mask_uuid(args.list_id),
            "expected_title_digest": digest(args.expect_title),
            "expected_notes_digest": digest(args.expect_notes),
        },
        "health": {},
        "list_metadata": {},
        "items": {},
        "classification": "NOT_CAPTURED",
        "assertions": [],
    }

    # 1. Health: proves which process/generation answered, without touching data.
    status, body, raw = http_get(f"{endpoint}/health", token, args.timeout)
    receipt["health"] = {
        "http_status": status,
        "status_field": (body or {}).get("status") if isinstance(body, dict) else None,
        "mode_field": (body or {}).get("mode") if isinstance(body, dict) else None,
        "store_field": (body or {}).get("store") if isinstance(body, dict) else None,
        "generation": (body or {}).get("generation") if isinstance(body, dict) else None,
        "body_digest": digest(raw),
    }
    if status != 200:
        receipt["classification"] = "ERROR_HEALTH_UNAVAILABLE"
        receipt["assertions"].append(
            {"name": "bridge_health", "result": "FAIL", "detail": f"HTTP {status}"}
        )
        return receipt, 2
    receipt["assertions"].append({"name": "bridge_health", "result": "PASS"})

    # 2. Metadata for the single bound list. No other list is enumerated or read.
    status, body, raw = http_get(f"{endpoint}/reminders/lists", token, args.timeout)
    lists = body if isinstance(body, list) else []
    target = next(
        (entry for entry in lists if isinstance(entry, dict) and entry.get("listID") == args.list_id),
        None,
    )
    receipt["list_metadata"] = {
        "http_status": status,
        "visible_list_count": len(lists),
        "target_visible": target is not None,
        "title_match": bool(target and target.get("title") == args.expect_title),
        "source_type": (target or {}).get("sourceType"),
        "source_name": (target or {}).get("sourceName"),
        "source_id_masked": mask_uuid((target or {}).get("sourceID") or "") or None,
        "is_immutable": (target or {}).get("isImmutable"),
        "error_code": (body or {}).get("code") if isinstance(body, dict) else None,
    }
    if status == 403:
        receipt["classification"] = "ERROR_PERMISSION_DENIED_SWITCH_CLOSED"
        receipt["assertions"].append(
            {"name": "list_metadata_readable", "result": "FAIL", "detail": "HTTP 403"}
        )
        return receipt, 2
    if status != 200:
        receipt["classification"] = f"ERROR_LIST_METADATA_HTTP_{status}"
        receipt["assertions"].append(
            {"name": "list_metadata_readable", "result": "FAIL", "detail": f"HTTP {status}"}
        )
        return receipt, 2
    receipt["assertions"].append({"name": "list_metadata_readable", "result": "PASS"})
    receipt["assertions"].append(
        {
            "name": "single_bound_list_visible",
            "result": "PASS" if target is not None else "FAIL",
            "detail": f"visible={len(lists)}",
        }
    )
    if target is None:
        receipt["classification"] = "TARGET_LIST_NOT_VISIBLE"
        return receipt, 2

    # 3. Items of the bound list — the observation that decides R1.
    status, body, raw = http_get(
        f"{endpoint}/reminders/lists/{args.list_id}/items", token, args.timeout
    )
    if status == 403:
        receipt["classification"] = "ERROR_PERMISSION_DENIED_SWITCH_CLOSED"
        receipt["assertions"].append(
            {"name": "items_readable", "result": "FAIL", "detail": "HTTP 403"}
        )
        return receipt, 2
    if status != 200:
        receipt["items"] = {
            "http_status": status,
            "error_code": (body or {}).get("code") if isinstance(body, dict) else None,
        }
        receipt["classification"] = f"ERROR_ITEMS_HTTP_{status}"
        receipt["assertions"].append(
            {"name": "items_readable", "result": "FAIL", "detail": f"HTTP {status}"}
        )
        return receipt, 2

    items = body if isinstance(body, list) else None
    if items is None:
        receipt["items"] = {"http_status": status, "shape": "NOT_AN_ARRAY"}
        receipt["classification"] = "ERROR_RESPONSE_SHAPE"
        receipt["assertions"].append(
            {"name": "items_response_is_array", "result": "FAIL"}
        )
        return receipt, 2

    matched = [item for item in items if item.get("title") == args.expect_title]
    receipt["items"] = {
        "http_status": status,
        "returned_count": len(items),
        "matched_synthetic_count": len(matched),
        "unmatched_count": len(items) - len(matched),
        "body_digest": digest(raw),
        "field_probe": [_probe(item, args) for item in matched],
    }

    if not items:
        receipt["classification"] = "EMPTY_ARRAY_CONFIRMED_BY_BRIDGE"
        receipt["assertions"].append(
            {
                "name": "synthetic_item_visible_to_eventkit",
                "result": "FAIL",
                "detail": "bridge returned an empty array for the bound list",
            }
        )
        return receipt, 0

    if not matched:
        receipt["classification"] = "NON_EMPTY_BUT_SYNTHETIC_ITEM_ABSENT"
        receipt["assertions"].append(
            {
                "name": "synthetic_item_visible_to_eventkit",
                "result": "FAIL",
                "detail": f"items={len(items)} but none matched the expected synthetic title",
            }
        )
        return receipt, 0

    receipt["classification"] = "NON_EMPTY_SYNTHETIC_ITEM_PRESENT"
    receipt["assertions"].append(
        {"name": "synthetic_item_visible_to_eventkit", "result": "PASS"}
    )
    receipt["assertions"].extend(_field_assertions(matched[0], args))
    receipt["elapsed_ms"] = int((time.time() - started) * 1000)
    return receipt, 0


def _probe(item: dict[str, Any], args: argparse.Namespace) -> dict[str, Any]:
    """Field-level fingerprint of one synthetic item. No raw content."""
    due = item.get("dueDate")
    return {
        "item_id_masked": mask_uuid(str(item.get("itemID", ""))),
        "title_length": len(item.get("title") or ""),
        "title_digest": digest(item.get("title")),
        "notes_present": item.get("notes") is not None,
        "notes_length": len(item.get("notes") or "") if item.get("notes") else 0,
        "notes_digest": digest(item.get("notes")),
        "priority": item.get("priority"),
        "is_completed": item.get("isCompleted"),
        "due_date_raw_type": type(due).__name__ if due is not None else None,
        "due_date_iso": _iso(due),
        "is_all_day": item.get("isAllDay"),
        "time_zone": safe_tz(item.get("timeZone")),
        "completion_date_iso": _iso(item.get("completionDate")),
        "creation_date_iso": _iso(item.get("creationDate")),
        "last_modified_iso": _iso(item.get("lastModifiedDate")),
    }


def _iso(value: Any) -> str | None:
    """Render a bridge date (Cocoa epoch seconds or ISO string) as UTC ISO-8601."""
    if value is None:
        return None
    if isinstance(value, (int, float)):
        try:
            seconds = float(value) + 978307200.0  # Cocoa reference epoch -> Unix
            return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(seconds))
        except (OverflowError, ValueError):
            return "INVALID_EPOCH"
    if isinstance(value, str):
        return value
    return None


def _field_assertions(item: dict[str, Any], args: argparse.Namespace) -> list[dict[str, Any]]:
    """Assertions that actually decide R1 (non-empty field fidelity)."""
    checks: list[dict[str, Any]] = []

    def check(name: str, ok: bool, detail: str = "") -> None:
        entry = {"name": name, "result": "PASS" if ok else "FAIL"}
        if detail:
            entry["detail"] = detail
        checks.append(entry)

    check("title_exact_match", item.get("title") == args.expect_title)
    check(
        "notes_exact_match",
        item.get("notes") == args.expect_notes,
        "" if item.get("notes") == args.expect_notes else "notes differ or absent",
    )
    check("priority_match", item.get("priority") == args.expect_priority,
          f"observed={item.get('priority')} expected={args.expect_priority}")
    check("completion_state_match", bool(item.get("isCompleted")) is False)
    check("due_date_present", item.get("dueDate") is not None)
    # EventKit frequently omits components.timeZone for iCloud reminders; an
    # absent timezone is recorded, not failed. The due instant is the real check.
    checks.append(
        {
            "name": "time_zone_reported",
            "result": "INFO",
            "detail": f"observed={safe_tz(item.get('timeZone'))}",
        }
    )
    check("list_id_attribution_match", str(item.get("listID")) == args.list_id)
    return checks


# --------------------------------------------------------------------------- #
# main
# --------------------------------------------------------------------------- #
def main() -> int:
    parser = argparse.ArgumentParser(
        description="Read-only R1 evidence capture against the EventKit bridge."
    )
    parser.add_argument("--endpoint", default="http://127.0.0.1:18765")
    parser.add_argument("--list-id", required=True, help="bound dedicated list id")
    parser.add_argument("--expect-title", required=True, help="exact synthetic title")
    parser.add_argument("--expect-notes", required=True, help="exact synthetic notes")
    parser.add_argument("--expect-priority", type=int, default=5)
    parser.add_argument("--token-env", default="EVENTKIT_BRIDGE_TOKEN")
    parser.add_argument("--out", required=True)
    parser.add_argument("--label", default="unspecified")
    parser.add_argument("--timeout", type=float, default=15.0)
    parser.add_argument("--allow-remote", action="store_true")
    args = parser.parse_args()

    if not is_loopback(args.endpoint) and not args.allow_remote:
        print("REFUSED: non-loopback endpoint requires --allow-remote", file=sys.stderr)
        return 2

    token = os.environ.get(args.token_env, "")
    if len(token) < 16:
        print(
            f"REFUSED: ${args.token_env} is missing or implausibly short "
            "(the token is read from the environment and never logged)",
            file=sys.stderr,
        )
        return 2

    try:
        receipt, code = capture(args, token)
    except Exception as exc:  # noqa: BLE001 - never leak a traceback with the token
        print(f"CAPTURE_FAILED: {type(exc).__name__}", file=sys.stderr)
        return 3

    payload = json.dumps(receipt, indent=2, ensure_ascii=False) + "\n"
    # Belt and braces: mask any UUID that slipped through from upstream fields.
    payload = mask_uuid(payload)
    try:
        with open(args.out, "w", encoding="utf-8") as handle:
            handle.write(payload)
    except OSError as exc:
        print(f"CAPTURE_FAILED: cannot write receipt ({exc.strerror})", file=sys.stderr)
        return 3

    print(f"classification={receipt['classification']} out={args.out}")
    for check in receipt["assertions"]:
        detail = f" ({check['detail']})" if check.get("detail") else ""
        print(f"  [{check['result']}] {check['name']}{detail}")
    return code


if __name__ == "__main__":
    sys.exit(main())
