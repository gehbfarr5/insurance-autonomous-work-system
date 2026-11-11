#!/usr/bin/env bash
# test_r1_r104_tools.sh — offline verification of the R1-04 offline preparation.
#
# Covers:
#   [D] r1_list_discover.py  — exact-title discovery: success (private 0600 +
#       public masked), zero candidates (UNKNOWN), multiple candidates,
#       source-type mismatch, account mismatch (sourceName and sourceID),
#       closed-gate HTTP error.
#   [R] r1_rebind.sh         — happy path (pair written, reload, strict
#       post-probe), post-probe failure with verified rollback, split-source
#       refusal, open-gate refusal, dry run, reload failure with backup
#       restoration.
#   [W] r1_discover_window.sh — W0 wiring: happy path (exactly 3 account-wide
#       reads), UNKNOWN discovery still closes the gate, launchctl failure
#       path, preflight static refusal.
#   [C] id-only capture       — capture with --skip-list-metadata touches only
#       the item endpoint; the window passes the flag through (preflight's own
#       gate check remains the single enumeration read).
#
# launchctl / codesign / pgrep / ps are replaced by stubs; the bridge is the
# loopback fake. No EventKit, no TCC, no Apple account, no real launchd job.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS="$(dirname "$HERE")"
DISCOVER="$SCRIPTS/r1_list_discover.py"
REBIND="$SCRIPTS/r1_rebind.sh"
DWINDOW="$SCRIPTS/r1_discover_window.sh"
WINDOW="$SCRIPTS/r1_window.sh"
CLIENT="$SCRIPTS/r1_bridge_client.py"
FAKE="$HERE/fake_bridge.py"

TOKEN="offline-test-token-0123456789abcdef"
OLD_ID="9D9A5AAD-E3F0-4459-8756-BBCDBCB703F3"
NEW_ID="11C2F3B4-A5D6-4E7F-8A9B-0C1D2E3F4A5B"
OLD_SRC="7B0B0000-0000-4000-8000-000000000001"
NEW_SRC="7B0B0000-0000-4000-8000-000000000001"   # same account -> same sourceID
NEW_TITLE="[MUSE-R1-04-SYNTEST] R1-04 专用列表发现核验"
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
  FX="$(mktemp -d "${TMPDIR:-/tmp}/r1r104.XXXXXX")"
  mkdir -p "$FX/bin" "$FX/fields" "$FX/work" "$FX/conf"
  BIN="$FX/EventKitBridgeServer"
  printf 'fake bridge binary for tests\n' > "$BIN"; chmod 755 "$BIN"
  SHA="$(/usr/bin/shasum -a 256 "$BIN" | awk '{print $1}')"

  printf '%s' "$TOKEN" > "$FX/token"; chmod 600 "$FX/token"

  # config file is the authoritative source (plist defines none of the keys)
  write_config() {  # $1 = gate value, $2 = allowed, $3 = bindings
    {
      echo "EVENTKIT_BRIDGE_MODE=PRODUCTION"
      echo "EVENTKIT_BRIDGE_PORT=18765"
      echo "EVENTKIT_BRIDGE_PRODUCTION_AUTHORIZED=$1"
      echo "EVENTKIT_BRIDGE_ALLOWED_LIST_IDS=$2"
      echo "EVENTKIT_BRIDGE_BINDINGS=$3"
      echo "EVENTKIT_BRIDGE_BEARER_TOKEN=$TOKEN"
    } > "$FX/conf/bridge.env"
    chmod 600 "$FX/conf/bridge.env"
  }
  write_config "false" "$OLD_ID" "$OLD_ID:$OLD_SRC:calDAV:iCloud"

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

  cat > "$FX/bin/launchctl" <<'STUB'
#!/bin/sh
echo "launchctl $*" >> "$STUB_DIR/launchctl.log"
COUNT_FILE="$STUB_DIR/launchctl.count"
N=$(cat "$COUNT_FILE" 2>/dev/null || echo 0)
N=$((N + 1)); echo "$N" > "$COUNT_FILE"
if [ -n "${STUB_LAUNCHCTL_SLEEP_ON_CALL:-}" ] && [ "$N" = "${STUB_LAUNCHCTL_SLEEP_ON_CALL:-}" ]; then
  sleep "${STUB_LAUNCHCTL_SLEEP_SECONDS:-30}"
fi
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
  *) echo "  4242 ?? S 0:00.00 EventKitBridgeServer" ;;
esac
exit 0
STUB
  cat > "$FX/bin/shasum" <<'STUB'
