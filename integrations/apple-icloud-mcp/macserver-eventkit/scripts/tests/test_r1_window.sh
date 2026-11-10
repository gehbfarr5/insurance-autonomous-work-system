#!/usr/bin/env bash
# test_r1_window.sh — offline verification of the window/orchestration gaps.
#
# Covers exactly the failure modes the revised application must stand behind:
#   preflight refusal, dry run, happy path, field mismatch, empty-at-capture,
#   capture transport failure, gate-open (load) failure, restore failure,
#   absolute-deadline firing, open-budget firing, and the main process being
#   SIGKILLed mid-window.
#
# launchctl / codesign / pgrep / ps are replaced by stubs; the bridge is the
# loopback fake. No EventKit, no TCC, no Apple account, no real launchd job.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS="$(dirname "$HERE")"
WINDOW="$SCRIPTS/r1_window.sh"
WATCHDOG="$SCRIPTS/r1_watchdog.sh"
GATE="$SCRIPTS/r1_gate.sh"
FAKE="$HERE/fake_bridge.py"

TOKEN="offline-test-token-0123456789abcdef"
LIST_ID="9D9A5AAD-E3F0-4459-8756-BBCDBCB703F3"
TITLE="[MUSE-R1-SYN-20261110-01] 只读读取保真核验"
NOTES="R1-01 合成事项，仅用于只读字段保真核验，验收后精准清理。MARKER=R1SYN20261110A"
DUE_UTC="2026-11-17T02:30:00Z"
DUE_COCOA=816575400
FAILS=0; TOTAL=0

check() {
  TOTAL=$((TOTAL + 1))
  if [ "$2" = "1" ]; then
    echo "  [PASS] $1"
  else
    echo "  [FAIL] $1 ${3:+($3)}"
    FAILS=$((FAILS + 1))
  fi
}

eq() { [ "$2" = "$3" ] && check "$1" 1 || check "$1" 0 "expected '$3' got '$2'"; }

# ---------------------------------------------------------------- fixture
new_fixture() {
  FX="$(mktemp -d "${TMPDIR:-/tmp}/r1win.XXXXXX")"
  mkdir -p "$FX/bin" "$FX/fields" "$FX/work" "$FX/conf"
  BIN="$FX/EventKitBridgeServer"
  printf 'fake bridge binary for tests\n' > "$BIN"; chmod 755 "$BIN"
  SHA="$(/usr/bin/shasum -a 256 "$BIN" | awk '{print $1}')"

  printf '%s' "$TOKEN" > "$FX/token"; chmod 600 "$FX/token"

  # config file is the authoritative gate source (plist defines no key)
  {
    echo "EVENTKIT_BRIDGE_MODE=PRODUCTION"
    echo "EVENTKIT_BRIDGE_PORT=18765"
    echo "EVENTKIT_BRIDGE_PRODUCTION_AUTHORIZED=false"
    echo "EVENTKIT_BRIDGE_ALLOWED_LIST_IDS=$LIST_ID"
    echo "EVENTKIT_BRIDGE_BINDINGS=$LIST_ID:7B0B0000-0000-4000-8000-000000000001:calDAV:iCloud"
    echo "EVENTKIT_BRIDGE_BEARER_TOKEN=$TOKEN"
  } > "$FX/conf/bridge.env"
  chmod 600 "$FX/conf/bridge.env"

  # plist without the gate key
  cat > "$FX/conf/agent.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.muse.macserver-eventkit</string>
  <key>EnvironmentVariables</key><dict>
    <key>EVENTKIT_BRIDGE_MODE</key><string>PRODUCTION</string>
  </dict>
</dict></plist>
PLIST

  # stubs
  cat > "$FX/bin/launchctl" <<'STUB'
#!/bin/sh
echo "launchctl $*" >> "$STUB_DIR/launchctl.log"
COUNT_FILE="$STUB_DIR/launchctl.count"
N=$(cat "$COUNT_FILE" 2>/dev/null || echo 0)
N=$((N + 1)); echo "$N" > "$COUNT_FILE"
if [ -n "${STUB_LAUNCHCTL_FAIL:-}" ]; then exit "${STUB_LAUNCHCTL_FAIL}"; fi
if [ -n "${STUB_LAUNCHCTL_FAIL_AFTER:-}" ] && [ "$N" -gt "${STUB_LAUNCHCTL_FAIL_AFTER}" ]; then
  exit 1
fi
exit 0
STUB
  cat > "$FX/bin/codesign" <<'STUB'
#!/bin/sh
[ -n "${STUB_CODESIGN_FAIL:-}" ] && exit 1
exit 0
STUB
  cat > "$FX/bin/pgrep" <<'STUB'
#!/bin/sh
[ -n "${STUB_NO_PROCESS:-}" ] && exit 1
echo 4242
STUB
  cat > "$FX/bin/ps" <<'STUB'
#!/bin/sh
for a in "$@"; do
  case "$a" in
    -o) : ;;
  esac
