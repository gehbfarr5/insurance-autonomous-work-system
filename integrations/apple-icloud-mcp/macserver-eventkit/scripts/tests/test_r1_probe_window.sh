#!/usr/bin/env bash
# test_r1_probe_window.sh — offline verification of the R1-03 probe window.
#
# Four scenarios the application must stand behind, plus the one structural
# claim the whole design rests on:
#   1. a normal close: open, probe, close, restore verified
#   2. the window process is SIGKILLed after the gate opened
#   3. the watchdog fires on the absolute deadline, and on the open budget
#   4. the restore itself fails and is reported as a failure, never as success
#   5. across every one of those runs, the request log contains no call to the
#      account-wide enumeration endpoint
#
# launchctl / codesign / pgrep / ps are stubs; the bridge is the loopback fake,
# which logs every request it answers. No EventKit, no TCC, no Apple account,
# no real launchd job.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS="$(dirname "$HERE")"
WINDOW="$SCRIPTS/r1_probe_window.sh"
WATCHDOG="$SCRIPTS/r1_watchdog.sh"
GATE="$SCRIPTS/r1_gate.sh"
CLOSE="$SCRIPTS/r1_probe_close.sh"
FAKE="$HERE/fake_bridge.py"

TOKEN="offline-test-token-0123456789abcdef"
LIST_ID="9D9A5AAD-E3F0-4459-8756-BBCDBCB703F3"
CANARY_ID="R1-CANARY-00000000-0000-0000-0000-000000000000"
FAILS=0; TOTAL=0
# Every scenario adds its own count here; the run is only clean if this stays 0.
ALL_ENUM=0

check() {
  TOTAL=$((TOTAL + 1))
  if [ "$2" = "1" ]; then echo "  [PASS] $1"
  else echo "  [FAIL] $1 ${3:+($3)}"; FAILS=$((FAILS + 1)); fi
}
eq() { [ "$2" = "$3" ] && check "$1" 1 || check "$1" 0 "expected '$3' got '$2'"; }

cleanup() {
  stop_bridge 2>/dev/null || true
  [ -n "${WD_PID:-}" ] && kill "$WD_PID" 2>/dev/null
  [ -n "${FX:-}" ] && rm -rf "$FX"
}

# ---------------------------------------------------------------- fixture
new_fixture() {
  FX="$(mktemp -d "${TMPDIR:-/tmp}/r103win.XXXXXX")"
  mkdir -p "$FX/bin" "$FX/fields" "$FX/work" "$FX/conf"
  BIN="$FX/EventKitBridgeServer"
  printf 'fake bridge binary for tests\n' > "$BIN"; chmod 755 "$BIN"
  SHA="$(/usr/bin/shasum -a 256 "$BIN" | awk '{print $1}')"
  printf '%s' "$TOKEN" > "$FX/token"; chmod 600 "$FX/token"

  # config file is the authoritative gate source (the plist defines no key), so
  # the reload is a kickstart: one launchctl call per gate operation.
  {
    echo "EVENTKIT_BRIDGE_MODE=PRODUCTION"
    echo "EVENTKIT_BRIDGE_PORT=18765"
    echo "EVENTKIT_BRIDGE_PRODUCTION_AUTHORIZED=false"
    echo "EVENTKIT_BRIDGE_ALLOWED_LIST_IDS=$LIST_ID"
    echo "EVENTKIT_BRIDGE_BINDINGS=$LIST_ID:7B0B0000-0000-4000-8000-000000000001:calDAV:iCloud"
    echo "EVENTKIT_BRIDGE_BEARER_TOKEN=$TOKEN"
  } > "$FX/conf/bridge.env"
  chmod 600 "$FX/conf/bridge.env"

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

  printf 'production' > "$FX/fields/store"
  printf 'false' > "$FX/fields/gate"
  printf '["%s"]' "$LIST_ID" > "$FX/fields/allowed_ids"
  # the items control is an object {listID: [items]}; an array here would make
  # the handler raise and look like an unreachable bridge on the client side
  printf '{}' > "$FX/fields/items"

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
# fail_on_close: every reload that is bringing the gate DOWN fails, while the
# reloads that bring it UP succeed. Selected by the value already written to the
# config file, so a test can break the restore without breaking the open.
if [ -f "$STUB_DIR/fail_on_close" ] \
   && grep -q '^EVENTKIT_BRIDGE_PRODUCTION_AUTHORIZED=false' "$STUB_DIR/conf/bridge.env"; then
  exit 1
fi
# A slow reload: proves that the budget is charged from the moment the gate is
# told to change, not from the moment the change returns.
if [ -n "${STUB_LAUNCHCTL_SLEEP:-}" ]; then
  [ -f "$STUB_DIR/reload.first" ] || date +%s > "$STUB_DIR/reload.first"
  sleep "${STUB_LAUNCHCTL_SLEEP}"
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
case "$*" in
  *lstart*) echo "STUB LSTART 00:00:00 2026" ;;
  *eww*) : ;;
  *) echo "  4242 ?? S 0:00.00 EventKitBridgeServer" ;;
