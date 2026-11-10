#!/usr/bin/env bash
# r1_window.sh — bounded, self-closing read-only capture window on MAC-1.
#
# Design rules (enforced below, not just documented):
#  1. Nothing changes before the independent watchdog is armed and verified.
#  2. The gate is opened only after: binary hash + signature check, health that
#     reports a production store, a static single-target/binding check, and a
#     live confirmation that the business endpoint is currently 403.
#  3. Every command's exit status is checked. "capture completed", "field
#     assertions passed" and "restore verified" are three separate verdicts and
#     are never collapsed into one success.
#  4. Restore always runs - on success, on failure, on interrupt - and a failed
#     restore exits non-zero with the real state written to disk.
#  5. Nothing secret is passed on a command line: the token is read from a 0600
#     file by the client.
#
# Usage
#   r1_window.sh --list-id ID --expect-title T --expect-notes N --expect-due-utc U
#                --token-file F --plist P --config-file C --work-dir D
#                [--endpoint http://127.0.0.1:18765] [--passes 2] [--interval 60]
#                [--window-seconds 1800] [--open-budget 180]
#                [--expect presence|absence] [--label r1] [--confirm]
#
#   --expect presence (default)  the synthetic item must be readable and exact
#   --expect absence             the list must be empty again after cleanup
#
# Exit codes
#   0  window complete: capture done, fidelity asserted, restore verified
#   2  usage / argument error (nothing changed)
#  10  preflight failed (nothing changed)
#  11  gate open or reload failed (restore attempted; see state files)
#  12  capture or fidelity failed (restore verified)
#  13  RESTORE FAILED - manual action required, state preserved
#  15  capture could not complete (transport/shape), restore verified
#  16  window truncated by its own deadline or by the watchdog firing; restore
#      verified, but a truncated window is never reported as success

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLIENT="$HERE/r1_bridge_client.py"
GATE="$HERE/r1_gate.sh"
WATCHDOG="$HERE/r1_watchdog.sh"

PYTHON="${PYTHON_BIN:-python3}"
SHASUM_BIN="${SHASUM_BIN:-shasum}"
CODESIGN_BIN="${CODESIGN_BIN:-codesign}"

LIST_ID=""; TITLE=""; NOTES=""; DUE_UTC=""; TOKEN_FILE=""
PLIST=""; CONFIG_FILE=""; ENDPOINT="http://127.0.0.1:18765"
WORK_ROOT=""; PASSES=2; INTERVAL=60; WINDOW_SECONDS=1800; OPEN_BUDGET=180
LABEL="r1"; CONFIRM=0; EXPECT="presence"
RESTORE_ATTEMPTS="${R1_RESTORE_ATTEMPTS:-2}"
BIN="${BIN:-/Users/shared/bin/EventKitBridgeServer}"
FROZEN_SHA256="${FROZEN_SHA256:-f78e24e533c2bf9a77161dc05eb154ce99687de9a5b881ad481bfbe2bbfb3074}"

while [ $# -gt 0 ]; do
  case "$1" in
    --list-id) LIST_ID="$2"; shift 2 ;;
    --expect-title) TITLE="$2"; shift 2 ;;
    --expect-notes) NOTES="$2"; shift 2 ;;
    --expect-due-utc) DUE_UTC="$2"; shift 2 ;;
    --token-file) TOKEN_FILE="$2"; shift 2 ;;
    --plist) PLIST="$2"; shift 2 ;;
    --config-file) CONFIG_FILE="$2"; shift 2 ;;
    --endpoint) ENDPOINT="$2"; shift 2 ;;
    --work-dir) WORK_ROOT="$2"; shift 2 ;;
    --passes) PASSES="$2"; shift 2 ;;
    --interval) INTERVAL="$2"; shift 2 ;;
    --window-seconds) WINDOW_SECONDS="$2"; shift 2 ;;
    --open-budget) OPEN_BUDGET="$2"; shift 2 ;;
    --label) LABEL="$2"; shift 2 ;;
    --expect) EXPECT="$2"; shift 2 ;;
    --confirm) CONFIRM=1; shift ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

die() { echo "PRECONDITION_FAIL[$1]: $2" >&2; exit "${3:-10}"; }