#!/bin/sh
exec /usr/bin/shasum "$@"
STUB
  chmod +x "$FX/bin/"*

  set_lists() { printf '%s' "$1" > "$FX/fields/lists"; }
  printf 'production' > "$FX/fields/store"
  printf '%s' "[{\"listID\":\"$OLD_ID\",\"title\":\"OLD-LIST\",\"sourceID\":\"$OLD_SRC\",\"sourceType\":\"calDAV\",\"sourceName\":\"iCloud\",\"color\":\"\",\"isImmutable\":true}]" > "$FX/fields/lists"

  GOOD_ITEM='[{"itemID":"11111111-2222-4333-8444-555555555555","title":"'"$NEW_TITLE"'","isCompleted":false,"priority":5,"listID":"'"$NEW_ID"'","notes":"'"$NOTES"'","dueDate":'"$DUE_COCOA"',"isAllDay":false}]'
  set_items() { printf '%s' "{\"$NEW_ID\": $1}" > "$FX/fields/items"; }
  set_items "[]"

  set_allowed() { printf '%s' "$1" > "$FX/fields/allowed_ids"; }
  set_allowed "[\"$OLD_ID\", \"$NEW_ID\"]"

  export STUB_DIR="$FX"
  export R1_LOCK_DIR="$FX/lock"
  export PATH="$FX/bin:$PATH"
}

start_bridge() {
  python3 "$FAKE" --field-dir "$FX/fields" --token "$TOKEN" --config-file "$FX/conf/bridge.env" \
    --plist "$FX/conf/agent.plist" \
    --request-log "$FX/requests.log" \
    > "$FX/bridge.url" 2>/dev/null &
  BRIDGE_PID=$!
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    [ -s "$FX/bridge.url" ] && break
    sleep 0.2
  done
  URL="$(cat "$FX/bridge.url")"
}

stop_bridge() { kill "$BRIDGE_PID" 2>/dev/null; wait "$BRIDGE_PID" 2>/dev/null; }

enum_reads() {  # count GET /reminders/lists in the request log
  [ -f "$FX/requests.log" ] || { echo 0; return; }
  local c
  c="$(grep -c $'\tGET\t/reminders/lists$' "$FX/requests.log" || true)"
  echo "${c:-0}"
}

config_field() { awk -F= -v k="$1" '$1==k{print $2}' "$FX/conf/bridge.env"; }

# The direct-tool scenarios ([D], [C1]) talk to the fake bridge without the
# gate script, so the config gate must already be true for /reminders/lists to
# answer 200. The window scenarios ([W]) keep it false: the window opens it.
open_config_gate() {
  sed -i '' 's/^EVENTKIT_BRIDGE_PRODUCTION_AUTHORIZED=false$/EVENTKIT_BRIDGE_PRODUCTION_AUTHORIZED=true/' "$FX/conf/bridge.env" 2>/dev/null \
    || sed -i 's/^EVENTKIT_BRIDGE_PRODUCTION_AUTHORIZED=false$/EVENTKIT_BRIDGE_PRODUCTION_AUTHORIZED=true/' "$FX/conf/bridge.env"
}

# ================================================================ [D] discover
echo "[D1] discover: exact single match, sourceID equals the binding"
new_fixture; start_bridge
open_config_gate
NEW_LIST_JSON="[{\"listID\":\"$NEW_ID\",\"title\":\"$NEW_TITLE\",\"sourceID\":\"$NEW_SRC\",\"sourceType\":\"calDAV\",\"sourceName\":\"iCloud\",\"color\":\"\",\"isImmutable\":true},{\"listID\":\"AAAB0000-0000-4000-8000-0000000000AA\",\"title\":\"Other List\",\"sourceID\":\"$OLD_SRC\",\"sourceType\":\"calDAV\",\"sourceName\":\"iCloud\",\"color\":\"\",\"isImmutable\":true}]"
printf '%s' "$NEW_LIST_JSON" > "$FX/fields/lists"
RC="$(python3 "$DISCOVER" --endpoint "$URL" --token-file "$FX/token" \
  --title "$NEW_TITLE" --expect-source-id "$OLD_SRC" \
  --private-out "$FX/work/priv.json" --out "$FX/work/pub.json" >/dev/null 2>"$FX/d1.err"; echo $?)"
eq "exit code 0" "$RC" "0"
[ -f "$FX/work/priv.json" ] && check "private record written" 1 || check "private record written" 0
PRIV_PERM="$(python3 -c 'import os,sys;print(oct(os.stat(sys.argv[1]).st_mode & 0o777))' "$FX/work/priv.json" 2>/dev/null)"
eq "private record is 0600" "$PRIV_PERM" "0o600"
grep -q "$NEW_ID" "$FX/work/priv.json" && check "private record holds the full listID" 1 || check "private record holds the full listID" 0
if grep -q "$NEW_ID" "$FX/work/pub.json"; then check "public receipt carries no full listID" 0; else check "public receipt carries no full listID" 1; fi
grep -q "$NEW_ID" "$FX/d1.err" 2>/dev/null && check "stderr leaks no full listID" 0 || check "stderr leaks no full listID" 1
grep -q '"decision": "DISCOVERED"' "$FX/work/pub.json" && check "decision DISCOVERED" 1 || check "decision DISCOVERED" 0
# a second run refuses to overwrite the private record
RC2="$(python3 "$DISCOVER" --endpoint "$URL" --token-file "$FX/token" \
  --title "$NEW_TITLE" --expect-source-id "$OLD_SRC" \
  --private-out "$FX/work/priv.json" --out "$FX/work/pub2.json" >/dev/null 2>&1; echo $?)"
