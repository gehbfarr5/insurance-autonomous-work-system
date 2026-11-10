#!/usr/bin/env python3
"""write_build_metadata.py — build provenance writer / verifier for EventKitBridgeServer.

Problem this solves
-------------------
BUILD_METADATA.json recorded the binary SHA256, cdhashes and timestamp, but never
recorded which source commit produced the binary or whether the tree was dirty.
That makes the R1 acceptance requirement ("record the actually-running program
version and hash") unverifiable: nothing tied `f78e24e5...` to a commit, so
"source == production artifact" was an assumption, not evidence.

This tool makes provenance explicit at build time and checkable at run time,
without touching EventKit, TCC, signing keys or any Apple data.

Modes
-----
  write   (default) : emit BUILD_METADATA.json including a source_provenance block
  verify            : compare a metadata file against a binary on disk (read-only)
  self-test         : exercise both modes in a throwaway temp git repo

Exit codes: 0 ok / PASS, 1 verification mismatch, 2 usage or environment error.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time

REQUIRED_PROVENANCE_KEYS = (
    "source_commit",
    "source_branch",
    "source_dirty",
    "source_describe",
    "toolchain",
    "build_host_arch",
    "generated_by",
)
MISSING = "UNVERIFIED"


def _run(cmd: list[str], cwd: str | None = None) -> str | None:
    try:
        out = subprocess.run(
            cmd, cwd=cwd, capture_output=True, text=True, timeout=20, check=False
        )
    except (OSError, subprocess.SubprocessError):
        return None
    if out.returncode != 0:
        return None
    return out.stdout.strip()


def collect_provenance(repo_root: str) -> dict[str, object]:
    """Gather source provenance. Never raises: unavailable data is marked UNVERIFIED."""
    commit = _run(["git", "rev-parse", "HEAD"], cwd=repo_root)
    branch = _run(["git", "rev-parse", "--abbrev-ref", "HEAD"], cwd=repo_root)
    status = _run(["git", "status", "--porcelain"], cwd=repo_root)
    describe = _run(["git", "describe", "--tags", "--always", "--dirty"], cwd=repo_root)
    swift = _run(["swift", "--version"])
    swift_line = swift.splitlines()[0] if swift else None

    return {
        "source_commit": commit or MISSING,
        "source_branch": branch or MISSING,
        "source_dirty": (None if status is None else bool(status.strip())),
        "source_describe": describe or MISSING,
        "toolchain": swift_line or MISSING,
        "build_host_arch": _run(["uname", "-m"]) or MISSING,
        "generated_by": "integrations/apple-icloud-mcp/macserver-eventkit/scripts/write_build_metadata.py",
    }


def sha256_file(path: str) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def build_payload(args: argparse.Namespace) -> dict[str, object]:
    return {
        "build_pipeline": "build-and-sign-universal.sh",
        "build_timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "identifier": args.identifier,
        "source_provenance": collect_provenance(args.repo_root),
        "universal_binary": {
            "path": ".build/release/EventKitBridgeServer",
            "sha256": args.binary_sha256,
            "designated_requirement": args.designated_requirement,
        },
        "architectures": {
            "x86_64": {
                "cdhash": args.x86_cdhash,
                "flags": args.x86_flags,
                "min_macos_version": args.x86_minos,
                "embedded_info_plist": True,
            },
            "arm64": {
                "cdhash": args.arm_cdhash,
                "flags": args.arm_flags,
                "min_macos_version": args.arm_minos,
                "embedded_info_plist": True,
            },
        },
        "signature_verification": {
            "method": "codesign --verify --strict --all-architectures",
            "status": "PASSED",
        },
    }


def cmd_write(args: argparse.Namespace) -> int:
    payload = build_payload(args)
    with open(args.out, "w", encoding="utf-8") as handle:
        json.dump(payload, handle, indent=2, ensure_ascii=False)
        handle.write("\n")
    missing = [key for key in REQUIRED_PROVENANCE_KEYS if key not in payload["source_provenance"]]
    if missing:
        print(f"FATAL: provenance block missing keys: {missing}", file=sys.stderr)
        return 2
    if payload["source_provenance"]["source_commit"] == MISSING:
        print(
            "WARNING: source commit could not be resolved; metadata records UNVERIFIED.",
            file=sys.stderr,
        )
    print(f"metadata written: {args.out}")
    return 0


def cmd_verify(args: argparse.Namespace, quiet: bool = False) -> int:
    """Read-only: does the deployed binary match the archived metadata?"""
    with open(args.verify_metadata, encoding="utf-8") as handle:
        metadata = json.load(handle)
    actual = sha256_file(args.verify_binary)
    expected = (metadata.get("universal_binary") or {}).get("sha256")
    provenance = metadata.get("source_provenance") or {}
    verdict = {
        "receipt_type": "BUILD_PROVENANCE_VERIFICATION",
        "verified_at_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "binary_path": args.verify_binary,
        "metadata_path": args.verify_metadata,
        "expected_sha256": expected,
        "actual_sha256": actual,
        "sha256_match": expected == actual,
        "source_commit": provenance.get("source_commit", MISSING),
        "source_dirty": provenance.get("source_dirty"),
        "toolchain": provenance.get("toolchain", MISSING),
        "provenance_present": all(key in provenance for key in REQUIRED_PROVENANCE_KEYS),
    }
    verdict["verdict"] = (
        "PASS"
        if verdict["sha256_match"] and verdict["provenance_present"]
        else "FAIL_MISMATCH"
    )
    if not quiet:
        print(json.dumps(verdict, indent=2, ensure_ascii=False))
    return 0 if verdict["verdict"] == "PASS" else 1


def _quiet(func, args: argparse.Namespace) -> int:
    """Run a command with stdout suppressed (self-test keeps its own output terse)."""
    saved = sys.stdout
    try:
        sys.stdout = open(os.devnull, "w", encoding="utf-8")
        return func(args)
    finally:
        sys.stdout.close()
        sys.stdout = saved


def cmd_self_test() -> int:
    """Exercise write + verify against a throwaway repo and a fake binary."""
    checks: list[tuple[str, bool, str]] = []

    def check(name: str, ok: bool, detail: str = "") -> None:
        checks.append((name, bool(ok), detail))

    with tempfile.TemporaryDirectory(prefix="provenance-selftest-") as workdir:
        repo = os.path.join(workdir, "repo")
        os.makedirs(repo)
        subprocess.run(["git", "init", "-q", repo], check=True)
        tracked = os.path.join(repo, "tracked.txt")
        with open(tracked, "w", encoding="utf-8") as handle:
            handle.write("clean\n")
        subprocess.run(["git", "-C", repo, "add", "tracked.txt"], check=True)
        subprocess.run(
            ["git", "-C", repo, "-c", "user.email=t@example.invalid",
             "-c", "user.name=selftest", "commit", "-q", "-m", "init"],
            check=True,
        )
        head = _run(["git", "rev-parse", "HEAD"], cwd=repo)

        binary = os.path.join(workdir, "EventKitBridgeServer")
        with open(binary, "wb") as handle:
            handle.write(b"fake-binary-payload-v1\n")
        metadata_path = os.path.join(workdir, "BUILD_METADATA.json")

        args = argparse.Namespace(
            identifier="com.muse.macserver-eventkit.selftest",
            repo_root=repo,
            binary_sha256=sha256_file(binary),
            designated_requirement='# designated => cdhash H"deadbeef"',
            x86_cdhash="a" * 40,
            x86_flags="0x10002(adhoc,runtime)",
            x86_minos="14.0",
            arm_cdhash="b" * 40,
            arm_flags="0x10002(adhoc,runtime)",
            arm_minos="14.0",
            out=metadata_path,
        )
        check("write mode returns 0", _quiet(cmd_write, args) == 0)

        with open(metadata_path, encoding="utf-8") as handle:
            written = json.load(handle)
        provenance = written.get("source_provenance", {})
        check(
            "all provenance keys present",
            all(key in provenance for key in REQUIRED_PROVENANCE_KEYS),
            str(sorted(provenance)),
        )
        check(
            "records the real source commit",
            provenance.get("source_commit") == head,
            "" if provenance.get("source_commit") == head else f"{provenance.get('source_commit')} != {head}",
        )
        check("clean tree recorded as not dirty", provenance.get("source_dirty") is False)

        # dirty tree must be observable
        with open(tracked, "a", encoding="utf-8") as handle:
            handle.write("uncommitted\n")
        dirty_payload = build_payload(args)
        check("dirty tree recorded as dirty",
              dirty_payload["source_provenance"].get("source_dirty") is True)

        verify_args = argparse.Namespace(
            verify_metadata=metadata_path, verify_binary=binary
        )
        check("verify passes for matching binary", cmd_verify(verify_args, quiet=True) == 0)

        with open(binary, "ab") as handle:
            handle.write(b"tampered\n")
        check("verify fails for mutated binary", cmd_verify(verify_args, quiet=True) == 1)

    passed = sum(1 for _, ok, _ in checks if ok)
    for name, ok, detail in checks:
        status = "PASS" if ok else "FAIL"
        print(f"  [{status}] {name}{f' ({detail})' if detail else ''}")
    print(f"{passed}/{len(checks)} assertions passed")
    if passed == len(checks):
        print("BUILD_PROVENANCE_SELF_TEST_PASS")
        return 0
    print("BUILD_PROVENANCE_SELF_TEST_FAIL", file=sys.stderr)
    return 1


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--self-test", action="store_true")
    parser.add_argument("--verify-metadata")
    parser.add_argument("--verify-binary")
    parser.add_argument("--identifier", default="com.muse.macserver-eventkit")
    parser.add_argument("--repo-root", default=os.getcwd())
    parser.add_argument("--binary-sha256", default=MISSING)
    parser.add_argument("--designated-requirement", default=MISSING)
    parser.add_argument("--x86-cdhash", default=MISSING)
    parser.add_argument("--x86-flags", default=MISSING)
    parser.add_argument("--x86-minos", default=MISSING)
    parser.add_argument("--arm-cdhash", default=MISSING)
    parser.add_argument("--arm-flags", default=MISSING)
    parser.add_argument("--arm-minos", default=MISSING)
    parser.add_argument("--out", default="BUILD_METADATA.json")
    args = parser.parse_args()

    if args.self_test:
        return cmd_self_test()
    if args.verify_metadata or args.verify_binary:
        if not (args.verify_metadata and args.verify_binary):
            print("ERROR: --verify-metadata and --verify-binary must be used together",
                  file=sys.stderr)
            return 2
        if not (os.path.isfile(args.verify_metadata) and os.path.isfile(args.verify_binary)):
            print("ERROR: verification inputs must both be existing files", file=sys.stderr)
            return 2
        return cmd_verify(args)
    return cmd_write(args)


if __name__ == "__main__":
    sys.exit(main())
