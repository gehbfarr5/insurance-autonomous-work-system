#!/usr/bin/env bash
# r1_gate.sh — the single place that opens or closes the MacServer bridge gate.
#
# Both the window script and the independent watchdog call this file, so a
# manual restore and an automatic restore are byte-identical operations.
#
# Why the gate source has to be detected, not assumed
# ---------------------------------------------------
# BridgeConfig.load() merges the LaunchAgent environment into the config file
# and the ENVIRONMENT WINS (`if mergedEnv[k] == nil || empty`). So:
#   * if the plist defines EVENTKIT_BRIDGE_PRODUCTION_AUTHORIZED, editing
#     bridge.env has no effect at all;
#   * and a disk value is not the running process state either — launchd caches
#     the job, so `kickstart -k` restarts the process but may reuse the cached
#     environment. A plist env change therefore needs bootout + bootstrap.
# This script decides which path applies, prints the decision, and verifies the
# outcome by behaviour (HTTP status) plus process identity, never by the file.
#
# Usage:
#   r1_gate.sh open|close --plist P --config-file F [--expect]
#              --token-file T --endpoint E --out O [--dry-run]
#
# Exit codes: 0 success (and verified when --expect), 2 precondition,
#             3 transport/verification failure, 4 reload failed, 5 source unknown.

set -uo pipefail

MODE="${1:-}"; shift || true
[ "$MODE" = "open" ] || [ "$MODE" = "close" ] || { echo "usage: r1_gate.sh open|close ..." >&2; exit 2; }

PLIST=""; CONFIG_FILE=""; TOKEN_FILE=""; ENDPOINT="http://127.0.0.1:18765"; OUT=""; DRY=0; DO_VERIFY=0
LAUNCHCTL="${LAUNCHCTL_BIN:-launchctl}"
PLUTIL="${PLUTIL_BIN:-plutil}"
PYTHON="${PYTHON_BIN:-python3}"
CLIENT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/r1_bridge_client.py"
LABEL="${BRIDGE_LABEL:-com.muse.macserver-eventkit}"

while [ $# -gt 0 ]; do
  case "$1" in
    --plist) PLIST="$2"; shift 2 ;;
    --config-file) CONFIG_FILE="$2"; shift 2 ;;
    --token-file) TOKEN_FILE="$2"; shift 2 ;;
    --endpoint) ENDPOINT="$2"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    --dry-run) DRY=1; shift ;;
    --expect) DO_VERIFY=1; shift ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

[ -n "$PLIST" ] || { echo "PRECONDITION: --plist required" >&2; exit 2; }
[ "$DRY" -eq 1 ] || [ -n "$OUT" ] || { echo "PRECONDITION: --out required" >&2; exit 2; }

WANT="false"; [ "$MODE" = "open" ] && WANT="true"

# --- 1. which source actually wins -------------------------------------------
plist_has=0; plist_val=""
if "$PLUTIL" -extract EnvironmentVariables.EVENTKIT_BRIDGE_PRODUCTION_AUTHORIZED raw "$PLIST" >/dev/null 2>&1; then
  plist_has=1
  plist_val="$("$PLUTIL" -extract EnvironmentVariables.EVENTKIT_BRIDGE_PRODUCTION_AUTHORIZED raw "$PLIST" 2>/dev/null || true)"
fi

cfg_has=0; cfg_val=""
if [ -n "$CONFIG_FILE" ] && [ -f "$CONFIG_FILE" ]; then
  if grep -Eq '^[[:space:]]*EVENTKIT_BRIDGE_PRODUCTION_AUTHORIZED[[:space:]]*=' "$CONFIG_FILE" 2>/dev/null; then
    cfg_has=1
    cfg_val="$(awk -F= '/^[[:space:]]*EVENTKIT_BRIDGE_PRODUCTION_AUTHORIZED[[:space:]]*=/{v=$2; gsub(/[[:space:]"]/,"",v); print v; exit}' "$CONFIG_FILE")"
  fi
fi

if [ "$plist_has" -eq 1 ]; then
  SOURCE="launchd_env"; EFFECTIVE="$plist_val"; RELOAD="bootout_bootstrap"
elif [ "$cfg_has" -eq 1 ]; then
  SOURCE="config_file"; EFFECTIVE="$cfg_val"; RELOAD="kickstart"
else
  SOURCE="absent"; EFFECTIVE="false"; RELOAD="kickstart"
  if [ "$MODE" = "open" ]; then
    # Nothing defines the gate: opening must create it in the config file, which
    # is also the only source the next process will fall back to.
    SOURCE="config_file"
  fi
fi

echo "[r1_gate] mode=$MODE source=$SOURCE current=$EFFECTIVE reload=$RELOAD"
if [ "$DRY" -eq 1 ]; then
  echo "[r1_gate] DRY RUN: no change written"
  exit 0
fi

