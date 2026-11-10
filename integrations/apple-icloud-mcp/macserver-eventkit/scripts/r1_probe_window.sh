#!/usr/bin/env bash
# r1_probe_window.sh — bounded window that resolves ONE bound ID. Enumerates nothing.
#
# This is the R1-03 counterpart of r1_window.sh. The difference is the question:
# r1_window.sh captured a synthetic item and compared fields; this one asks only
# whether the bound identifier still resolves, and whether its source identity
# still matches the registered binding. It therefore needs no synthetic item, no
# field expectations, and no second pass.
#
# Both windows reuse the same gate and watchdog plumbing, unchanged in spirit:
#   * r1_gate.sh is the single place that opens or closes the gate: one mutex,
#     one authoritative-source decision, unconditional verification by observed
#     behaviour. This window passes --list-id, which switches that verification
#     to the item endpoint, so the open, the close and the watchdog's restore all
#     avoid /reminders/lists.
#   * every close - normal, failed-open, and the one an operator types by hand -
#     goes through r1_probe_close.sh, which refuses to run without a target ID
#     and appends --require-no-enumeration itself.
#   * r1_watchdog.sh enforces the absolute deadline and the cumulative open
#     budget, and refuses to report a restore it could not verify.
#
# Request budget (nothing else is ever sent):
#   normal path
#     pre : 1 /health + 1 canary item + 1 target item
#     open: 1 target item   (the gate operation's own verification)
#     post: 1 target item   (the close operation's own verification)
#   restore budget (bounded, only on the failure paths)
#     <= R1_RESTORE_ATTEMPTS further close probes, one item request each
#   A restore never sends an open-phase probe: it closes, it does not re-ask the
#   question the window was built to ask.
#
# The canary runs once, in the pre phase. That is where the allowlist claim is
# established; repeating it at open and close would add two requests without
# adding information, because neither gate operation touches the allowlist.
#
# Ordering rules that are load-bearing (see 7.3.1 of the application):
#   * the open-budget stamp is written BEFORE the gate changes, never after the
#     open request returns - otherwise a blocked open is free of charge;
#   * a restore that cannot be verified does NOT disarm the watchdog, write its
#     stop file, or drop the budget stamp: the only thing left protecting the
#     gate is the deadline it is still holding;
#   * an interrupted window is never reported as a completed one.
#
# Usage
#   r1_probe_window.sh --list-id ID --token-file F --plist P
#                      --work-dir D [--config-file C] [--canary-id CID]
#                      [--endpoint http://127.0.0.1:18765]
#                      [--window-seconds 300] [--open-budget 120]
#                      [--label r103] [--confirm]
#
# Exit codes
#   0  window complete: probe result recorded, restore verified
#   2  usage / argument error (nothing changed)
#   10 preflight failed (nothing changed)
#   11 gate open failed or its verification failed (restore attempted)
#   12 open succeeded but produced no classification (restore attempted)
#   13 RESTORE FAILED - manual action required, state preserved
#   16 truncated by deadline, watchdog or signal; restore verified

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLIENT="$HERE/r1_bridge_client.py"
GATE="$HERE/r1_gate.sh"
CLOSE="$HERE/r1_probe_close.sh"
WATCHDOG="$HERE/r1_watchdog.sh"

PYTHON="${PYTHON_BIN:-python3}"
SHASUM_BIN="${SHASUM_BIN:-shasum}"
CODESIGN_BIN="${CODESIGN_BIN:-codesign}"
BIN="${BIN:-/Users/shared/bin/EventKitBridgeServer}"
FROZEN_SHA256="${FROZEN_SHA256:-f78e24e533c2bf9a77161dc05eb154ce99687de9a5b881ad481bfbe2bbfb3074}"

LIST_ID=""; TOKEN_FILE=""; PLIST=""; CONFIG_FILE=""; WORK_ROOT=""
CANARY_ID=""; ENDPOINT="http://127.0.0.1:18765"
WINDOW_SECONDS=300; OPEN_BUDGET=120; LABEL="r103"; CONFIRM=0
RESTORE_ATTEMPTS="${R1_RESTORE_ATTEMPTS:-2}"
RESTORE_DELAY="${R1_RESTORE_DELAY:-2}"

while [ $# -gt 0 ]; do
  case "$1" in
    --list-id) LIST_ID="$2"; shift 2 ;;
    --canary-id) CANARY_ID="$2"; shift 2 ;;
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

# Installed before anything can take time, because the window must be able to
# say "I was interrupted" no matter where the signal lands. Bash defers a trap
# until the foreground command returns, so the flag is read at the checkpoints
# below rather than acted on inside the handler.
INTERRUPTED=0
trap 'INTERRUPTED=1; echo "[window] signal received; the window will be reported as truncated" >&2' INT TERM

