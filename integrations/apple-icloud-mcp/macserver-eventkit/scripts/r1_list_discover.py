#!/usr/bin/env python3
"""r1_list_discover.py — R1-04 W0: resolve the new dedicated list's identity.

One account-wide GET /reminders/lists inside the discovery window, matched by
exact title. This is the only sanctioned use of the enumeration endpoint in
R1-04 besides the legacy gate verification reads; every run is recorded and the
match rules are fixed, not improvised:

  * exact title match (case-sensitive, no substring, no normalisation);
  * sourceType must be "calDAV";
  * sourceName must be "iCloud" (the account identity as the store reports it);
  * when --expect-source-id is given (taken from the existing binding), the
    candidate's sourceID must equal it - a new list created in the same
    account shares the account's sourceID, so a difference means the candidate
    is not in the account the binding points at.

Anything that is not exactly one fully-matching candidate is an UNKNOWN or a
mismatch. The UNKNOWN rule from the application applies: one read-only check,
no retry, no second enumeration in the same window.

Outputs
-------
  --private-out  the ONLY place the full listID/sourceID are written; refused
                 if the path already exists; written 0600. Must live inside a
                 restricted evidence directory.
  --out          public receipt: masked identifiers, the search title, the
                 source type/name, the candidate count and the decision. No
                 full identifier ever appears here.

Exit codes
----------
  0   exactly one candidate matched every rule
  2   usage / precondition (token file, endpoint, private path)
  3   transport or HTTP failure (result unknown)
  40  zero candidates with that title (UNKNOWN - read-only, no retry)
  41  more than one candidate with that title (ambiguous - no rebind)
  42  single candidate but sourceType is not calDAV
  43  account mismatch: sourceName is not iCloud, or sourceID differs from
      --expect-source-id
"""

from __future__ import annotations

import argparse
import json
import os
import sys

SCRIPT_VERSION = "1.0.0"

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import r1_bridge_client as client  # noqa: E402  (reuses the tested HTTP/token/masking layer)