esac
exit 0
STUB
  cat > "$FX/bin/shasum" <<'STUB'
#!/bin/sh
exec /usr/bin/shasum "$@"
STUB
  chmod +x "$FX/bin/"*

  export STUB_DIR="$FX"
  export R1_LOCK_DIR="$FX/lock"
  export PATH="$FX/bin:$PATH"
  REQ_LOG="$FX/requests.log"
  : > "$REQ_LOG"
  unset STUB_LAUNCHCTL_FAIL STUB_LAUNCHCTL_FAIL_AFTER STUB_LAUNCHCTL_SLEEP 2>/dev/null || true
}

start_bridge() {
  python3 "$FAKE" --field-dir "$FX/fields" --token "$TOKEN" \
    --config-file "$FX/conf/bridge.env" --plist "$FX/conf/agent.plist" \
    --request-log "$REQ_LOG" > "$FX/bridge.url" 2>/dev/null &
  BRIDGE_PID=$!
  for _ in 1 2 3 4 5 6 7 8 9 10; do [ -s "$FX/bridge.url" ] && break; sleep 0.2; done
  URL="$(cat "$FX/bridge.url")"
}
stop_bridge() { [ -n "${BRIDGE_PID:-}" ] && kill "$BRIDGE_PID" 2>/dev/null; wait "$BRIDGE_PID" 2>/dev/null; BRIDGE_PID=""; }
trap 'stop_bridge; [ -n "${WD_PID:-}" ] && kill "$WD_PID" 2>/dev/null; true' EXIT

gate_value() { awk -F= '/^EVENTKIT_BRIDGE_PRODUCTION_AUTHORIZED=/{print $2}' "$FX/conf/bridge.env"; }

# --- request-log assertions -------------------------------------------------
enumeration_calls() { awk -F'\t' '$3=="/reminders/lists"{n++} END{print n+0}' "$1"; }
item_calls() { awk -F'\t' '$3 ~ /^\/reminders\/lists\/[^\/]+\/items$/{n++} END{print n+0}' "$1"; }
health_calls() { awk -F'\t' '$3=="/health"{n++} END{print n+0}' "$1"; }
other_calls() {
  awk -F'\t' '$3!="/health" && $3 !~ /^\/reminders\/lists\/[^\/]+\/items$/{n++} END{print n+0}' "$1"
}

wait_watchdog_state() {  # $1 = state dir, $2 = timeout
  local f="$1/watchdog_status.env" waited=0
  while [ "$waited" -lt "${2:-40}" ]; do
    grep -qE '^WATCHDOG_STATE=(FIRED_[A-Z_]+|DISARMED_BY_MAIN)$' "$f" 2>/dev/null && return 0
    sleep 1; waited=$((waited + 1))
  done
  return 1
}
watchdog_state() { awk -F= '/^WATCHDOG_STATE=/{print $2}' "$1/watchdog_status.env" 2>/dev/null; }

