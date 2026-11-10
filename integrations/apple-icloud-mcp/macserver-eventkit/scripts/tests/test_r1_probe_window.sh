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
FAKE="$HERE/fake_bridge.py"

TOKEN="offline-test-token-0123456789abcdef"
LIST_ID="9D9A5AAD-E3F0-4459-8756-BBCDBCB703F3"
CANARY_ID="R1-CANARY-00000000-0000-0000-0000-000000000000"
FAILS=0; TOTAL=0

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
  unset STUB_LAUNCHCTL_FAIL STUB_LAUNCHCTL_FAIL_AFTER 2>/dev/null || true
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
check "health was probed more than once" \
  "$([ "$(health_calls "$REQ_LOG")" -ge 3 ] && echo 1 || echo 0)" "health=$(health_calls "$REQ_LOG")"
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
unset STUB_LAUNCHCTL_FAIL
stop_bridge

# ============================================================================
echo
if [ "$FAILS" -eq 0 ]; then
  echo "$TOTAL/$TOTAL checks passed"
  echo "R1-03 PROBE WINDOW: OFFLINE_TEST_PASS"
  exit 0
fi
echo "$((TOTAL - FAILS))/$TOTAL checks passed, $FAILS FAILED"
exit 1