done
case "$*" in
  *lstart*) echo "STUB LSTART 00:00:00 2026" ;;
  *) echo "  4242 ?? S 0:00.00 EventKitBridgeServer" ;;
esac
exit 0
STUB
  cat > "$FX/bin/shasum" <<'STUB'
#!/bin/sh
exec /usr/bin/shasum "$@"
STUB
  chmod +x "$FX/bin/"*

  write_items() {  # $1 = json array
    printf '%s' "$1" > "$FX/fields/items_json"
    python3 - "$FX/fields/items_json" "$LIST_ID" <<'PY'
import json, sys
items = json.load(open(sys.argv[1], encoding="utf-8"))
json.dump({sys.argv[2]: items}, open(sys.argv[1] + ".table", "w", encoding="utf-8"), ensure_ascii=False)
PY
    mv "$FX/fields/items_json.table" "$FX/fields/items"
  }
  printf '%s' "[{\"listID\":\"$LIST_ID\",\"title\":\"SYNTHETIC-LIST\",\"sourceID\":\"7B0B0000-0000-4000-8000-000000000001\",\"sourceType\":\"calDAV\",\"sourceName\":\"iCloud\",\"color\":\"\",\"isImmutable\":true}]" > "$FX/fields/lists"
  printf 'production' > "$FX/fields/store"

  export STUB_DIR="$FX"
  export R1_LOCK_DIR="$FX/lock"        # isolate the gate mutex per scenario
  export PATH="$FX/bin:$PATH"
}

start_bridge() {
  python3 "$FAKE" --field-dir "$FX/fields" --token "$TOKEN" --config-file "$FX/conf/bridge.env" \
    --plist "$FX/conf/agent.plist" \
    > "$FX/bridge.url" 2>/dev/null &
  BRIDGE_PID=$!
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    [ -s "$FX/bridge.url" ] && break
    sleep 0.2
  done
  URL="$(cat "$FX/bridge.url")"
}

stop_bridge() { kill "$BRIDGE_PID" 2>/dev/null; wait "$BRIDGE_PID" 2>/dev/null; }

run_window() {
  BIN="$BIN" FROZEN_SHA256="$SHA" \
  "$WINDOW" \
    --list-id "$LIST_ID" --expect-title "$TITLE" --expect-notes "$NOTES" \
    --expect-due-utc "$DUE_UTC" --token-file "$FX/token" \
    --plist "$FX/conf/agent.plist" --config-file "$FX/conf/bridge.env" \
    --endpoint "$URL" --work-dir "$FX/work" --label t "$@" > "$FX/window.out" 2>&1
  echo $?
}

gate_value() { awk -F= '/^EVENTKIT_BRIDGE_PRODUCTION_AUTHORIZED=/{print $2}' "$FX/conf/bridge.env"; }

# The watchdog writes its verdict only after r1_gate.sh has finished its settle
# and verification window, so a fixed sleep is racy. Wait for a terminal state,
# bounded, and fail loudly instead of reading a half-written "RUNNING".
wait_watchdog_state() {  # $1 = run dir, $2 = timeout seconds
  local f="$1/state/watchdog_status.env" waited=0
  while [ "$waited" -lt "${2:-30}" ]; do
    if grep -qE '^WATCHDOG_STATE=(FIRED_[A-Z_]+|DISARMED_BY_MAIN)$' "$f" 2>/dev/null; then
      return 0
    fi
    sleep 1; waited=$((waited + 1))
  done
  return 1
}

