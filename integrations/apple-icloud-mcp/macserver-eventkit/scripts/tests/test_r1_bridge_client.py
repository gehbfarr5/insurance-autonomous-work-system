#!/usr/bin/env python3
"""test_r1_bridge_client.py — offline verification for r1_bridge_client.py.

Covers the failure modes the R1 application must survive:
  empty list / present item / duplicate / wrong date / wrong priority /
  completed item / missing itemId / fake store / account-wide enumeration with
  the target present and with it absent / cleanup not effective / evidence
  directory already populated / token file with loose permissions / masking.

No EventKit, no TCC, no Apple account, no network beyond loopback.
"""

from __future__ import annotations

import json
import os
import shutil
import stat
import subprocess
import sys
import tempfile
import time
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPTS = os.path.dirname(HERE)
CLIENT = os.path.join(SCRIPTS, "r1_bridge_client.py")
FAKE = os.path.join(HERE, "fake_bridge.py")

TOKEN = "offline-test-token-0123456789abcdef"
LIST_ID = "9D9A5AAD-E3F0-4459-8756-BBCDBCB703F3"
LIST_TITLE = "SYNTHETIC-LIST"
TITLE = "[MUSE-R1-SYN-20261110-01] 只读读取保真核验"
NOTES = "R1-01 合成事项，仅用于只读字段保真核验，验收后精准清理。MARKER=R1SYN20261110A"
DUE_ISO = "2026-11-17T02:30:00Z"
DUE_UNIX = 1794882600                # 2026-11-17T02:30:00Z
DUE_COCOA = DUE_UNIX - 978307200     # = 816575400 (Cocoa reference seconds)

results: list[tuple[str, bool, str]] = []


def check(name: str, ok: bool, detail: str = "") -> None:
    results.append((name, bool(ok), detail))
    print(f"  [{'PASS' if ok else 'FAIL'}] {name}{f' ({detail})' if detail and not ok else ''}")


def item(**overrides):
    base = {
        "itemID": "11111111-2222-4333-8444-555555555555",
        "title": TITLE,
        "isCompleted": False,
        "priority": 5,
        "listID": LIST_ID,
        "notes": NOTES,
        "dueDate": DUE_COCOA,
        "isAllDay": False,
    }
    base.update(overrides)
    return {k: v for k, v in base.items() if v is not None}


def write_control(field_dir: str, name: str, value) -> None:
    with open(os.path.join(field_dir, name), "w", encoding="utf-8") as handle:
        handle.write(value if isinstance(value, str) else json.dumps(value, ensure_ascii=False))


def run_client(*args: str, out_hint: str = "", env_extra: dict | None = None) -> tuple[int, dict | None, str]:
    args = list(args)
    if args and args[0] in ("health", "gate") and "--out" not in args:
        args += ["--out", out_hint or os.path.join(tempfile.mkdtemp(prefix="r1-out-"), "r.json")]
    env = dict(os.environ)
    env.update(env_extra or {})
    proc = subprocess.run([sys.executable, CLIENT, *args], capture_output=True, text=True, env=env)
    receipt_path = None
    if args and args[0] == "capture":
        # capture always writes inside its own batch directory
        receipt_path = os.path.join(args[args.index("--batch-dir") + 1], "capture.json")
    for index, value in enumerate(args):
        if value == "--out":
            receipt_path = args[index + 1]
    data = None
    if receipt_path and os.path.exists(receipt_path):
        try:
            with open(receipt_path, encoding="utf-8") as handle:
                data = json.load(handle)
        except json.JSONDecodeError:
            data = None
    return proc.returncode, data, proc.stdout + proc.stderr


class Bridge:
    def __init__(self, field_dir: str):
        self.proc = subprocess.Popen(
            [sys.executable, FAKE, "--field-dir", field_dir, "--token", TOKEN],
            stdout=subprocess.PIPE, text=True,
        )
        self.url = self.proc.stdout.readline().strip()

    def stop(self) -> None:
        self.proc.terminate()
        try:
            self.proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.proc.kill()


