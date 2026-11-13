#!/usr/bin/env bash
# r1_digest_window.sh — R1-04 W0-DIAG: bounded, self-closing digest-diagnostic window.
#
# Purpose
# -------
# One account-wide metadata read to resolve the new dedicated list's ID, inside
# the same gate/watchdog discipline as every other window. The gate is opened
# in legacy mode (r1_gate.sh without --list-id), whose open verification is
# itself one enumeration read; the discovery is the second read; the legacy
# close verification is the third. That is the whole account-wide budget for
# this window: exactly 3 enumeration reads, recorded in the summary.
#
#   1. legacy open      GET /reminders/lists -> 200   (gate verification)
#   2. discovery        GET /reminders/lists -> 200   (title match; r1_list_discover.py)
#   3. legacy close     GET /reminders/lists -> 403   (gate verification)
#
# A single 200 response cannot serve both the open verification and the
# candidate match: r1_gate.sh consumes the verification response internally
# (only a body digest reaches its receipt), so reuse would mean modifying the
# frozen gate client or bypassing verification. Both 200 reads are authorized
# in the application.
#
# The watchdog is armed BEFORE any change and runs WITHOUT --list-id: while the
# binding still points at the old list, a single-ID restore verification would
# misread a 404 as a failed restore. Without --list-id the watchdog's restore
# goes through the legacy r1_gate.sh close, which natively supports this mode.
#
# Sequence (mirrors r1_window.sh):
#   preflight (token 0600, frozen binary hash + signature, health, static
#   gate-false check) -> watchdog armed -> gate_open_since written -> legacy
#   open -> discover (exactly once; UNKNOWN is never retried) -> legacy close
#   on every path -> disarm only after a verified close -> summary.
#
# The discovery's private record (full listID/sourceID, 0600) is written only
# inside this window's 0700 run directory; the public receipt keeps masked
# identifiers.
#
# Exit codes
#   0   discovery completed (exact single match, source and account verified)
#  10   preflight failed (nothing changed)
#  11   gate open failed (restore attempted)
#  12   discovery failed or was inconclusive (restore verified; classification
#       in the summary - UNKNOWN, ambiguous, source or account mismatch)
#  13   RESTORE FAILED - manual action required, state preserved
#  16   window truncated by its own deadline or by the watchdog firing; restore
#       verified, but a truncated window is never reported as success

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISCOVER="$HERE/r1_title_digest_diag.py"
GATE="$HERE/r1_gate.sh"
WATCHDOG="$HERE/r1_watchdog.sh"

PYTHON="${PYTHON_BIN:-python3}"
SHASUM_BIN="${SHASUM_BIN:-shasum}"
CODESIGN_BIN="${CODESIGN_BIN:-codesign}"

TITLE=""; TOKEN_FILE=""; PLIST=""; CONFIG_FILE=""; ENDPOINT="http://127.0.0.1:18765"
WORK_ROOT=""; WINDOW_SECONDS=900; OPEN_BUDGET=180; LABEL="r1-04-w0"; CONFIRM=0
EXPECT_SOURCE_ID=""
BIN="${BIN:-/Users/shared/bin/EventKitBridgeServer}"
FROZEN_SHA256="${FROZEN_SHA256:-f78e24e533c2bf9a77161dc05eb154ce99687de9a5b881ad481bfbe2bbfb3074}"

while [ $# -gt 0 ]; do
  case "$1" in
    --title) TITLE="$2"; shift 2 ;;
    --expect-source-id) EXPECT_SOURCE_ID="$2"; shift 2 ;;
    --token-file) TOKEN_FILE="$2"; shift 2 ;;
    --plist) PLIST="$2"; shift 2 ;;
    --config-file) CONFIG_FILE="$2"; shift 2 ;;
    --endpoint) ENDPOINT="$2"; shift 2 ;;
    --work-dir) WORK_ROOT="$2"; shift 2 ;;
    --window-seconds) WINDOW_SECONDS="$2"; shift 2 ;;
    --open-budget) OPEN_BUDGET="$2"; shift 2 ;;
    --label) LABEL="$2"; shift 2 ;;
    --confirm) CONFIRM=1; shift ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