run_window() {
  BIN="$BIN" FROZEN_SHA256="$SHA" "$WINDOW" \
    --list-id "$LIST_ID" --canary-id "$CANARY_ID" --token-file "$FX/token" \
    --plist "$FX/conf/agent.plist" --config-file "$FX/conf/bridge.env" \
    --endpoint "$URL" --work-dir "$FX/work" --label t "$@" > "$FX/window.out" 2>&1
  echo $?
}

arm_watchdog_direct() {  # $1 = deadline epoch, $2 = open budget
  # A wrapper subshell records the watchdog's exit status: disown removes it
  # from this shell's job table, so `wait` would no longer work.
  (
    "$WATCHDOG" --state-dir "$FX/wd" --deadline-epoch "$1" --open-budget "$2" \
      --plist "$FX/conf/agent.plist" --config-file "$FX/conf/bridge.env" \
      --token-file "$FX/token" --endpoint "$URL" \
      --list-id "$LIST_ID" --require-no-enumeration \
      --poll 1 --restore-attempts 2 --restore-delay 1 >> "$FX/watchdog.log" 2>&1
    echo $? > "$FX/wd/exit_code"
  ) &
  WD_PID=$!
  disown 2>/dev/null || true
  sleep 1
}
watchdog_exit() { cat "$FX/wd/exit_code" 2>/dev/null || echo "none"; }

# ============================================================ 1. normal close
echo "[1] normal window: pre -> open -> close, restore verified"
new_fixture; start_bridge
RC="$(run_window --window-seconds 60 --open-budget 30 --confirm)"
eq "window exits 0" "$RC" "0"
eq "gate is closed again on disk" "$(gate_value)" "false"
SUM="$FX/work/window-t-*/summary.json"
SUMMARY="$(cat $SUM 2>/dev/null)"
eq "summary outcome COMPLETED" \
  "$(printf '%s' "$SUMMARY" | python3 -c 'import json,sys;print(json.load(sys.stdin)["window_outcome"])' 2>/dev/null)" \
  "COMPLETED"
eq "open probe produced a resolvability classification" \
  "$(printf '%s' "$SUMMARY" | python3 -c 'import json,sys;print(json.load(sys.stdin)["open_probe_classification"])' 2>/dev/null)" \
  "RESOLVED_IDENTITY_MATCH_EMPTY"
eq "close probe says the gate is restored" \
  "$(printf '%s' "$SUMMARY" | python3 -c 'import json,sys;print(json.load(sys.stdin)["restore_probe_classification"])' 2>/dev/null)" \
  "GATE_RESTORED_CLOSED"
eq "restore reported verified" \
  "$(printf '%s' "$SUMMARY" | python3 -c 'import json,sys;print(json.load(sys.stdin)["restore_verified"])' 2>/dev/null)" \
  "True"
eq "watchdog disarmed by main" "$(watchdog_state "$FX/work/window-t-"*/state)" "DISARMED_BY_MAIN"
eq "pre receipt recorded a closed-gate baseline" \
  "$(python3 -c 'import json,glob;d=json.load(open(glob.glob("'"$FX"'/work/window-t-*/probe_pre.json")[0]));print(d["classification"])' 2>/dev/null)" \
  "GATE_CLOSED_AS_EXPECTED"
eq "pre receipt fired the canary through the allowlist" \
  "$(python3 -c 'import json,glob;d=json.load(open(glob.glob("'"$FX"'/work/window-t-*/probe_pre.json")[0]));print(d["canary"]["error_code"])' 2>/dev/null)" \
  "LIST_NOT_ALLOWED"
eq "gate receipt used the probe verifier" \
  "$(python3 -c 'import json,glob;d=json.load(open(glob.glob("'"$FX"'/work/window-t-*/gate_open.json")[0]));print(d["verification_mode"])' 2>/dev/null)" \
  "probe"
eq "zero enumeration calls in the whole run" "$(enumeration_calls "$REQ_LOG")" "0"
eq "no request outside /health and the item path" "$(other_calls "$REQ_LOG")" "0"
eq "item requests were made (4 expected)" "$(item_calls "$REQ_LOG")" "4"
eq "the summary records the stamp written before the change" \
  "$(printf '%s' "$SUMMARY" | python3 -c 'import json,sys;d=json.load(sys.stdin);print(1 if d["gate_open_since_epoch"] else 0)' 2>/dev/null)" \
  "1"
