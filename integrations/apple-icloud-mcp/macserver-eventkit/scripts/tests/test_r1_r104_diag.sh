#!/usr/bin/env bash
# test_r1_r104_diag.sh — offline verification of the R1-04 digest diagnostic.
#
# Covers:
#   [G1] r1_title_digest_diag.py — variant match (trailing-space title),
#        private 0600 with NO titles, public receipt masked, no full listID.
#   [G2] exact match -> DIGEST_MATCH_EXACT.
#   [G3] no match -> exit 40, NO_DIGEST_MATCH, private digests-only record.
#   [G4] closed gate -> exit 3 DIAG_HTTP_ERROR.
#   [G5] r1_digest_window.sh — window wiring: exactly 3 account-wide reads,
#        match path exits 0 with gate restored; no-match path exits 12 with
#        gate restored.
#   [G6] second run refuses to overwrite the private record.
#
# launchctl / codesign / pgrep / ps are replaced by stubs; the bridge is the
# loopback fake. No EventKit, no TCC, no Apple account, no real launchd job.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS="$(dirname "$HERE")"
DIAG="$SCRIPTS/r1_title_digest_diag.py"
DWINDOW="$SCRIPTS/r1_digest_window.sh"
CLIENT="$SCRIPTS/r1_bridge_client.py"
FAKE="$HERE/fake_bridge.py"

TOKEN="offline-test-token-0123456789abcdef"
OLD_ID="9D9A5AAD-E3F0-4459-8756-BBCDBCB703F3"
OLD_SRC="7B0B0000-0000-4000-8000-000000000001"
TARGET="MUSE-R1-04-SYNTEST"
OTHER_TITLE="Secret-List-Title-XYZ"
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
  FX="$(mktemp -d "${TMPDIR:-/tmp}/r1diag.XXXXXX")"
  mkdir -p "$FX/bin" "$FX/fields" "$FX/work" "$FX/conf"
  BIN="$FX/EventKitBridgeServer"
  printf 'fake bridge binary for tests\n' > "$BIN"; chmod 755 "$BIN"

  printf '%s' "$TOKEN" > "$FX/token"; chmod 600 "$FX/token"

  write_config() {  # $1 = gate value
    {
      echo "EVENTKIT_BRIDGE_MODE=PRODUCTION"
      echo "EVENTKIT_BRIDGE_PORT=18765"
      echo "EVENTKIT_BRIDGE_PRODUCTION_AUTHORIZED=$1"
      echo "EVENTKIT_BRIDGE_ALLOWED_LIST_IDS=$OLD_ID"
      echo "EVENTKIT_BRIDGE_BINDINGS=$OLD_ID:$OLD_SRC:calDAV:iCloud"
      echo "EVENTKIT_BRIDGE_BEARER_TOKEN=$TOKEN"
    } > "$FX/conf/bridge.env"
    chmod 600 "$FX/conf/bridge.env"
  }
  write_config "false"

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

  printf 'production' > "$FX/fields/store"

  set_lists() { printf '%s' "$1" > "$FX/fields/lists"; }
  set_lists "$LISTS_JSON_DEFAULT"

  set_allowed() { printf '%s' "$1" > "$FX/fields/allowed_ids"; }
  set_allowed "[\"$OLD_ID\"]"

  export STUB_DIR="$FX"
  export R1_LOCK_DIR="$FX/lock"
  export PATH="$FX/bin:$PATH"
}

LISTS_JSON_DEFAULT='[{"listID":"AAAB0000-0000-4000-8000-0000000000AA","title":"'"$OTHER_TITLE"'","sourceID":"'"$OLD_SRC"'","sourceType":"calDAV","sourceName":"iCloud","color":"","isImmutable":true}]'

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

enum_reads() {
  [ -f "$FX/requests.log" ] || { echo 0; return; }
  local c
  c="$(grep -c $'\tGET\t/reminders/lists$' "$FX/requests.log" || true)"
  echo "${c:-0}"
}

open_config_gate() {
  sed -i '' 's/^EVENTKIT_BRIDGE_PRODUCTION_AUTHORIZED=false$/EVENTKIT_BRIDGE_PRODUCTION_AUTHORIZED=true/' "$FX/conf/bridge.env" 2>/dev/null \
    || sed -i 's/^EVENTKIT_BRIDGE_PRODUCTION_AUTHORIZED=false$/EVENTKIT_BRIDGE_PRODUCTION_AUTHORIZED=true/' "$FX/conf/bridge.env"
}