# --- 2. back up the plist before editing it ---------------------------------
# The plist carries the LaunchAgent EnvironmentVariables, which may include the
# bearer token, so the backup must not be world-readable and must not sit next
# to the original. It goes into the evidence directory, which is 0700.
BACKUP=""
if [ "$SOURCE" = "launchd_env" ]; then
  BACKUP="$OUT.plist-backup"
  if cp -p "$PLIST" "$BACKUP" 2>/dev/null && chmod 600 "$BACKUP" 2>/dev/null; then
    echo "[r1_gate] plist backed up to a 0600 file inside the restricted evidence dir"
  else
    BACKUP=""
    echo "[r1_gate] FAILED: could not create a 0600 backup of the plist; refusing to edit it" >&2
    emit_failure_receipt backup 3
    exit 3
  fi
fi

# --- 3. write the authoritative source --------------------------------------
set_config_gate() {
  [ -n "$CONFIG_FILE" ] && [ -f "$CONFIG_FILE" ] || return 7
  "$PYTHON" - "$CONFIG_FILE" "$WANT" <<'PYEOF'
import re, sys
path, want = sys.argv[1], sys.argv[2]
with open(path, encoding="utf-8") as fh:
    text = fh.read()
pattern = re.compile(r'^([ \t]*EVENTKIT_BRIDGE_PRODUCTION_AUTHORIZED[ \t]*=).*$', re.M)
if pattern.search(text):
    text = pattern.sub(lambda m: f"{m.group(1)}{want}", text)
else:
    text = text.rstrip("\n") + f"\nEVENTKIT_BRIDGE_PRODUCTION_AUTHORIZED={want}\n"
with open(path, "w", encoding="utf-8") as fh:
    fh.write(text)
PYEOF
}

# A failed gate operation must still leave evidence. Exiting without a receipt
# was an evidence gap: an auditor could see a non-zero code but not which stage
# failed, what the intended value was, or that the disk value had already been
# written before the reload failed (disk != running process state).
emit_failure_receipt() {
  local stage="$1" rc="$2"
  [ -n "$OUT" ] || return 0
  R1_OUT="$OUT" R1_MODE="$MODE" R1_SOURCE="$SOURCE" R1_RELOAD="$RELOAD" \
  R1_WANT="$WANT" R1_STAGE="$stage" R1_RC="$rc" \
  R1_BEFORE="${BEFORE_PID:-}" R1_AFTER="${AFTER_PID:-}" R1_CFG="$CONFIG_FILE" \
  R1_PLIST="$PLIST" R1_BACKUP="${BACKUP:-}" \
  "$PYTHON" - <<'PYEOF'
import json, os
env = os.environ
receipt = {
  "receipt_type": "R1_GATE_OPERATION",
  "mode": env["R1_MODE"],
  "gate_source_detected": env["R1_SOURCE"],
  "reload_method": env["R1_RELOAD"],
  "target_gate_value": env["R1_WANT"],
  "before_pid": env["R1_BEFORE"] or "none",
  "after_pid": env["R1_AFTER"] or "none",
  "process_restarted": bool(env["R1_BEFORE"] and env["R1_AFTER"] and env["R1_BEFORE"] != env["R1_AFTER"]),
  "process_env_observation": "not_observed_failed_before_verification",
  "health_store": None,
  "health_classification": None,
  "gate_http_status": None,
  "gate_expected_status": 200 if env["R1_MODE"] == "open" else 403,
  "gate_classification": None,
  "verification": "FAIL",
  "failure_stage": env["R1_STAGE"],
  "failure_exit_code": int(env["R1_RC"]),
  "disk_written_before_failure": env["R1_STAGE"] != "write",
  "plist_backup": env.get("R1_BACKUP") or None,
  "plist_backup_mode": "0600" if env.get("R1_BACKUP") else None,
  "note": "A failed gate operation leaves the disk value and the running process "
          "possibly divergent; only the HTTP behaviour of the endpoint proves the "
          "real state, and this operation never reached that proof.",
  "evidence_files": [],
}
with open(env["R1_OUT"], "w", encoding="utf-8") as fh:
    json.dump(receipt, fh, indent=2, ensure_ascii=False)
    fh.write("\n")
print("[r1_gate] FAILURE RECEIPT written: stage=%s rc=%s" % (env["R1_STAGE"], env["R1_RC"]))
PYEOF
}

WRITE_RC=0
if [ "$SOURCE" = "launchd_env" ]; then
  "$PLUTIL" -replace EnvironmentVariables.EVENTKIT_BRIDGE_PRODUCTION_AUTHORIZED -string "$WANT" "$PLIST" || WRITE_RC=$?
  # Mirror into the config file as well: it is the fallback if a future build
  # stops defining the key in the plist.
  if [ "$WRITE_RC" -eq 0 ] && [ "$cfg_has" -eq 1 ]; then set_config_gate || WRITE_RC=$?; fi
else
  set_config_gate || WRITE_RC=$?