die() { echo "PRECONDITION_FAIL[$1]: $2" >&2; exit "${3:-10}"; }

[ -n "$TITLE" ] || die args "--title required" 2
[ -n "$TOKEN_FILE" ] || die args "--token-file required" 2
[ -n "$PLIST" ] || die args "--plist required" 2
[ -n "$CONFIG_FILE" ] || die args "--config-file required" 2
[ -n "$WORK_ROOT" ] || die args "--work-dir required" 2

# ---------------------------------------------------------------- preflight
echo "== R1-04 digest-diagnostic window preflight =="
command -v "$PYTHON" >/dev/null 2>&1 || die tools "python3 not available"
for f in "$DISCOVER" "$GATE" "$WATCHDOG"; do [ -f "$f" ] || die tools "missing $f"; done
[ -f "$PLIST" ] || die plist "not found: $PLIST"
[ -f "$CONFIG_FILE" ] || die config "not found: $CONFIG_FILE"
[ -f "$TOKEN_FILE" ] || die token "not found: $TOKEN_FILE"
PERM="$("$PYTHON" -c 'import os,sys;print(oct(os.stat(sys.argv[1]).st_mode & 0o777))' "$TOKEN_FILE")"
[ "$PERM" = "0o600" ] || die token "permissions $PERM, expected 0o600"

ACTUAL_SHA="$("$SHASUM_BIN" -a 256 "$BIN" 2>/dev/null | awk '{print $1}')"
[ "$ACTUAL_SHA" = "$FROZEN_SHA256" ] || die binary "sha256 $ACTUAL_SHA != frozen $FROZEN_SHA256"
"$CODESIGN_BIN" --verify --strict --all-architectures "$BIN" >/dev/null 2>&1 \
  || die binary "codesign verification failed; refusing to open the gate for an unverified binary"
echo "  binary      : $ACTUAL_SHA (frozen match), signature VALID"

probe_writable() {  # $1 = dir, $2 = what to call it in the message
  local probe="$1/.r1-write-probe.$$"
  if ! : > "$probe" 2>/dev/null; then
    die evidence "$2 is not writable: $1" 17
  fi
  rm -f "$probe" 2>/dev/null || true
}

if [ ! -e "$WORK_ROOT" ]; then
  WORK_PARENT="$(dirname "$WORK_ROOT")"
  [ -d "$WORK_PARENT" ] || die evidence "parent of --work-dir does not exist: $WORK_PARENT (refusing to invent a tree)" 17
  mkdir "$WORK_ROOT" 2>/dev/null || die evidence "cannot create --work-dir: $WORK_ROOT" 17
  chmod 700 "$WORK_ROOT" 2>/dev/null || die evidence "cannot restrict --work-dir to 0700: $WORK_ROOT" 17
elif [ ! -d "$WORK_ROOT" ]; then
  die evidence "--work-dir is not a directory: $WORK_ROOT" 17
fi
probe_writable "$WORK_ROOT" "--work-dir"

RUN_DIR="$WORK_ROOT/digest-$(date -u +%Y%m%dT%H%M%SZ)-$LABEL"
[ -e "$RUN_DIR" ] && die evidence "run directory already exists: $RUN_DIR" 17
mkdir "$RUN_DIR" 2>/dev/null || die evidence "cannot create the run directory: $RUN_DIR" 17
chmod 700 "$RUN_DIR" 2>/dev/null || die evidence "cannot restrict the run directory to 0700: $RUN_DIR" 17
probe_writable "$RUN_DIR" "run directory"
STATE="$RUN_DIR/state"
mkdir "$STATE" 2>/dev/null || die evidence "cannot create the state directory: $STATE" 17
chmod 700 "$STATE" 2>/dev/null || die evidence "cannot restrict the state directory to 0700: $STATE" 17
probe_writable "$STATE" "state directory"
echo "  run dir     : $RUN_DIR (0700, write-verified)"

HEALTH="$STATE/health_before.json"
"$PYTHON" "$HERE/r1_bridge_client.py" health --endpoint "$ENDPOINT" --out "$HEALTH" >/dev/null 2>&1 \
  || die health "bridge health unacceptable (see $HEALTH)"
echo "  health      : production store confirmed"