check "health was probed more than once" \
  "$([ "$(health_calls "$REQ_LOG")" -ge 3 ] && echo 1 || echo 0)" "health=$(health_calls "$REQ_LOG")"
ALL_ENUM=$((ALL_ENUM + $(enumeration_calls "$REQ_LOG")))
stop_bridge

# ============================================================ 2. main killed
echo "[2] window process SIGKILLed after the gate opened -> watchdog restores"
new_fixture; start_bridge
BIN="$BIN" FROZEN_SHA256="$SHA" "$WINDOW" \
  --list-id "$LIST_ID" --canary-id "$CANARY_ID" --token-file "$FX/token" \
  --plist "$FX/conf/agent.plist" --config-file "$FX/conf/bridge.env" \
  --endpoint "$URL" --work-dir "$FX/work" --label k \
  --window-seconds 10 --open-budget 6 --confirm > "$FX/window.out" 2>&1 &
WIN_PID=$!
opened=0
for _ in $(seq 1 60); do
  [ "$(gate_value)" = "true" ] && { opened=1; break; }
  sleep 0.5
done
eq "gate opened before the kill" "$opened" "1"
kill -9 "$WIN_PID" 2>/dev/null
wait "$WIN_PID" 2>/dev/null
STATE_DIR="$(echo "$FX"/work/window-k-*/state)"
if wait_watchdog_state "$STATE_DIR" 45; then
  check "watchdog reached a terminal state" 1
else
  check "watchdog reached a terminal state" 0 "still RUNNING after 45s"
fi
eq "watchdog fired and verified the restore" "$(watchdog_state "$STATE_DIR")" "FIRED_RESTORED"
eq "gate closed by the watchdog" "$(gate_value)" "false"
eq "the kill did not cause an enumeration" "$(enumeration_calls "$REQ_LOG")" "0"
eq "the kill did not send any other path" "$(other_calls "$REQ_LOG")" "0"
check "watchdog's close used the probe verifier" \
  "$(python3 -c 'import json,glob,os
f=glob.glob("'"$FX"'/work/window-k-*/state/gate_close_*_attempt1.json")
d=json.load(open(f[0]))
print(1 if d.get("verification_mode")=="probe" else 0)' 2>/dev/null)" "1"
check "watchdog's close asked the post-phase question, not the open one" \
  "$(python3 -c 'import json,glob
f=glob.glob("'"$FX"'/work/window-k-*/state/gate_close_*_attempt1.json")
d=json.load(open(f[0]))
print(1 if d.get("probe_phase")=="post" else 0)' 2>/dev/null)" "1"
ALL_ENUM=$((ALL_ENUM + $(enumeration_calls "$REQ_LOG")))
stop_bridge

# ============================================================ 3a. deadline
echo "[3a] watchdog fires on the absolute deadline"
new_fixture; start_bridge
"$GATE" open --plist "$FX/conf/agent.plist" --config-file "$FX/conf/bridge.env" \
  --token-file "$FX/token" --endpoint "$URL" --list-id "$LIST_ID" \
  --require-no-enumeration --purpose test:open --out "$FX/open.json" >/dev/null 2>&1
eq "gate opened for the deadline test" "$(gate_value)" "true"
mkdir -p "$FX/wd"; date +%s > "$FX/wd/gate_open_since"
arm_watchdog_direct "$(( $(date +%s) + 2 ))" 300
if wait_watchdog_state "$FX/wd" 40; then check "deadline watchdog terminal" 1; else check "deadline watchdog terminal" 0; fi
eq "deadline fired FIRED_RESTORED" "$(watchdog_state "$FX/wd")" "FIRED_RESTORED"
eq "deadline reason is recorded" \
  "$(awk -F= '/^WATCHDOG_REASON=/{print $2}' "$FX/wd/watchdog_status.env" 2>/dev/null)" "deadline"