eq "second run refuses to overwrite the private record" "$RC2" "2"
stop_bridge

echo "[D2] discover: zero candidates is UNKNOWN, no retry, no private write"
new_fixture; start_bridge
open_config_gate
printf '%s' '[{"listID":"AAAB0000-0000-4000-8000-0000000000AA","title":"Other List","sourceID":"'"$OLD_SRC"'","sourceType":"calDAV","sourceName":"iCloud","color":"","isImmutable":true}]' > "$FX/fields/lists"
RC="$(python3 "$DISCOVER" --endpoint "$URL" --token-file "$FX/token" \
  --title "$NEW_TITLE" --private-out "$FX/work/priv.json" --out "$FX/work/pub.json" >/dev/null 2>&1; echo $?)"
eq "exit code 40" "$RC" "40"
[ ! -e "$FX/work/priv.json" ] && check "no private record on UNKNOWN" 1 || check "no private record on UNKNOWN" 0
grep -q "UNKNOWN_ZERO_CANDIDATES" "$FX/work/pub.json" && check "decision UNKNOWN_ZERO_CANDIDATES" 1 || check "decision UNKNOWN_ZERO_CANDIDATES" 0
stop_bridge

echo "[D3] discover: two candidates with the same title is ambiguous"
new_fixture; start_bridge
open_config_gate
CAND="[{\"listID\":\"$NEW_ID\",\"title\":\"$NEW_TITLE\",\"sourceID\":\"$NEW_SRC\",\"sourceType\":\"calDAV\",\"sourceName\":\"iCloud\",\"color\":\"\",\"isImmutable\":true},{\"listID\":\"BBBC0000-0000-4000-8000-0000000000BB\",\"title\":\"$NEW_TITLE\",\"sourceID\":\"$NEW_SRC\",\"sourceType\":\"calDAV\",\"sourceName\":\"iCloud\",\"color\":\"\",\"isImmutable\":true}]"
printf '%s' "$CAND" > "$FX/fields/lists"
RC="$(python3 "$DISCOVER" --endpoint "$URL" --token-file "$FX/token" \
  --title "$NEW_TITLE" --private-out "$FX/work/priv.json" --out "$FX/work/pub.json" >/dev/null 2>&1; echo $?)"
eq "exit code 41" "$RC" "41"
[ ! -e "$FX/work/priv.json" ] && check "no private record on ambiguity" 1 || check "no private record on ambiguity" 0
stop_bridge

echo "[D4] discover: sourceType mismatch refuses"
new_fixture; start_bridge
open_config_gate
printf '%s' "[{\"listID\":\"$NEW_ID\",\"title\":\"$NEW_TITLE\",\"sourceID\":\"$NEW_SRC\",\"sourceType\":\"local\",\"sourceName\":\"On My Mac\",\"color\":\"\",\"isImmutable\":true}]" > "$FX/fields/lists"
RC="$(python3 "$DISCOVER" --endpoint "$URL" --token-file "$FX/token" \
  --title "$NEW_TITLE" --private-out "$FX/work/priv.json" --out "$FX/work/pub.json" >/dev/null 2>&1; echo $?)"
eq "exit code 42" "$RC" "42"
grep -q "SOURCE_TYPE_MISMATCH" "$FX/work/pub.json" && check "decision SOURCE_TYPE_MISMATCH" 1 || check "decision SOURCE_TYPE_MISMATCH" 0
stop_bridge

echo "[D5] discover: account mismatch (sourceName, then sourceID)"
new_fixture; start_bridge
open_config_gate
printf '%s' "[{\"listID\":\"$NEW_ID\",\"title\":\"$NEW_TITLE\",\"sourceID\":\"$NEW_SRC\",\"sourceType\":\"calDAV\",\"sourceName\":\"On My Mac\",\"color\":\"\",\"isImmutable\":true}]" > "$FX/fields/lists"
RC="$(python3 "$DISCOVER" --endpoint "$URL" --token-file "$FX/token" \
  --title "$NEW_TITLE" --private-out "$FX/work/priv.json" --out "$FX/work/pub.json" >/dev/null 2>&1; echo $?)"
eq "sourceName mismatch exits 43" "$RC" "43"
printf '%s' "[{\"listID\":\"$NEW_ID\",\"title\":\"$NEW_TITLE\",\"sourceID\":\"DDDD0000-0000-4000-8000-0000000000DD\",\"sourceType\":\"calDAV\",\"sourceName\":\"iCloud\",\"color\":\"\",\"isImmutable\":true}]" > "$FX/fields/lists"
RC="$(python3 "$DISCOVER" --endpoint "$URL" --token-file "$FX/token" \
  --title "$NEW_TITLE" --expect-source-id "$OLD_SRC" \
  --private-out "$FX/work/priv2.json" --out "$FX/work/pub.json" >/dev/null 2>&1; echo $?)"