[ -n "$LIST_ID" ] || die args "--list-id required" 2
[ -n "$TOKEN_FILE" ] || die args "--token-file required" 2
[ -n "$PLIST" ] || die args "--plist required" 2
[ -n "$WORK_ROOT" ] || die args "--work-dir required" 2
case "$WINDOW_SECONDS$OPEN_BUDGET" in
  *[!0-9]*) die args "--window-seconds and --open-budget must be integers" 2 ;;
esac
[ "$OPEN_BUDGET" -lt "$WINDOW_SECONDS" ] \
  || die args "--open-budget ($OPEN_BUDGET) must be smaller than the window ($WINDOW_SECONDS)" 2

# ---------------------------------------------------------------- preflight
echo "== R1-03 probe window preflight =="
command -v "$PYTHON" >/dev/null 2>&1 || die tools "python3 not available"
for f in "$CLIENT" "$GATE" "$CLOSE" "$WATCHDOG"; do [ -f "$f" ] || die tools "missing $f"; done
[ -f "$PLIST" ] || die plist "not found: $PLIST"
[ -n "$CONFIG_FILE" ] && [ ! -f "$CONFIG_FILE" ] && die config "not found: $CONFIG_FILE"
[ -f "$TOKEN_FILE" ] || die token "not found: $TOKEN_FILE"
PERM="$("$PYTHON" -c 'import os,sys;print(oct(os.stat(sys.argv[1]).st_mode & 0o777))' "$TOKEN_FILE")"
[ "$PERM" = "0o600" ] || die token "permissions $PERM, expected 0o600"

ACTUAL_SHA="$("$SHASUM_BIN" -a 256 "$BIN" 2>/dev/null | awk '{print $1}')"
[ "$ACTUAL_SHA" = "$FROZEN_SHA256" ] || die binary "sha256 ${ACTUAL_SHA:-none} != frozen $FROZEN_SHA256"
"$CODESIGN_BIN" --verify --strict --all-architectures "$BIN" >/dev/null 2>&1 \
  || die binary "codesign verification failed; refusing to open the gate for an unverified binary"
echo "  binary      : $ACTUAL_SHA (frozen match), signature VALID"

# Evidence must be writable before anything production-facing happens, and a
# run directory is never reused: two windows must not share one evidence tree.
[ -d "$WORK_ROOT" ] || die workdir "does not exist: $WORK_ROOT (create it first)"
probe_writable() {
  local probe="$1/.r1-write-probe.$$"
  : > "$probe" 2>/dev/null || { rm -f "$probe" 2>/dev/null; return 1; }
  rm -f "$probe" 2>/dev/null; return 0
}
probe_writable "$WORK_ROOT" || die workdir "not writable: $WORK_ROOT"
RUN_DIR="$WORK_ROOT/window-$LABEL-$(date -u +%Y%m%dT%H%M%SZ)"
[ -e "$RUN_DIR" ] && die workdir "run directory already exists: $RUN_DIR"
mkdir -m 700 "$RUN_DIR" || die workdir "cannot create $RUN_DIR"
STATE="$RUN_DIR/state"

# Static configuration check: reads files only. It proves the allowlist is
# exactly the bound ID and that its binding is calDAV/iCloud, which is what
# makes "only the target can be resolved" a property of the config rather than
# a hope. It also refuses a window that is already open.
STATIC_JSON="$RUN_DIR/static_config.json"
R1_LIST_ID="$LIST_ID" R1_PLIST="$PLIST" R1_CONFIG="$CONFIG_FILE" "$PYTHON" - "$STATIC_JSON" <<'PYEOF' || die static "could not evaluate static configuration"
import json, os, plistlib, sys
out, list_id = sys.argv[1], os.environ["R1_LIST_ID"]
key = "EVENTKIT_BRIDGE_PRODUCTION_AUTHORIZED"
plist_env, source = {}, "absent"
try:
    with open(os.environ["R1_PLIST"], "rb") as fh:
        plist_env = (plistlib.load(fh).get("EnvironmentVariables") or {})
except Exception:
    plist_env = {}
cfg = {}
path = os.environ.get("R1_CONFIG") or ""
if path and os.path.exists(path):
    for line in open(path, encoding="utf-8"):
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        k, _, v = line.partition("=")
        cfg[k.strip()] = v.strip().strip('"').strip("'")
merged = dict(cfg)
merged.update({k: v for k, v in plist_env.items() if v not in (None, "")})
if key in plist_env and str(plist_env[key]).strip() != "":
    source = "launchd_env"