eq "gate closed after the deadline" "$(gate_value)" "false"
eq "deadline path enumerated nothing" "$(enumeration_calls "$REQ_LOG")" "0"
stop_bridge

# ============================================================ 3b. open budget
echo "[3b] watchdog fires on the cumulative open budget"
new_fixture; start_bridge
"$GATE" open --plist "$FX/conf/agent.plist" --config-file "$FX/conf/bridge.env" \
  --token-file "$FX/token" --endpoint "$URL" --list-id "$LIST_ID" \
  --require-no-enumeration --purpose test:open --out "$FX/open.json" >/dev/null 2>&1
eq "gate opened for the budget test" "$(gate_value)" "true"
mkdir -p "$FX/wd"; printf '%s' "$(( $(date +%s) - 100 ))" > "$FX/wd/gate_open_since"
arm_watchdog_direct "$(( $(date +%s) + 300 ))" 5
if wait_watchdog_state "$FX/wd" 40; then check "budget watchdog terminal" 1; else check "budget watchdog terminal" 0; fi
eq "budget fired FIRED_RESTORED" "$(watchdog_state "$FX/wd")" "FIRED_RESTORED"
eq "budget reason is recorded" \
  "$(awk -F= '/^WATCHDOG_REASON=/{print $2}' "$FX/wd/watchdog_status.env" 2>/dev/null)" "open_budget"
eq "gate closed after the budget fired" "$(gate_value)" "false"
eq "budget path enumerated nothing" "$(enumeration_calls "$REQ_LOG")" "0"
stop_bridge

# ============================================================ 4. restore fails
echo "[4] a failed restore is reported as a failure, never as success"
new_fixture; start_bridge
"$GATE" open --plist "$FX/conf/agent.plist" --config-file "$FX/conf/bridge.env" \
  --token-file "$FX/token" --endpoint "$URL" --list-id "$LIST_ID" \
  --require-no-enumeration --purpose test:open --out "$FX/open.json" >/dev/null 2>&1
eq "gate opened for the restore-failure test" "$(gate_value)" "true"
mkdir -p "$FX/wd"; date +%s > "$FX/wd/gate_open_since"
export STUB_LAUNCHCTL_FAIL=1
arm_watchdog_direct "$(( $(date +%s) + 2 ))" 300
if wait_watchdog_state "$FX/wd" 45; then check "restore-failure watchdog terminal" 1; else check "restore-failure watchdog terminal" 0; fi
eq "failure is named, not softened" "$(watchdog_state "$FX/wd")" "FIRED_RESTORE_FAILED"
check "no receipt claims a verified restore" \
  "$(python3 -c 'import json,glob
bad=[]
for f in glob.glob("'"$FX"'/wd/gate_close_*_attempt*.json"):
    try:
        d=json.load(open(f))
    except Exception:
        continue
    if d.get("verification")=="PASS": bad.append(f)
print(1 if not bad else 0)' 2>/dev/null)" "1"
eq "watchdog exit code is 6 (restore failed)" "$(watchdog_exit)" "6"
eq "the failed restore still enumerated nothing" "$(enumeration_calls "$REQ_LOG")" "0"
ALL_ENUM=$((ALL_ENUM + $(enumeration_calls "$REQ_LOG")))
unset STUB_LAUNCHCTL_FAIL
stop_bridge

# ============================== 5. a failed restore must not disarm anything
# The window gives up on its own close. If it also writes the watchdog's stop
# file, the only remaining protection over a gate of unknown state is deleted by
# the very code that failed to close it.
echo "[5] the window cannot restore: the watchdog stays armed and still fires"
new_fixture; start_bridge
: > "$FX/fail_on_close"
RC="$(run_window --window-seconds 20 --open-budget 16 --confirm)"
eq "window reports a failed restore" "$RC" "13"
STATE_DIR="$(echo "$FX"/work/window-t-*/state)"
eq "no stop file was written" \
  "$([ -f "$STATE_DIR/stop" ] && echo present || echo absent)" "absent"
eq "the open-budget stamp was kept" \
  "$([ -f "$STATE_DIR/gate_open_since" ] && echo present || echo absent)" "present"