GOOD_ITEM='[{"itemID":"11111111-2222-4333-8444-555555555555","title":"'"$TITLE"'","isCompleted":false,"priority":5,"listID":"'"$LIST_ID"'","notes":"'"$NOTES"'","dueDate":'"$DUE_COCOA"',"isAllDay":false}]'

# ---------------------------------------------------------------- scenarios
echo "[1] preflight refuses a binary whose hash does not match"
new_fixture; start_bridge
write_items "[]"
RC="$(BIN="$BIN" FROZEN_SHA256="deadbeef" "$WINDOW" --list-id "$LIST_ID" --expect-title "$TITLE" \
  --expect-notes "$NOTES" --expect-due-utc "$DUE_UTC" --token-file "$FX/token" \
  --plist "$FX/conf/agent.plist" --config-file "$FX/conf/bridge.env" \
  --endpoint "$URL" --work-dir "$FX/work" --label t1 --confirm >"$FX/o1" 2>&1; echo $?)"
eq "exit code 10" "$RC" "10"
eq "gate stays false" "$(gate_value)" "false"
grep -q "sha256" "$FX/o1" && check "reports the hash mismatch" 1 || check "reports the hash mismatch" 0
stop_bridge

echo "[2] dry run changes nothing"
new_fixture; start_bridge
write_items "[]"
RC="$(run_window)"
eq "exit code 0" "$RC" "0"
eq "gate stays false" "$(gate_value)" "false"
grep -q "DRY RUN" "$FX/window.out" && check "prints DRY RUN" 1 || check "prints DRY RUN" 0
[ -d "$FX/work" ] && check "no run directory created" 1 || check "no run directory created" 0
stop_bridge

echo "[3] happy path: open, capture, fidelity, restore"
new_fixture; start_bridge
python3 - "$FX/fields" "$GOOD_ITEM" <<'PY'
import json, sys
fields, item = sys.argv[1], json.loads(sys.argv[2])
json.dump({"9D9A5AAD-E3F0-4459-8756-BBCDBCB703F3": item},
          open(fields + "/items", "w", encoding="utf-8"), ensure_ascii=False)
PY
RC="$(run_window --confirm --passes 1 --window-seconds 120 --open-budget 60)"
eq "exit code 0" "$RC" "0"
RUN_DIR="$(ls -d "$FX"/work/window-* 2>/dev/null | head -1)"
[ -n "$RUN_DIR" ] && check "run directory created" 1 || check "run directory created" 0
python3 - "$RUN_DIR/window_summary.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
checks = [
    ("capture verdict COMPLETED", d["verdicts"]["capture_completed"] == "COMPLETED"),
    ("fidelity verdict ASSERTED", d["verdicts"]["fidelity_asserted"] == "ASSERTED"),
    ("restore verdict VERIFIED", d["verdicts"]["restore_verified"] == "VERIFIED"),
]
for name, ok in checks:
    print(("  [PASS] " if ok else "  [FAIL] ") + name)
sys.exit(0 if all(ok for _, ok in checks) else 1)
PY
[ $? -eq 0 ] && TOTAL=$((TOTAL + 3)) || { TOTAL=$((TOTAL + 3)); FAILS=$((FAILS + 1)); }
eq "gate restored to false" "$(gate_value)" "false"
[ -f "$RUN_DIR/state/gate_close.json" ] && check "close receipt written" 1 || check "close receipt written" 0
grep -q '"verification": "PASS"' "$RUN_DIR/state/gate_close.json" && check "close verified 403" 1 || check "close verified 403" 0
[ -f "$RUN_DIR/batch-1-t/capture.json" ] && check "batch evidence kept" 1 || check "batch evidence kept" 0
stop_bridge

echo "[4] field mismatch (priority 0) -> fidelity fails but restore still verified"
new_fixture; start_bridge
python3 - "$FX/fields" "$GOOD_ITEM" <<'PY'
import json, sys
fields, item = sys.argv[1], json.loads(sys.argv[2])
item[0]["priority"] = 0
json.dump({"9D9A5AAD-E3F0-4459-8756-BBCDBCB703F3": item},
          open(fields + "/items", "w", encoding="utf-8"), ensure_ascii=False)
