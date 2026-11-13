#!/usr/bin/env python3
"""test_r1_probe.py — offline verification for the R1-03 `probe` subcommand.

What this proves, and what it does not
--------------------------------------
It proves the *client's* classification is the one the matrix specifies, for
every response shape the matrix names, and that the client cannot construct the
account-wide enumeration URL. It does NOT prove the Swift server emits those
shapes: `fake_bridge.py` is a fixture written from the source branches, so a
mismatch between fixture and server would be invisible here. The 404 row in
particular has no HTTP-level test in the Swift suite (see the R1-03 document,
section 4.4), so its label here is only as good as the source reading.

No EventKit, no TCC, no Apple account, no network beyond loopback.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPTS = os.path.dirname(HERE)
CLIENT = os.path.join(SCRIPTS, "r1_bridge_client.py")
FAKE = os.path.join(HERE, "fake_bridge.py")

sys.path.insert(0, SCRIPTS)
import r1_bridge_client as client  # noqa: E402

TOKEN = "offline-test-token-0123456789abcdef"
LIST_ID = "9D9A5AAD-E3F0-4459-8756-BBCDBCB703F3"
CANARY_ID = "R1-CANARY-00000000-0000-0000-0000-000000000000"

results: list[tuple[str, bool, str]] = []


def check(name: str, ok: bool, detail: str = "") -> None:
    results.append((name, bool(ok), detail))
    print(f"  [{'PASS' if ok else 'FAIL'}] {name}{f' ({detail})' if detail and not ok else ''}")


def write_control(field_dir: str, name: str, value) -> None:
    with open(os.path.join(field_dir, name), "w", encoding="utf-8") as handle:
        handle.write(value if isinstance(value, str) else json.dumps(value, ensure_ascii=False))


def clear_control(field_dir: str, name: str) -> None:
    path = os.path.join(field_dir, name)
    if os.path.exists(path):
        os.unlink(path)


class Bridge:
    def __init__(self, field_dir: str):
        self.field_dir = field_dir
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


def probe(bridge: Bridge | None, tmp: str, phase: str, expect: str, *extra: str,
          token: str | None = TOKEN) -> tuple[int, dict | None, str]:
    out = os.path.join(tempfile.mkdtemp(dir=tmp, prefix="probe-"), "probe.json")
    token_file = os.path.join(tmp, "token")
    with open(token_file, "w", encoding="utf-8") as handle:
        handle.write(token if token is not None else TOKEN)
    os.chmod(token_file, 0o600)
    argv = [
        sys.executable, CLIENT, "probe",
        "--endpoint", bridge.url if bridge else "http://127.0.0.1:1",
        "--token-file", token_file,
        "--list-id", LIST_ID,
        "--phase", phase,
        "--expect", expect,
        "--out", out,
        "--timeout", "5",
        *extra,
    ]
    proc = subprocess.run(argv, capture_output=True, text=True)
    data = None
    if os.path.exists(out):
        with open(out, encoding="utf-8") as handle:
            data = json.load(handle)
    return proc.returncode, data, proc.stdout + proc.stderr


# --------------------------------------------------------------------------- #
# 1. classify(): the mapping itself, with no server involved
# --------------------------------------------------------------------------- #
def test_classify() -> None:
    print("classify(): every matrix row")
    cases = [
        ((200, []), "RESOLVED_IDENTITY_MATCH_EMPTY"),
        ((200, [{"itemID": "x"}]), "RESOLVED_WITH_ITEMS"),
        ((200, {"not": "a list"}), "ERROR_UNEXPECTED_BODY"),
        ((404, {"code": "LIST_NOT_FOUND"}), "NOT_RESOLVABLE"),
        ((404, {"code": "INTERNAL_ERROR"}), "ERROR_ROUTE"),
        ((404, {}), "ERROR_ROUTE"),
        ((403, {"code": "SOURCE_MISMATCH"}), "RESOLVED_SOURCE_IDENTITY_CHANGED"),
        ((403, {"code": "SOURCE_NOT_ALLOWED"}), "ANOMALOUS_SOURCE_NOT_ALLOWED"),
        ((403, {"code": "PERMISSION_DENIED"}), "BLOCKED_PERMISSION_OR_GATE"),
        ((403, {"code": "LIST_NOT_ALLOWED"}), "BLOCKED_NOT_ON_ALLOWLIST"),
        ((403, {"code": "UNAUTHORIZED_SCOPE"}), "BLOCKED_AUTH"),
        ((403, {"code": "SOMETHING_NEW"}), "ERROR_UNRECOGNISED_403"),
        ((401, {"code": "AUTHENTICATION_FAILED"}), "BLOCKED_AUTH"),
        ((429, {"code": "RATE_LIMIT_EXCEEDED"}), "BLOCKED_RATE_LIMIT"),
        ((503, {"code": "CONCURRENCY_LIMIT_EXCEEDED"}), "BLOCKED_BUSY"),
        ((504, {"code": "TIMEOUT"}), "BLOCKED_TIMEOUT"),
        ((500, {"code": "INTERNAL_ERROR"}), "ERROR_INTERNAL"),
        ((0, None), "ERROR_BRIDGE_UNREACHABLE"),
    ]
    for (status, body), expected in cases:
        label, _code, _count = client.classify(status, body)
        hint = body.get("code") if isinstance(body, dict) else type(body).__name__
        check(f"classify {status} {hint or ''} -> {expected}", label == expected, f"got {label}")

    # A 404 must never be read as "the identifier did not resolve" unless the
    # code says so. This is the single most likely misread in the whole matrix.
    label, _c, _n = client.classify(404, {"code": "INTERNAL_ERROR"})
    check("404 INTERNAL_ERROR is not NOT_RESOLVABLE", label != "NOT_RESOLVABLE", label)


def test_apply_phase() -> None:
    print("apply_phase(): pre/open/post reading of one identical response")
    check("pre + PERMISSION_DENIED -> GATE_CLOSED_AS_EXPECTED",
          client.apply_phase("BLOCKED_PERMISSION_OR_GATE", "pre") == "GATE_CLOSED_AS_EXPECTED")
    check("post + PERMISSION_DENIED -> GATE_RESTORED_CLOSED",
          client.apply_phase("BLOCKED_PERMISSION_OR_GATE", "post") == "GATE_RESTORED_CLOSED")
    check("pre + NOT_RESOLVABLE -> GATE_ALREADY_OPEN",
          client.apply_phase("NOT_RESOLVABLE", "pre") == "GATE_ALREADY_OPEN")
    check("post + RESOLVED_WITH_ITEMS -> GATE_STILL_OPEN",
          client.apply_phase("RESOLVED_WITH_ITEMS", "post") == "GATE_STILL_OPEN")
    check("open phase never rewrites the label",
          client.apply_phase("NOT_RESOLVABLE", "open") == "NOT_RESOLVABLE")
    check("pre + BLOCKED_AUTH stays BLOCKED_AUTH (auth is not the gate)",
          client.apply_phase("BLOCKED_AUTH", "pre") == "BLOCKED_AUTH")
    check("pre + ERROR_ROUTE stays ERROR_ROUTE (a bad path is not an open gate)",
          client.apply_phase("ERROR_ROUTE", "pre") == "ERROR_ROUTE")
    check("pre + BLOCKED_TIMEOUT -> GATE_ALREADY_OPEN (504 is behind the guard)",
          client.apply_phase("BLOCKED_TIMEOUT", "pre") == "GATE_ALREADY_OPEN")


def test_url_builder() -> None:
    print("item_url(): structurally incapable of the enumeration path")
    url = client.item_url("http://127.0.0.1:18765", LIST_ID)
    check("builds the item path", url.endswith(f"/reminders/lists/{LIST_ID}/items"), url)
    check("path has exactly five segments",
          client.urllib.parse.urlsplit(url).path.count("/") == 4, url)
    # No argument produces /reminders/lists: the builder always appends two
    # segments and the assertion re-checks the shape afterwards.
    for hostile in ("..", "reminders/lists", "a/b/items"):
        built = client.item_url("http://127.0.0.1:18765", hostile)
        ok = built.endswith("/items") and "lists//items" not in built
        check(f"hostile id {hostile!r} still yields an item-shaped path", ok, built)
    try:
        client.item_url("http://127.0.0.1:18765", "")
        raised = False
    except AssertionError:
        raised = True
    check("an empty id is refused rather than sent as a malformed path", raised)


# --------------------------------------------------------------------------- #
# 2. end-to-end against the fixture
# --------------------------------------------------------------------------- #
def test_closed_gate(bridge: Bridge, fields: str, tmp: str) -> None:
    print("pre phase: three refusals are three different codes")
    write_control(fields, "allowed_ids", [LIST_ID])
    write_control(fields, "gate", "false")

    code, data, _out = probe(bridge, tmp, "pre", "GATE_CLOSED_AS_EXPECTED", "--canary-id", CANARY_ID)
    check("closed gate, target allowlisted -> GATE_CLOSED_AS_EXPECTED", code == 0, str(code))
    if data:
        check("target answered 403 PERMISSION_DENIED",
              data["target"]["http_status"] == 403 and data["target"]["error_code"] == "PERMISSION_DENIED")
        check("canary was stopped by the allowlist, not the gate",
              data["canary"]["error_code"] == "LIST_NOT_ALLOWED", str(data["canary"]))
        check("boundary: zero enumerations", data["boundary"]["list_enumerations_called"] == 0)
        check("boundary: only item paths in the request log",
              all(entry["path_template"] == client.ITEM_PATH_TEMPLATE for entry in data["requests"]))
        check("boundary: enumeration path unavailable to the client",
              data["boundary"]["enumeration_path_available_to_client"] is False)

    # A gate that is already open must not be reported as a closed baseline.
    write_control(fields, "gate", "true")
    code, data, _out = probe(bridge, tmp, "pre", "GATE_ALREADY_OPEN", "--canary-id", CANARY_ID)
    check("open gate read in the pre phase -> GATE_ALREADY_OPEN", code == 0, str(code))

    # Config that points elsewhere: same 403 family, different meaning.
    write_control(fields, "gate", "false")
    write_control(fields, "allowed_ids", ["SOME-OTHER-ID"])
    code, data, _out = probe(bridge, tmp, "pre", "BLOCKED_NOT_ON_ALLOWLIST")
    check("target off the allowlist -> BLOCKED_NOT_ON_ALLOWLIST", code == 0, str(code))
    if data:
        check("off-allowlist target never reached the store",
              data["target"]["error_code"] == "LIST_NOT_ALLOWED")


def test_auth_failure(bridge: Bridge, fields: str, tmp: str) -> None:
    print("authentication failure is its own outcome")
    write_control(fields, "allowed_ids", [LIST_ID])
    write_control(fields, "gate", "false")
    code, data, _out = probe(bridge, tmp, "pre", "BLOCKED_AUTH", "--canary-id", CANARY_ID,
                             token="wrong-token-wrong-token")
    check("bad token -> BLOCKED_AUTH", code == 0, str(code))
    if data:
        check("auth failure is reported as 401", data["target"]["http_status"] == 401)
        check("auth failure is not folded into the gate",
              data["classification"] == "BLOCKED_AUTH", str(data.get("classification")))


def test_open_outcomes(bridge: Bridge, fields: str, tmp: str) -> None:
    print("open phase: every resolvability outcome")
    write_control(fields, "gate", "true")
    write_control(fields, "allowed_ids", [LIST_ID])

    scenarios = [
        ({"status": 404, "code": "LIST_NOT_FOUND"}, "NOT_RESOLVABLE"),
        ({"status": 403, "code": "SOURCE_MISMATCH"}, "RESOLVED_SOURCE_IDENTITY_CHANGED"),
        ({"status": 403, "code": "SOURCE_NOT_ALLOWED"}, "ANOMALOUS_SOURCE_NOT_ALLOWED"),
        ({"status": 404, "code": "INTERNAL_ERROR"}, "ERROR_ROUTE"),
        ({"status": 429, "code": "RATE_LIMIT_EXCEEDED"}, "BLOCKED_RATE_LIMIT"),
        ({"status": 503, "code": "CONCURRENCY_LIMIT_EXCEEDED"}, "BLOCKED_BUSY"),
        ({"status": 504, "code": "TIMEOUT"}, "BLOCKED_TIMEOUT"),
        ({"status": 500, "code": "INTERNAL_ERROR"}, "ERROR_INTERNAL"),
    ]
    for injected, expected in scenarios:
        write_control(fields, "item_status", {LIST_ID: injected})
        code, data, _out = probe(bridge, tmp, "open", expected)
        check(f"injected {injected['status']} {injected['code']} -> {expected}", code == 0, str(code))
        if data and expected == "RESOLVED_SOURCE_IDENTITY_CHANGED":
            check("SOURCE_MISMATCH is recorded as 'resolved, identity changed'",
                  data["inference"]["id_resolvable"] is True
                  and data["inference"]["source_identity_matches_binding"] is False)
        if data and expected == "NOT_RESOLVABLE":
            check("a 404 does not assert deletion", data["inference"]["deleted_asserted"] is False)

    clear_control(fields, "item_status")

    # 200 with no items
    write_control(fields, "items", {LIST_ID: []})
    code, data, _out = probe(bridge, tmp, "open", "RESOLVED_IDENTITY_MATCH_EMPTY")
    check("200 [] -> RESOLVED_IDENTITY_MATCH_EMPTY", code == 0, str(code))
    if data:
        check("item_count is 0 and nothing else is kept",
              data["target"]["item_count"] == 0 and data["target"]["items_persisted"] is False)

    # 200 with items: must be counted, never quoted
    secret_title = "SECRET-TITLE-DO-NOT-PERSIST"
    secret_notes = "SECRET-NOTES-DO-NOT-PERSIST"
    write_control(fields, "items", {LIST_ID: [
        {"itemID": "11111111-2222-4333-8444-555555555555",
         "title": secret_title, "notes": secret_notes, "isCompleted": False,
         "priority": 5, "listID": LIST_ID}
    ]})
    code, data, _out = probe(bridge, tmp, "open", "RESOLVED_WITH_ITEMS")
    check("200 [1] -> RESOLVED_WITH_ITEMS", code == 0, str(code))
    if data:
        blob = json.dumps(data, ensure_ascii=False)
        check("item_count is 1", data["target"]["item_count"] == 1)
        check("no item title in the receipt", secret_title not in blob)
        check("no item notes in the receipt", secret_notes not in blob)
        check("no raw list identifier in the receipt", LIST_ID not in blob)
        check("no follow-up was triggered", data["follow_up"]["triggered"] is False)


def test_post_phase(bridge: Bridge, fields: str, tmp: str) -> None:
    print("post phase: the window closes back")
    write_control(fields, "allowed_ids", [LIST_ID])
    write_control(fields, "gate", "false")
    code, data, _out = probe(bridge, tmp, "post", "GATE_RESTORED_CLOSED")
    check("gate closed again -> GATE_RESTORED_CLOSED", code == 0, str(code))

    write_control(fields, "gate", "true")
    code, data, _out = probe(bridge, tmp, "post", "GATE_STILL_OPEN")
    check("gate left open -> GATE_STILL_OPEN", code == 0, str(code))


def test_failure_modes(bridge: Bridge, fields: str, tmp: str) -> None:
    print("preconditions and refusals")
    # canary contradicted: allowlist control absent means the fixture allows
    # everything, so the canary reaches the gate and answers PERMISSION_DENIED.
    clear_control(fields, "allowed_ids")
    write_control(fields, "gate", "false")
    code, data, _out = probe(bridge, tmp, "pre", "GATE_CLOSED_AS_EXPECTED", "--canary-id", CANARY_ID)
    check("canary not stopped by the allowlist -> ANOMALOUS_CANARY (exit 25)", code == 25, str(code))
    if data:
        check("the anomaly is named, not explained away",
              data["classification"] == "ANOMALOUS_CANARY")

    # store=fake cannot stand in for evidence
    write_control(fields, "store", "fake")
    write_control(fields, "allowed_ids", [LIST_ID])
    code, data, _out = probe(bridge, tmp, "pre", "GATE_CLOSED_AS_EXPECTED")
    check("fake store -> ERROR_NOT_PRODUCTION_STORE (exit 20)", code == 20, str(code))
    clear_control(fields, "store")

    # expected classification mismatch is a failure, not a warning
    code, data, _out = probe(bridge, tmp, "pre", "NOT_RESOLVABLE")
    check("wrong --expect -> exit 24", code == 24, str(code))

    # unreachable bridge
    code, data, _out = probe(None, tmp, "pre", "ERROR_BRIDGE_UNREACHABLE")
    check("no listener -> ERROR_BRIDGE_UNREACHABLE (exit 3)", code == 3, str(code))


def test_no_enumeration_switch() -> None:
    print("the enumeration escape hatch does not exist")
    proc = subprocess.run([sys.executable, CLIENT, "probe", "--help"],
                          capture_output=True, text=True)
    text = proc.stdout + proc.stderr
    check("probe --help has no --allow-enumeration", "--allow-enumeration" not in text)
    check("probe --help names the item path only",
          "/reminders/lists" not in text.replace("/reminders/lists/{id}/items", ""))


def main() -> int:
    work = tempfile.mkdtemp(prefix="r1-probe-test-")
    fields = os.path.join(work, "fields")
    os.makedirs(fields)
    write_control(fields, "store", "production")
    write_control(fields, "gate", "false")

    test_classify()
    test_apply_phase()
    test_url_builder()
    test_no_enumeration_switch()

    bridge = Bridge(fields)
    try:
        test_closed_gate(bridge, fields, work)
        test_auth_failure(bridge, fields, work)
        test_open_outcomes(bridge, fields, work)
        test_post_phase(bridge, fields, work)
        test_failure_modes(bridge, fields, work)
    finally:
        bridge.stop()

    passed = sum(1 for _, ok, _ in results if ok)
    total = len(results)
    print(f"\n{passed}/{total} checks passed")
    if passed != total:
        for name, ok, detail in results:
            if not ok:
                print(f"  FAILED: {name} {detail}")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