eq "the watchdog is still armed" "$(watchdog_state "$STATE_DIR")" "RUNNING"
eq "the summary says the restore failed, not that the window completed" \
  "$(python3 -c 'import json,glob;print(json.load(open(glob.glob("'"$FX"'/work/window-t-*/summary.json")[0]))["window_outcome"])' 2>/dev/null)" \
  "RESTORE_FAILED"
eq "the summary reports the restore as unverified" \
  "$(python3 -c 'import json,glob;print(json.load(open(glob.glob("'"$FX"'/work/window-t-*/summary.json")[0]))["restore_verified"])' 2>/dev/null)" \
  "False"
eq "the bound on restore attempts was honoured" \
  "$(python3 -c 'import json,glob;d=json.load(open(glob.glob("'"$FX"'/work/window-t-*/summary.json")[0]));print(d["restore_attempts_used"] <= d["restore_attempts_allowed"])' 2>/dev/null)" \
  "True"
# Now let the reload succeed again: the deadline the window did NOT cancel has
# to close the gate on its own.
rm -f "$FX/fail_on_close"
if wait_watchdog_state "$STATE_DIR" 45; then check "the kept watchdog still fires" 1
else check "the kept watchdog still fires" 0 "still RUNNING"; fi
eq "the watchdog restored and verified on its own" "$(watchdog_state "$STATE_DIR")" "FIRED_RESTORED"
eq "gate closed by the watchdog the window had kept armed" "$(gate_value)" "false"
eq "the failed restore enumerated nothing" "$(enumeration_calls "$REQ_LOG")" "0"
ALL_ENUM=$((ALL_ENUM + $(enumeration_calls "$REQ_LOG")))
stop_bridge

# ============================== 6. a blocked open still spends the budget
echo "[6] a blocked open is charged to the budget from before the change"
new_fixture; start_bridge
export STUB_LAUNCHCTL_SLEEP=5
RC="$(run_window --window-seconds 90 --open-budget 60 --confirm)"
unset STUB_LAUNCHCTL_SLEEP
eq "window completed despite the slow reload" "$RC" "0"
STAMP="$(cat "$FX"/work/window-t-*/state/gate_open_since)"
FIRST_RELOAD="$(cat "$FX/reload.first" 2>/dev/null || echo 0)"
check "the stamp was written before the reload was even started" \
  "$([ "$STAMP" -le "$FIRST_RELOAD" ] && echo 1 || echo 0)" \
  "stamp=$STAMP reload_started=$FIRST_RELOAD"
OPEN_RECEIPT_MTIME="$(stat -f %m "$FX"/work/window-t-*/gate_open.json 2>/dev/null || echo 0)"
check "the block was already charged when the open returned" \
  "$([ $(( OPEN_RECEIPT_MTIME - STAMP )) -ge 5 ] && echo 1 || echo 0)" \
  "open_returned_at=$OPEN_RECEIPT_MTIME stamp=$STAMP"
eq "the slow open enumerated nothing" "$(enumeration_calls "$REQ_LOG")" "0"
ALL_ENUM=$((ALL_ENUM + $(enumeration_calls "$REQ_LOG")))
stop_bridge
# ... and a watchdog reading that stamp enforces the budget the blocked open spent
new_fixture; start_bridge
"$GATE" open --plist "$FX/conf/agent.plist" --config-file "$FX/conf/bridge.env" \
  --token-file "$FX/token" --endpoint "$URL" --list-id "$LIST_ID" \
  --require-no-enumeration --purpose test:open --out "$FX/open.json" >/dev/null 2>&1
eq "gate opened for the blocked-open budget test" "$(gate_value)" "true"
mkdir -p "$FX/wd"; printf '%s' "$(( $(date +%s) - 20 ))" > "$FX/wd/gate_open_since"
arm_watchdog_direct "$(( $(date +%s) + 300 ))" 5
if wait_watchdog_state "$FX/wd" 40; then check "budget watchdog terminal" 1; else check "budget watchdog terminal" 0; fi
eq "an old stamp still trips the budget" "$(watchdog_state "$FX/wd")" "FIRED_RESTORED"
eq "the budget reason is the one recorded" \
  "$(awk -F= '/^WATCHDOG_REASON=/{print $2}' "$FX/wd/watchdog_status.env" 2>/dev/null)" "open_budget"