def main() -> int:
    work = tempfile.mkdtemp(prefix="r1-client-test-")
    fields = os.path.join(work, "fields")
    os.makedirs(fields)
    token_file = os.path.join(work, "token")
    with open(token_file, "w", encoding="utf-8") as handle:
        handle.write(TOKEN)
    os.chmod(token_file, 0o600)

    write_control(fields, "gate", "true")
    write_control(fields, "store", "production")
    write_control(fields, "lists", [{
        "listID": LIST_ID, "title": LIST_TITLE,
        "sourceID": "7B0B0000-0000-4000-8000-000000000001",
        "sourceType": "calDAV", "sourceName": "iCloud",
        "color": "#007AFF", "isImmutable": True,
    }])

    bridge = Bridge(fields)
    base = ["--endpoint", bridge.url]
    capture_common = base + [
        "--token-file", token_file, "--list-id", LIST_ID,
        "--expect-title", TITLE, "--expect-notes", NOTES,
        "--expect-due-utc", DUE_ISO,
    ]

    try:
        # ---- 1. health: real production store
        print("\n[1] health with production store")
        rc, data, out = run_client("health", *base)
        check("health exit 0", rc == 0, f"rc={rc} {out}")
        check("classification HEALTH_PRODUCTION_STORE_OK",
              data and data.get("classification") == "HEALTH_PRODUCTION_STORE_OK", str(data and data.get("classification")))

        # ---- 2. health: fake store must be rejected
        print("\n[2] health with fake store (must not be usable as evidence)")
        write_control(fields, "store", "fake")
        rc, data, out = run_client("health", *base)
        check("health exit 20 for fake store", rc == 20, f"rc={rc}")
        check("production_store_confirmed FAIL",
              any(a["name"] == "production_store_confirmed" and a["result"] == "FAIL"
                  for a in (data or {}).get("assertions", [])))
        write_control(fields, "store", "production")

        # ---- 3. gate closed
        print("\n[3] gate assertions")
        write_control(fields, "gate", "false")
        rc, data, out = run_client("gate", *base, "--token-file", token_file,
                                   "--expect", "403")
        check("gate expects 403 -> exit 0", rc == 0, f"rc={rc}")
        rc, _, _ = run_client("gate", *base, "--token-file", token_file,
                              "--expect", "200")
        check("gate expects 200 while closed -> exit 22", rc == 22, f"rc={rc}")
        write_control(fields, "gate", "true")

        # ---- 4. capture: full fidelity pass
        print("\n[4] capture: item present with all fields correct")
        write_control(fields, "items", {LIST_ID: [item()]})
        bdir = os.path.join(work, "batch-1")
        rc, data, out = run_client("capture", *capture_common, "--expect", "presence",
                                   "--batch-dir", bdir)
        check("capture exits 0", rc == 0, f"rc={rc} {out}")
        check("classification NON_EMPTY_FIDELITY_PASS",
              data and data.get("classification") == "NON_EMPTY_FIDELITY_PASS", str(data and data.get("classification")))
        probe = (data or {}).get("items", {}).get("field_probe", [{}])[0]
        check("date contract detected as cocoa_reference_seconds",
              probe.get("date_contract_detected") == "cocoa_reference_seconds", str(probe.get("date_contract_detected")))
        check("due instant decoded exactly", probe.get("due_date_iso") == DUE_ISO, str(probe.get("due_date_iso")))
        fidelity = {a["name"]: a["result"] for a in (data or {}).get("assertions", {}).get("fidelity", [])}
        for name in ("title_exact_match", "notes_exact_match", "priority_5", "is_completed_false",
                     "is_all_day_false", "item_id_non_empty", "list_attribution_match",
                     "due_date_present", "due_date_contract_known", "due_instant_exact",
                     "unique_synthetic_item"):
            check(f"fidelity {name} PASS", fidelity.get(name) == "PASS", str(fidelity.get(name)))
        check("timeZone absence recorded as INFO, not PASS/FAIL",
              fidelity.get("time_zone_absent") == "INFO", str(fidelity.get("time_zone_absent")))
        check("no raw title in receipt",
              TITLE not in json.dumps(data, ensure_ascii=False))
        check("no unmasked uuid in receipt",
              all(len(part) != 36 for part in json.dumps(data, ensure_ascii=False).split('"')))

        # ---- 5. wrong due date
        print("\n[5] capture: wrong due instant")
        write_control(fields, "items", {LIST_ID: [item(dueDate=DUE_COCOA - 3600)]})
        rc, data, _ = run_client("capture", *capture_common, "--expect", "presence",
                                 "--batch-dir", os.path.join(work, "batch-2"))
        check("wrong date -> exit 20", rc == 20, f"rc={rc}")
        check("classification NON_EMPTY_FIDELITY_MISMATCH",
              data and data.get("classification") == "NON_EMPTY_FIDELITY_MISMATCH")

        # ---- 6. wrong priority / completed / missing itemId
        print("\n[6] capture: priority, completion, itemId defects")
        for label, patch in (
            ("priority 0 instead of 5", {"priority": 0}),
            ("isCompleted true", {"isCompleted": True}),
            ("empty itemId", {"itemID": " "}),
            ("isAllDay true", {"isAllDay": True}),
        ):
            write_control(fields, "items", {LIST_ID: [item(**patch)]})
            rc, data, _ = run_client("capture", *capture_common, "--expect", "presence",
                                     "--batch-dir", os.path.join(work, f"batch-6-{abs(hash(label))}"))
            check(f"{label} -> exit 20", rc == 20, f"rc={rc}")

        # ---- 7. duplicate synthetic items
        print("\n[7] capture: duplicate synthetic items")
        write_control(fields, "items", {LIST_ID: [item(), item(itemID="22222222-3333-4444-8555-666666666666")]})
        rc, data, _ = run_client("capture", *capture_common, "--expect", "presence",
                                 "--batch-dir", os.path.join(work, "batch-7"))
        check("duplicates -> exit 21", rc == 21, f"rc={rc}")
        check("classification NON_EMPTY_DUPLICATE_SYNTHETIC_ITEMS",
              data and data.get("classification") == "NON_EMPTY_DUPLICATE_SYNTHETIC_ITEMS")

        # ---- 8. present expectation, empty list
        print("\n[8] capture: expectation present but list empty")
        write_control(fields, "items", {LIST_ID: []})
        rc, data, _ = run_client("capture", *capture_common, "--expect", "presence",
                                 "--batch-dir", os.path.join(work, "batch-8"))
        check("empty -> exit 23", rc == 23, f"rc={rc}")
        check("classification EMPTY_ARRAY_CONFIRMED_BY_BRIDGE",
              data and data.get("classification") == "EMPTY_ARRAY_CONFIRMED_BY_BRIDGE")

        # ---- 9. cleanup expectation
        print("\n[9] capture: cleanup assertions are separate from fidelity")
        rc, data, _ = run_client("capture", *capture_common, "--expect", "absence",
                                 "--batch-dir", os.path.join(work, "batch-9a"))
        check("absence on empty list -> exit 0", rc == 0, f"rc={rc}")
        check("cleanup_asserted true", data and data.get("verdict", {}).get("cleanup_asserted") is True)
        check("fidelity_asserted false in cleanup run",
              data and data.get("verdict", {}).get("fidelity_asserted") is False)

        write_control(fields, "items", {LIST_ID: [item()]})
        rc, data, _ = run_client("capture", *capture_common, "--expect", "absence",
                                 "--batch-dir", os.path.join(work, "batch-9b"))
        check("absence but item still present -> exit 22", rc == 22, f"rc={rc}")
        check("classification CLEANUP_NOT_EFFECTIVE",
              data and data.get("classification") == "CLEANUP_NOT_EFFECTIVE")

        # ---- 10. evidence directory protection
        print("\n[10] evidence directory must not be overwritten")
        protected = os.path.join(work, "batch-protected")
        os.makedirs(protected)
        with open(os.path.join(protected, "capture.json"), "w", encoding="utf-8") as handle:
            handle.write('{"first_non_empty_evidence": true}\n')
        rc, _, out = run_client("capture", *capture_common, "--expect", "presence",
                                "--batch-dir", protected)
        check("refuses populated batch dir -> exit 5", rc == 5, f"rc={rc} {out}")
        with open(os.path.join(protected, "capture.json"), encoding="utf-8") as handle:
            check("original evidence untouched", "first_non_empty_evidence" in handle.read())

        # ---- 11. account-wide enumeration
        print("\n[11] capture: enumeration is account-wide, not allowlist-filtered")
        # GET /reminders/lists returns every reminder calendar in the account
        # (EventKitBridgeServer .listReminders -> fetchListsMetadata, no
        # allowlistValidator call); only the item endpoint is allowlisted.
        # v2.1.0 required exactly one visible list, which made the precondition
        # unsatisfiable on any real account and could never produce a capture.
        write_control(fields, "lists", [
            {"listID": LIST_ID, "title": LIST_TITLE, "sourceID": "7B0B0000-0000-4000-8000-000000000001",
             "sourceType": "calDAV", "sourceName": "iCloud", "color": "", "isImmutable": True},
            {"listID": "AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE", "title": "OTHER",
             "sourceID": "7B0B0000-0000-4000-8000-000000000001", "sourceType": "calDAV",
             "sourceName": "iCloud", "color": "", "isImmutable": True},
        ])
        write_control(fields, "items", {LIST_ID: [item()]})
        rc, data, out = run_client("capture", *capture_common, "--expect", "presence",
                                   "--batch-dir", os.path.join(work, "batch-11a"))
        check("target present among two lists -> exit 0", rc == 0, f"rc={rc} {out}")
        pre = {a["name"]: a["result"] for a in (data or {}).get("assertions", {}).get("preconditions", [])}
        check("target_list_visible PASS", pre.get("target_list_visible") == "PASS", str(pre))
        check("no single_visible_list precondition remains",
              "single_visible_list" not in pre, str(sorted(pre)))
        check("visible_list_count recorded as 2",
              (data or {}).get("list_metadata", {}).get("visible_list_count") == 2,
              str((data or {}).get("list_metadata", {}).get("visible_list_count")))
        check("enumeration_scope recorded as account_wide",
              (data or {}).get("boundary", {}).get("enumeration_scope") == "account_wide")
        blob = json.dumps(data, ensure_ascii=False)
        check("other list title never persisted", "OTHER" not in blob)
        check("other list identifier never persisted", "AAAAAAAA-BBBB" not in blob)
        check("non_target_metadata_persisted false",
              (data or {}).get("boundary", {}).get("non_target_metadata_persisted") is False)

        # The signal that matters is the target's absence, not the account size.
        write_control(fields, "lists", [
            {"listID": "AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE", "title": "OTHER",
             "sourceID": "7B0B0000-0000-4000-8000-000000000001", "sourceType": "calDAV",
             "sourceName": "iCloud", "color": "", "isImmutable": True},
            {"listID": "BBBBBBBB-CCCC-4DDD-8EEE-FFFFFFFFFFFF", "title": "OTHER2",
             "sourceID": "7B0B0000-0000-4000-8000-000000000001", "sourceType": "calDAV",
             "sourceName": "iCloud", "color": "", "isImmutable": True},
        ])
        rc, data, out = run_client("capture", *capture_common, "--expect", "presence",
                                   "--batch-dir", os.path.join(work, "batch-11b"))
        check("target absent among two lists -> exit 20", rc == 20, f"rc={rc}")
        check("classification ERROR_TARGET_LIST_IDENTITY",
              data and data.get("classification") == "ERROR_TARGET_LIST_IDENTITY")
        pre = {a["name"]: a["result"] for a in (data or {}).get("assertions", {}).get("preconditions", [])}
        check("target_list_visible FAIL is the reason", pre.get("target_list_visible") == "FAIL", str(pre))
        check("no item query issued when the target is absent",
              (data or {}).get("items") == {}, str((data or {}).get("items")))

        # ---- 12. token file permissions
        print("\n[12] token file must be 0600")
        loose = os.path.join(work, "token-loose")
        shutil.copyfile(token_file, loose)
        os.chmod(loose, 0o644)
        rc, _, out = run_client("gate", *base, "--token-file", loose, "--expect", "403")
        check("loose permissions refused -> exit 2", rc == 2, f"rc={rc} {out}")

        # ---- 13. token must never appear in any receipt
        print("\n[13] token hygiene across every batch written so far")
        scanned = 0
        for root, _dirs, files in os.walk(work):
            for name in files:
                if not name.endswith(".json"):
                    continue
                with open(os.path.join(root, name), encoding="utf-8", errors="replace") as handle:
                    text = handle.read()
                scanned += 1
                if TOKEN in text:
                    check(f"{name} contains the token", False)
        check("no receipt anywhere contains the token", scanned > 5, f"scanned={scanned}")

        # ---- 14. transport failure
        print("\n[14] bridge unreachable")
        rc, data, _ = run_client("health", "--endpoint", "http://127.0.0.1:9",
                                 "--timeout", "2")
        check("unreachable -> exit 3", rc == 3, f"rc={rc}")
        check("classification ERROR_BRIDGE_UNREACHABLE",
              data and data.get("classification") == "ERROR_BRIDGE_UNREACHABLE")

        # ---- 15. non-loopback endpoint refused
        print("\n[15] non-loopback endpoint refused")
        rc, _, out = run_client("health", "--endpoint", "http://10.0.0.1:18765")
        check("non-loopback -> exit 2", rc == 2, f"rc={rc} {out}")

        # ---- 16. a 3xx is refused rather than followed with the token
        print("\n[16] redirect refused (the token must never leave the window)")
        write_control(fields, "redirect_to", "http://127.0.0.1:9/elsewhere")
        rc, data, out = run_client("gate", *base, "--token-file", token_file, "--expect", "200")
        check("redirect -> non-zero exit", rc != 0, f"rc={rc}")
        check("receipt records 302 instead of a followed redirect",
              bool(data) and data.get("http_status") == 302,
              f"http_status={data.get('http_status') if data else None}")
        os.remove(os.path.join(fields, "redirect_to"))

        # ---- 17. proxy settings cannot divert a loopback request
        print("\n[17] proxy environment cannot divert the loopback request")
        proxy_env = {
            "HTTP_PROXY": "http://127.0.0.1:9",
            "http_proxy": "http://127.0.0.1:9",
            "ALL_PROXY": "http://127.0.0.1:9",
            "all_proxy": "http://127.0.0.1:9",
        }
        rc, data, out = run_client("health", *base, env_extra=proxy_env)
        check("health still succeeds with proxies set", rc == 0, f"rc={rc} {out}")

        sys.path.insert(0, SCRIPTS)
        import r1_bridge_client as client_module  # noqa: E402

        check("proxy mapping is explicitly empty (no scheme may be proxied)",
              client_module._NO_PROXY.proxies == {},
              f"proxies={client_module._NO_PROXY.proxies}")
        check("redirect refusal is installed on the opener",
              any(isinstance(h, client_module._RefuseRedirect) for h in client_module._OPENER.handlers),
              f"handlers={[type(h).__name__ for h in client_module._OPENER.handlers]}")
    finally:
        bridge.stop()
        shutil.rmtree(work, ignore_errors=True)

    passed = sum(1 for _, ok, _ in results if ok)
    print(f"\n{passed}/{len(results)} assertions passed")
    if passed != len(results):
        for name, ok, _ in results:
            if not ok:
                print(f"  FAILED: {name}")
        return 1
    print("R1 BRIDGE CLIENT: OFFLINE_TEST_PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
