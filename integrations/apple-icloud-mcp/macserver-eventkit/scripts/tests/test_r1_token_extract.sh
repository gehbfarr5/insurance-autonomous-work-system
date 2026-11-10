#!/bin/bash
# test_r1_token_extract.sh - offline verification for r1_token_extract.sh
#
# Scope: the quoting defect only. No EventKit, no TCC, no Apple account, no
# network, no bridge. Every fixture is a temporary env file written by this
# script and deleted afterwards.
#
# The defect under test: bridge.env stores the value wrapped in double quotes.
# A naive awk extraction keeps them, the resulting token authenticates as
# garbage, and the bridge answers 401 - which reads like a revoked credential
# rather than a quoting bug.

set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/../r1_token_extract.sh"
[ -x "$SCRIPT" ] || { echo "missing or non-executable: $SCRIPT" >&2; exit 1; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/r1-token-test.XXXXXX")" || exit 1
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0
check() {
  local name="$1" ok="$2" detail="${3:-}"
  if [ "$ok" = "1" ]; then
    PASS=$((PASS + 1)); echo "  PASS  $name"
  else
    FAIL=$((FAIL + 1)); echo "  FAIL  $name ${detail:+($detail)}"
  fi
}

SECTION=0
section() { SECTION=$((SECTION + 1)); echo; echo "[$SECTION] $1"; }

SECRET="0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
SHORT="short"

# Build an env file with one line of the given raw form. $1 = raw value text.
mkenv() {
  local path="$1" raw="$2" eol="${3:-$'\n'}"
  printf 'OTHER_KEY=ignored\nEVENTKIT_BRIDGE_BEARER_TOKEN=%s%s' "$raw" "$eol" > "$path"
}

run_extract() {  # $1 env file, $2 out path, extra args after
  local env="$1" out="$2"; shift 2
  "$SCRIPT" --env-file "$env" --key EVENTKIT_BRIDGE_BEARER_TOKEN --out "$out" "$@" 2>&1
}

# ---------------------------------------------------------------------------
section "quoted value: the shape that broke the first P0 dry run"
ENVF="$WORK/env-quoted"
OUT="$WORK/token-quoted"
mkenv "$ENVF" "\"$SECRET\""
OUTPUT="$(run_extract "$ENVF" "$OUT")"; RC=$?
check "double-quoted value -> exit 0" "$([ "$RC" -eq 0 ] && echo 1 || echo 0)" "rc=$RC $OUTPUT"
GOT="$(cat "$OUT" 2>/dev/null)"
check "quotes stripped from file content" "$([ "$GOT" = "$SECRET" ] && echo 1 || echo 0)"
check "file byte count matches the unquoted secret" \
      "$([ "$(wc -c < "$OUT" | tr -d ' ')" -eq "$(( ${#SECRET} + 1 ))" ] && echo 1 || echo 0)"
check "shape reported as double_quoted" \
      "$(printf '%s' "$OUTPUT" | grep -q "shape=double_quoted" && echo 1 || echo 0)" "$OUTPUT"
check "permissions are 0600" \
      "$([ "$(stat -f '%Lp' "$OUT")" = "600" ] && echo 1 || echo 0)"
check "secret never printed" \
      "$(printf '%s' "$OUTPUT" | grep -q "$SECRET" && echo 0 || echo 1)" "$OUTPUT"

# ---------------------------------------------------------------------------
section "other value shapes a real env file can contain"
ENVF="$WORK/env-single"
OUT="$WORK/token-single"
mkenv "$ENVF" "'$SECRET'"
run_extract "$ENVF" "$OUT" >/dev/null 2>&1
check "single-quoted value -> stripped" \
      "$([ "$(cat "$OUT" 2>/dev/null)" = "$SECRET" ] && echo 1 || echo 0)"

ENVF="$WORK/env-plain"
OUT="$WORK/token-plain"
mkenv "$ENVF" "$SECRET"
run_extract "$ENVF" "$OUT" >/dev/null 2>&1
check "unquoted value -> unchanged" \
      "$([ "$(cat "$OUT" 2>/dev/null)" = "$SECRET" ] && echo 1 || echo 0)"

ENVF="$WORK/env-padded"
OUT="$WORK/token-padded"
mkenv "$ENVF" "   \"$SECRET\"   "
run_extract "$ENVF" "$OUT" >/dev/null 2>&1
check "surrounding whitespace trimmed before unquoting" \
      "$([ "$(cat "$OUT" 2>/dev/null)" = "$SECRET" ] && echo 1 || echo 0)"

ENVF="$WORK/env-crlf"
OUT="$WORK/token-crlf"
mkenv "$ENVF" "\"$SECRET\"" $'\r\n'
run_extract "$ENVF" "$OUT" >/dev/null 2>&1
check "CRLF file -> no CR left in the value" \
      "$([ "$(cat "$OUT" 2>/dev/null)" = "$SECRET" ] && echo 1 || echo 0)"

# ---------------------------------------------------------------------------
section "refusals: the script must not guess"
ENVF="$WORK/env-short"
OUT="$WORK/token-short"
mkenv "$ENVF" "\"$SHORT\""
OUTPUT="$(run_extract "$ENVF" "$OUT")"; RC=$?
check "implausibly short value -> exit 2" "$([ "$RC" -eq 2 ] && echo 1 || echo 0)" "rc=$RC"
check "no file written on refusal" "$([ -e "$OUT" ] && echo 0 || echo 1)"

ENVF="$WORK/env-empty"
OUT="$WORK/token-empty"
mkenv "$ENVF" '""'
OUTPUT="$(run_extract "$ENVF" "$OUT")"; RC=$?
check "empty value -> exit 2" "$([ "$RC" -eq 2 ] && echo 1 || echo 0)" "rc=$RC"

ENVF="$WORK/env-absent"
OUT="$WORK/token-absent"
printf 'OTHER_KEY=ignored\n' > "$ENVF"
OUTPUT="$(run_extract "$ENVF" "$OUT")"; RC=$?
check "key absent -> exit 2" "$([ "$RC" -eq 2 ] && echo 1 || echo 0)" "rc=$RC"

ENVF="$WORK/env-dup-differs"
OUT="$WORK/token-dup"
{ echo "OTHER_KEY=ignored"; echo "EVENTKIT_BRIDGE_BEARER_TOKEN=\"$SECRET\""; echo "EVENTKIT_BRIDGE_BEARER_TOKEN=\"${SECRET}zz\""; } > "$ENVF"
OUTPUT="$(run_extract "$ENVF" "$OUT")"; RC=$?
check "duplicate key with differing values -> exit 2" "$([ "$RC" -eq 2 ] && echo 1 || echo 0)" "rc=$RC"
check "refusal names the ambiguity" \
      "$(printf '%s' "$OUTPUT" | grep -qi "differing values" && echo 1 || echo 0)" "$OUTPUT"

ENVF="$WORK/env-nested"
OUT="$WORK/token-nested"
mkenv "$ENVF" "\"\\\"$SECRET\\\"\""
OUTPUT="$(run_extract "$ENVF" "$OUT")"; RC=$?
check "nested quoting -> exit 2 rather than a guess" "$([ "$RC" -eq 2 ] && echo 1 || echo 0)" "rc=$RC"

ENVF="$WORK/env-ok"
OUT="$WORK/token-exists"
mkenv "$ENVF" "\"$SECRET\""
: > "$OUT"
OUTPUT="$(run_extract "$ENVF" "$OUT")"; RC=$?
check "existing destination -> exit 3 (no overwrite)" "$([ "$RC" -eq 3 ] && echo 1 || echo 0)" "rc=$RC"
check "existing destination left untouched" "$([ ! -s "$OUT" ] && echo 1 || echo 0)"

OUT="$WORK/no-such-dir/token"
OUTPUT="$(run_extract "$ENVF" "$OUT")"; RC=$?
check "missing destination directory -> exit 3" "$([ "$RC" -eq 3 ] && echo 1 || echo 0)" "rc=$RC"

OUT="$WORK/token-badkey"
OUTPUT="$("$SCRIPT" --env-file "$ENVF" --key 'EVENTKIT_*' --out "$OUT" 2>&1)"; RC=$?
check "glob in key refused -> exit 2" "$([ "$RC" -eq 2 ] && echo 1 || echo 0)" "rc=$RC"

# ---------------------------------------------------------------------------
section "the client refuses a quoted token instead of sending it"
# A quoted token would otherwise reach the bridge and come back as 401, which
# looks like a revoked credential. The client must reject it locally, exit 2,
# and say what is wrong.
OUT="$WORK/token-for-client"
mkenv "$WORK/env-quoted" "\"$SECRET\""
cp "$WORK/token-quoted" "$OUT" 2>/dev/null || true
printf '"%s"\n' "$SECRET" > "$OUT"
chmod 600 "$OUT"
CLIENT_DIR="$HERE/.."
OUTPUT="$(cd "$CLIENT_DIR" && python3 -c '
import sys
sys.path.insert(0, ".")
import r1_bridge_client as c
try:
    c.read_token(sys.argv[1])
except c.TokenFileError as exc:
    print("TokenFileError:", exc)
    raise SystemExit(2)
except Exception as exc:  # noqa: BLE001
    print("wrong exception:", type(exc).__name__, exc)
    raise SystemExit(9)
raise SystemExit(0)
' "$OUT" 2>&1)"; RC=$?
check "quoted token file -> TokenFileError, exit 2" "$([ "$RC" -eq 2 ] && echo 1 || echo 0)" "rc=$RC $OUTPUT"
check "message names the quoting cause" \
      "$(printf '%s' "$OUTPUT" | grep -qi "quotes" && echo 1 || echo 0)" "$OUTPUT"

# And the normalised file the extractor produces must be accepted.
OUTPUT="$(cd "$CLIENT_DIR" && python3 -c '
import sys
sys.path.insert(0, ".")
import r1_bridge_client as c
print("accepted:", len(c.read_token(sys.argv[1])))
' "$WORK/token-quoted" 2>&1)"; RC=$?
check "extractor output accepted by the client" "$([ "$RC" -eq 0 ] && echo 1 || echo 0)" "rc=$RC $OUTPUT"

# ---------------------------------------------------------------------------
echo
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