PY
RC="$(run_window --confirm --passes 1 --window-seconds 120 --open-budget 60)"
eq "exit code 12" "$RC" "12"
eq "gate restored to false" "$(gate_value)" "false"
stop_bridge

echo "[5] empty list at capture time -> capture completed, fidelity failed"
new_fixture; start_bridge
write_items "[]"
RC="$(run_window --confirm --passes 1 --window-seconds 120 --open-budget 60)"
eq "exit code 12" "$RC" "12"
eq "gate restored to false" "$(gate_value)" "false"
stop_bridge

echo "[6] capture transport failure -> capture incomplete, restore verified"
new_fixture; start_bridge
write_items "$GOOD_ITEM"
: > "$FX/fields/fail_items"
RC="$(run_window --confirm --passes 1 --window-seconds 120 --open-budget 60)"
eq "exit code 15" "$RC" "15"
eq "gate restored to false" "$(gate_value)" "false"
stop_bridge

echo "[7] gate reload failure -> open fails, restore also fails, non-zero and state kept"
new_fixture; start_bridge
write_items "$GOOD_ITEM"
RC="$(STUB_LAUNCHCTL_FAIL=1 run_window --confirm --passes 1 --window-seconds 120 --open-budget 60)"
eq "exit code 13" "$RC" "13"
grep -q "OPEN_FAILED" "$FX/window.out" && check "reports OPEN_FAILED" 1 || check "reports OPEN_FAILED" 0
RUN_DIR="$(ls -d "$FX"/work/window-* 2>/dev/null | head -1)"
[ -n "$RUN_DIR" ] || { echo "  [FAIL] run directory missing for the failed-open path"; FAILS=$((FAILS + 1)); }
python3 - "$RUN_DIR/window_summary.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
checks = [
    ("summary exists on the failed-open path", d.get("window_outcome") == "OPEN_FAILED"),
    ("restore verdict is FAILED, never success", d["verdicts"]["restore_verified"] == "FAILED"),
    ("capture is not claimed", d["verdicts"]["capture_completed"] == "FAIL"),
]
for name, ok in checks:
    print(("  [PASS] " if ok else "  [FAIL] ") + name)
sys.exit(0 if all(ok for _, ok in checks) else 1)
PY
[ $? -eq 0 ] && TOTAL=$((TOTAL + 3)) || { TOTAL=$((TOTAL + 3)); FAILS=$((FAILS + 1)); }
stop_bridge

echo "[8] restore failure after a successful open -> exit 13, failure recorded as evidence"
new_fixture; start_bridge
write_items "$GOOD_ITEM"
RC="$(STUB_LAUNCHCTL_FAIL_AFTER=1 run_window --confirm --passes 1 --window-seconds 120 --open-budget 60)"
eq "exit code 13" "$RC" "13"
grep -q "RESTORE_FAILED" "$FX/window.out" && check "reports RESTORE_FAILED" 1 || check "reports RESTORE_FAILED" 0
RUN_DIR="$(ls -d "$FX"/work/window-* 2>/dev/null | head -1)"
python3 - "$RUN_DIR/state/gate_close.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
checks = [
    ("close receipt exists for a failed restore", d.get("receipt_type") == "R1_GATE_OPERATION"),
    ("close receipt verification is FAIL", d.get("verification") == "FAIL"),
    ("failure stage is the reload, not the write", d.get("failure_stage") == "reload"),
    ("disk value was already written before the reload failed",
     d.get("disk_written_before_failure") is True),
]
for name, ok in checks:
    print(("  [PASS] " if ok else "  [FAIL] ") + name)
sys.exit(0 if all(ok for _, ok in checks) else 1)
PY
[ $? -eq 0 ] && TOTAL=$((TOTAL + 4)) || { TOTAL=$((TOTAL + 4)); FAILS=$((FAILS + 1)); }
grep -q "WINDOW_RESULT: RESTORE_FAILED" "$FX/window.out" && check "no success line is printed" 1 || check "no success line is printed" 0
[ ! -f "$RUN_DIR/state/stop" ] && check "protection is NOT disarmed after a failed restore" 1 \
  || check "protection is NOT disarmed after a failed restore" 0