# Static gate-false check. No live 403 probe here: a live check would be a
# fourth account-wide read, outside the 3-read budget recorded in the
# application. The legacy open's 200 verification is the live proof instead.
STATIC_JSON="$STATE/static_config.json"
R1_PLIST="$PLIST" R1_CONFIG="$CONFIG_FILE" "$PYTHON" - > "$STATIC_JSON" <<'PYEOF'
import json, os, plistlib

def env_from_plist(path):
    try:
        with open(path, "rb") as fh:
            data = plistlib.load(fh)
        return {k: str(v) for k, v in (data.get("EnvironmentVariables") or {}).items()}
    except Exception:
        return {}

def env_from_config(path):
    out = {}
    try:
        with open(path, encoding="utf-8") as fh:
            for line in fh:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                key, _, value = line.partition("=")
                out[key.strip()] = value.strip().strip('"').strip("'")
    except Exception:
        pass
    return out

plist_env = env_from_plist(os.environ["R1_PLIST"])
config_env = env_from_config(os.environ["R1_CONFIG"])
merged = dict(config_env)
merged.update(plist_env)

gate_key = "EVENTKIT_BRIDGE_PRODUCTION_AUTHORIZED"
source = "launchd_env" if gate_key in plist_env else ("config_file" if gate_key in config_env else "absent")
print(json.dumps({
    "gate_source": source,
    "gate_value": merged.get(gate_key, "false").lower(),
    "mode": merged.get("EVENTKIT_BRIDGE_MODE", ""),
}, ensure_ascii=False))
PYEOF
[ -s "$STATIC_JSON" ] || die static "could not evaluate static configuration"

"$PYTHON" - "$STATIC_JSON" <<'PYEOF' || die static "static gate-false check failed (see static_config.json)"
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
problems = []
if d["gate_value"] == "true":
    problems.append("gate is already true before the window")
if str(d["mode"]).upper() != "PRODUCTION":
    problems.append(f"bridge mode is {d['mode']!r}, expected PRODUCTION")
if problems:
    print("STATIC_CHECK_FAIL: " + "; ".join(problems), file=sys.stderr)
    sys.exit(1)
print("  static      : gate_source=%s gate=false, mode=PRODUCTION" % d["gate_source"])
PYEOF

echo "== plan =="
echo "  reads: legacy open verify (1) + digest diag (1) + legacy close verify (1) = 3 account-wide reads"
echo "  match: title='$TITLE' source=calDAV/iCloud expect_source_id=$([ -n "$EXPECT_SOURCE_ID" ] && echo 'yes (from the existing binding)' || echo 'not provided')"
if [ "$CONFIRM" -ne 1 ]; then
  echo "DRY RUN: preflight passed, no gate operation was performed; preflight evidence kept in $RUN_DIR"
  echo "         re-run with --confirm inside the approved window"
  exit 0
fi

# ---------------------------------------------------------------- watchdog first
DEADLINE=$(( $(date +%s) + WINDOW_SECONDS ))
echo "== arming watchdog (before any change; legacy restore, no --list-id) =="
nohup "$WATCHDOG" \
  --state-dir "$STATE" \
  --deadline-epoch "$DEADLINE" \
  --open-budget "$OPEN_BUDGET" \
  --plist "$PLIST" \
  --config-file "$CONFIG_FILE" \
  --token-file "$TOKEN_FILE" \
  --endpoint "$ENDPOINT" \
  --poll 2 >/dev/null 2>&1 &
disown 2>/dev/null || true
sleep 1
[ -f "$STATE/watchdog.pid" ] || die watchdog "watchdog did not publish its pid"
ACTUAL_WPID="$(cat "$STATE/watchdog.pid")"
kill -0 "$ACTUAL_WPID" 2>/dev/null || die watchdog "watchdog $ACTUAL_WPID is not alive"
grep -q "^WATCHDOG_DEADLINE_EPOCH=$DEADLINE$" "$STATE/watchdog_meta.env" 2>/dev/null \
  || die watchdog "watchdog deadline metadata mismatch"
echo "  watchdog    : pid=$ACTUAL_WPID deadline=$DEADLINE budget=${OPEN_BUDGET}s verified alive"

