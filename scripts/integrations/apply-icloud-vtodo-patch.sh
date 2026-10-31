#!/usr/bin/env bash
# Apply the exact 2026-10-31 Seoul VTODO fix to a clean upstream checkout.
# Defaults to --check; does not deploy, restart containers or use credentials.
set -euo pipefail

MODE="${1:---check}"
UPSTREAM="${2:-}"
case "$MODE" in --check|--apply) ;; *) echo "Usage: $0 --check|--apply /path/to/apple-icloud-mcp" >&2; exit 2;; esac
if [[ -z "$UPSTREAM" || ! -d "$UPSTREAM/.git" ]]; then
  echo "Pass the existing upstream Git checkout as the second argument" >&2
  exit 2
fi
UPSTREAM="$(cd "$UPSTREAM" && pwd)"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PATCH_DIR="$REPO_ROOT/patches/apple-icloud-mcp"

for patch in \
  "$PATCH_DIR/0001-vtodo-explicit-filter-20261031.patch" \
  "$PATCH_DIR/0002-vtodo-unit-regression-20261031.patch"; do
  if git -C "$UPSTREAM" apply --reverse --check "$patch" >/dev/null 2>&1; then
    echo "ALREADY_APPLIED $(basename "$patch")"
  elif git -C "$UPSTREAM" apply --check "$patch" >/dev/null 2>&1; then
    if [[ "$MODE" == "--apply" ]]; then
      git -C "$UPSTREAM" apply "$patch"
      echo "APPLIED $(basename "$patch")"
    else
      echo "READY_TO_APPLY $(basename "$patch")"
    fi
  else
    echo "BLOCKED_PATCH_DRIFT $(basename "$patch") (review upstream changes; no auto overwrite)" >&2
    exit 3
  fi
done
git -C "$UPSTREAM" diff --check
echo "VTODO_PATCH_${MODE#--}_PASS"