[ -f "$RUN_DIR/state/gate_open_since" ] && check "open-budget clock keeps running while the gate may still be open" 1 \
  || check "open-budget clock keeps running while the gate may still be open" 0
[ -n "$(cat "$RUN_DIR/state/watchdog.pid" 2>/dev/null)" ] && kill -0 "$(cat "$RUN_DIR/state/watchdog.pid")" 2>/dev/null \
  && check "watchdog is still armed after the window gave up" 1 || check "watchdog is still armed after the window gave up" 0
touch "$RUN_DIR/state/stop"   # disarm the leftover watchdog before moving on
stop_bridge

echo "[9] absolute deadline fires while the window is busy"
new_fixture; start_bridge
write_items "$GOOD_ITEM"
RC="$(run_window --confirm --passes 2 --interval 8 --window-seconds 4 --open-budget 300)"
RUN_DIR="$(ls -d "$FX"/work/window-* 2>/dev/null | head -1)"
wait_watchdog_state "$RUN_DIR" 30 && check "watchdog reached a terminal state" 1 || check "watchdog reached a terminal state" 0
grep -q "WATCHDOG_STATE=FIRED_RESTORED" "$RUN_DIR/state/watchdog_status.env" 2>/dev/null \
  && check "watchdog fired and restored on deadline" 1 || check "watchdog fired and restored on deadline" 0
grep -q "WATCHDOG_REASON=deadline" "$RUN_DIR/state/watchdog_status.env" 2>/dev/null \
  && check "reason recorded as deadline" 1 || check "reason recorded as deadline" 0
eq "gate restored to false" "$(gate_value)" "false"
eq "truncated window is not reported as success" "$RC" "16"
grep -q "WINDOW_TRUNCATED_RESTORE_VERIFIED" "$FX/window.out" \
  && check "explains that the window was truncated" 1 || check "explains that the window was truncated" 0
python3 - "$RUN_DIR/window_summary.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
checks = [
    ("summary records truncation", d.get("window_truncated") is True),
    ("summary records fewer passes than planned", d["passes_completed"] < d["passes_planned"]),
]
for name, ok in checks:
    print(("  [PASS] " if ok else "  [FAIL] ") + name)
sys.exit(0 if all(ok for _, ok in checks) else 1)
PY
[ $? -eq 0 ] && TOTAL=$((TOTAL + 2)) || { TOTAL=$((TOTAL + 2)); FAILS=$((FAILS + 1)); }
stop_bridge

echo "[10] cumulative open budget fires"
new_fixture; start_bridge
write_items "$GOOD_ITEM"
RC="$(run_window --confirm --passes 2 --interval 10 --window-seconds 300 --open-budget 2)"
RUN_DIR="$(ls -d "$FX"/work/window-* 2>/dev/null | head -1)"
wait_watchdog_state "$RUN_DIR" 30 && check "watchdog reached a terminal state" 1 || check "watchdog reached a terminal state" 0
grep -q "WATCHDOG_REASON=open_budget" "$RUN_DIR/state/watchdog_status.env" 2>/dev/null \
  && check "reason recorded as open_budget" 1 || check "reason recorded as open_budget" 0
eq "gate restored to false" "$(gate_value)" "false"
eq "budget-truncated window is not reported as success" "$RC" "16"
stop_bridge

echo "[11] main process SIGKILLed mid-window -> watchdog still restores"
new_fixture; start_bridge
write_items "$GOOD_ITEM"
BIN="$BIN" FROZEN_SHA256="$SHA" "$WINDOW" \
  --list-id "$LIST_ID" --expect-title "$TITLE" --expect-notes "$NOTES" \
  --expect-due-utc "$DUE_UTC" --token-file "$FX/token" \
  --plist "$FX/conf/agent.plist" --config-file "$FX/conf/bridge.env" \
  --endpoint "$URL" --work-dir "$FX/work" --label kill --confirm \
  --passes 3 --interval 15 --window-seconds 6 --open-budget 300 > "$FX/window.out" 2>&1 &
