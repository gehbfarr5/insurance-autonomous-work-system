#!/usr/bin/env python3
"""r1_title_digest_diag.py — R1-04 W0-DIAG: title digest diagnostic.

Purpose
-------
After repeated UNKNOWN_ZERO_CANDIDATES discovery windows, the user approved a
one-shot diagnostic (hash deviation from the frozen tool set explicitly
authorized) to distinguish two hypotheses WITHOUT exposing any list title:

  A. the target list's actual title differs from the expected string by an
     invisible character (trailing space, different Unicode normalization,
     full-width character) so exact matching can never succeed;
  B. the target list is genuinely absent from the bridge's enumeration.

Method: ONE account-wide GET /reminders/lists (inside an open window, same
discipline as every other read). For every visible list the script computes
SHA-256 digests of the title under a fixed set of variants (exact, NFC, NFD,
stripped, stripped+NFC/NFD, whitespace-removed) and intersects them with the
same variant digests of the expected title. NO title of any list is written
anywhere - not even into the 0600 private record, which holds digests and
identifiers only.

Outputs
-------
  --private-out  0600, refuse-to-overwrite: per-list full listID/sourceID +
                 title SHA-256 digests and lengths. No titles.
  --out          public receipt: per-list digest16 prefixes, lengths, masked
                 identifiers, and the match verdict. No titles of other lists.

Exit codes
----------
  0   digest match found (decision says whether it was exact or a variant)
  2   usage / precondition failure
  3   transport or HTTP failure (result unknown)
  40  no digest match under any variant (title truly absent from enumeration)
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import sys
import unicodedata

SCRIPT_VERSION = "1.0.0"

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import r1_bridge_client as client  # noqa: E402  (reuses the tested HTTP/token/masking layer)


def _digest_variants(title: str) -> dict:
    """Fixed, documented variant set; keys are names, values are sha256 hex."""
    candidates = {
        "exact": title,
        "nfc": unicodedata.normalize("NFC", title),
        "nfd": unicodedata.normalize("NFD", title),
        "stripped": title.strip(),
        "stripped_nfc": unicodedata.normalize("NFC", title.strip()),
        "stripped_nfd": unicodedata.normalize("NFD", title.strip()),
        "no_ws": "".join(title.split()),
    }
    out = {}
    for name, value in candidates.items():
        out[name] = hashlib.sha256(value.encode("utf-8")).hexdigest()
    return out


def _write_private(path: str, payload: dict) -> None:
    """0600, refuse to overwrite: the first diagnostic record is the record."""
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
                        help="expected title of the dedicated list")
    parser.add_argument("--expect-source-id", default="",
                        help="sourceID from the existing binding, recorded for "
                             "the account-identity comparison of any match")
    parser.add_argument("--private-out", required=True,
                        help="0600 file inside the restricted evidence dir; "
                             "holds digests and full identifiers, no titles")
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

    target_variants = _digest_variants(args.title)
    # digest -> list of variant names (lossless: identical digests keep ALL
    # their names, so an exact-equality check stays explicit below)
    target_by_digest: dict = {}
    for _name, _digest in target_variants.items():
        target_by_digest.setdefault(_digest, []).append(_name)

    receipt: dict = {
        "receipt_type": "R1_04_TITLE_DIGEST_DIAG",
        "task": "REM-R1-01",
        "step": "R1-04/W0-DIAG",
        "client_version": SCRIPT_VERSION,
        "observed_at_utc": client.utc_stamp(),
        "endpoint": args.endpoint,
        "search_title": args.title,
        "target_digest16_exact": target_variants["exact"][:16],
        "expected_source_id_masked": client.mask_uuid(args.expect_source_id) or None,
        "http_status": None,
        "visible_list_count": None,
        "lists": [],
        "matches": [],
        "decision": None,
        "boundary": {
            "http_methods": ["GET"],
            "enumeration_reads": 1,
            "titles_persisted_anywhere": False,
            "writes_attempted": 0,
            "token_persisted": False,
        },
        "authorization_note": "user-approved diagnostic outside the frozen "
                              "hash set (UNKNOWN disposition, 2026-11-11)",
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
        receipt["decision"] = "DIAG_HTTP_ERROR"
        receipt["error_code"] = code
        client.emit(receipt, args.out)
        print(f"diag: DIAG_HTTP_ERROR (http={status}, code={code})")
        return 3

    private_lists = []
    matches = []
    for entry in lists:
        if not isinstance(entry, dict):
            continue
        title = entry.get("title")
        if not isinstance(title, str):
            title = ""
        list_variants = _digest_variants(title)
        item = {
            "title_digest16": list_variants["exact"][:16],
            "title_len": len(title),
            "list_id_masked": client.mask_uuid(str(entry.get("listID") or "")),
            "source_id_masked": client.mask_uuid(str(entry.get("sourceID") or "")),
            "source_type": entry.get("sourceType"),
            "source_name": entry.get("sourceName"),
        }
        receipt["lists"].append(item)
        private_lists.append({
            "listID": entry.get("listID"),
            "sourceID": entry.get("sourceID"),
            "sourceType": entry.get("sourceType"),
            "sourceName": entry.get("sourceName"),
            "title_len": len(title),
            "title_sha256": list_variants,
        })
        exact_hit = list_variants["exact"] == target_variants["exact"]
        if exact_hit:
            matches.append({
                "title_digest16": list_variants["exact"][:16],
                "via": "exact",
                "list_id_masked": item["list_id_masked"],
                "source_id_masked": item["source_id_masked"],
                "source_type": entry.get("sourceType"),
                "source_name": entry.get("sourceName"),
            })
        for lv_name, lv_digest in list_variants.items():
            if lv_name == "exact" and exact_hit:
                continue
            tv_names = target_by_digest.get(lv_digest)
            if not tv_names:
                continue
            matches.append({
                "title_digest16": lv_digest[:16],
                "via": "variant",
                "via_list_variant": lv_name,
                "via_target_variants": tv_names,
                "list_id_masked": item["list_id_masked"],
                "source_id_masked": item["source_id_masked"],
                "source_type": entry.get("sourceType"),
                "source_name": entry.get("sourceName"),
            })

    receipt["matches"] = matches

    if matches:
        try:
            _write_private(args.private_out, {
                "record_type": "R1_04_TITLE_DIGEST_DIAG_PRIVATE",
                "observed_at_utc": client.utc_stamp(),
                "endpoint": args.endpoint,
                "target_title_sha256": target_variants,
                "target_title_len": len(args.title),
                "lists": private_lists,
                "matches": matches,
                "note": "restricted record; digests and identifiers only, "
                        "no list titles are persisted anywhere",
            })
        except FileExistsError:
            print("REFUSED: private diagnostic record already exists "
                  f"({args.private_out}); the first record is the record",
                  file=sys.stderr)
            return 2
        receipt["private_record_written"] = True
        exact = any(m.get("via") == "exact" for m in matches)
        receipt["decision"] = "DIGEST_MATCH_EXACT" if exact else "DIGEST_MATCH_VARIANT"
        client.emit(receipt, args.out)
        print(f"diag: {receipt['decision']} (matches={len(matches)}, "
              f"visible={len(lists)})")
        return 0

    # No match: the private record still has forensic value (identifiers +
    # digests prove which lists the bridge sees); write it even on NO_MATCH.
    try:
        _write_private(args.private_out, {
            "record_type": "R1_04_TITLE_DIGEST_DIAG_PRIVATE",
            "observed_at_utc": client.utc_stamp(),
            "endpoint": args.endpoint,
            "target_title_sha256": target_variants,
            "target_title_len": len(args.title),
            "lists": private_lists,
            "matches": [],
            "note": "restricted record; digests and identifiers only, "
                    "no list titles are persisted anywhere",
        })
    except FileExistsError:
        print("REFUSED: private diagnostic record already exists "
              f"({args.private_out}); the first record is the record",
              file=sys.stderr)
        return 2
    receipt["private_record_written"] = True
    receipt["decision"] = "NO_DIGEST_MATCH"
    client.emit(receipt, args.out)
    print(f"diag: NO_DIGEST_MATCH (visible={len(lists)}, "
          f"target_digest16={target_variants['exact'][:16]})")
    return 40


if __name__ == "__main__":
    sys.exit(main())