[ -n "$LIST_ID" ] || die args "--list-id required" 2
[ -n "$TITLE" ] || die args "--expect-title required" 2
[ -n "$NOTES" ] || die args "--expect-notes required" 2
[ -n "$DUE_UTC" ] || die args "--expect-due-utc required" 2
[ -n "$TOKEN_FILE" ] || die args "--token-file required" 2
[ -n "$PLIST" ] || die args "--plist required" 2
[ -n "$CONFIG_FILE" ] || die args "--config-file required" 2
[ -n "$WORK_ROOT" ] || die args "--work-dir required" 2
case "$EXPECT" in
  presence|absence) : ;;
  *) die args "--expect must be presence or absence" 2 ;;
esac

# ---------------------------------------------------------------- preflight
echo "== R1 window preflight =="
command -v "$PYTHON" >/dev/null 2>&1 || die tools "python3 not available"
for f in "$CLIENT" "$GATE" "$WATCHDOG"; do [ -f "$f" ] || die tools "missing $f"; done
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

RUN_DIR="$WORK_ROOT/window-$(date -u +%Y%m%dT%H%M%SZ)-$LABEL"
[ -e "$RUN_DIR" ] && die evidence "run directory already exists: $RUN_DIR"
mkdir -p "$RUN_DIR" && chmod 700 "$RUN_DIR"
STATE="$RUN_DIR/state"; mkdir -p "$STATE" && chmod 700 "$STATE"
echo "  run dir     : $RUN_DIR"

HEALTH="$STATE/health_before.json"
"$PYTHON" "$CLIENT" health --endpoint "$ENDPOINT" --out "$HEALTH" >/dev/null 2>&1 \
  || die health "bridge health unacceptable (see $HEALTH)"
echo "  health      : production store confirmed"

GATE_BEFORE="$STATE/gate_before.json"
"$PYTHON" "$CLIENT" gate --endpoint "$ENDPOINT" --token-file "$TOKEN_FILE" \
  --expect 403 --out "$GATE_BEFORE" >/dev/null 2>&1 \
  || die gate "business endpoint is not 403 before the window; refusing to start"
echo "  gate        : closed (403) confirmed"

STATIC_JSON="$STATE/static_config.json"
R1_LIST_ID="$LIST_ID" R1_PLIST="$PLIST" R1_CONFIG="$CONFIG_FILE" "$PYTHON" - > "$STATIC_JSON" <<'PYEOF'
import json, os, plistlib

list_id = os.environ["R1_LIST_ID"]
plist_path = os.environ["R1_PLIST"]
config_path = os.environ["R1_CONFIG"]

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

plist_env = env_from_plist(plist_path)
config_env = env_from_config(config_path)
merged = dict(config_env)
merged.update(plist_env)  # environment wins, exactly as BridgeConfig.load does

gate_key = "EVENTKIT_BRIDGE_PRODUCTION_AUTHORIZED"
source = "launchd_env" if gate_key in plist_env else ("config_file" if gate_key in config_env else "absent")
allowed = [x.strip() for x in merged.get("EVENTKIT_BRIDGE_ALLOWED_LIST_IDS", "").split(",") if x.strip()]
binding_ok = False
for entry in merged.get("EVENTKIT_BRIDGE_BINDINGS", "").split(";"):
    parts = [p.strip() for p in entry.split(":")]
    if len(parts) == 4 and parts[0] == list_id:
        binding_ok = parts[2].lower() == "caldav" and parts[3] == "iCloud"
print(json.dumps({
    "gate_source": source,
    "gate_value": merged.get(gate_key, "false").lower(),
    "mode": merged.get("EVENTKIT_BRIDGE_MODE", ""),
    "allowed_list_count": len(allowed),
    "allowed_list_matches_target": allowed == [list_id],
    "binding_present_and_caldav_icloud": binding_ok,
    "port": merged.get("EVENTKIT_BRIDGE_PORT", "18765"),
}, ensure_ascii=False))
PYEOF
[ -s "$STATIC_JSON" ] || die static "could not evaluate static configuration"

"$PYTHON" - "$STATIC_JSON" <<'PYEOF' || die static "single-target/binding check failed (see static_config.json)"
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
problems = []
if d["gate_value"] == "true":
    problems.append("gate is already true before the window")
if str(d["mode"]).upper() != "PRODUCTION":
    problems.append(f"bridge mode is {d['mode']!r}, expected PRODUCTION")
if not d["allowed_list_matches_target"]:
    problems.append(f"allowlist is not exactly the one bound list (count={d['allowed_list_count']})")
if not d["binding_present_and_caldav_icloud"]:
    problems.append("no calDAV/iCloud binding for the target list id")
if problems:
    print("STATIC_CHECK_FAIL: " + "; ".join(problems), file=sys.stderr)
    sys.exit(1)