WIN_PID=$!
sleep 3
kill -9 "$WIN_PID" 2>/dev/null
wait "$WIN_PID" 2>/dev/null
RUN_DIR="$(ls -d "$FX"/work/window-* 2>/dev/null | head -1)"
wait_watchdog_state "$RUN_DIR" 60 && check "watchdog outlived the SIGKILLed window" 1 || check "watchdog outlived the SIGKILLed window" 0
grep -q "WATCHDOG_STATE=FIRED_RESTORED" "$RUN_DIR/state/watchdog_status.env" 2>/dev/null \
  && check "watchdog restored after the window process was SIGKILLed" 1 \
  || check "watchdog restored after the window process was SIGKILLed" 0
eq "gate restored to false" "$(gate_value)" "false"
stop_bridge

echo "[12] gate defined in the launchd plist -> bootout/bootstrap path, backup before edit"
new_fixture
python3 - "$FX/conf/agent.plist" <<'PY'
import plistlib, sys
path = sys.argv[1]
with open(path, "rb") as fh:
    data = plistlib.load(fh)
data["EnvironmentVariables"]["EVENTKIT_BRIDGE_PRODUCTION_AUTHORIZED"] = "false"
with open(path, "wb") as fh:
    plistlib.dump(data, fh)
PY
start_bridge
write_items "$GOOD_ITEM"
: > "$FX/launchctl.log"
CFG_SHA_BEFORE="$(shasum -a 256 "$FX/conf/bridge.env" | awk '{print $1}')"
RC="$(run_window --confirm --passes 1 --window-seconds 120 --open-budget 60)"
eq "exit code 0" "$RC" "0"
eq "non-authoritative config file is byte-identical afterwards" \
  "$(shasum -a 256 "$FX/conf/bridge.env" | awk '{print $1}')" "$CFG_SHA_BEFORE"
eq "plist holds false again" \
  "$(plutil -extract EnvironmentVariables.EVENTKIT_BRIDGE_PRODUCTION_AUTHORIZED raw "$FX/conf/agent.plist" 2>/dev/null)" "false"
grep -q "gate_source=launchd_env" "$FX/window.out" && check "detects the plist as the authoritative source" 1 \
  || check "detects the plist as the authoritative source" 0
grep -q "bootout" "$FX/launchctl.log" && check "unloads the job before reloading it" 1 \
  || check "unloads the job before reloading it" 0
grep -q "bootstrap" "$FX/launchctl.log" && check "bootstraps the edited plist" 1 \
  || check "bootstraps the edited plist" 0
RUN_DIR="$(ls -d "$FX"/work/window-* 2>/dev/null | head -1)"
BACKUP="$RUN_DIR/state/gate_open.json.plist-backup"
[ -f "$BACKUP" ] && check "plist backed up before editing" 1 || check "plist backed up before editing" 0
eq "backup is 0600" "$(stat -f %Lp "$BACKUP" 2>/dev/null)" "600"
python3 - "$RUN_DIR/state/gate_open.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
checks = [
    ("receipt records the launchd source", d.get("gate_source_detected") == "launchd_env"),
    ("receipt records the bootout/bootstrap reload", d.get("reload_method") == "bootout_bootstrap"),
    ("receipt records the 0600 backup", d.get("plist_backup_mode") == "0600"),
    ("process environment was observed, not assumed",
     d.get("process_env_observation") in ("process_env_matches", "process_env_differs_or_hidden")),
]
for name, ok in checks:
    print(("  [PASS] " if ok else "  [FAIL] ") + name)
sys.exit(0 if all(ok for _, ok in checks) else 1)
PY
[ $? -eq 0 ] && TOTAL=$((TOTAL + 4)) || { TOTAL=$((TOTAL + 4)); FAILS=$((FAILS + 1)); }
stop_bridge