eq "gate closed after the budget fired" "$(gate_value)" "false"
eq "the budget path enumerated nothing" "$(enumeration_calls "$REQ_LOG")" "0"
ALL_ENUM=$((ALL_ENUM + $(enumeration_calls "$REQ_LOG")))
stop_bridge

# ============================== 7. the emergency path refuses before any change
echo "[7] an emergency close without a target ID changes nothing"
new_fixture; start_bridge
CFG_BEFORE="$(/usr/bin/shasum -a 256 "$FX/conf/bridge.env" | awk '{print $1}')"
"$CLOSE" --plist "$FX/conf/agent.plist" --config-file "$FX/conf/bridge.env" \
  --token-file "$FX/token" --endpoint "$URL" --out "$FX/emergency.json" \
  > "$FX/emergency.out" 2>&1
EMERGENCY_RC=$?
eq "the close wrapper refuses without --list-id" "$EMERGENCY_RC" "2"
eq "the config file was not touched" \
  "$(/usr/bin/shasum -a 256 "$FX/conf/bridge.env" | awk '{print $1}')" "$CFG_BEFORE"
eq "no receipt was written" \
  "$([ -f "$FX/emergency.json" ] && echo yes || echo no)" "no"
eq "the refusal happened before any request" "$(wc -l < "$REQ_LOG" | tr -d ' ')" "0"
eq "the refusal names the missing flag" \
  "$(grep -c -- '--list-id' "$FX/emergency.out" >/dev/null && echo named || echo silent)" "named"
# The gate itself keeps refusing the same half-configuration, so the wrapper is
# not the only thing standing between a typo and an enumeration.
"$GATE" close --plist "$FX/conf/agent.plist" --config-file "$FX/conf/bridge.env" \
  --token-file "$FX/token" --endpoint "$URL" --require-no-enumeration \
  --out "$FX/gateclose.json" > "$FX/gateclose.out" 2>&1
GATECLOSE_RC=$?
eq "the gate refuses --require-no-enumeration without --list-id" "$GATECLOSE_RC" "2"
eq "the config file is still untouched" \
  "$(/usr/bin/shasum -a 256 "$FX/conf/bridge.env" | awk '{print $1}')" "$CFG_BEFORE"
eq "still no request was sent" "$(wc -l < "$REQ_LOG" | tr -d ' ')" "0"
ALL_ENUM=$((ALL_ENUM + $(enumeration_calls "$REQ_LOG")))
stop_bridge

# ==================================================== 8. no open probe on retry
# Every close receipt any restore produced asked the post-phase question. A
# restore that re-ran the open probe would be re-opening the question under a
# different name, and the receipts make that visible.
echo "[8] restore retries never re-ask the open question"
new_fixture; start_bridge
"$GATE" open --plist "$FX/conf/agent.plist" --config-file "$FX/conf/bridge.env" \
  --token-file "$FX/token" --endpoint "$URL" --list-id "$LIST_ID" \
  --require-no-enumeration --purpose test:open --out "$FX/open.json" >/dev/null 2>&1
: > "$FX/fail_on_close"
mkdir -p "$FX/wd"; date +%s > "$FX/wd/gate_open_since"
arm_watchdog_direct "$(( $(date +%s) + 2 ))" 300
if wait_watchdog_state "$FX/wd" 45; then check "restore-retry watchdog terminal" 1
else check "restore-retry watchdog terminal" 0 "still RUNNING"; fi
eq "every attempt failed" "$(watchdog_state "$FX/wd")" "FIRED_RESTORE_FAILED"
check "no close receipt ever reported probe_phase=open" \
  "$(python3 -c 'import json,glob
bad = [f for f in glob.glob("'"$FX"'/wd/gate_close_*.json")
       if json.load(open(f)).get("probe_phase") == "open"]