eq "sourceID mismatch exits 43" "$RC" "43"
stop_bridge

echo "[D6] discover: closed gate answers 403 -> HTTP error"
new_fixture; start_bridge   # config gate=false
RC="$(python3 "$DISCOVER" --endpoint "$URL" --token-file "$FX/token" \
  --title "$NEW_TITLE" --private-out "$FX/work/priv.json" --out "$FX/work/pub.json" >/dev/null 2>&1; echo $?)"
eq "exit code 3" "$RC" "3"
grep -q "DISCOVER_HTTP_ERROR" "$FX/work/pub.json" && check "decision DISCOVER_HTTP_ERROR" 1 || check "decision DISCOVER_HTTP_ERROR" 0
stop_bridge

# ================================================================= [R] rebind
echo "[R1] rebind: happy path - pair written, reload, strict post-probe"
new_fixture; start_bridge
set_items "$GOOD_ITEM"
RC="$(BIN="$BIN" "$REBIND" --plist "$FX/conf/agent.plist" --config-file "$FX/conf/bridge.env" \
  --token-file "$FX/token" --endpoint "$URL" --out "$FX/work/rebind.json" \
  --old-list-id "$OLD_ID" --new-list-id "$NEW_ID" --new-source-id "$NEW_SRC" \
  --purpose "test" >"$FX/r1.out" 2>&1; echo $?)"
eq "exit code 0" "$RC" "0"
eq "allowlist now the new id" "$(config_field EVENTKIT_BRIDGE_ALLOWED_LIST_IDS)" "$NEW_ID"
eq "bindings now the new pair" "$(config_field EVENTKIT_BRIDGE_BINDINGS)" "$NEW_ID:$NEW_SRC:calDAV:iCloud"
eq "gate key untouched" "$(config_field EVENTKIT_BRIDGE_PRODUCTION_AUTHORIZED)" "false"
grep -q "kickstart" "$FX/launchctl.log" && check "service reloaded" 1 || check "service reloaded" 0
grep -q '"verification": "PASS"' "$FX/work/rebind.json" && check "receipt verification PASS" 1 || check "receipt verification PASS" 0
grep -q '"pre_check_classification": "GATE_AS_EXPECTED"' "$FX/work/rebind.json" && check "pre-check gate-not-open label" 1 || check "pre-check gate-not-open label" 0
grep -q "GATE_RESTORED_CLOSED" "$FX/work/rebind.json" && check "post-probe strict closed-gate label" 1 || check "post-probe strict closed-gate label" 0
eq "exactly 1 enumeration read (pre-check; post-probe is item-scoped)" "$(enum_reads)" "1"
RB_PERM="$(python3 -c 'import os,sys;print(oct(os.stat(sys.argv[1]).st_mode & 0o777))' "$FX/work/rebind.json.config-backup" 2>/dev/null)"
eq "config backup is 0600" "$RB_PERM" "0o600"
stop_bridge

echo "[R2] rebind: post-probe failure rolls back to the old pair"
new_fixture; start_bridge
set_allowed "[\"$OLD_ID\"]"   # the new id is NOT allowlisted -> post-probe fails
RC="$(BIN="$BIN" "$REBIND" --plist "$FX/conf/agent.plist" --config-file "$FX/conf/bridge.env" \
  --token-file "$FX/token" --endpoint "$URL" --out "$FX/work/rebind.json" \
  --old-list-id "$OLD_ID" --new-list-id "$NEW_ID" --new-source-id "$NEW_SRC" \
  >"$FX/r2.out" 2>&1; echo $?)"
eq "exit code 3" "$RC" "3"
eq "allowlist restored" "$(config_field EVENTKIT_BRIDGE_ALLOWED_LIST_IDS)" "$OLD_ID"
eq "bindings restored" "$(config_field EVENTKIT_BRIDGE_BINDINGS)" "$OLD_ID:$OLD_SRC:calDAV:iCloud"
grep -q '"rolled_back": true' "$FX/work/rebind.json" && check "receipt records the rollback" 1 || check "receipt records the rollback" 0
grep -q '"verification": "FAIL"' "$FX/work/rebind.json" && check "receipt verification FAIL" 1 || check "receipt verification FAIL" 0
grep -q "BLOCKED_NOT_ON_ALLOWLIST" "$FX/work/rebind.json" && check "post-probe classification kept" 1 || check "post-probe classification kept" 0
[ -f "$FX/work/rebind.json.rollbackprobe.json" ] && check "rollback re-probe receipt kept" 1 || check "rollback re-probe receipt kept" 0
stop_bridge

