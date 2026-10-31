#!/usr/bin/env python3
"""Idempotent, non-destructive WorkBuddy -> iCloud CardDAV remote MCP config.

Run on the user's WorkBuddy Mac (NOT on the Seoul host):
  python3 scripts/agent-onboarding/workbuddy_carddav.py --check
  python3 scripts/agent-onboarding/workbuddy_carddav.py --apply

Default is dry-run. Does not access passwords, launch OAuth, or touch contacts.
"""
import argparse
import json
import os
from pathlib import Path
import shutil
import sys
from datetime import datetime, timezone

NAME = "icloud-carddav"
ENTRY = {"type": "http", "url": "https://seoul-forge-01.tail4db0d9.ts.net/mcp"}


def prepare(file_path):
    if file_path.exists():
        try:
            data = json.loads(file_path.read_text("utf-8"))
        except (ValueError, UnicodeError) as e:
            raise RuntimeError("Existing WorkBuddy mcp.json is invalid; refusing to overwrite") from e
        if not isinstance(data, dict) or not isinstance(data.get("mcpServers", {}), dict):
            raise RuntimeError("Existing config has an unexpected shape; refusing to overwrite")
    else:
        data = {"mcpServers": {}}
    existing = data["mcpServers"].get(NAME)
    if existing == ENTRY:
        return data, "ALREADY_CONFIGURED"
    if existing is not None:
        raise RuntimeError("icloud-carddav exists with different configuration: refusing to replace")
    data["mcpServers"][NAME] = dict(ENTRY)
    return data, "READY_TO_ADD"


def install(file_path, apply=False):
    data, state = prepare(file_path)
    if state == "ALREADY_CONFIGURED":
        return state
    if not apply:
        return "DRY_RUN_READY"
    file_path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    os.chmod(file_path.parent, 0o700)
    if file_path.exists():
        # Separate backup with previous exact bytes (preserve users' other MCP entries).
        stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
        backup = file_path.with_name(file_path.name + ".backup-" + stamp)
        if backup.exists():
            raise RuntimeError("Backup filename already exists; refusing to overwrite")
        shutil.copy2(file_path, backup)
        os.chmod(backup, 0o600)
    temporary = file_path.with_name(file_path.name + ".tmp-" + str(os.getpid()))
    try:
        with temporary.open("x", encoding="utf-8") as out:
            json.dump(data, out, ensure_ascii=False, indent=2)
            out.write("\n")
        os.chmod(temporary, 0o600)
        os.replace(temporary, file_path)
    finally:
        temporary.unlink(missing_ok=True)
    return "INSTALLED_CONFIG_ONLY_OAUTH_REQUIRED"


def main():
    p = argparse.ArgumentParser(description=__doc__)
    group = p.add_mutually_exclusive_group()
    group.add_argument("--apply", action="store_true", help="Back up existing config, then add remote MCP entry")
    group.add_argument("--check", action="store_true", help="Dry-run config check (default)")
    p.add_argument("--file", type=Path, default=Path.home()/".workbuddy"/"mcp.json",
                   help="For local fixtures/tests; don't use on the server")
    args = p.parse_args()
    try:
        print(install(args.file.expanduser(), apply=args.apply))
    except (OSError, RuntimeError) as e:
        print("BLOCKED:", e, file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