print("  static      : gate_source=%s mode=PRODUCTION single target, binding ok" % d["gate_source"])
PYEOF

PID_BEFORE="$(pgrep -x EventKitBridgeServer 2>/dev/null | head -1 || true)"
PID_COUNT="$(pgrep -x EventKitBridgeServer 2>/dev/null | wc -l | tr -d ' ')"
[ "$PID_COUNT" = "1" ] || die process "expected exactly one EventKitBridgeServer process, found $PID_COUNT"
LSTART_BEFORE="$(ps -p "$PID_BEFORE" -o lstart= 2>/dev/null | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
echo "  process     : pid=$PID_BEFORE lstart='$LSTART_BEFORE'"

echo "== plan =="
echo "  passes=$PASSES interval=${INTERVAL}s window=${WINDOW_SECONDS}s open_budget=${OPEN_BUDGET}s expect=$EXPECT"
if [ "$CONFIRM" -ne 1 ]; then
  echo "DRY RUN: preflight passed, nothing was changed. Re-run with --confirm inside the approved window."
  exit 0
fi

# ---------------------------------------------------------------- watchdog first
DEADLINE=$(( $(date +%s) + WINDOW_SECONDS ))
echo "== arming watchdog (before any change) =="
# macOS ships no setsid; nohup + disown detaches the watchdog from this shell so
# a crash or SIGKILL of this script cannot take the deadline protection with it.
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

CAPTURE_OK=0; FIDELITY_OK=0; RESTORE_OK=0; CAPTURE_RC_SUMMARY=""
CLEANUP_OK=0; ASSERT_OK=0
TRUNCATED=0; PASSES_DONE=0
PASS_RAN=0; PASS_CLEAN=0

# The summary is written on EVERY exit path, including an open failure and an
# interrupt. Exiting with a bare code and no summary was an evidence gap: the
# operator could not tell "never opened" from "opened, capture failed, restore
# also failed" without reading three separate state files.
write_summary() {
  PID_AFTER="$(pgrep -x EventKitBridgeServer 2>/dev/null | head -1 || true)"
  CAPTURE_VERDICT="FAIL"; [ "$CAPTURE_OK" -eq 1 ] && CAPTURE_VERDICT="COMPLETED"
  if [ "$EXPECT" = "presence" ]; then
    FIDELITY_VERDICT="FAIL"; [ "$FIDELITY_OK" -eq 1 ] && FIDELITY_VERDICT="ASSERTED"
    ASSERT_OK="$FIDELITY_OK"
  else
    FIDELITY_VERDICT="CLEANUP_FAILED"; [ "$CLEANUP_OK" -eq 1 ] && FIDELITY_VERDICT="CLEANUP_ASSERTED"
    ASSERT_OK="$CLEANUP_OK"
  fi
  RESTORE_VERDICT="FAILED"; [ "$RESTORE_OK" -eq 1 ] && RESTORE_VERDICT="VERIFIED"
  R1_TRUNCATED="$TRUNCATED" R1_PASSES_DONE="$PASSES_DONE" R1_PASSES_PLANNED="$PASSES" \
  R1_EXPECT="$EXPECT" R1_PASS_RAN="$PASS_RAN" R1_PASS_CLEAN="$PASS_CLEAN" \
  "$PYTHON" - "$RUN_DIR" "$CAPTURE_VERDICT" "$FIDELITY_VERDICT" "$RESTORE_VERDICT" \
    "$CAPTURE_RC_SUMMARY" "$PID_BEFORE" "$PID_AFTER" "$DEADLINE" "${1:-}" <<'PYEOF'
import json, os, sys
run_dir, cap, fid, res, rcs, pid_before, pid_after, deadline, outcome = sys.argv[1:10]
wd = {}
status = os.path.join(run_dir, "state", "watchdog_status.env")
if os.path.exists(status):
    for line in open(status, encoding="utf-8"):
        if "=" in line:
            k, _, v = line.strip().partition("=")
            wd[k] = v
summary = {
    "receipt_type": "R1_WINDOW_SUMMARY",
    "task": "REM-R1-01",
    "window_dir": run_dir,
    "window_outcome": outcome or "COMPLETED",
    "expectation": os.environ.get("R1_EXPECT"),
    "verdicts": {
        "capture_completed": cap,
        "fidelity_asserted": fid,
        "restore_verified": res,
    },
    "capture_exit_codes": rcs.split(),
    "window_truncated": os.environ.get("R1_TRUNCATED") == "1",
    "passes_planned": int(os.environ.get("R1_PASSES_PLANNED") or 0),
    "passes_completed": int(os.environ.get("R1_PASSES_DONE") or 0),
    "passes_with_observation": int(os.environ.get("R1_PASS_RAN") or 0),
    "passes_clean": int(os.environ.get("R1_PASS_CLEAN") or 0),
    "pid_before": pid_before,
    "pid_after": pid_after,
    "process_restarted": bool(pid_before and pid_after and pid_before != pid_after),
    "deadline_epoch": int(deadline),
    "watchdog_state": wd.get("WATCHDOG_STATE"),
    "watchdog_reason": wd.get("WATCHDOG_REASON"),
    "note": "These three verdicts are independent: a completed capture with a failed "
            "restore is not a success, and asserted fidelity never implies restoration.",
}
with open(os.path.join(run_dir, "window_summary.json"), "w", encoding="utf-8") as fh:
    json.dump(summary, fh, indent=2, ensure_ascii=False)
    fh.write("\n")
print("VERDICT capture=%s fidelity=%s restore=%s" % (cap, fid, res))
PYEOF
}