echo "[13] cleanup verification mode (--expect absence)"
new_fixture; start_bridge
write_items "[]"
RC="$(run_window --confirm --passes 1 --window-seconds 120 --open-budget 60 --expect absence)"
eq "exit code 0 when the list is empty again" "$RC" "0"
RUN_DIR="$(ls -d "$FX"/work/window-* 2>/dev/null | head -1)"
python3 - "$RUN_DIR/window_summary.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
checks = [
    ("summary records the absence expectation", d.get("expectation") == "absence"),
    ("cleanup is reported as asserted", d["verdicts"]["fidelity_asserted"] == "CLEANUP_ASSERTED"),
    ("restore is still verified independently", d["verdicts"]["restore_verified"] == "VERIFIED"),
]
for name, ok in checks:
    print(("  [PASS] " if ok else "  [FAIL] ") + name)
sys.exit(0 if all(ok for _, ok in checks) else 1)
PY
[ $? -eq 0 ] && TOTAL=$((TOTAL + 3)) || { TOTAL=$((TOTAL + 3)); FAILS=$((FAILS + 1)); }
stop_bridge

echo "[14] cleanup verification fails when the item is still there"
new_fixture; start_bridge
write_items "$GOOD_ITEM"
RC="$(run_window --confirm --passes 1 --window-seconds 120 --open-budget 60 --expect absence)"
eq "exit code 12 when cleanup did not take effect" "$RC" "12"
eq "gate restored to false" "$(gate_value)" "false"
stop_bridge

echo "[15] watchdog: a close that reloads but fails verification is NOT a restore"
new_fixture; start_bridge
write_items "$GOOD_ITEM"
STATE_DIR="$FX/wd"; mkdir -p "$STATE_DIR"
date +%s > "$STATE_DIR/gate_open_since"
printf 'fake' > "$FX/fields/store"      # health no longer reports a production store
"$WATCHDOG" --state-dir "$STATE_DIR" \
  --deadline-epoch "$(( $(date +%s) + 1 ))" --open-budget 300 \
  --plist "$FX/conf/agent.plist" --config-file "$FX/conf/bridge.env" \
  --token-file "$FX/token" --endpoint "$URL" --poll 1 --restore-attempts 1 \
  > "$FX/wd.out" 2>&1
WD_RC=$?
eq "watchdog exits 6 when the restore cannot be verified" "$WD_RC" "6"
grep -q "WATCHDOG_STATE=FIRED_RESTORE_FAILED" "$STATE_DIR/watchdog_status.env" 2>/dev/null \
  && check "state is FIRED_RESTORE_FAILED, never FIRED_RESTORED" 1 \
  || check "state is FIRED_RESTORE_FAILED, never FIRED_RESTORED" 0
grep -q "WATCHDOG_STATE=FIRED_RESTORED" "$STATE_DIR/watchdog_status.env" 2>/dev/null \
  && check "success is not claimed anywhere" 0 || check "success is not claimed anywhere" 1
grep -q '"verification": "FAIL"' "$STATE_DIR/gate_close_deadline_attempt1.json" 2>/dev/null \
  && check "the failed close receipt is kept as evidence" 1 \
  || check "the failed close receipt is kept as evidence" 0
stop_bridge

echo "[16] gate mutex: a held lock is never overridden, a dead holder is reclaimed"
new_fixture; start_bridge
write_items "$GOOD_ITEM"
mkdir -p "$FX/lock/gate.lock"
sleep 60 & HOLDER=$!
{
  echo "LOCK_PID=$HOLDER"
  echo "LOCK_LSTART=$(ps -p "$HOLDER" -o lstart= 2>/dev/null | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
  echo "LOCK_PURPOSE=test-holder"
} > "$FX/lock/gate.lock/owner.env"
CFG_SHA_BEFORE="$(shasum -a 256 "$FX/conf/bridge.env" | awk '{print $1}')"
R1_LOCK_DIR="$FX/lock" "$GATE" close --plist "$FX/conf/agent.plist" \
  --config-file "$FX/conf/bridge.env" --token-file "$FX/token" \
  --endpoint "$URL" --out "$FX/busy.json" --lock-wait 2 --purpose test > "$FX/busy.out" 2>&1
BUSY_RC=$?
eq "busy lock -> exit 7, no forcing" "$BUSY_RC" "7"
eq "the config file was not touched while the lock was held" \
  "$(shasum -a 256 "$FX/conf/bridge.env" | awk '{print $1}')" "$CFG_SHA_BEFORE"