DISCOVERED=0; RESTORE_OK=0; DISCOVER_RC=""; DISCOVER_OUTCOME="NOT_RUN"; TRUNCATED=0

write_summary() {
  PID_AFTER="$(pgrep -x EventKitBridgeServer 2>/dev/null | head -1 || true)"
  RESTORE_VERDICT="FAILED"; [ "$RESTORE_OK" -eq 1 ] && RESTORE_VERDICT="VERIFIED"
  R1_DISCOVER_RC="$DISCOVER_RC" R1_OUTCOME="$DISCOVER_OUTCOME" \
  R1_TRUNCATED="$TRUNCATED" R1_DEADLINE="$DEADLINE" \
  "$PYTHON" - "$RUN_DIR" "$RESTORE_VERDICT" "${1:-}" <<'PYEOF'
import json, os, sys
run_dir, restore, outcome = sys.argv[1:4]
wd = {}
status = os.path.join(run_dir, "state", "watchdog_status.env")
if os.path.exists(status):
    for line in open(status, encoding="utf-8"):
        if "=" in line:
            k, _, v = line.strip().partition("=")
            wd[k] = v
summary = {
    "receipt_type": "R1_04_DIGEST_DIAG_WINDOW_SUMMARY",
    "task": "REM-R1-01",
    "step": "R1-04/W0-DIAG",
    "window_dir": run_dir,
    "window_outcome": outcome,
    "discovery_exit_code": os.environ.get("R1_DISCOVER_RC"),
    "discovery_outcome": os.environ.get("R1_OUTCOME"),
    "restore_verified": restore == "VERIFIED",
    "window_truncated": os.environ.get("R1_TRUNCATED") == "1",
    "deadline_epoch": int(os.environ.get("R1_DEADLINE") or 0),
    "watchdog_state": wd.get("WATCHDOG_STATE"),
    "watchdog_reason": wd.get("WATCHDOG_REASON"),
    "account_wide_reads_budget": 3,
    "account_wide_reads": {
        "open_verification": "GET /reminders/lists -> 200",
        "discovery": "GET /reminders/lists -> 200 (only on a verified open)",
        "close_verification": "GET /reminders/lists -> 403 observed",
    },
    "private_record": os.path.join(run_dir, "state", "discovered_binding.json"),
    "note": "UNKNOWN discovery results are read-only and are never retried inside "
            "this window; the close runs on every path, before any verdict.",
}
with open(os.path.join(run_dir, "digest_summary.json"), "w", encoding="utf-8") as fh:
    json.dump(summary, fh, indent=2, ensure_ascii=False)
    fh.write("\n")
print("VERDICT discovery=%s restore=%s" % (os.environ.get("R1_OUTCOME"), restore))
PYEOF
}

open_gate() {
  date +%s > "$STATE/gate_open_since"
  chmod 600 "$STATE/gate_open_since" 2>/dev/null || true
  # Legacy mode on purpose: no --list-id. The binding still points at the old
  # list; the legacy verification reads the enumeration endpoint (read 1/3).
  "$GATE" open --plist "$PLIST" --config-file "$CONFIG_FILE" \
    --token-file "$TOKEN_FILE" --endpoint "$ENDPOINT" \
    --out "$STATE/gate_open.json" --purpose "discover-window:$LABEL:open"
}

finish() {
  local attempt=1 rc=0 out="$STATE/gate_close.json" max="${R1_RESTORE_ATTEMPTS:-2}"
  RESTORE_OK=0
  while [ "$attempt" -le "$max" ]; do
    [ "$attempt" -gt 1 ] && out="$STATE/gate_close_retry$((attempt - 1)).json"
    # Legacy close (no --list-id): this is the entry that actually supports the
    # enumeration-based verification this window was opened with.
    "$GATE" close --plist "$PLIST" --config-file "$CONFIG_FILE" \
      --token-file "$TOKEN_FILE" --endpoint "$ENDPOINT" \
      --out "$out" --purpose "discover-window:$LABEL:close" --lock-wait 15 \
      >>"$RUN_DIR/digest.log" 2>&1
    rc=$?
    if [ "$rc" -eq 0 ]; then RESTORE_OK=1; break; fi
    echo "[discover-window] close attempt $attempt not verified (rc=$rc); see $out" >&2
    attempt=$((attempt + 1))
  done
  if [ "$RESTORE_OK" -eq 1 ]; then
    rm -f "$STATE/gate_open_since"
    : > "$STATE/stop"
    sleep 1
  else
    echo "[discover-window] RESTORE NOT VERIFIED after $max attempts; watchdog left armed, gate_open_since kept, no stop file written" >&2
  fi
}