echo "[R3] rebind: split-source configuration is refused"
new_fixture; start_bridge
# bindings key only in the plist -> the pair is split across sources
cat > "$FX/conf/agent.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.muse.macserver-eventkit</string>
  <key>EnvironmentVariables</key><dict>
    <key>EVENTKIT_BRIDGE_MODE</key><string>PRODUCTION</string>
    <key>EVENTKIT_BRIDGE_BINDINGS</key><string>$OLD_ID:$OLD_SRC:calDAV:iCloud</string>
  </dict>
</dict></plist>
PLIST
RC="$(BIN="$BIN" "$REBIND" --plist "$FX/conf/agent.plist" --config-file "$FX/conf/bridge.env" \
  --token-file "$FX/token" --endpoint "$URL" --out "$FX/work/rebind.json" \
  --old-list-id "$OLD_ID" --new-list-id "$NEW_ID" --new-source-id "$NEW_SRC" \
  >"$FX/r3.out" 2>&1; echo $?)"
eq "exit code 5" "$RC" "5"
eq "config untouched" "$(config_field EVENTKIT_BRIDGE_ALLOWED_LIST_IDS)" "$OLD_ID"
stop_bridge

echo "[R4] rebind: an open gate is refused by the enumeration pre-check"
new_fixture; start_bridge
open_config_gate
set_items "$GOOD_ITEM"
RC="$(BIN="$BIN" "$REBIND" --plist "$FX/conf/agent.plist" --config-file "$FX/conf/bridge.env" \
  --token-file "$FX/token" --endpoint "$URL" --out "$FX/work/rebind.json" \
  --old-list-id "$OLD_ID" --new-list-id "$NEW_ID" --new-source-id "$NEW_SRC" \
  >"$FX/r4.out" 2>&1; echo $?)"
eq "exit code 3" "$RC" "3"
eq "config untouched" "$(config_field EVENTKIT_BRIDGE_ALLOWED_LIST_IDS)" "$OLD_ID"
grep -q "GATE_UNEXPECTED_HTTP_200" "$FX/work/rebind.json" && check "pre-check observed GATE_UNEXPECTED_HTTP_200" 1 || check "pre-check observed GATE_UNEXPECTED_HTTP_200" 0
grep -q "failure_stage.: .pre_check" "$FX/work/rebind.json" && check "failure stage pre_check" 1 || check "failure stage pre_check" 0
stop_bridge

echo "[R5] rebind: dry run changes nothing"
new_fixture; start_bridge
RC="$(BIN="$BIN" "$REBIND" --plist "$FX/conf/agent.plist" --config-file "$FX/conf/bridge.env" \
  --token-file "$FX/token" --endpoint "$URL" --out "$FX/work/rebind.json" \
  --old-list-id "$OLD_ID" --new-list-id "$NEW_ID" --new-source-id "$NEW_SRC" \
  --dry-run >"$FX/r5.out" 2>&1; echo $?)"
eq "exit code 0" "$RC" "0"
eq "config untouched" "$(config_field EVENTKIT_BRIDGE_ALLOWED_LIST_IDS)" "$OLD_ID"
grep -q "DRY RUN" "$FX/r5.out" && check "prints DRY RUN" 1 || check "prints DRY RUN" 0
stop_bridge

echo "[R6] rebind: reload failure restores the backups and reports 4"
new_fixture; start_bridge
STUB_LAUNCHCTL_FAIL=1
RC="$(BIN="$BIN" STUB_LAUNCHCTL_FAIL=1 "$REBIND" --plist "$FX/conf/agent.plist" --config-file "$FX/conf/bridge.env" \
  --token-file "$FX/token" --endpoint "$URL" --out "$FX/work/rebind.json" \
  --old-list-id "$OLD_ID" --new-list-id "$NEW_ID" --new-source-id "$NEW_SRC" \
  >"$FX/r6.out" 2>&1; echo $?)"
eq "exit code 4" "$RC" "4"
eq "allowlist restored" "$(config_field EVENTKIT_BRIDGE_ALLOWED_LIST_IDS)" "$OLD_ID"
eq "bindings restored" "$(config_field EVENTKIT_BRIDGE_BINDINGS)" "$OLD_ID:$OLD_SRC:calDAV:iCloud"
grep -q "failure_stage.: .reload" "$FX/work/rebind.json" && check "failure stage reload" 1 || check "failure stage reload" 0
grep -q '"rolled_back": true' "$FX/work/rebind.json" && check "backups restored" 1 || check "backups restored" 0
grep -q '"rollback_verification"' "$FX/work/rebind.json" && check "rollback verification recorded" 1 || check "rollback verification recorded" 0
stop_bridge