elif key in cfg:
    source = "config_file"
allowed = [x for x in merged.get("EVENTKIT_BRIDGE_ALLOWED_LIST_IDS", "").split(",") if x.strip()]
binding_ok = False
for entry in merged.get("EVENTKIT_BRIDGE_BINDINGS", "").split(";"):
    parts = [p.strip() for p in entry.split(":")]
    if len(parts) == 4 and parts[0] == list_id:
        binding_ok = parts[2].lower() == "caldav" and parts[3] == "iCloud"
json.dump({
    "gate_source": source,
    "gate_value": str(merged.get(key, "false")).lower(),
    "mode": merged.get("EVENTKIT_BRIDGE_MODE", ""),
    "allowed_list_count": len(allowed),
    "allowed_list_matches_target": allowed == [list_id],
    "binding_present_and_caldav_icloud": binding_ok,
}, open(out, "w", encoding="utf-8"), ensure_ascii=False, indent=2)
PYEOF

"$PYTHON" - "$STATIC_JSON" <<'PYEOF' || die static "static check failed (see static_config.json)"
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

# pre: the baseline must be a closed gate reached through the allowlist. A 401
# here is an auth problem, 403 LIST_NOT_ALLOWED is a config problem and only
# 403 PERMISSION_DENIED is a closed-gate baseline; probe keeps them apart.
echo "== pre phase (closed gate) =="
PRE_ARGS=(--endpoint "$ENDPOINT" --token-file "$TOKEN_FILE" --list-id "$LIST_ID"
          --phase pre --expect GATE_CLOSED_AS_EXPECTED --out "$RUN_DIR/probe_pre.json")
[ -n "$CANARY_ID" ] && PRE_ARGS+=(--canary-id "$CANARY_ID")
if ! "$PYTHON" "$CLIENT" probe "${PRE_ARGS[@]}" > "$RUN_DIR/probe_pre.out" 2>&1; then
  cat "$RUN_DIR/probe_pre.out" >&2
  die baseline "pre phase did not observe a closed-gate baseline; nothing was changed"
fi
cat "$RUN_DIR/probe_pre.out"
echo "  evidence    : $RUN_DIR/probe_pre.json"

echo "== plan =="
echo "  window=${WINDOW_SECONDS}s open_budget=${OPEN_BUDGET}s restore_attempts=$RESTORE_ATTEMPTS"
if [ "$CONFIRM" -ne 1 ]; then
  echo "DRY RUN: preflight passed, no gate operation was performed; evidence kept in $RUN_DIR"
  echo "         re-run with --confirm inside the approved window"
  exit 0
fi

# ---------------------------------------------------------------- watchdog first
DEADLINE=$(( $(date +%s) + WINDOW_SECONDS ))
echo "== arming watchdog (before any change) =="
nohup "$WATCHDOG" \
  --state-dir "$STATE" \
  --deadline-epoch "$DEADLINE" \
  --open-budget "$OPEN_BUDGET" \
  --plist "$PLIST" \
  --config-file "$CONFIG_FILE" \
  --token-file "$TOKEN_FILE" \
  --endpoint "$ENDPOINT" \
  --list-id "$LIST_ID" \
  --require-no-enumeration \
  --poll 2 >/dev/null 2>&1 &
disown 2>/dev/null || true
sleep 1
[ -f "$STATE/watchdog.pid" ] || die watchdog "watchdog did not publish its pid"
ACTUAL_WPID="$(cat "$STATE/watchdog.pid")"
kill -0 "$ACTUAL_WPID" 2>/dev/null || die watchdog "watchdog $ACTUAL_WPID is not alive"
grep -q "^WATCHDOG_DEADLINE_EPOCH=$DEADLINE$" "$STATE/watchdog_meta.env" 2>/dev/null \
  || die watchdog "watchdog deadline metadata mismatch"
echo "  watchdog    : pid=$ACTUAL_WPID deadline=$DEADLINE (absolute) budget=${OPEN_BUDGET}s verified alive"

OPEN_OK=0; RESTORE_OK=0; TRUNCATED=0; OPEN_CLASS=""; RESTORE_CLASS=""
RESTORE_USED=0; INTERRUPTED=0; OPEN_STAMP=""
PID_BEFORE="$(pgrep -x EventKitBridgeServer 2>/dev/null | head -1 || true)"

disarm_watchdog() {
  touch "$STATE/stop" 2>/dev/null || true
  local waited=0
  while [ "$waited" -lt 20 ]; do
    grep -qE '^WATCHDOG_STATE=(DISARMED_BY_MAIN|FIRED_[A-Z_]+)$' "$STATE/watchdog_status.env" 2>/dev/null && return 0
    sleep 1; waited=$((waited + 1))
  done
  return 1
}