print(1 if not bad else 0)' 2>/dev/null)" "1"
check "the retries stayed within the configured attempt bound" \
  "$([ "$(ls "$FX"/wd/gate_close_deadline_attempt*.json 2>/dev/null | wc -l | tr -d ' ')" -le 2 ] && echo 1 || echo 0)" \
  "files=$(ls "$FX"/wd/gate_close_deadline_attempt*.json 2>/dev/null | wc -l | tr -d ' ')"
eq "the retry path enumerated nothing" "$(enumeration_calls "$REQ_LOG")" "0"
ALL_ENUM=$((ALL_ENUM + $(enumeration_calls "$REQ_LOG")))
rm -f "$FX/fail_on_close"
stop_bridge

# ============================================== 9. an interrupt is not a finish
# The window is blocked inside a slow reload, with the gate already open, when
# the signal arrives. It still restores, but it must not then describe itself as
# having completed: the last thing this script may do is turn an operator's
# Ctrl-C into a clean receipt.
echo "[9] an interrupted window is never reported as completed"
new_fixture; start_bridge
export STUB_LAUNCHCTL_SLEEP=6
BIN="$BIN" FROZEN_SHA256="$SHA" "$WINDOW" \
  --list-id "$LIST_ID" --canary-id "$CANARY_ID" --token-file "$FX/token" \
  --plist "$FX/conf/agent.plist" --config-file "$FX/conf/bridge.env" \
  --endpoint "$URL" --work-dir "$FX/work" --label s \
  --window-seconds 90 --open-budget 60 --confirm > "$FX/window.out" 2>&1 &
WIN_PID=$!
# Wait for the stamp: it is written immediately before the gate is changed, so a
# signal at that point lands inside the open, not before it.
STAMPED=0
for _ in $(seq 1 60); do
  if ls "$FX"/work/window-s-*/state/gate_open_since >/dev/null 2>&1; then STAMPED=1; break; fi
  sleep 0.5
done
eq "the window reached the open before the signal" "$STAMPED" "1"
kill -TERM "$WIN_PID" 2>/dev/null
wait "$WIN_PID" 2>/dev/null
INTERRUPT_RC=$?
unset STUB_LAUNCHCTL_SLEEP
eq "the interrupted window exits 16, not 0" "$INTERRUPT_RC" "16"
eq "the outcome is TRUNCATED, never COMPLETED" \
  "$(python3 -c 'import json,glob;print(json.load(open(glob.glob("'"$FX"'/work/window-s-*/summary.json")[0]))["window_outcome"])' 2>/dev/null)" \
  "TRUNCATED"
eq "the summary marks it as truncated" \
  "$(python3 -c 'import json,glob;print(json.load(open(glob.glob("'"$FX"'/work/window-s-*/summary.json")[0]))["truncated"])' 2>/dev/null)" \
  "True"
eq "the summary marks it as interrupted" \
  "$(python3 -c 'import json,glob;print(json.load(open(glob.glob("'"$FX"'/work/window-s-*/summary.json")[0]))["interrupted"])' 2>/dev/null)" \
  "True"
eq "it still restored the gate" \
  "$(python3 -c 'import json,glob;print(json.load(open(glob.glob("'"$FX"'/work/window-s-*/summary.json")[0]))["restore_verified"])' 2>/dev/null)" \
  "True"
eq "the gate is closed on disk" "$(gate_value)" "false"
eq "the interrupted run enumerated nothing" "$(enumeration_calls "$REQ_LOG")" "0"
ALL_ENUM=$((ALL_ENUM + $(enumeration_calls "$REQ_LOG")))
stop_bridge

# ============================================================================
eq "across every scenario, the account-wide endpoint was never called" "$ALL_ENUM" "0"
echo
if [ "$FAILS" -eq 0 ]; then
  echo "$TOTAL/$TOTAL checks passed"
  echo "R1-03 PROBE WINDOW: OFFLINE_TEST_PASS"
  exit 0
fi
echo "$((TOTAL - FAILS))/$TOTAL checks passed, $FAILS FAILED"
exit 1