echo "[R7] rebind: deadline mid-reload -> bounded recovery reloads the old config and verifies it"
new_fixture; start_bridge
set_allowed "[\"$OLD_ID\"]"   # after the rollback the NEW id must fail the OLD allowlist
set_items "$GOOD_ITEM"
rm -f "$FX/requests.log" "$FX/launchctl.log"
# op budget 3s; the FIRST launchctl call (the kickstart reload) sleeps 30s and is
# killed mid-flight by run_bounded -> deadline_exit -> recovery: restore backups,
# reload again (call 2, no sleep), then health + gate 403 + new-id
# BLOCKED_NOT_ON_ALLOWLIST under the recovery clock.
RC="$(BIN="$BIN" STUB_LAUNCHCTL_SLEEP_ON_CALL=1 STUB_LAUNCHCTL_SLEEP_SECONDS=30 \
  "$REBIND" --plist "$FX/conf/agent.plist" --config-file "$FX/conf/bridge.env" \
  --token-file "$FX/token" --endpoint "$URL" --out "$FX/work/rebind.json" \
  --old-list-id "$OLD_ID" --new-list-id "$NEW_ID" --new-source-id "$NEW_SRC" \
  --op-timeout 3 >"$FX/r7.out" 2>&1; echo $?)"
eq "exit code 8 (deadline is never a success)" "$RC" "8"
eq "allowlist restored on disk" "$(config_field EVENTKIT_BRIDGE_ALLOWED_LIST_IDS)" "$OLD_ID"
eq "bindings restored on disk" "$(config_field EVENTKIT_BRIDGE_BINDINGS)" "$OLD_ID:$OLD_SRC:calDAV:iCloud"
KICKS="$(grep -c kickstart "$FX/launchctl.log" 2>/dev/null || echo 0)"
eq "reload attempted twice (killed + recovery)" "$KICKS" "2"
grep -q '"deadline_phase": "reload"' "$FX/work/rebind.json" && check "deadline phase recorded" 1 || check "deadline phase recorded" 0
grep -q '"reloaded": true' "$FX/work/rebind.json" && check "recovery reloaded the old config" 1 || check "recovery reloaded the old config" 0
grep -q '"health": "OK"' "$FX/work/rebind.json" && check "recovery health OK" 1 || check "recovery health OK" 0
grep -q '"gate_check": "GATE_AS_EXPECTED"' "$FX/work/rebind.json" && check "recovery gate closed" 1 || check "recovery gate closed" 0
grep -q '"new_id_probe": "BLOCKED_NOT_ON_ALLOWLIST"' "$FX/work/rebind.json" && check "recovery: old allowlist proven live (new id refused)" 1 || check "recovery: old allowlist proven live (new id refused)" 0
grep -q '"verdict": "VERIFIED"' "$FX/work/rebind.json" && check "recovery verdict VERIFIED" 1 || check "recovery verdict VERIFIED" 0
eq "recovery reads: 2 enumeration (pre-check + recovery gate), 1 item (new id)" "$(enum_reads)" "2"
grep -q "GATE_UNEXPECTED" "$FX/work/rebind.json" && check "no unexpected gate state" 0 || check "no unexpected gate state" 1
[ -f "$FX/work/rebind.json.recovery-health.json" ] && check "recovery health receipt kept" 1 || check "recovery health receipt kept" 0
[ -f "$FX/work/rebind.json.recovery-probe.json" ] && check "recovery probe receipt kept" 1 || check "recovery probe receipt kept" 0
stop_bridge
cleanup_watchdogs() {
  for d in "$FX"/work/discover-*; do
    [ -d "$d" ] || continue
    : > "$d/state/stop" 2>/dev/null
  done
  sleep 1.5
}

echo "[W1] W0 happy path: open, discover, close; exactly 3 enumeration reads"
new_fixture; start_bridge
set_lists "[{\"listID\":\"$NEW_ID\",\"title\":\"$NEW_TITLE\",\"sourceID\":\"$NEW_SRC\",\"sourceType\":\"calDAV\",\"sourceName\":\"iCloud\",\"color\":\"\",\"isImmutable\":true}]"
RC="$(BIN="$BIN" FROZEN_SHA256="$SHA" "$DWINDOW" \
  --title "$NEW_TITLE" --expect-source-id "$OLD_SRC" \
  --token-file "$FX/token" --plist "$FX/conf/agent.plist" \
  --config-file "$FX/conf/bridge.env" --endpoint "$URL" \
  --work-dir "$FX/work" --label t --confirm >"$FX/w1.out" 2>&1; echo $?)"
