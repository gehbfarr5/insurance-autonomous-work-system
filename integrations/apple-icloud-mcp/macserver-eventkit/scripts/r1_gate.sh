#!/usr/bin/env bash
# r1_gate.sh — the single place that opens or closes the MacServer bridge gate.
#
# Every restorer goes through this file: the window script, the independent
# watchdog, and an emergency manual close. They therefore share one mutex, one
# ownership check and one verification rule - a manual close cannot accidentally
# be a different, weaker operation than an automatic one.
#
# Why verification cannot be optional
# -----------------------------------
# The disk value and the running process are different things: BridgeConfig
# loads LaunchAgent EnvironmentVariables over the config file, and launchd
# caches the job. A successful `plutil -replace` plus a successful `kickstart`
# therefore proves nothing about what the endpoint now answers. This script
# always re-reads /health and the business endpoint after reloading, and exits
# non-zero unless the observed behaviour matches the requested state. Callers do
# not have to remember a flag; there is no flag.
#
# Why only one source is ever written
# -----------------------------------
# If the plist defines the key, the plist wins and writing the config file is a
# no-op that silently desyncs the two files. So exactly one authoritative source
# is modified. If neither defines the key, `open` refuses (exit 5): inventing a
# gate key in an unapproved file is a deployment change, not a diagnostic step.
#
# Usage:
#   r1_gate.sh open|close --plist P --token-file T --out O
#              [--config-file F] [--endpoint E] [--purpose TEXT]
#              [--lock-wait SECONDS] [--dry-run]
#
# `--expect` is still accepted for backwards compatibility but is ignored: the
# expected status is derived from the mode and verification always runs.
#
# Exit codes: 0 verified success, 2 precondition, 3 write/backup/verification
#             failure, 4 reload failure, 5 no authoritative source, 7 lock busy.

set -uo pipefail

MODE="${1:-}"; shift || true
[ "$MODE" = "open" ] || [ "$MODE" = "close" ] || { echo "usage: r1_gate.sh open|close ..." >&2; exit 2; }

PLIST=""; CONFIG_FILE=""; TOKEN_FILE=""; ENDPOINT="http://127.0.0.1:18765"; OUT=""
DRY=0; PURPOSE="unspecified"; LOCK_WAIT=20
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
    --purpose) PURPOSE="$2"; shift 2 ;;
    --lock-wait) LOCK_WAIT="$2"; shift 2 ;;
    --dry-run) DRY=1; shift ;;
    --expect) shift 2 ;;   # deprecated: verification is unconditional
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

[ -n "$PLIST" ] || { echo "PRECONDITION: --plist required" >&2; exit 2; }
[ "$DRY" -eq 1 ] || [ -n "$OUT" ] || { echo "PRECONDITION: --out required" >&2; exit 2; }

WANT="false"; [ "$MODE" = "open" ] && WANT="true"
EXPECT_CODE=403; [ "$MODE" = "open" ] && EXPECT_CODE=200

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
  SOURCE="absent"; EFFECTIVE=""; RELOAD="none"
fi

echo "[r1_gate] mode=$MODE source=$SOURCE current=${EFFECTIVE:-unknown} reload=$RELOAD purpose=$PURPOSE"

# Nothing defines the gate. Closing then only needs to prove the endpoint is
# already closed; opening would have to invent state, which is not authorized.
if [ "$SOURCE" = "absent" ] && [ "$MODE" = "open" ]; then
  echo "[r1_gate] REFUSED: no authoritative source defines the gate; refusing to create one" >&2
  exit 5
fi

if [ "$DRY" -eq 1 ]; then
  echo "[r1_gate] DRY RUN: no lock taken, no change written"
  exit 0
fi