write_summary() {
  local outcome="$1"
  R1_OUTCOME="$outcome" R1_OPEN_CLASS="$OPEN_CLASS" R1_RESTORE_CLASS="$RESTORE_CLASS" \
  R1_OPENED="$OPEN_OK" R1_RESTORED="$RESTORE_OK" R1_TRUNC="${TRUNCATED}" \
  R1_DEADLINE="$DEADLINE" R1_BUDGET="$OPEN_BUDGET" R1_PID_BEFORE="$PID_BEFORE" \
  R1_RESTORE_USED="$RESTORE_USED" R1_INTERRUPTED="$INTERRUPTED" R1_STAMP="$OPEN_STAMP" \
  R1_RESTORE_MAX="$RESTORE_ATTEMPTS" \
  "$PYTHON" - "$RUN_DIR" <<'PYEOF'
import json, os, sys
run_dir = sys.argv[1]
wd = {}
status = os.path.join(run_dir, "state", "watchdog_status.env")
if os.path.exists(status):
    for line in open(status, encoding="utf-8"):
        if "=" in line:
            k, _, v = line.strip().partition("=")
            wd[k] = v
env = os.environ
summary = {
    "receipt_type": "R1_03_PROBE_WINDOW_SUMMARY",
    "task": "REM-R1-01",
    "step": "R1-03",
    "window_dir": run_dir,
    "window_outcome": env["R1_OUTCOME"],
    "truncated": env["R1_TRUNC"] == "1",
    "interrupted": env["R1_INTERRUPTED"] == "1",
    "absolute_deadline_epoch": int(env["R1_DEADLINE"]),
    "open_budget_seconds": int(env["R1_BUDGET"]),
    # The stamp is written before the gate changes, so it is the lower bound of
    # the time the gate may have been open - never the moment the open returned.
    "gate_open_since_epoch": int(env["R1_STAMP"]) if env["R1_STAMP"] else None,
    "gate_opened": env["R1_OPENED"] == "1",
    "open_probe_classification": env["R1_OPEN_CLASS"] or None,
    "restore_verified": env["R1_RESTORED"] == "1",
    "restore_probe_classification": env["R1_RESTORE_CLASS"] or None,
    "restore_attempts_used": int(env["R1_RESTORE_USED"]),
    "restore_attempts_allowed": int(env["R1_RESTORE_MAX"]),
    "watchdog_state": wd.get("WATCHDOG_STATE"),
    "watchdog_reason": wd.get("WATCHDOG_REASON"),
    "follow_up": {"triggered": False,
                  "reason": "a probe result never starts a read, a write or a fidelity check"},
}
with open(os.path.join(run_dir, "summary.json"), "w", encoding="utf-8") as fh:
    json.dump(summary, fh, indent=2, ensure_ascii=False)
    fh.write("\n")
print("[window] outcome=%s opened=%s open_class=%s restored=%s restore_class=%s watchdog=%s" % (
    summary["window_outcome"], summary["gate_opened"], summary["open_probe_classification"],
    summary["restore_verified"], summary["restore_probe_classification"],
    summary["watchdog_state"]))
PYEOF
}

# A signal must not be turned into a clean finish. The handler installed at the
# top only records the flag; the flow below still restores, but the outcome
# stays "truncated" and the exit code stays 16 even when the restore verified.

# One close = one item request. The retries are bounded, they run through
# r1_probe_close.sh (which cannot drop --list-id or --require-no-enumeration),
# and they never send an open-phase probe: a restore closes, it does not re-ask
# the question.
#
# The stamp is NOT created here. If it is absent, the gate was never touched by
# this window, and inventing a stamp now would restart the open budget at the
# very moment it is most needed.
restore() {
  local purpose="$1" attempt=1 rc=0 out=""
  echo "== close ($purpose) =="
  while [ "$attempt" -le "$RESTORE_ATTEMPTS" ]; do
    out="$RUN_DIR/gate_close_${purpose}_attempt${attempt}.json"
    "$CLOSE" --plist "$PLIST" --config-file "$CONFIG_FILE" \
      --token-file "$TOKEN_FILE" --endpoint "$ENDPOINT" \
      --list-id "$LIST_ID" --purpose "window:$purpose" \
      --lock-wait 15 --out "$out" >> "$RUN_DIR/gate_close_$purpose.log" 2>&1
    rc=$?
    RESTORE_USED="$attempt"
    RESTORE_CLASS="$("$PYTHON" -c 'import json,sys
try:
    print(json.load(open(sys.argv[1], encoding="utf-8")).get("probe_classification") or "")
except Exception:
    print("")' "$out" 2>/dev/null)"
    if [ "$rc" -eq 0 ] && [ "$RESTORE_CLASS" = "GATE_RESTORED_CLOSED" ]; then
      RESTORE_OK=1
      return 0
    fi
    echo "  attempt $attempt/$RESTORE_ATTEMPTS not verified (rc=$rc, class=${RESTORE_CLASS:-none})" >&2
    attempt=$((attempt + 1))
    if [ "$attempt" -le "$RESTORE_ATTEMPTS" ]; then sleep "$RESTORE_DELAY"; fi
  done
  return 1
}

