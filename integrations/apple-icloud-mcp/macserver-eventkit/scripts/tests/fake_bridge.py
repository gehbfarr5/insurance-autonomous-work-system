#!/usr/bin/env python3
"""fake_bridge.py — controllable stand-in for the MacServer EventKit bridge.

Used only by offline tests. It behaves like the real bridge at the HTTP contract
level (including Swift JSONEncoder date encoding) but reads its state from files
so a test can change behaviour between requests without restarting anything.

Control files inside --field-dir:
  gate            "true" / "false"      production gate state
  store           "production"/"fake"   value reported by /health
  lists           array of list objects
  items           object: {listID: [items]}
  fail_items      if present, items endpoint returns 500
  items_delay     seconds to sleep before answering the items endpoint
  allowed_ids     JSON array of allowlisted IDs. Absent = allow every ID.
                  Present-but-not-listed answers 403 LIST_NOT_ALLOWED,
                  and it does so BEFORE the gate check, mirroring the real
                  order (auth at :418, allowlist at :419, store guard at :136).
  item_status     JSON object: {listID or "*": {"status": int, "code": str}}.
                  Lets a test pin 404 LIST_NOT_FOUND, 403 SOURCE_MISMATCH,
                  403 SOURCE_NOT_ALLOWED etc. without touching the normal path.

This process never touches EventKit, TCC, or any Apple account.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

DEFAULTS = {"gate": "true", "store": "production"}


class Handler(BaseHTTPRequestHandler):
    field_dir = ""
    token = ""
    config_file = ""
    plist = ""
    items_seen = 0
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt: str, *args) -> None:  # silence default stderr logging
        pass

    def _gate_from_config(self) -> str:
        """Mirror BridgeConfig precedence: read the config file the way the real
        process would, so gate open/close can be exercised end to end."""
        if not self.config_file or not os.path.exists(self.config_file):
            return ""
        with open(self.config_file, "r", encoding="utf-8") as handle:
            for line in handle:
                line = line.strip()
                if line.startswith("EVENTKIT_BRIDGE_PRODUCTION_AUTHORIZED="):
                    value = line.split("=", 1)[1].strip().strip('"').strip("'")
                    return value
        return ""

    def _gate_from_plist(self) -> str:
        """LaunchAgent EnvironmentVariables win over the config file.

        This mirrors BridgeConfig.load(): `if mergedEnv[k] == nil || empty` means
        a key present in the plist makes the config file value irrelevant.
        """
        if not self.plist or not os.path.exists(self.plist):
            return ""
        try:
            import plistlib

            with open(self.plist, "rb") as handle:
                data = plistlib.load(handle)
        except Exception:
            return ""
        env = data.get("EnvironmentVariables") or {}
        value = env.get("EVENTKIT_BRIDGE_PRODUCTION_AUTHORIZED")
        return "" if value is None else str(value).strip()

    def _gate(self) -> str:
        return self._gate_from_plist() or self._gate_from_config() or self._control("gate")

    def _control(self, name: str) -> str:
        path = os.path.join(self.field_dir, name)
        if os.path.exists(path):
            with open(path, "r", encoding="utf-8") as handle:
                return handle.read().strip()
        return DEFAULTS.get(name, "")

    def _json(self, status: int, payload) -> None:
        body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self) -> None:  # noqa: N802
        self._json(405, {"success": "false", "error": "readonly", "code": "WRITE_OPERATION_REJECTED"})

    do_PUT = do_POST
    do_PATCH = do_POST
    do_DELETE = do_POST

    def do_GET(self) -> None:  # noqa: N802
        path = self.path.split("?")[0]

        # A redirect control proves the client refuses to follow a 3xx: following
        # one would re-send the Authorization header to wherever it points.
        redirect_to = self._control("redirect_to")
        if redirect_to:
            body = b""
            self.send_response(302)
            self.send_header("Location", redirect_to)
            self.send_header("Content-Length", "0")
            self.end_headers()
            self.wfile.write(body)
            return

        if path == "/health":
            self._json(200, {
                "status": "ok",
                "mode": "readonly",
                "store": self._control("store") or "production",
                "generation": 0,
                "active_requests": 0,
                "active_store_operations": 0,
                "max_store_operations": 10,
            })
            return

        if path == "/reminders/lists":
            if self.headers.get("Authorization") != f"Bearer {self.token}":
                self._json(401, {"success": "false", "error": "auth", "code": "AUTHENTICATION_FAILED"})
                return
            if self._gate() != "true":
                self._json(403, {"success": "false", "error": "gate closed", "code": "PERMISSION_DENIED"})
                return
            lists_path = os.path.join(self.field_dir, "lists")
            payload = json.load(open(lists_path, encoding="utf-8")) if os.path.exists(lists_path) else []
            self._json(200, payload)
            return

        prefix = "/reminders/lists/"
        suffix = "/items"
        if path.startswith(prefix) and path.endswith(suffix):
            if self.headers.get("Authorization") != f"Bearer {self.token}":
                self._json(401, {"success": "false", "error": "auth", "code": "AUTHENTICATION_FAILED"})
                return
            # Exact-match allowlist, ahead of the gate - the real server runs
            # allowlistValidator at :419 and the store guard at :136, so a
            # closed gate must not mask a config that points elsewhere.
            allowed_path = os.path.join(self.field_dir, "allowed_ids")
            if os.path.exists(allowed_path):
                with open(allowed_path, encoding="utf-8") as handle:
                    allowed = json.load(handle)
                list_id_probe = path[len(prefix):-len(suffix)]
                if list_id_probe not in allowed:
                    self._json(403, {"success": "false",
                                     "error": "The specified list is not on the allowlist.",
                                     "code": "LIST_NOT_ALLOWED"})
                    return
            if self._gate() != "true":
                self._json(403, {"success": "false", "error": "gate closed", "code": "PERMISSION_DENIED"})
                return
            status_path = os.path.join(self.field_dir, "item_status")
            if os.path.exists(status_path):
                with open(status_path, encoding="utf-8") as handle:
                    table = json.load(handle)
                requested = path[len(prefix):-len(suffix)]
                entry = table.get(requested) or table.get("*")
                if entry:
                    self._json(
                        int(entry.get("status", 500)),
                        {"success": "false",
                         "error": entry.get("error", "injected"),
                         "code": entry.get("code", "INTERNAL_ERROR")},
                    )
                    return
            if os.path.exists(os.path.join(self.field_dir, "fail_items")):
                self._json(500, {"success": "false", "error": "boom", "code": "INTERNAL_ERROR"})
                return
            delay = self._control("items_delay")
            if delay:
                time.sleep(float(delay))
            # items_seq: one entry per items request, in order, clamped to the
            # last entry. An entry of "ERROR" answers 500. This exists so a test
            # can make batch 1 succeed and batch 2 fail deterministically,
            # instead of relying on timing.
            seq_path = os.path.join(self.field_dir, "items_seq")
            if os.path.exists(seq_path):
                with open(seq_path, encoding="utf-8") as handle:
                    seq = json.load(handle)
                index = min(Handler.items_seen, len(seq) - 1)
                Handler.items_seen += 1
                entry = seq[index]
                if entry == "ERROR":
                    self._json(500, {"success": "false", "error": "seq error", "code": "INTERNAL_ERROR"})
                    return
                self._json(200, entry)
                return
            list_id = path[len(prefix):-len(suffix)]
            items_path = os.path.join(self.field_dir, "items")
            table = json.load(open(items_path, encoding="utf-8")) if os.path.exists(items_path) else {}
            self._json(200, table.get(list_id, []))
            return

        self._json(404, {"success": "false", "error": "unknown route", "code": "INTERNAL_ERROR"})


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--field-dir", required=True)
    parser.add_argument("--token", required=True)
    parser.add_argument("--config-file", default="")
    parser.add_argument("--plist", default="")
    parser.add_argument("--port", type=int, default=0)
    args = parser.parse_args()

    Handler.field_dir = args.field_dir
    Handler.token = args.token
    Handler.config_file = args.config_file
    Handler.plist = args.plist
    server = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    print(f"http://127.0.0.1:{server.server_address[1]}", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