on_signal() {
  echo "[discover-window] interrupted, restoring" >&2
  finish
  write_summary INTERRUPTED
  exit 13
}
trap on_signal INT TERM

echo "== opening gate (legacy) =="
open_gate >>"$RUN_DIR/digest.log" 2>&1
OPEN_RC=$?
if [ "$OPEN_RC" -ne 0 ]; then
  echo "OPEN_FAILED rc=$OPEN_RC; restoring" >&2
  finish
  write_summary OPEN_FAILED
  if [ "$RESTORE_OK" -eq 1 ]; then exit 11; else exit 13; fi
fi
echo "  gate open   : verified 200 (read 1/3)"

echo "== digest diagnostic (read 2/3; exactly once) =="
PRIV="$STATE/diag_binding_digest.json"
PUB="$STATE/digest_receipt.json"
DISCOVER_ARGS=(--endpoint "$ENDPOINT" --token-file "$TOKEN_FILE"
               --title "$TITLE" --private-out "$PRIV" --out "$PUB")
[ -n "$EXPECT_SOURCE_ID" ] && DISCOVER_ARGS+=(--expect-source-id "$EXPECT_SOURCE_ID")
"$PYTHON" "$DISCOVER" "${DISCOVER_ARGS[@]}" >>"$RUN_DIR/digest.log" 2>&1
DISCOVER_RC=$?
case "$DISCOVER_RC" in
  0)  DISCOVER_OUTCOME="DISCOVERED" ;;
  40) DISCOVER_OUTCOME="UNKNOWN_ZERO_CANDIDATES" ;;
  41) DISCOVER_OUTCOME="AMBIGUOUS_MULTIPLE_CANDIDATES" ;;
  42) DISCOVER_OUTCOME="SOURCE_TYPE_MISMATCH" ;;
  43) DISCOVER_OUTCOME="ACCOUNT_MISMATCH" ;;
  *)  DISCOVER_OUTCOME="DISCOVER_FAILED" ;;
esac
if [ "$DISCOVER_RC" -eq 0 ]; then
  DISCOVERED=1
  echo "  digest diag  : DISCOVERED (private record: $PRIV)"
else
  echo "  digest diag  : $DISCOVER_OUTCOME (exit $DISCOVER_RC) - no retry inside this window" >&2
fi

WD_STATE_NOW="$(awk -F= '/^WATCHDOG_STATE=/{print $2}' "$STATE/watchdog_status.env" 2>/dev/null || true)"
case "$WD_STATE_NOW" in
  FIRED_*) TRUNCATED=1; echo "  watchdog fired ($WD_STATE_NOW); the window did not complete as authorized" >&2 ;;
esac
if [ "$(date +%s)" -ge "$DEADLINE" ]; then
  TRUNCATED=1
fi

echo "== closing gate (legacy) =="
finish
write_summary COMPLETED

echo "== result =="
echo "  digest diag  : $DISCOVER_OUTCOME (exit $DISCOVER_RC)"
echo "  restore     : $RESTORE_VERDICT"
echo "  evidence    : $RUN_DIR"

if [ "$RESTORE_OK" -ne 1 ]; then
  echo "DISCOVER_WINDOW_RESULT: RESTORE_FAILED - state preserved, manual action required" >&2
  exit 13
fi
if [ "$TRUNCATED" -eq 1 ]; then
  echo "DISCOVER_WINDOW_RESULT: WINDOW_TRUNCATED_RESTORE_VERIFIED - not an authorized completion" >&2
  exit 16
fi
if [ "$DISCOVERED" -eq 1 ]; then
  echo "DISCOVER_WINDOW_RESULT: DISCOVERED_RESTORE_VERIFIED"
  exit 0
fi
echo "DISCOVER_WINDOW_RESULT: DISCOVERY_INCONCLUSIVE_RESTORE_VERIFIED"
exit 12