# ---------------------------------------------------------------- open + probe
# A signal that arrived while the watchdog was being armed means nothing was
# changed yet: stop here, leave the gate alone, and report a truncated window.
if [ "$INTERRUPTED" -eq 1 ]; then
  disarm_watchdog || true
  write_summary TRUNCATED
  exit 16
fi

echo "== open =="
# The open budget starts here, before the first change, not when the open
# request returns. Deriving it afterwards would price a blocked reload at zero
# and hand back exactly the time the block consumed.
OPEN_STAMP="$(date +%s)"
printf '%s\n' "$OPEN_STAMP" > "$STATE/gate_open_since"
echo "  budget      : starts at $OPEN_STAMP (written before the gate changed)"
if ! "$GATE" open --plist "$PLIST" --config-file "$CONFIG_FILE" \
      --token-file "$TOKEN_FILE" --endpoint "$ENDPOINT" \
      --list-id "$LIST_ID" --require-no-enumeration --purpose "window:open" \
      --lock-wait 20 --out "$RUN_DIR/gate_open.json" >> "$RUN_DIR/gate_open.log" 2>&1; then
  echo "[window] gate open failed or did not verify; see $RUN_DIR/gate_open.log" >&2
  # No disarm here on failure: if the close cannot be verified the watchdog is
  # the only thing still holding a deadline over this gate.
  restore open_failed || { write_summary GATE_OPEN_FAILED_RESTORE_FAILED; exit 13; }
  disarm_watchdog || true
  write_summary GATE_OPEN_FAILED
  exit 11
fi
OPEN_OK=1
OPEN_CLASS="$("$PYTHON" -c 'import json,sys
print(json.load(open(sys.argv[1], encoding="utf-8")).get("probe_classification") or "")' \
  "$RUN_DIR/gate_open.json" 2>/dev/null)"
echo "  open probe  : ${OPEN_CLASS:-<none>} (open returned $(date +%s), stamp $OPEN_STAMP)"
if [ -z "$OPEN_CLASS" ]; then
  restore no_classification || { write_summary NO_CLASSIFICATION_RESTORE_FAILED; exit 13; }
  disarm_watchdog || true
  write_summary NO_CLASSIFICATION
  exit 12
fi

# No further read. A non-empty result is counted, never inspected.
echo "== close =="
if ! restore normal; then
  # Deliberately no disarm_watchdog, no stop file, no removal of the stamp.
  # Writing stop here would delete the deadline protection at the exact moment
  # it is the only thing left; the watchdog must stay armed and keep its own
  # absolute deadline over a gate whose state is now unknown.
  write_summary RESTORE_FAILED
  echo "[window] CRITICAL: restore NOT verified; the watchdog stays armed and state is kept in $RUN_DIR" >&2
  exit 13
fi

if ! disarm_watchdog; then
  echo "[window] watchdog did not disarm in time; state kept in $RUN_DIR" >&2
  write_summary WATCHDOG_DISARM_TIMEOUT
  exit 13
fi
# If the watchdog fired before we disarmed, or a signal arrived at any point,
# the window was truncated even though the restore verified. TRUNCATED is never
# reset: a truncated window is never reported as a completed one.
WD_STATE="$(awk -F= '/^WATCHDOG_STATE=/{print $2}' "$STATE/watchdog_status.env" 2>/dev/null)"
case "$WD_STATE" in
  FIRED_*) TRUNCATED=1 ;;
esac
# An interrupt anywhere in the window makes it a truncated window, even when
# everything after it succeeded. This is the line the previous version was
# missing: it reset TRUNCATED to 0 here and then reported a clean completion.
[ "$INTERRUPTED" -eq 1 ] && TRUNCATED=1

write_summary "$([ "$TRUNCATED" -eq 1 ] && echo TRUNCATED || echo COMPLETED)"
[ "$TRUNCATED" -eq 1 ] && exit 16
exit 0
