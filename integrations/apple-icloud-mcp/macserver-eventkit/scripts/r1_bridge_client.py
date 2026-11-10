#!/usr/bin/env python3
"""r1_bridge_client.py — read-only client for the MacServer EventKit bridge.

Subcommands
-----------
  health    GET /health and assert the answering process is a real production
            store (a Fake store must never be usable as R1 evidence).
  gate      GET /reminders/lists and assert the business endpoint returns the
            expected status (403 = closed or denied, 200 = open).
  capture   Read exactly one bound list and evaluate a two-part verdict:
            fidelity (a synthetic item exists and its fields match) and
            cleanup (the list is empty again after removal).

Boundaries enforced by construction
-----------------------------------
  * GET only; one list; loopback refused otherwise.
  * The bearer token is read from a 0600 file and never appears in argv, in
    the environment, in logs, or in any receipt.
  * Receipts carry counts, booleans, digests, dates and masked identifiers.
    Raw titles, raw notes and raw object identifiers are never written.
  * Each run writes into a fresh batch directory and refuses to overwrite an
    existing one, so the first non-empty evidence can never be replaced.

Exit codes
----------
  0  expected outcome observed and all asserted fields matched
  2  precondition failure (bad arguments, token file, endpoint)
  3  transport / IO problem, result unknown
  5  batch directory already exists (evidence protection)
  20 fidelity mismatch (item found, field assertions failed)
  21 duplicate synthetic items (more than one match)
  22 expected-empty check failed (cleanup did not take effect)
  23 expected-present check failed (no synthetic item visible)
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

SCRIPT_VERSION = "2.0.0"

UUID_RE = re.compile(
    r"[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}"
)
TZ_RE = re.compile(r"^[A-Za-z0-9_+\-/]{1,64}$")
LOOPBACK_RE = re.compile(r"^http://(127\.0\.0\.1|localhost|\[::1\])(:\d+)?/?$")
COCOA_EPOCH_OFFSET = 978307200.0  # 2001-01-01T00:00:00Z


# --------------------------------------------------------------------------- #
# small helpers
# --------------------------------------------------------------------------- #
def mask_uuid(value: str) -> str:
    return UUID_RE.sub(lambda m: f"{m.group(0)[:4]}****{m.group(0)[-4:]}", value)


def digest(value: str | None) -> str | None:
    if value is None:
        return None
    return hashlib.sha256(value.encode("utf-8")).hexdigest()[:12]


def utc_stamp() -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def utc_iso_from_epoch(seconds: float) -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(seconds))


def read_token(path: str) -> str:
    """Token from a 0600 file. Never echoed, never passed via argv or env."""
    with open(path, "r", encoding="utf-8") as handle:
        token = handle.read().strip()
    if len(token) < 16:
        raise ValueError("token file content is implausibly short")
    mode = os.stat(path).st_mode & 0o777
    if mode & 0o077:
        raise ValueError(f"token file permissions are {oct(mode)}, expected 0600")
    return token


class _RefuseRedirect(urllib.request.HTTPRedirectHandler):
    """A 3xx must never be followed.

    urllib follows redirects by default, and it re-sends the Authorization
    header to the new location. A redirect from the loopback bridge would move
    the request - and the token - off the machine the window is authorized on.
    """

    def redirect_request(self, req, fp, code, msg, headers, newurl):  # noqa: D102
        raise urllib.error.HTTPError(
            req.full_url, code, f"redirect to {newurl} refused by R1 client", headers, fp
        )


# Empty ProxyHandler: an http_proxy in the environment must not silently move a
# loopback request to another host. Passing an explicit empty mapping also makes
# build_opener skip the default ProxyHandler, so no proxy dispatch is installed
# at all - the window is authorized for 127.0.0.1 and nothing else.
_NO_PROXY = urllib.request.ProxyHandler({})
_OPENER = urllib.request.build_opener(_NO_PROXY, _RefuseRedirect)


def http_get(url: str, token: str | None, timeout: float) -> tuple[int, Any, str]:
    headers = {"Accept": "application/json", "User-Agent": f"MUSE-R1/{SCRIPT_VERSION}"}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    request = urllib.request.Request(url, method="GET", headers=headers)
    try:
        with _OPENER.open(request, timeout=timeout) as response:
            raw = response.read().decode("utf-8", errors="replace")
            return response.status, _maybe_json(raw), raw
    except urllib.error.HTTPError as exc:
        raw = exc.read().decode("utf-8", errors="replace")
        return exc.code, _maybe_json(raw), raw
    except (urllib.error.URLError, TimeoutError, OSError) as exc:
        return 0, None, f"TRANSPORT_ERROR:{type(exc).__name__}"


def _maybe_json(raw: str) -> Any:
    try:
        return json.loads(raw) if raw.strip() else None
    except json.JSONDecodeError:
        return None


def emit(receipt: dict[str, Any], path: str) -> None:
    payload = mask_uuid(json.dumps(receipt, indent=2, ensure_ascii=False) + "\n")
    with open(path, "w", encoding="utf-8") as handle:
        handle.write(payload)


def fresh_dir(path: str) -> None:
    """Create a batch directory that must not already contain evidence."""
    if os.path.exists(path):
        if os.listdir(path):
            raise FileExistsError(path)
    else:
        os.makedirs(path, mode=0o700)
    os.chmod(path, 0o700)


# --------------------------------------------------------------------------- #
# health
# --------------------------------------------------------------------------- #
def cmd_health(args: argparse.Namespace) -> int:
    status, body, raw = http_get(f"{args.endpoint}/health", None, args.timeout)
    store = body.get("store") if isinstance(body, dict) else None
    body_status = body.get("status") if isinstance(body, dict) else None
    receipt = {
        "receipt_type": "R1_HEALTH",
        "task": "REM-R1-01",
        "client_version": SCRIPT_VERSION,
        "observed_at_utc": utc_stamp(),
        "endpoint": args.endpoint,
        "http_status": status,
        "status_field": body_status,
        "mode_field": body.get("mode") if isinstance(body, dict) else None,
        "store_field": store,
        "generation": body.get("generation") if isinstance(body, dict) else None,
        "active_requests": body.get("active_requests") if isinstance(body, dict) else None,
        "body_digest": digest(raw),
        "assertions": [],
    }

    def check(name: str, ok: bool, detail: str = "") -> None:
        entry = {"name": name, "result": "PASS" if ok else "FAIL"}
        if detail:
            entry["detail"] = detail
        receipt["assertions"].append(entry)

    if status != 200:
        receipt["classification"] = "ERROR_BRIDGE_UNREACHABLE"
        emit(receipt, args.out)
        print(f"health: ERROR_BRIDGE_UNREACHABLE (http={status})")
        return 3

    check("health_http_200", status == 200)
    check("status_field_ok", body_status == "ok", f"observed={body_status}")
    # A Fake store cannot be R1 evidence. Absence of the field is also a failure.
    check(
        "production_store_confirmed",
        store == "production",
        f"observed={store!r}; 'fake' or missing means this process cannot serve as R1 evidence",
    )
    if isinstance(body, dict) and body.get("mode"):
        check("mode_readonly", body.get("mode") == "readonly", f"observed={body.get('mode')}")

    ok = all(entry["result"] == "PASS" for entry in receipt["assertions"])
    receipt["classification"] = "HEALTH_PRODUCTION_STORE_OK" if ok else "HEALTH_STORE_NOT_ACCEPTABLE"
    emit(receipt, args.out)
    print(f"health: {receipt['classification']} (store={store})")
    return 0 if ok else 20


# --------------------------------------------------------------------------- #
# gate
# --------------------------------------------------------------------------- #
def cmd_gate(args: argparse.Namespace) -> int:
    token = read_token(args.token_file)
    status, body, raw = http_get(f"{args.endpoint}/reminders/lists", token, args.timeout)
    code = body.get("code") if isinstance(body, dict) else None
    receipt = {
        "receipt_type": "R1_GATE_STATE",
        "task": "REM-R1-01",
        "client_version": SCRIPT_VERSION,
        "observed_at_utc": utc_stamp(),
        "http_status": status,
        "error_code": code,
        "expected_status": args.expect,
        "body_digest": digest(raw),
        "note": "403 is an outcome, not a diagnosis: closed gate and denied TCC"
                " permission are indistinguishable at this endpoint.",
    }
    matched = status == args.expect
    receipt["classification"] = (
        "GATE_AS_EXPECTED" if matched else f"GATE_UNEXPECTED_HTTP_{status}"
    )
    emit(receipt, args.out)
    print(f"gate: status={status} expected={args.expect} -> {receipt['classification']}")
    return 0 if matched else 22


# --------------------------------------------------------------------------- #
# capture
# --------------------------------------------------------------------------- #
def cmd_capture(args: argparse.Namespace) -> int:
    fresh_dir(args.batch_dir)
    token = read_token(args.token_file)
    receipt: dict[str, Any] = {
        "receipt_type": "R1_CAPTURE_BATCH",
        "task": "REM-R1-01",
        "layer": "A_ENGINEERING_DIRECT_DIAGNOSTIC",
        "client_version": SCRIPT_VERSION,
        "label": args.label,
        "captured_at_utc": utc_stamp(),
        "endpoint": args.endpoint,
        "expectation": args.expect,
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
        "assertions": {"preconditions": [], "fidelity": [], "cleanup": []},
        "verdict": {"capture_completed": False, "fidelity_asserted": False,
                    "cleanup_asserted": False},
        "classification": "NOT_CAPTURED",
    }

    def add(group: str, name: str, ok: bool | None, detail: str = "") -> None:
        entry: dict[str, Any] = {"name": name, "result": "INFO" if ok is None else ("PASS" if ok else "FAIL")}
        if detail:
            entry["detail"] = detail
        receipt["assertions"][group].append(entry)

    # 1. health: the answering process must be a production store
    status, body, raw = http_get(f"{args.endpoint}/health", None, args.timeout)
    store = body.get("store") if isinstance(body, dict) else None
    receipt["health"] = {
        "http_status": status,
        "store_field": store,
        "mode_field": body.get("mode") if isinstance(body, dict) else None,
        "generation": body.get("generation") if isinstance(body, dict) else None,
        "body_digest": digest(raw),
    }
    if status != 200:
        receipt["classification"] = "ERROR_BRIDGE_UNREACHABLE"
        emit(receipt, os.path.join(args.batch_dir, "capture.json"))
        print(f"capture: ERROR_BRIDGE_UNREACHABLE (http={status})")
        return 3
    add("preconditions", "health_http_200", True)
    add(
        "preconditions",
        "production_store_confirmed",
        store == "production",
        f"observed={store!r}; a fake store cannot stand in for R1 evidence",
    )
    if store != "production":
        receipt["classification"] = "ERROR_NOT_PRODUCTION_STORE"
        emit(receipt, os.path.join(args.batch_dir, "capture.json"))
        print(f"capture: ERROR_NOT_PRODUCTION_STORE (store={store})")
        return 20

    # 2. metadata for the single bound list
    status, body, raw = http_get(f"{args.endpoint}/reminders/lists", token, args.timeout)
    lists = body if isinstance(body, list) else []
    target = next(
        (e for e in lists if isinstance(e, dict) and e.get("listID") == args.list_id), None
    )
    receipt["list_metadata"] = {
        "http_status": status,
        "visible_list_count": len(lists),
        "target_visible": target is not None,
        "source_type": (target or {}).get("sourceType"),
        "source_name": (target or {}).get("sourceName"),
        "source_id_masked": mask_uuid((target or {}).get("sourceID") or "") or None,
        "error_code": (body or {}).get("code") if isinstance(body, dict) else None,
    }
    if status != 200:
        receipt["classification"] = f"ERROR_LIST_METADATA_HTTP_{status}"
        emit(receipt, os.path.join(args.batch_dir, "capture.json"))
        print(f"capture: ERROR_LIST_METADATA_HTTP_{status}")
        return 3
    add("preconditions", "list_metadata_http_200", True)
    add("preconditions", "single_visible_list", len(lists) == 1, f"visible={len(lists)}")
    add("preconditions", "target_list_visible", target is not None)
    add(
        "preconditions",
        "source_binding_caldav_icloud",
        (target or {}).get("sourceType") == "calDAV" and (target or {}).get("sourceName") == "iCloud",
        f"{ (target or {}).get('sourceType') }/{ (target or {}).get('sourceName') }",
    )
    if target is None or len(lists) != 1:
        receipt["classification"] = "ERROR_TARGET_LIST_IDENTITY"
        emit(receipt, os.path.join(args.batch_dir, "capture.json"))
        print("capture: ERROR_TARGET_LIST_IDENTITY")
        return 20

    # 3. items
    status, body, raw = http_get(
        f"{args.endpoint}/reminders/lists/{args.list_id}/items", token, args.timeout
    )
    if status != 200 or not isinstance(body, list):
        receipt["items"] = {
            "http_status": status,
            "shape": "NOT_AN_ARRAY" if status == 200 else "HTTP_ERROR",
            "error_code": (body or {}).get("code") if isinstance(body, dict) else None,
        }
        receipt["classification"] = f"ERROR_ITEMS_HTTP_{status}" if status != 200 else "ERROR_RESPONSE_SHAPE"
        emit(receipt, os.path.join(args.batch_dir, "capture.json"))
        print(f"capture: {receipt['classification']}")
        return 3

    matched = [item for item in body if item.get("title") == args.expect_title]
    receipt["items"] = {
        "http_status": status,
        "returned_count": len(body),
        "matched_synthetic_count": len(matched),
        "unmatched_count": len(body) - len(matched),
        "body_digest": digest(raw),
        "field_probe": [_probe(item) for item in matched],
    }
    receipt["verdict"]["capture_completed"] = True

    if args.expect == "absence":
        ok = len(body) == 0
        add("cleanup", "list_empty_after_removal", ok, f"returned={len(body)}")
        add(
            "cleanup",
            "no_synthetic_marker_present",
            len(matched) == 0,
            f"matched={len(matched)}",
        )
        receipt["verdict"]["cleanup_asserted"] = ok
        receipt["classification"] = (
            "EMPTY_ARRAY_CONFIRMED_BY_BRIDGE" if ok else "CLEANUP_NOT_EFFECTIVE"
        )
        emit(receipt, os.path.join(args.batch_dir, "capture.json"))
        print(f"capture: {receipt['classification']} (returned={len(body)})")
        return 0 if ok else 22

    # expectation == presence
    if not body:
        add("fidelity", "synthetic_item_visible", False, "bridge returned an empty array")
        receipt["classification"] = "EMPTY_ARRAY_CONFIRMED_BY_BRIDGE"
        emit(receipt, os.path.join(args.batch_dir, "capture.json"))
        print("capture: EMPTY_ARRAY_CONFIRMED_BY_BRIDGE")
        return 23

    if not matched:
        add("fidelity", "synthetic_item_visible", False, f"items={len(body)} none matched")
        receipt["classification"] = "NON_EMPTY_BUT_SYNTHETIC_ITEM_ABSENT"
        emit(receipt, os.path.join(args.batch_dir, "capture.json"))
        print("capture: NON_EMPTY_BUT_SYNTHETIC_ITEM_ABSENT")
        return 23

    if len(matched) > 1:
        add("fidelity", "unique_synthetic_item", False, f"matched={len(matched)}")
        receipt["classification"] = "NON_EMPTY_DUPLICATE_SYNTHETIC_ITEMS"
        emit(receipt, os.path.join(args.batch_dir, "capture.json"))
        print(f"capture: NON_EMPTY_DUPLICATE_SYNTHETIC_ITEMS (matched={len(matched)})")
        return 21

    add("fidelity", "synthetic_item_visible", True)
    add("fidelity", "unique_synthetic_item", True)
    item = matched[0]
    _fidelity_assertions(item, args, add)
    # INFO entries are observations, not verdicts: only a FAIL blocks fidelity.
    receipt["verdict"]["fidelity_asserted"] = all(
        entry["result"] != "FAIL" for entry in receipt["assertions"]["fidelity"]
    )
    receipt["classification"] = (
        "NON_EMPTY_FIDELITY_PASS"
        if receipt["verdict"]["fidelity_asserted"]
        else "NON_EMPTY_FIDELITY_MISMATCH"
    )
    emit(receipt, os.path.join(args.batch_dir, "capture.json"))
    print(
        f"capture: {receipt['classification']} (items={len(body)}, matched=1, "
        f"fidelity={'PASS' if receipt['verdict']['fidelity_asserted'] else 'FAIL'})"
    )
    return 0 if receipt["verdict"]["fidelity_asserted"] else 20


def _probe(item: dict[str, Any]) -> dict[str, Any]:
    due = item.get("dueDate")
    contract, due_iso = _decode_due(due)
    tz_raw = item.get("timeZone")
    return {
        "item_id_masked": mask_uuid(str(item.get("itemID", ""))),
        "item_id_present": bool(str(item.get("itemID", "")).strip()),
        "title_length": len(item.get("title") or ""),
        "title_digest": digest(item.get("title")),
        "notes_present": item.get("notes") is not None,
        "notes_length": len(item.get("notes") or "") if item.get("notes") else 0,
        "notes_digest": digest(item.get("notes")),
        "priority": item.get("priority"),
        "is_completed": item.get("isCompleted"),
        "due_raw_type": type(due).__name__ if due is not None else None,
        "date_contract_detected": contract,
        "due_date_iso": due_iso,
        "is_all_day": item.get("isAllDay"),
        "time_zone": (tz_raw if isinstance(tz_raw, str) and TZ_RE.match(tz_raw) else tz_raw),
        "completion_date_iso": _as_iso(item.get("completionDate")),
        "last_modified_iso": _as_iso(item.get("lastModifiedDate")),
    }


def _decode_due(value: Any) -> tuple[str | None, str | None]:
    """Return (contract, iso). Contract is detected, not assumed."""
    if value is None:
        return None, None
    if isinstance(value, bool):
        return "invalid_bool", None
    if isinstance(value, (int, float)):
        # Swift JSONEncoder default (.deferredToDate) emits seconds since 2001-01-01.
        return "cocoa_reference_seconds", utc_iso_from_epoch(float(value) + COCOA_EPOCH_OFFSET)
    if isinstance(value, str):
        try:
            parsed = time.strptime(value[:19], "%Y-%m-%dT%H:%M:%S")
            import calendar

            return "iso8601_string", utc_iso_from_epoch(calendar.timegm(parsed))
        except ValueError:
            return "unparseable_string", None
    return f"unexpected_{type(value).__name__}", None


def _as_iso(value: Any) -> str | None:
    contract, iso = _decode_due(value)
    return iso if contract else None


def _fidelity_assertions(item: dict[str, Any], args: argparse.Namespace, add) -> None:
    add("fidelity", "title_exact_match", item.get("title") == args.expect_title)
    add("fidelity", "notes_exact_match", item.get("notes") == args.expect_notes,
        "" if item.get("notes") == args.expect_notes else "notes differ or absent")
    add("fidelity", "priority_5", item.get("priority") == 5, f"observed={item.get('priority')}")
    add("fidelity", "is_completed_false", item.get("isCompleted") is False,
        f"observed={item.get('isCompleted')}")
    add("fidelity", "is_all_day_false", item.get("isAllDay") is False,
        f"observed={item.get('isAllDay')}")
    add("fidelity", "item_id_non_empty", bool(str(item.get("itemID", "")).strip()))
    add("fidelity", "list_attribution_match", item.get("listID") == args.list_id)

    contract, due_iso = _decode_due(item.get("dueDate"))
    add("fidelity", "due_date_present", item.get("dueDate") is not None)
    add("fidelity", "due_date_contract_known",
        contract == "cocoa_reference_seconds", f"contract={contract}")
    if args.expect_due_utc:
        add("fidelity", "due_instant_exact", due_iso == args.expect_due_utc,
            f"observed={due_iso} expected={args.expect_due_utc}")
    if item.get("timeZone") is None:
        # Recorded as an observation of this item only. No general claim is made.
        add("fidelity", "time_zone_absent", None,
            "this item returned no timeZone; recorded as observed, no general inference drawn")


# --------------------------------------------------------------------------- #
# main
# --------------------------------------------------------------------------- #
def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)

    def common(p: argparse.ArgumentParser) -> None:
        p.add_argument("--endpoint", default="http://127.0.0.1:18765")
        p.add_argument("--timeout", type=float, default=15.0)

    p_health = sub.add_parser("health", help="assert a production store answers")
    common(p_health)
    p_health.add_argument("--out", required=True)
    p_health.set_defaults(func=cmd_health)

    p_gate = sub.add_parser("gate", help="assert the business endpoint status")
    common(p_gate)
    p_gate.add_argument("--out", required=True)
    p_gate.add_argument("--token-file", required=True)
    p_gate.add_argument("--expect", type=int, required=True, choices=[200, 403])
    p_gate.set_defaults(func=cmd_gate)

    p_cap = sub.add_parser("capture", help="capture one bound list")
    common(p_cap)
    p_cap.add_argument("--token-file", required=True)
    p_cap.add_argument("--list-id", required=True)
    p_cap.add_argument("--expect-title", required=True)
    p_cap.add_argument("--expect-notes", required=True)
    p_cap.add_argument("--expect-due-utc", default="")
    p_cap.add_argument("--expect", required=True, choices=["presence", "absence"])
    p_cap.add_argument("--batch-dir", required=True)
    p_cap.add_argument("--label", default="unspecified")
    p_cap.set_defaults(func=cmd_capture)
    return parser


def main() -> int:
    args = build_parser().parse_args()
    if not LOOPBACK_RE.match(args.endpoint.rstrip("/") + "/"):
        print("REFUSED: endpoint must be loopback (127.0.0.1/localhost/[::1])", file=sys.stderr)
        return 2
    if args.command in ("gate", "capture"):
        if not os.path.isfile(args.token_file):
            print("REFUSED: token file not found", file=sys.stderr)
            return 2
        try:
            os.stat(args.token_file)
            read_token(args.token_file)
        except ValueError as exc:
            print(f"REFUSED: {exc}", file=sys.stderr)
            return 2
    try:
        return args.func(args)
    except FileExistsError as exc:
        print(f"REFUSED: batch directory already contains evidence: {exc}", file=sys.stderr)
        return 5
    except Exception as exc:  # noqa: BLE001 - never leak a traceback carrying secrets
        print(f"FAILED: {type(exc).__name__}", file=sys.stderr)
        return 3


if __name__ == "__main__":
    sys.exit(main())