# --- 2. shared mutex ---------------------------------------------------------
# Callers must not race: two overlapping restores would interleave a write with
# a reload and could leave the process running an older value than the disk.
# The lock is never taken by force. If it cannot be taken within the bound, the
# operation fails with evidence instead of proceeding.
LOCK_ROOT="${R1_LOCK_DIR:-$HOME/.muse-r1}"
LOCK="$LOCK_ROOT/gate.lock"
LOCK_HELD=0
mkdir -p "$LOCK_ROOT" 2>/dev/null && chmod 700 "$LOCK_ROOT" 2>/dev/null

lock_owner_field() { awk -F= -v k="$1" '$1==k{sub(/^[^=]*=/,""); print; exit}' "$LOCK/owner.env" 2>/dev/null; }

release_lock() {
  [ "$LOCK_HELD" -eq 1 ] || return 0
  # Only the owner removes it: if the pid differs, another process reclaimed a
  # stale lock and we must not delete its lock.
  if [ "$(lock_owner_field LOCK_PID)" = "$$" ]; then rm -rf "$LOCK"; fi
  LOCK_HELD=0
}

acquire_lock() {
  local waited=0 owner_pid owner_lstart live
  while :; do
    if mkdir "$LOCK" 2>/dev/null; then
      chmod 700 "$LOCK" 2>/dev/null || true
      {
        echo "LOCK_PID=$$"
        echo "LOCK_LSTART=$(ps -p $$ -o lstart= 2>/dev/null | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
        echo "LOCK_UID=$UID"
        echo "LOCK_PURPOSE=$PURPOSE"
        echo "LOCK_ACQUIRED=$(date +%s)"
      } > "$LOCK/owner.env"
      chmod 600 "$LOCK/owner.env" 2>/dev/null || true
      LOCK_HELD=1
      trap release_lock EXIT
      return 0
    fi
    owner_pid="$(lock_owner_field LOCK_PID)"
    owner_lstart="$(lock_owner_field LOCK_LSTART)"
    live=0
    if [ -n "$owner_pid" ] && kill -0 "$owner_pid" 2>/dev/null; then
      # pid reuse check: the same pid with a different start time is another
      # process, so the lock holder is gone.
      if [ -z "$owner_lstart" ] || [ "$(ps -p "$owner_pid" -o lstart= 2>/dev/null | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')" = "$owner_lstart" ]; then
        live=1
      fi
    fi
    if [ "$live" -eq 0 ]; then
      # Stale lock: rename first so two reclaimers cannot both win, then remove.
      if mv "$LOCK" "$LOCK.stale.$$" 2>/dev/null; then
        rm -rf "$LOCK.stale.$$"
        echo "[r1_gate] reclaimed a stale lock (owner pid=${owner_pid:-unknown})"
        continue
      fi
    fi
    [ "$waited" -ge "$LOCK_WAIT" ] && return 1
    sleep 0.5; waited=$(printf '%s' "$waited" | awk '{print $1+1}')
  done
}

if ! acquire_lock; then
  echo "[r1_gate] FAILED: gate mutex busy for ${LOCK_WAIT}s (holder pid=$(lock_owner_field LOCK_PID), purpose=$(lock_owner_field LOCK_PURPOSE)); not forcing it" >&2
  R1_MODE_FOR_LOCK="$MODE" R1_STAGE=lock R1_RC=7 R1_LOCKHOLDER="$(lock_owner_field LOCK_PID)/$(lock_owner_field LOCK_PURPOSE)" \
  "$PYTHON" - "$OUT" <<'PYEOF'
import json, os, sys
receipt = {
  "receipt_type": "R1_GATE_OPERATION",
  "mode": os.environ.get("R1_MODE_FOR_LOCK", "unknown"),
  "verification": "FAIL",
  "failure_stage": "lock",
  "failure_exit_code": 7,
  "lock_holder": os.environ.get("R1_LOCKHOLDER"),
  "note": "Another gate operation held the mutex. This operation did not write or reload anything.",
}
with open(sys.argv[1], "w", encoding="utf-8") as fh:
    json.dump(receipt, fh, indent=2, ensure_ascii=False)
    fh.write("\n")
PYEOF
  exit 7
fi