python3 - "$FX/busy.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
print(("  [PASS] " if d.get("failure_stage") == "lock" else "  [FAIL] ") + "busy-lock receipt records the stage")
sys.exit(0 if d.get("failure_stage") == "lock" else 1)
PY
[ $? -eq 0 ] && TOTAL=$((TOTAL + 1)) || { TOTAL=$((TOTAL + 1)); FAILS=$((FAILS + 1)); }
kill "$HOLDER" 2>/dev/null; wait "$HOLDER" 2>/dev/null
R1_LOCK_DIR="$FX/lock" "$GATE" close --plist "$FX/conf/agent.plist" \
  --config-file "$FX/conf/bridge.env" --token-file "$FX/token" \
  --endpoint "$URL" --out "$FX/reclaimed.json" --lock-wait 6 --purpose test > "$FX/reclaimed.out" 2>&1
eq "a dead holder's lock is reclaimed and the close verifies" "$?" "0"
[ -f "$FX/lock/gate.lock/owner.env" ] && check "the lock is released after the operation" 0 \
  || check "the lock is released after the operation" 1
stop_bridge

echo "[17] batch 1 succeeds, batch 2 errors -> not an overall success"
new_fixture; start_bridge
python3 - "$FX/fields" "$GOOD_ITEM" <<'PY'
import json, sys
fields, good = sys.argv[1], json.loads(sys.argv[2])
json.dump([good, "ERROR"], open(fields + "/items_seq", "w", encoding="utf-8"))
PY
RC="$(run_window --confirm --passes 2 --interval 1 --window-seconds 120 --open-budget 60)"
eq "exit code 15 (capture incomplete)" "$RC" "15"
RUN_DIR="$(ls -d "$FX"/work/window-* 2>/dev/null | head -1)"
python3 - "$RUN_DIR/window_summary.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
checks = [
    ("capture is not claimed as completed", d["verdicts"]["capture_completed"] == "FAIL"),
    ("fidelity is not claimed", d["verdicts"]["fidelity_asserted"] == "FAIL"),
    ("only one pass produced an observation", d["passes_with_observation"] == 1),
]
for name, ok in checks:
    print(("  [PASS] " if ok else "  [FAIL] ") + name)
sys.exit(0 if all(ok for _, ok in checks) else 1)
PY
[ $? -eq 0 ] && TOTAL=$((TOTAL + 3)) || { TOTAL=$((TOTAL + 3)); FAILS=$((FAILS + 1)); }
stop_bridge

echo "[18] batch 1 succeeds, batch 2 finds duplicates -> not an overall success"
new_fixture; start_bridge
python3 - "$FX/fields" "$GOOD_ITEM" <<'PY'
import json, sys
fields, good = sys.argv[1], json.loads(sys.argv[2])
json.dump([good, good + good], open(fields + "/items_seq", "w", encoding="utf-8"))
PY
RC="$(run_window --confirm --passes 2 --interval 1 --window-seconds 120 --open-budget 60)"
eq "exit code 12 (a later batch failed an assertion)" "$RC" "12"
RUN_DIR="$(ls -d "$FX"/work/window-* 2>/dev/null | head -1)"
python3 - "$RUN_DIR/window_summary.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
checks = [
    ("both passes produced an observation", d["passes_with_observation"] == 2),
    ("only one pass was clean", d["passes_clean"] == 1),
    ("fidelity is not claimed", d["verdicts"]["fidelity_asserted"] == "FAIL"),
]
for name, ok in checks:
    print(("  [PASS] " if ok else "  [FAIL] ") + name)
sys.exit(0 if all(ok for _, ok in checks) else 1)
PY
[ $? -eq 0 ] && TOTAL=$((TOTAL + 3)) || { TOTAL=$((TOTAL + 3)); FAILS=$((FAILS + 1)); }
stop_bridge

echo
echo "$((TOTAL - FAILS))/$TOTAL assertions passed"
if [ "$FAILS" -ne 0 ]; then
  echo "R1 WINDOW: OFFLINE_TEST_FAIL"
  exit 1
fi
echo "R1 WINDOW: OFFLINE_TEST_PASS"
