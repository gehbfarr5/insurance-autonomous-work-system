#!/bin/bash
# r1_token_extract.sh - extract exactly one key from an env file into a 0600 file.
#
# Why this exists
# ---------------
# The documented one-liner in the R1 application used awk alone. The value in
# bridge.env is wrapped in double quotes, so awk produced a 66-byte string that
# still contained the quotes. The bridge then answered 401
# AUTHENTICATION_FAILED, and a 401 is indistinguishable from a revoked
# credential at the HTTP layer - so the first P0 dry run looked like a gate
# problem when it was a quoting bug in the procedure.
#
# This script normalises the value the way a shell would, refuses anything it
# cannot make sense of, and never prints the secret.
#
# Guarantees
#   * reads exactly one key; a missing key, an empty value, or the same key
#     appearing with differing values is a hard failure, never a guess
#   * strips one layer of matching "..." or '...' quoting, a trailing CR from
#     CRLF, and surrounding whitespace
#   * writes under umask 077 and re-asserts 0600 afterwards
#   * refuses to overwrite an existing destination
#   * reports lengths and a digest prefix only - never the value
#
# Exit codes
#   0  token written
#   2  precondition failure (bad arguments, unreadable source, missing/empty key)
#   3  destination unusable (exists, unwritable, wrong permissions after write)
#
# Usage
#   r1_token_extract.sh --env-file F --key K --out DEST [--quiet]

set -u

ENV_FILE=""
KEY=""
OUT=""
QUIET=0
MIN_LEN=16

die() {
  local stage="$1" msg="$2" rc="${3:-2}"
  echo "TOKEN_EXTRACT_FAILED[$stage]: $msg" >&2
  exit "$rc"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --env-file) ENV_FILE="${2:-}"; shift 2 ;;
    --key)      KEY="${2:-}"; shift 2 ;;
    --out)      OUT="${2:-}"; shift 2 ;;
    --quiet)    QUIET=1; shift ;;
    -h|--help)  sed -n '2,36p' "$0"; exit 0 ;;
    *)          die args "unknown argument: $1" ;;
  esac
done

[ -n "$ENV_FILE" ] || die args "--env-file required"
[ -n "$KEY" ]      || die args "--key required"
[ -n "$OUT" ]      || die args "--out required"

# The key is a literal identifier, not a pattern: refuse anything that could
# widen the match (globs, regex metacharacters, whitespace).
case "$KEY" in
  ""|*[!A-Za-z0-9_]*) die args "key must be a plain identifier: $KEY" ;;
esac

[ -f "$ENV_FILE" ] || die source "env file not found: $ENV_FILE"
[ -r "$ENV_FILE" ] || die source "env file not readable: $ENV_FILE"

# Refuse to overwrite: a second write could replace the record of what was
# actually used.
if [ -e "$OUT" ]; then
  die dest "destination already exists: $OUT" 3
fi
OUT_DIR="$(dirname "$OUT")"
[ -d "$OUT_DIR" ] || die dest "destination directory does not exist: $OUT_DIR" 3
[ -w "$OUT_DIR" ] || die dest "destination directory is not writable: $OUT_DIR" 3

# Collect every line for this key so a duplicate cannot silently win.
RAW="$(awk -v key="$KEY" '
  index($0, key "=") == 1 {
    v = substr($0, length(key) + 2)
    sub(/\r$/, "", v)          # CRLF file
    print v
  }
' "$ENV_FILE")" || die source "cannot read $ENV_FILE"

[ -n "$(printf '%s' "$RAW" | tr -d '[:space:]')" ] || die key "key not present or empty: $KEY"

COUNT="$(printf '%s\n' "$RAW" | wc -l | tr -d ' ')"
DISTINCT="$(printf '%s\n' "$RAW" | sort -u | wc -l | tr -d ' ')"
if [ "$DISTINCT" -gt 1 ]; then
  die key "key appears $COUNT times with differing values; refusing to choose"
fi

# Keep the last occurrence (they are identical when DISTINCT == 1).
VALUE="$(printf '%s\n' "$RAW" | tail -1)"
VALUE="${VALUE%$'\r'}"

# Trim surrounding whitespace without sed (bash parameter expansion only).
VALUE="${VALUE#"${VALUE%%[![:space:]]*}"}"
VALUE="${VALUE%"${VALUE##*[![:space:]]}"}"

SHAPE="plain"
FIRST="${VALUE:0:1}"
LAST="${VALUE: -1}"
if [ "$FIRST" = '"' ] && [ "$LAST" = '"' ] && [ "${#VALUE}" -ge 2 ]; then
  VALUE="${VALUE:1:${#VALUE}-2}"
  SHAPE="double_quoted"
elif [ "$FIRST" = "'" ] && [ "$LAST" = "'" ] && [ "${#VALUE}" -ge 2 ]; then
  VALUE="${VALUE:1:${#VALUE}-2}"
  SHAPE="single_quoted"
fi

# After removing one layer of quoting the value must not still look quoted:
# that is nested quoting we do not understand, and guessing is not acceptable.
case "$VALUE" in
  \"*|*\"|\'*|*\') die key "value is still quoted after normalisation" ;;
esac

[ -n "$VALUE" ] || die key "value is empty: $KEY"
[ "${#VALUE}" -ge "$MIN_LEN" ] || die key "value is implausibly short (${#VALUE} chars)"

( umask 077; printf '%s\n' "$VALUE" > "$OUT" ) || die dest "cannot write $OUT" 3
chmod 600 "$OUT" 2>/dev/null || die dest "cannot chmod 600 $OUT" 3

PERM="$(stat -f '%Lp' "$OUT" 2>/dev/null || stat -c '%a' "$OUT" 2>/dev/null)"
[ "$PERM" = "600" ] || die dest "post-write permissions are $PERM, expected 600" 3

if [ "$QUIET" -ne 1 ]; then
  DIGEST="$(shasum -a 256 "$OUT" | cut -c1-12)"
  # Length, shape and digest prefix only. The value itself is never printed.
  echo "token written: key=$KEY shape=$SHAPE bytes=${#VALUE} digest=$DIGEST out=$OUT"
fi

exit 0