open_gate() {
  date +%s > "$STATE/gate_open_since"
  chmod 600 "$STATE/gate_open_since" 2>/dev/null || true
  "$GATE" open --plist "$PLIST" --config-file "$CONFIG_FILE" \
    --token-file "$TOKEN_FILE" --endpoint "$ENDPOINT" \
    --out "$STATE/gate_open.json" --purpose "window:$LABEL:open"
}

# Restore is bounded, verified, and never disarms the protection it depends on.
# The old version removed gate_open_since first and wrote the stop file whether
# or not the close had been verified, which both stopped the open-budget clock
# while the gate could still be open and told the watchdog its job was done.
finish() {
  local attempt=1 rc=0 out="$STATE/gate_close.json"
  RESTORE_OK=0
  while [ "$attempt" -le "$RESTORE_ATTEMPTS" ]; do
    [ "$attempt" -gt 1 ] && out="$STATE/gate_close_retry$((attempt - 1)).json"
    "$GATE" close --plist "$PLIST" --config-file "$CONFIG_FILE" \
      --token-file "$TOKEN_FILE" --endpoint "$ENDPOINT" \
      --out "$out" --purpose "window:$LABEL:close" --lock-wait 15 \
      >>"$RUN_DIR/window.log" 2>&1
    rc=$?
    if [ "$rc" -eq 0 ]; then RESTORE_OK=1; break; fi
    echo "[window] close attempt $attempt not verified (rc=$rc); see $out" >&2
    attempt=$((attempt + 1))
  done

  if [ "$RESTORE_OK" -eq 1 ]; then
    # Only now is it safe to stop the budget clock and disarm the watchdog.
    rm -f "$STATE/gate_open_since"
    : > "$STATE/stop"
    sleep 1
  else
    # Keep everything armed: the deadline path is the last line of defence and
    # must still be able to close the gate after this process gives up.
    echo "[window] RESTORE NOT VERIFIED after $RESTORE_ATTEMPTS attempts; watchdog left armed, gate_open_since kept, no stop file written" >&2
  fi
}

on_signal() {
  echo "[window] interrupted, restoring" >&2
  finish
  write_summary INTERRUPTED
  exit 13
}
trap on_signal INT TERM

echo "== opening gate =="
open_gate >>"$RUN_DIR/window.log" 2>&1
OPEN_RC=$?
if [ "$OPEN_RC" -ne 0 ]; then
  echo "OPEN_FAILED rc=$OPEN_RC; restoring" >&2
  finish
  write_summary OPEN_FAILED
  if [ "$RESTORE_OK" -eq 1 ]; then exit 11; else exit 13; fi
fi
echo "  gate open   : verified 200"