# ================================================================ [G1]
echo "[G1] diag: trailing-space title matches via the stripped variant"
new_fixture; start_bridge; open_config_gate
printf '%s' "[{\"listID\":\"AAAB0000-0000-4000-8000-0000000000AA\",\"title\":\"$TARGET \",\"sourceID\":\"$OLD_SRC\",\"sourceType\":\"calDAV\",\"sourceName\":\"iCloud\",\"color\":\"\",\"isImmutable\":true},$LISTS_JSON_DEFAULT]" > "$FX/fields/lists"
RC="$(python3 "$DIAG" --endpoint "$URL" --token-file "$FX/token" \
  --title "$TARGET" --expect-source-id "$OLD_SRC" \
  --private-out "$FX/work/priv.json" --out "$FX/work/pub.json" >/dev/null 2>&1; echo $?)"
eq "exit code 0" "$RC" "0"
grep -q "DIGEST_MATCH_VARIANT" "$FX/work/pub.json" && check "decision DIGEST_MATCH_VARIANT" 1 || check "decision DIGEST_MATCH_VARIANT" 0
grep -q '"via_list_variant": "stripped"' "$FX/work/pub.json" && check "match via stripped variant" 1 || check "match via stripped variant" 0
PERM="$(python3 -c 'import os,sys;print(oct(os.stat(sys.argv[1]).st_mode & 0o777))' "$FX/work/priv.json" 2>/dev/null)"
eq "private record is 0600" "$PERM" "0o600"
grep -q "$OTHER_TITLE" "$FX/work/pub.json" && check "public receipt has no other list title" 0 || check "public receipt has no other list title" 1
grep -q "$OTHER_TITLE" "$FX/work/priv.json" && check "private record has no titles" 0 || check "private record has no titles" 1
if grep -q "AAAB0000-0000-4000-8000-0000000000AA" "$FX/work/pub.json"; then
  check "public receipt carries no full listID" 0
else
  check "public receipt carries no full listID" 1
fi
stop_bridge

# ================================================================ [G2]
echo "[G2] diag: exact title matches exactly"
new_fixture; start_bridge; open_config_gate
printf '%s' "[{\"listID\":\"AAAB0000-0000-4000-8000-0000000000AA\",\"title\":\"$TARGET\",\"sourceID\":\"$OLD_SRC\",\"sourceType\":\"calDAV\",\"sourceName\":\"iCloud\",\"color\":\"\",\"isImmutable\":true}]" > "$FX/fields/lists"
RC="$(python3 "$DIAG" --endpoint "$URL" --token-file "$FX/token" \
  --title "$TARGET" --private-out "$FX/work/priv.json" --out "$FX/work/pub.json" >/dev/null 2>&1; echo $?)"
eq "exit code 0" "$RC" "0"
grep -q '"decision": "DIGEST_MATCH_EXACT"' "$FX/work/pub.json" && check "decision DIGEST_MATCH_EXACT" 1 || check "decision DIGEST_MATCH_EXACT" 0
stop_bridge

# ================================================================ [G3]
echo "[G3] diag: absent title -> NO_DIGEST_MATCH, digests-only private record"
new_fixture; start_bridge; open_config_gate
RC="$(python3 "$DIAG" --endpoint "$URL" --token-file "$FX/token" \
  --title "$TARGET" --private-out "$FX/work/priv.json" --out "$FX/work/pub.json" >/dev/null 2>&1; echo $?)"
eq "exit code 40" "$RC" "40"
grep -q '"decision": "NO_DIGEST_MATCH"' "$FX/work/pub.json" && check "decision NO_DIGEST_MATCH" 1 || check "decision NO_DIGEST_MATCH" 0
grep -q '"visible_list_count": 1' "$FX/work/pub.json" && check "visible count recorded" 1 || check "visible count recorded" 0
[ -f "$FX/work/priv.json" ] && check "private digests-only record written on NO_MATCH" 1 || check "private digests-only record written on NO_MATCH" 0
grep -q "$OTHER_TITLE" "$FX/work/priv.json" && check "private record still has no titles" 0 || check "private record still has no titles" 1
stop_bridge

# ================================================================ [G4]
echo "[G4] diag: closed gate is an HTTP error"
new_fixture; start_bridge
RC="$(python3 "$DIAG" --endpoint "$URL" --token-file "$FX/token" \
  --title "$TARGET" --private-out "$FX/work/priv.json" --out "$FX/work/pub.json" >/dev/null 2>&1; echo $?)"
eq "exit code 3" "$RC" "3"
grep -q "DIAG_HTTP_ERROR" "$FX/work/pub.json" && check "decision DIAG_HTTP_ERROR" 1 || check "decision DIAG_HTTP_ERROR" 0
stop_bridge