# --- 3. back up the authoritative source before touching it ------------------
# Both files may contain the bearer token, so neither backup may be readable by
# others and neither sits next to the original.
BACKUP=""
CFG_BACKUP=""
backup_source() {
  local src="$1" suffix="$2"
  BACKUP="$OUT.$suffix"
  cp -p "$src" "$BACKUP" 2>/dev/null && chmod 600 "$BACKUP" 2>/dev/null
}

emit_failure_receipt() {
  local stage="$1" rc="$2"
  [ -n "$OUT" ] || return 0
  R1_OUT="$OUT" R1_MODE="$MODE" R1_SOURCE="$SOURCE" R1_RELOAD="$RELOAD" \
  R1_WANT="$WANT" R1_STAGE="$stage" R1_RC="$rc" \
  R1_BEFORE="${BEFORE_PID:-}" R1_AFTER="${AFTER_PID:-}" R1_CFG="$CONFIG_FILE" \
  R1_PLIST="$PLIST" R1_BACKUP="${BACKUP:-}" R1_PURPOSE="$PURPOSE" \
  R1_CFG_BACKUP="${CFG_BACKUP:-}" \
  "$PYTHON" - <<'PYEOF'
import json, os
env = os.environ
receipt = {
  "receipt_type": "R1_GATE_OPERATION",
  "mode": env["R1_MODE"],
  "gate_source_detected": env["R1_SOURCE"],
  "reload_method": env["R1_RELOAD"],
  "target_gate_value": env["R1_WANT"],
  "purpose": env.get("R1_PURPOSE"),
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
  "authoritative_source": env["R1_SOURCE"],
  "plist_backup": env.get("R1_BACKUP") or None,
  "plist_backup_mode": "0600" if env.get("R1_BACKUP") else None,
  "config_backup": env.get("R1_CFG_BACKUP") or None,
  "config_backup_mode": "0600" if env.get("R1_CFG_BACKUP") else None,
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

if [ "$SOURCE" = "launchd_env" ]; then
  if ! backup_source "$PLIST" plist-backup; then
    BACKUP=""
    echo "[r1_gate] FAILED: could not create a 0600 backup of the plist; refusing to edit it" >&2
    emit_failure_receipt backup 3
    exit 3
  fi
  echo "[r1_gate] plist backed up to a 0600 file inside the restricted evidence dir"
elif [ "$SOURCE" = "config_file" ]; then
  CFG_BACKUP=""
  if ! cp -p "$CONFIG_FILE" "$OUT.config-backup" 2>/dev/null || ! chmod 600 "$OUT.config-backup" 2>/dev/null; then
    echo "[r1_gate] FAILED: could not create a 0600 backup of the config file; refusing to edit it" >&2
    emit_failure_receipt backup 3
    exit 3
  fi
  CFG_BACKUP="$OUT.config-backup"
  echo "[r1_gate] config file backed up to a 0600 file; only the gate key will change"
fi

# --- 4. write exactly the authoritative source, atomically -------------------
set_config_gate() {
  [ -n "$CONFIG_FILE" ] && [ -f "$CONFIG_FILE" ] || return 7
  # Write a sibling temp file with the original mode, then rename: a reader
  # (including the next process) never sees a half-written config, and the
  # single-key scope is enforced by the regex below.
  "$PYTHON" - "$CONFIG_FILE" "$WANT" <<'PYEOF'
import os, re, sys, tempfile
path, want = sys.argv[1], sys.argv[2]
with open(path, encoding="utf-8") as fh:
    text = fh.read()
pattern = re.compile(r'^([ \t]*EVENTKIT_BRIDGE_PRODUCTION_AUTHORIZED[ \t]*=).*$', re.M)
if not pattern.search(text):
    sys.exit(9)  # caller decided this file is authoritative; if it is not, stop
new_text = pattern.sub(lambda m: f"{m.group(1)}{want}", text)
mode = os.stat(path).st_mode & 0o777
directory = os.path.dirname(os.path.abspath(path))
fd, tmp = tempfile.mkstemp(prefix=".r1-gate-", dir=directory)
try:
    with os.fdopen(fd, "w", encoding="utf-8") as fh:
        fh.write(new_text)
    os.chmod(tmp, mode)
    os.replace(tmp, path)
finally:
    if os.path.exists(tmp):
        os.unlink(tmp)
PYEOF
}

WRITE_RC=0
if [ "$SOURCE" = "launchd_env" ]; then
  "$PLUTIL" -replace EnvironmentVariables.EVENTKIT_BRIDGE_PRODUCTION_AUTHORIZED -string "$WANT" "$PLIST" || WRITE_RC=$?
elif [ "$SOURCE" = "config_file" ]; then
  set_config_gate || WRITE_RC=$?
else
  # absent + close: nothing to write, only the endpoint has to be proven closed.
  echo "[r1_gate] no authoritative source defines the gate; nothing to rewrite (close verifies only)"
fi
if [ "$WRITE_RC" -ne 0 ]; then
  echo "[r1_gate] FAILED: writing the gate source returned $WRITE_RC" >&2
  emit_failure_receipt write "$WRITE_RC"
  exit 3
fi

# --- 5. reload so a new process re-reads it ---------------------------------
BEFORE_PID="$(pgrep -x EventKitBridgeServer 2>/dev/null | head -1 || true)"
RELOAD_RC=0
if [ "$SOURCE" = "launchd_env" ]; then
  BOOTOUT_RC=0
  "$LAUNCHCTL" bootout "gui/$(id -u)/$LABEL" 2>/dev/null || BOOTOUT_RC=$?
  if [ "$BOOTOUT_RC" -ne 0 ]; then
    # bootout fails when the job is not loaded; that is only acceptable if the
    # job really is not loaded. Anything else is a main-path error and must not
    # be swallowed before bootstrap.
    if "$LAUNCHCTL" print "gui/$(id -u)/$LABEL" >/dev/null 2>&1; then
      echo "[r1_gate] FAILED: bootout returned $BOOTOUT_RC but the job is still loaded" >&2
      emit_failure_receipt bootout "$BOOTOUT_RC"
      exit 4
    fi
    echo "[r1_gate] bootout reported $BOOTOUT_RC and the job is not loaded; continuing"
  fi
  sleep 1
  "$LAUNCHCTL" bootstrap "gui/$(id -u)" "$PLIST" || RELOAD_RC=$?
elif [ "$SOURCE" = "config_file" ]; then
  "$LAUNCHCTL" kickstart -k "gui/$(id -u)/$LABEL" || RELOAD_RC=$?
fi
if [ "$RELOAD_RC" -ne 0 ]; then
  echo "[r1_gate] FAILED: reload returned $RELOAD_RC" >&2
  AFTER_PID="$(pgrep -x EventKitBridgeServer 2>/dev/null | head -1 || true)"
  emit_failure_receipt reload "$RELOAD_RC"
  exit 4
fi

# --- 6. verify by behaviour and by process identity (always) ----------------
sleep "${R1_SETTLE_SECONDS:-3}"
AFTER_PID="$(pgrep -x EventKitBridgeServer 2>/dev/null | head -1 || true)"
VERIFY_RC=0
HEALTH_JSON="$OUT.health.json"
"$PYTHON" "$CLIENT" health --endpoint "$ENDPOINT" --out "$HEALTH_JSON" >/dev/null 2>&1 || VERIFY_RC=3

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
  "purpose": "$PURPOSE",
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
  "verification_basis": "http behaviour after reload + process identity; never the file value",
  "plist_backup": "${BACKUP}" or None,
  "plist_backup_mode": "0600" if "${BACKUP}" else None,
  "config_backup": "${CFG_BACKUP}" or None,
  "config_backup_mode": "0600" if "${CFG_BACKUP}" else None,
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

# Verification is not optional: a caller can no longer get exit 0 without it.
[ "$RECEIPT_RC" -eq 0 ] || exit 3
exit 0