eq "exit code 0" "$RC" "0"
eq "exactly 3 account-wide reads" "$(enum_reads)" "3"
eq "gate back to false" "$(config_field EVENTKIT_BRIDGE_PRODUCTION_AUTHORIZED)" "false"
SUM="$(ls "$FX"/work/discover-*/discover_summary.json 2>/dev/null | head -1)"
[ -n "$SUM" ] && check "summary written" 1 || check "summary written" 0
grep -q '"discovery_outcome": "DISCOVERED"' "$SUM" 2>/dev/null && check "summary DISCOVERED" 1 || check "summary DISCOVERED" 0
PRIV="$(ls "$FX"/work/discover-*/state/discovered_binding.json 2>/dev/null | head -1)"
[ -n "$PRIV" ] && check "private discovery record inside the run dir" 1 || check "private discovery record inside the run dir" 0
PRIV_PERM="$(python3 -c 'import os,sys;print(oct(os.stat(sys.argv[1]).st_mode & 0o777))' "$PRIV" 2>/dev/null)"
eq "private record is 0600" "$PRIV_PERM" "0o600"
grep -q '"restore_verified": true' "$SUM" 2>/dev/null && check "restore verified" 1 || check "restore verified" 0
cleanup_watchdogs; stop_bridge

echo "[W2] W0: UNKNOWN discovery still closes the gate and reports 12"
new_fixture; start_bridge   # lists contains only the old list -> title not found
RC="$(BIN="$BIN" FROZEN_SHA256="$SHA" "$DWINDOW" \
  --title "$NEW_TITLE" --token-file "$FX/token" --plist "$FX/conf/agent.plist" \
  --config-file "$FX/conf/bridge.env" --endpoint "$URL" \
  --work-dir "$FX/work" --label t --confirm >"$FX/w2.out" 2>&1; echo $?)"
eq "exit code 12" "$RC" "12"
eq "gate back to false" "$(config_field EVENTKIT_BRIDGE_PRODUCTION_AUTHORIZED)" "false"
eq "still exactly 3 account-wide reads" "$(enum_reads)" "3"
SUM="$(ls "$FX"/work/discover-*/discover_summary.json 2>/dev/null | head -1)"
grep -q '"discovery_outcome": "UNKNOWN_ZERO_CANDIDATES"' "$SUM" 2>/dev/null && check "summary UNKNOWN_ZERO_CANDIDATES" 1 || check "summary UNKNOWN_ZERO_CANDIDATES" 0
[ ! -e "$(ls "$FX"/work/discover-*/state/discovered_binding.json 2>/dev/null | head -1)" ] && check "no private record on UNKNOWN" 1 || check "no private record on UNKNOWN" 0
grep -q "no retry inside this window" "$FX/w2.out" && check "no-retry message shown" 1 || check "no-retry message shown" 0
cleanup_watchdogs; stop_bridge

echo "[W3] W0: launchctl failure on open leads to a close attempt and exit 13"
new_fixture; start_bridge
RC="$(BIN="$BIN" FROZEN_SHA256="$SHA" STUB_LAUNCHCTL_FAIL=1 "$DWINDOW" \
  --title "$NEW_TITLE" --token-file "$FX/token" --plist "$FX/conf/agent.plist" \
  --config-file "$FX/conf/bridge.env" --endpoint "$URL" \
  --work-dir "$FX/work" --label t --confirm >"$FX/w3.out" 2>&1; echo $?)"
eq "exit code 13" "$RC" "13"
eq "gate stays false" "$(config_field EVENTKIT_BRIDGE_PRODUCTION_AUTHORIZED)" "false"
cleanup_watchdogs; stop_bridge

echo "[W4] W0 preflight: a gate that is already true is refused statically"
new_fixture; start_bridge
sed -i '' 's/^EVENTKIT_BRIDGE_PRODUCTION_AUTHORIZED=false$/EVENTKIT_BRIDGE_PRODUCTION_AUTHORIZED=true/' "$FX/conf/bridge.env" 2>/dev/null \
  || sed -i 's/^EVENTKIT_BRIDGE_PRODUCTION_AUTHORIZED=false$/EVENTKIT_BRIDGE_PRODUCTION_AUTHORIZED=true/' "$FX/conf/bridge.env"
RC="$(BIN="$BIN" FROZEN_SHA256="$SHA" "$DWINDOW" \
  --title "$NEW_TITLE" --token-file "$FX/token" --plist "$FX/conf/agent.plist" \
  --config-file "$FX/conf/bridge.env" --endpoint "$URL" \
  --work-dir "$FX/work" --label t --confirm >"$FX/w4.out" 2>&1; echo $?)"
eq "exit code 10" "$RC" "10"
grep -q "gate is already true" "$FX/w4.out" && check "static refusal reported" 1 || check "static refusal reported" 0
stop_bridge

# ==================================================== [C] id-only capture
echo "[C1] capture --skip-list-metadata touches only the item endpoint"
new_fixture; start_bridge
sed -i '' 's/^EVENTKIT_BRIDGE_PRODUCTION_AUTHORIZED=false$/EVENTKIT_BRIDGE_PRODUCTION_AUTHORIZED=true/' "$FX/conf/bridge.env" 2>/dev/null \
  || sed -i 's/^EVENTKIT_BRIDGE_PRODUCTION_AUTHORIZED=false$/EVENTKIT_BRIDGE_PRODUCTION_AUTHORIZED=true/' "$FX/conf/bridge.env"
