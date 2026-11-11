#!/usr/bin/env bash
# r1_probe_close.sh — the only close command R1-03 issues, including the
# emergency one an operator types by hand.
#
# Why a wrapper instead of "remember to pass two flags":
#
#   r1_gate.sh close without --list-id verifies by calling /reminders/lists,
#   because that is how R1 proved the gate was shut. For R1-03 that fallback
#   must not exist, but a fallback that is merely discouraged is one typo away
#   from being taken at the worst possible moment - a restore. So the R1-03
#   close is its own command: it requires a target ID, it appends
#   --require-no-enumeration itself, and it offers no way to drop either.
#
#   The refusal happens before r1_gate.sh is executed, so a malformed emergency
#   command changes nothing: no write, no reload, no mutex, no receipt.
#
# Usage
#   r1_probe_close.sh --list-id ID --token-file T --plist P --out O
#                     [--config-file F] [--endpoint U]
#                     [--purpose TEXT] [--lock-wait SECONDS]
#                     [--op-timeout SECONDS]
#
# --op-timeout is forwarded to the gate, which uses it to bound the time this
# close spends holding the mutex. A close that runs out of time puts the key
# back to closed and exits 8; the wrapper does not swallow that code.
#
# Exit codes
#   2  refused: a required argument is missing (nothing was read or changed)
#   3  the gate script is missing (nothing changed)
#   *  whatever r1_gate.sh close returns (0 verified, 3/4/6/7/8 otherwise)

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GATE="${R1_GATE_BIN:-$HERE/r1_gate.sh}"

LIST_ID=""; TOKEN_FILE=""; PLIST=""; CONFIG_FILE=""; OUT=""
ENDPOINT="http://127.0.0.1:18765"; PURPOSE="r1-03:close"; LOCK_WAIT=15
OP_TIMEOUT="${R1_OP_TIMEOUT:-30}"

while [ $# -gt 0 ]; do
  case "$1" in
    --list-id) LIST_ID="$2"; shift 2 ;;
    --token-file) TOKEN_FILE="$2"; shift 2 ;;
    --plist) PLIST="$2"; shift 2 ;;
    --config-file) CONFIG_FILE="$2"; shift 2 ;;
    --endpoint) ENDPOINT="$2"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    --purpose) PURPOSE="$2"; shift 2 ;;
    --lock-wait) LOCK_WAIT="$2"; shift 2 ;;
    --op-timeout) OP_TIMEOUT="$2"; shift 2 ;;
    *) echo "r1_probe_close: unknown argument: $1" >&2; exit 2 ;;
  esac
done

# Every check below runs before the gate is invoked. There is deliberately no
# option that skips them and no default that guesses a target.
missing=""
[ -n "$LIST_ID" ]    || missing="$missing --list-id"
[ -n "$TOKEN_FILE" ] || missing="$missing --token-file"
[ -n "$PLIST" ]      || missing="$missing --plist"
[ -n "$OUT" ]        || missing="$missing --out"
if [ -n "$missing" ]; then
  echo "r1_probe_close: REFUSED, missing:$missing" >&2
  echo "r1_probe_close: an R1-03 close needs the bound list id; without it the" >&2
  echo "r1_probe_close: gate can only be verified by enumerating the account," >&2
  echo "r1_probe_close: which this task does not authorize. Nothing was changed." >&2
  exit 2
fi

[ -x "$GATE" ] || [ -f "$GATE" ] || {
  echo "r1_probe_close: the gate script is missing: $GATE; nothing was changed" >&2
  exit 3
}

# --require-no-enumeration is not a parameter here: it is what this command is.
exec "$GATE" close \
  --plist "$PLIST" \
  --config-file "$CONFIG_FILE" \
  --token-file "$TOKEN_FILE" \
  --endpoint "$ENDPOINT" \
  --list-id "$LIST_ID" \
  --require-no-enumeration \
  --purpose "$PURPOSE" \
  --lock-wait "$LOCK_WAIT" \
  --op-timeout "$OP_TIMEOUT" \
  --out "$OUT"