for pass in $(seq 1 "$PASSES"); do
  # A window that has passed its absolute deadline must stop capturing. The
  # watchdog may already have closed the gate; continuing to read after that
  # would produce a "successful" capture from a state the authorization no
  # longer covers.
  if [ "$(date +%s)" -ge "$DEADLINE" ]; then
    TRUNCATED=1
    echo "  deadline reached before pass $pass; stopping capture" >&2
    break
  fi
  BDIR="$RUN_DIR/batch-${pass}-$LABEL"
  echo "== capture pass $pass -> $BDIR =="
  "$PYTHON" "$CLIENT" capture \
    --endpoint "$ENDPOINT" --token-file "$TOKEN_FILE" \
    --list-id "$LIST_ID" --expect-title "$TITLE" --expect-notes "$NOTES" \
    --expect-due-utc "$DUE_UTC" --expect "$EXPECT" \
    --batch-dir "$BDIR" --label "pass-$pass" >>"$RUN_DIR/window.log" 2>&1
  rc=$?
  CAPTURE_RC_SUMMARY="$CAPTURE_RC_SUMMARY $rc"
  PASSES_DONE="$pass"
  case "$rc" in
    # 0 = the expected state was observed. 20/21/22/23 = the read completed but a
    # field, uniqueness, presence or cleanup assertion failed. Anything else is a
    # transport or shape failure: that pass produced no evidence at all.
    0)           PASS_RAN=$((PASS_RAN + 1)); PASS_CLEAN=$((PASS_CLEAN + 1)) ;;
    20|21|22|23) PASS_RAN=$((PASS_RAN + 1)) ;;
    *)           : ;;
  esac
  echo "  pass $pass   : exit $rc"
  if [ "$pass" -lt "$PASSES" ]; then sleep "$INTERVAL"; fi
done

# The watchdog firing means the window no longer owns the gate: whatever was
# captured after that point happened outside the authorized state, so the
# outcome cannot be reported as success.
WD_STATE_NOW="$(awk -F= '/^WATCHDOG_STATE=/{print $2}' "$STATE/watchdog_status.env" 2>/dev/null || true)"
case "$WD_STATE_NOW" in
  FIRED_*) TRUNCATED=1; echo "  watchdog fired ($WD_STATE_NOW); the window did not complete as authorized" >&2 ;;
esac
if [ "$(date +%s)" -ge "$DEADLINE" ] && [ "$PASSES_DONE" -lt "$PASSES" ]; then
  TRUNCATED=1
fi

# Aggregate across passes. A window is only "capture completed" when every
# planned pass actually produced an observation, and only "asserted" when every
# pass observed the expected state. The previous version let one good pass
# outvote a later transport error or a duplicate, which is exactly how a batch
# that failed could still be reported as overall success.
if [ "$TRUNCATED" -eq 0 ] && [ "$PASS_RAN" -eq "$PASSES" ] && [ "$PASSES_DONE" -eq "$PASSES" ]; then
  CAPTURE_OK=1
  if [ "$PASS_CLEAN" -eq "$PASSES" ]; then
    if [ "$EXPECT" = "presence" ]; then FIDELITY_OK=1; else CLEANUP_OK=1; fi
  fi
fi
if [ "$PASS_RAN" -lt "$PASSES" ] || [ "$PASSES_DONE" -lt "$PASSES" ]; then
  echo "  aggregation : only $PASS_RAN/$PASSES passes produced an observation; not a completed capture" >&2
elif [ "$PASS_CLEAN" -lt "$PASSES" ]; then
  echo "  aggregation : $PASS_CLEAN/$PASSES passes observed the expected state; one failing pass blocks the verdict" >&2
fi

echo "== closing gate =="
finish
write_summary COMPLETED

echo "== result =="
echo "  capture     : $CAPTURE_VERDICT (rcs:$CAPTURE_RC_SUMMARY)"
echo "  fidelity    : $FIDELITY_VERDICT"
echo "  restore     : $RESTORE_VERDICT (pid $PID_BEFORE -> $PID_AFTER)"
echo "  evidence    : $RUN_DIR"
[ "$TRUNCATED" -eq 1 ] && echo "  truncated   : yes (passes $PASSES_DONE/$PASSES)"

if [ "$RESTORE_OK" -ne 1 ]; then
  echo "WINDOW_RESULT: RESTORE_FAILED - state preserved, manual action required, do not retry blindly" >&2
  exit 13
fi
if [ "$TRUNCATED" -eq 1 ]; then
  echo "WINDOW_RESULT: WINDOW_TRUNCATED_RESTORE_VERIFIED - the window ended at its deadline or lost the gate to the watchdog; this is not an authorized completion and must not be counted as evidence" >&2
  exit 16
fi
if [ "$ASSERT_OK" -eq 1 ]; then
  echo "WINDOW_RESULT: CAPTURE_OK_FIDELITY_ASSERTED_RESTORE_VERIFIED"
  exit 0
fi
if [ "$CAPTURE_OK" -eq 1 ]; then
  echo "WINDOW_RESULT: CAPTURE_OK_FIDELITY_FAILED_RESTORE_VERIFIED"
  exit 12
fi
echo "WINDOW_RESULT: CAPTURE_INCOMPLETE_RESTORE_VERIFIED"
exit 15