# ================================================================ [G5]
echo "[G5] digest window: match path (3 account-wide reads, gate restored)"
new_fixture; start_bridge
printf '%s' "[{\"listID\":\"AAAB0000-0000-4000-8000-0000000000AA\",\"title\":\"$TARGET\",\"sourceID\":\"$OLD_SRC\",\"sourceType\":\"calDAV\",\"sourceName\":\"iCloud\",\"color\":\"\",\"isImmutable\":true}]" > "$FX/fields/lists"
BIN_SHA="$(/usr/bin/shasum -a 256 "$FX/EventKitBridgeServer" | awk '{print $1}')"
OUT="$(BIN="$FX/EventKitBridgeServer" FROZEN_SHA256="$BIN_SHA" PYTHON_BIN=python3 \
  bash "$DWINDOW" --title "$TARGET" --expect-source-id "$OLD_SRC" \
  --token-file "$FX/token" --plist "$FX/conf/agent.plist" \
  --config-file "$FX/conf/bridge.env" --endpoint "$URL" \
  --work-dir "$FX/work" --window-seconds 300 --open-budget 120 \
  --label r1-04-diag-test --confirm 2>&1; echo "RC=$?")"
RC="$(printf '%s' "$OUT" | sed -n 's/^RC=//p')"
eq "window exit code 0" "$RC" "0"
eq "exactly 3 enumeration reads" "$(enum_reads)" "3"
RUN_DIR="$(ls -d "$FX/work"/digest-*-r1-04-diag-test 2>/dev/null | head -1)"
[ -n "$RUN_DIR" ] && check "run dir found" 1 || check "run dir found" 0
grep -q "DIGEST_MATCH_EXACT" "$RUN_DIR/state/digest_receipt.json" && check "digest receipt decision" 1 || check "digest receipt decision" 0
config_field() { awk -F= -v k="$1" '$1==k{print $2}' "$FX/conf/bridge.env"; }
eq "gate restored to false" "$(config_field EVENTKIT_BRIDGE_PRODUCTION_AUTHORIZED)" "false"
[ ! -e "$RUN_DIR/state/gate_open_since" ] && check "gate_open_since cleaned" 1 || check "gate_open_since cleaned" 0
stop_bridge

echo "[G5b] digest window: no-match path (exit 12, gate restored)"
new_fixture; start_bridge
BIN_SHA="$(/usr/bin/shasum -a 256 "$FX/EventKitBridgeServer" | awk '{print $1}')"
OUT="$(BIN="$FX/EventKitBridgeServer" FROZEN_SHA256="$BIN_SHA" PYTHON_BIN=python3 \
  bash "$DWINDOW" --title "$TARGET" --expect-source-id "$OLD_SRC" \
  --token-file "$FX/token" --plist "$FX/conf/agent.plist" \
  --config-file "$FX/conf/bridge.env" --endpoint "$URL" \
  --work-dir "$FX/work" --window-seconds 300 --open-budget 120 \
  --label r1-04-diag-test-b --confirm 2>&1; echo "RC=$?")"
RC="$(printf '%s' "$OUT" | sed -n 's/^RC=//p')"
eq "window exit code 12" "$RC" "12"
eq "exactly 3 enumeration reads" "$(enum_reads)" "3"
eq "gate restored to false" "$(config_field EVENTKIT_BRIDGE_PRODUCTION_AUTHORIZED)" "false"
stop_bridge

# ================================================================ [G6]
echo "[G6] diag: second run refuses to overwrite the private record"
new_fixture; start_bridge; open_config_gate
printf '%s' "[{\"listID\":\"AAAB0000-0000-4000-8000-0000000000AA\",\"title\":\"$TARGET\",\"sourceID\":\"$OLD_SRC\",\"sourceType\":\"calDAV\",\"sourceName\":\"iCloud\",\"color\":\"\",\"isImmutable\":true}]" > "$FX/fields/lists"
python3 "$DIAG" --endpoint "$URL" --token-file "$FX/token" \
  --title "$TARGET" --private-out "$FX/work/priv.json" --out "$FX/work/pub.json" >/dev/null 2>&1
RC2="$(python3 "$DIAG" --endpoint "$URL" --token-file "$FX/token" \
  --title "$TARGET" --private-out "$FX/work/priv.json" --out "$FX/work/pub2.json" >/dev/null 2>&1; echo $?)"
eq "second run exit code 2" "$RC2" "2"
stop_bridge

# ---------------------------------------------------------------- result
echo
echo "total=$TOTAL fails=$FAILS"
if [ "$FAILS" -eq 0 ]; then echo "ALL PASS"; else echo "FAILURES PRESENT"; exit 1; fi