fi
if [ "$WRITE_RC" -ne 0 ]; then
  echo "[r1_gate] FAILED: writing the gate source returned $WRITE_RC" >&2
  emit_failure_receipt write "$WRITE_RC"
  exit 3
fi

# --- 4. reload so a new process re-reads it ---------------------------------
BEFORE_PID="$(pgrep -x EventKitBridgeServer 2>/dev/null | head -1 || true)"
RELOAD_RC=0
case "$RELOAD" in
  bootout_bootstrap)
    "$LAUNCHCTL" bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
    sleep 1
    "$LAUNCHCTL" bootstrap "gui/$(id -u)" "$PLIST" || RELOAD_RC=$?
    if [ "$RELOAD_RC" -ne 0 ]; then
      echo "[r1_gate] bootstrap failed ($RELOAD_RC); trying legacy load" >&2
      "$LAUNCHCTL" load -w "$PLIST" || RELOAD_RC=$?
    fi
    ;;
  kickstart)
    "$LAUNCHCTL" kickstart -k "gui/$(id -u)/$LABEL" || RELOAD_RC=$?
    ;;
esac
if [ "$RELOAD_RC" -ne 0 ]; then
  echo "[r1_gate] FAILED: reload returned $RELOAD_RC" >&2
  AFTER_PID="$(pgrep -x EventKitBridgeServer 2>/dev/null | head -1 || true)"
  emit_failure_receipt reload "$RELOAD_RC"
  exit 4
fi

# --- 5. verify by behaviour and by process identity -------------------------
sleep "${R1_SETTLE_SECONDS:-3}"
AFTER_PID="$(pgrep -x EventKitBridgeServer 2>/dev/null | head -1 || true)"
VERIFY_RC=0
HEALTH_JSON="$OUT.health.json"
"$PYTHON" "$CLIENT" health --endpoint "$ENDPOINT" --out "$HEALTH_JSON" >/dev/null 2>&1 || VERIFY_RC=3

EXPECT_CODE=403; [ "$MODE" = "open" ] && EXPECT_CODE=200
GATE_JSON="$OUT.gate.json"
if [ "$VERIFY_RC" -eq 0 ]; then
  "$PYTHON" "$CLIENT" gate --endpoint "$ENDPOINT" --token-file "$TOKEN_FILE" \
    --expect "$EXPECT_CODE" --out "$GATE_JSON" >/dev/null 2>&1 || VERIFY_RC=3
fi

ENV_OBS="not_applicable"
if [ "$SOURCE" = "launchd_env" ] && [ -n "$AFTER_PID" ]; then
  # Filtered read: only this one key is ever printed, never the whole environment.
  if ps eww -p "$AFTER_PID" 2>/dev/null | tr ' ' '\n' | grep -q '^EVENTKIT_BRIDGE_PRODUCTION_AUTHORIZED='"$WANT"'$'; then
    ENV_OBS="process_env_matches"
  else
    ENV_OBS="process_env_differs_or_hidden"
  fi
fi

"$PYTHON" - "$OUT" <<PYEOF
import json, os, sys
out = sys.argv[1]
def load(p):
    try:
        with open(p, encoding="utf-8") as fh:
            return json.load(fh)
    except Exception:
        return {}
health = load(out + ".health.json")
gate = load(out + ".gate.json")
receipt = {
  "receipt_type": "R1_GATE_OPERATION",
  "mode": "$MODE",
  "gate_source_detected": "$SOURCE",
  "reload_method": "$RELOAD",
  "target_gate_value": "$WANT",
  "before_pid": "${BEFORE_PID:-none}",
  "after_pid": "${AFTER_PID:-none}",
  "process_restarted": bool("${BEFORE_PID:-}" and "${AFTER_PID:-}" and "${BEFORE_PID}" != "${AFTER_PID}"),
  "process_env_observation": "$ENV_OBS",
  "health_store": health.get("store_field"),
  "health_classification": health.get("classification"),
  "gate_http_status": gate.get("http_status"),
  "gate_expected_status": gate.get("expected_status"),
  "gate_classification": gate.get("classification"),
  "verification": "PASS" if ("$VERIFY_RC" == "0") else "FAIL",
  "plist_backup": "${BACKUP}" or None,
  "plist_backup_mode": "0600" if "${BACKUP}" else None,
  "evidence_files": [out + ".health.json", out + ".gate.json"],
}
with open(out, "w", encoding="utf-8") as fh:
    json.dump(receipt, fh, indent=2, ensure_ascii=False)
    fh.write("\n")
print("[r1_gate] verification: %s (health=%s gate=%s pid %s -> %s)" % (
    receipt["verification"], receipt["health_store"], receipt["gate_http_status"],
    receipt["before_pid"], receipt["after_pid"]))
sys.exit(0 if receipt["verification"] == "PASS" else 1)
PYEOF
RECEIPT_RC=$?

if [ "$DO_VERIFY" -eq 0 ]; then
  exit 0
fi
[ "$RECEIPT_RC" -eq 0 ] || exit 3
exit 0