def _write_private(path: str, payload: dict) -> None:
    """0600, refuse to overwrite: the first discovery record is the record."""
    if os.path.exists(path):
        raise FileExistsError(path)
    parent = os.path.dirname(os.path.abspath(path)) or "."
    client.ensure_dir_writable(parent, "private evidence directory")
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            json.dump(payload, fh, indent=2, ensure_ascii=False)
            fh.write("\n")
    finally:
        if os.path.exists(path):
            os.chmod(path, 0o600)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--endpoint", default="http://127.0.0.1:18765")
    parser.add_argument("--timeout", type=float, default=15.0)
    parser.add_argument("--token-file", required=True)
    parser.add_argument("--title", required=True,
                        help="exact title of the dedicated list to discover")
    parser.add_argument("--expect-source-id", default="",
                        help="sourceID from the existing binding; a candidate "
                             "whose sourceID differs is an account mismatch")
    parser.add_argument("--private-out", required=True,
                        help="0600 file inside the restricted evidence dir that "
                             "will hold the full listID and sourceID")
    parser.add_argument("--out", required=True, help="public (masked) receipt")
    args = parser.parse_args()

    if not client.LOOPBACK_RE.match(args.endpoint.rstrip("/") + "/"):
        print("REFUSED: endpoint must be loopback (127.0.0.1/localhost/[::1])",
              file=sys.stderr)
        return 2
    if not os.path.isfile(args.token_file):
        print("REFUSED: token file not found", file=sys.stderr)
        return 2
    try:
        client.read_token(args.token_file)
    except client.TokenFileError as exc:
        print(f"REFUSED: {exc}", file=sys.stderr)
        return 2

    receipt: dict = {
        "receipt_type": "R1_04_LIST_DISCOVERY",
        "task": "REM-R1-01",
        "step": "R1-04/W0",
        "client_version": SCRIPT_VERSION,
        "observed_at_utc": client.utc_stamp(),
        "endpoint": args.endpoint,
        "search_title": args.title,
        "expected_source_id_masked": client.mask_uuid(args.expect_source_id) or None,
        "http_status": None,
        "visible_list_count": None,
        "title_matched_count": None,
        "candidate": None,
        "decision": None,
        "boundary": {
            "http_methods": ["GET"],
            "enumeration_reads": 1,
            "other_lists_titles_persisted": False,
            "writes_attempted": 0,
            "token_persisted": False,
        },
        "unknown_policy": "one read-only check; UNKNOWN is never retried in the same window",
    }

    try:
        status, body, raw = client.http_get(
            f"{args.endpoint}/reminders/lists", client.read_token(args.token_file), args.timeout
        )
    except Exception as exc:  # noqa: BLE001 - never leak a traceback carrying secrets
        print(f"FAILED: {type(exc).__name__}", file=sys.stderr)
        return 3

    lists = body if isinstance(body, list) else []
    receipt["http_status"] = status
    receipt["visible_list_count"] = len(lists)
    receipt["body_digest"] = client.digest(raw)

    if status != 200 or not isinstance(body, list):
        code = body.get("code") if isinstance(body, dict) else None
        receipt["decision"] = "DISCOVER_HTTP_ERROR"
        receipt["error_code"] = code
        client.emit(receipt, args.out)
        print(f"discover: DISCOVER_HTTP_ERROR (http={status}, code={code})")
        return 3

    matched = [e for e in lists if isinstance(e, dict) and e.get("title") == args.title]
    receipt["title_matched_count"] = len(matched)

    if not matched:
        receipt["decision"] = "UNKNOWN_ZERO_CANDIDATES"
        client.emit(receipt, args.out)
        print("discover: UNKNOWN_ZERO_CANDIDATES "
              f"(visible={len(lists)}, title_matched=0)")
        return 40

    if len(matched) > 1:
        receipt["decision"] = "AMBIGUOUS_MULTIPLE_CANDIDATES"
        client.emit(receipt, args.out)
        print(f"discover: AMBIGUOUS_MULTIPLE_CANDIDATES (title_matched={len(matched)})")
        return 41

    cand = matched[0]
    masked = {
        "list_id_masked": client.mask_uuid(str(cand.get("listID") or "")),
        "source_id_masked": client.mask_uuid(str(cand.get("sourceID") or "")),
        "title": cand.get("title"),
        "source_type": cand.get("sourceType"),
        "source_name": cand.get("sourceName"),
    }
    receipt["candidate"] = masked

    if cand.get("sourceType") != "calDAV":
        receipt["decision"] = "SOURCE_TYPE_MISMATCH"
        client.emit(receipt, args.out)
        print(f"discover: SOURCE_TYPE_MISMATCH (observed={cand.get('sourceType')!r})")
        return 42

    if cand.get("sourceName") != "iCloud":
        receipt["decision"] = "ACCOUNT_MISMATCH"
        receipt["mismatch_reason"] = f"sourceName={cand.get('sourceName')!r}, expected 'iCloud'"
        client.emit(receipt, args.out)
        print("discover: ACCOUNT_MISMATCH "
              f"(sourceName={cand.get('sourceName')!r})")
        return 43

    if args.expect_source_id and str(cand.get("sourceID") or "") != args.expect_source_id:
        receipt["decision"] = "ACCOUNT_MISMATCH"
        receipt["mismatch_reason"] = (
            "candidate sourceID differs from the existing binding's sourceID; "
            "the candidate is not in the account the binding points at"
        )
        client.emit(receipt, args.out)
        print("discover: ACCOUNT_MISMATCH (sourceID differs from the binding)")
        return 43

    try:
        _write_private(args.private_out, {
            "record_type": "R1_04_DISCOVERED_BINDING",
            "observed_at_utc": client.utc_stamp(),
            "endpoint": args.endpoint,
            "listID": cand.get("listID"),
            "sourceID": cand.get("sourceID"),
            "title": cand.get("title"),
            "sourceType": cand.get("sourceType"),
            "sourceName": cand.get("sourceName"),
            "match_basis": {
                "title_exact": True,
                "source_type_calDAV": True,
                "source_name_iCloud": True,
                "source_id_equals_binding": bool(args.expect_source_id),
            },
            "note": "restricted record; the public receipt carries masked identifiers only",
        })
    except FileExistsError:
        print("REFUSED: private discovery record already exists "
              f"({args.private_out}); the first record is the record", file=sys.stderr)
        return 2

    receipt["decision"] = "DISCOVERED"
    receipt["private_record_written"] = True
    client.emit(receipt, args.out)
    print(f"discover: DISCOVERED (list_id={masked['list_id_masked']}, "
          f"source_type={cand.get('sourceType')}, source_name={cand.get('sourceName')})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