set_allowed "[\"$NEW_ID\"]"
set_lists "[{\"listID\":\"$NEW_ID\",\"title\":\"$NEW_TITLE\",\"sourceID\":\"$NEW_SRC\",\"sourceType\":\"calDAV\",\"sourceName\":\"iCloud\",\"color\":\"\",\"isImmutable\":true}]"
set_items "$GOOD_ITEM"
rm -f "$FX/requests.log"
RC="$(python3 "$CLIENT" capture --endpoint "$URL" --token-file "$FX/token" \
  --list-id "$NEW_ID" --expect-title "$NEW_TITLE" --expect-notes "$NOTES" \
  --expect-due-utc "$DUE_UTC" --expect presence --skip-list-metadata \
  --batch-dir "$FX/work/batch-skip" --label t >/dev/null 2>&1; echo $?)"
eq "capture exit code 0" "$RC" "0"
eq "zero enumeration reads with the flag" "$(enum_reads)" "0"
grep -q '"skipped": true' "$FX/work/batch-skip/capture.json" && check "list_metadata skipped in receipt" 1 || check "list_metadata skipped in receipt" 0
rm -f "$FX/requests.log"
RC="$(python3 "$CLIENT" capture --endpoint "$URL" --token-file "$FX/token" \
  --list-id "$NEW_ID" --expect-title "$NEW_TITLE" --expect-notes "$NOTES" \
  --expect-due-utc "$DUE_UTC" --expect presence \
  --batch-dir "$FX/work/batch-meta" --label t >/dev/null 2>&1; echo $?)"
eq "default capture exit code 0" "$RC" "0"
eq "exactly one enumeration read without the flag" "$(enum_reads)" "1"
stop_bridge

echo "[C2] window --skip-metadata passes the flag through (3 enumeration reads remain: preflight + open verify + close verify)"
new_fixture; start_bridge
set_allowed "[\"$NEW_ID\"]"
set_lists "[{\"listID\":\"$NEW_ID\",\"title\":\"$NEW_TITLE\",\"sourceID\":\"$NEW_SRC\",\"sourceType\":\"calDAV\",\"sourceName\":\"iCloud\",\"color\":\"\",\"isImmutable\":true}]"
set_items "$GOOD_ITEM"
sed -i '' "s/^EVENTKIT_BRIDGE_ALLOWED_LIST_IDS=$OLD_ID$/EVENTKIT_BRIDGE_ALLOWED_LIST_IDS=$NEW_ID/" "$FX/conf/bridge.env" 2>/dev/null \
  || sed -i "s/^EVENTKIT_BRIDGE_ALLOWED_LIST_IDS=$OLD_ID$/EVENTKIT_BRIDGE_ALLOWED_LIST_IDS=$NEW_ID/" "$FX/conf/bridge.env"
sed -i '' "s/^EVENTKIT_BRIDGE_BINDINGS=$OLD_ID:$OLD_SRC:calDAV:iCloud$/EVENTKIT_BRIDGE_BINDINGS=$NEW_ID:$NEW_SRC:calDAV:iCloud/" "$FX/conf/bridge.env" 2>/dev/null \
  || sed -i "s/^EVENTKIT_BRIDGE_BINDINGS=$OLD_ID:$OLD_SRC:calDAV:iCloud$/EVENTKIT_BRIDGE_BINDINGS=$NEW_ID:$NEW_SRC:calDAV:iCloud/" "$FX/conf/bridge.env"
RC="$(BIN="$BIN" FROZEN_SHA256="$SHA" "$WINDOW" \
  --list-id "$NEW_ID" --expect-title "$NEW_TITLE" --expect-notes "$NOTES" \
  --expect-due-utc "$DUE_UTC" --token-file "$FX/token" \
  --plist "$FX/conf/agent.plist" --config-file "$FX/conf/bridge.env" \
  --endpoint "$URL" --work-dir "$FX/work" --label t --passes 2 --interval 1 \
  --skip-metadata --confirm >"$FX/c2.out" 2>&1; echo $?)"
eq "window exit code 0" "$RC" "0"
eq "exactly 3 enumeration reads (preflight 403, open 200, close 403)" "$(enum_reads)" "3"
grep -q '"skipped": true' "$FX"/work/window-*/batch-1-t/capture.json 2>/dev/null && check "batch receipt records the skipped metadata" 1 || check "batch receipt records the skipped metadata" 0
grep -q "skip_metadata=yes" "$FX/c2.out" && check "plan line records skip_metadata" 1 || check "plan line records skip_metadata" 0
stop_bridge

# ---------------------------------------------------------------- result
echo
echo "TOTAL=$TOTAL FAIL=$FAILS"
if [ "$FAILS" -eq 0 ]; then
  echo "R1-04 TOOLS: ALL TESTS PASSED"
  exit 0
fi
echo "R1-04 TOOLS: FAILURES PRESENT"
exit 1
