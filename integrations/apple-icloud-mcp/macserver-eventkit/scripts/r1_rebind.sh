#!/usr/bin/env bash
# r1_rebind.sh — R1-04: swap the bridge's binding and allowlist to the new
# dedicated list, as ONE verified pair, with automatic rollback.
#
# What this changes (and nothing else)
# ------------------------------------
# The bridge honours two configuration keys that must move together:
#   EVENTKIT_BRIDGE_ALLOWED_LIST_IDS   -> NEW_LIST_ID
#   EVENTKIT_BRIDGE_BINDINGS           -> NEW_LIST_ID:NEW_SOURCE_ID:calDAV:iCloud
# Writing only one of them desynchronises allowlist and binding; the script
# refuses any state where the two keys do not live in the same authoritative
# source, refuses an allowlist that is not exactly the one old list, and writes
# the pair before reloading once. No other key is read or written.
#
# Why the gate must already be closed, and how that is proven
# -----------------------------------------------------------
# Rebinding while the gate is open would let a capture run against a binding
# that no authorization covered. The proof is behavioural, not a file read:
#
#   pre-check  GET /reminders/lists with the token, expect 403 (client gate).
#     The enumeration endpoint returns LIST METADATA ONLY - it never carries
#     item content for any list - so this proof cannot read a single reminder
#     no matter what state the gate is in. 403 means "gate closed, or TCC
#     denied"; the second case is content-safe as well (no items can be served
#     at all while TCC denies the store) and would surface at W1.
#
#   post-probe NEW id, probe --phase post --expect GATE_RESTORED_CLOSED
#     After the rebind the NEW id is the only allowlisted id, so PERMISSION_
#     DENIED after the allowlist check proves the gate is closed against the
#     NEW binding. A LIST_NOT_ALLOWED here means the reload did not take
#     effect - failure, rollback. The read targets the new list only.
#
#   rollback / deadline-recovery verification (both checks, in this order):
#     1. enumeration 403 again (the gate is closed; zero item content);
#     2. NEW id probe --phase post --expect BLOCKED_NOT_ON_ALLOWLIST.
#     After the backups are restored, the NEW id must be refused by the (old)
#     allowlist BEFORE the gate is even consulted - LIST_NOT_ALLOWED is the
#     behavioural proof that the OLD allowlist is live in the running process.
#     If PERMISSION_DENIED comes back instead, the new allowlist is still
#     active and the rollback did NOT take effect.
#
#   The OLD list id is NEVER probed by this script. Every item read it makes
#   targets the new list, so an unexpectedly open gate cannot widen the read
#   scope beyond the authorized target - the scope conflict an old-id probe
#   would create is excluded by the execution path, not by documentation.
#
#   (Both earlier sketches - the relaxed new-id pre-probe and the old-id
#   pre-probe - are retired: the first cannot distinguish "gate closed" from
#   "not yet allowlisted" on the real server, the second reads the old list's
#   item endpoint, which is outside the authorized item scope when the gate is
#   unexpectedly open.)
#
# Same mutex, same clock, same discipline as r1_gate.sh
# ------------------------------------------------------
# The lock, the operation deadline, run_bounded and the bootout/bootstrap
# reload are copied verbatim from r1_gate.sh (they share R1_LOCK_DIR /
# ~/.muse-r1/gate.lock), so a rebind can never interleave with a gate open, a
# window close, or a watchdog restore. A deadline exit restores the backups and
# exits 8 without a second reload, exactly like the gate does.
#
# Rollback
# --------
# If the write, the reload, or the post-probe verification fails, both backups
# are copied back, the service is reloaded again, and the restore is verified
# with the two scope-safe checks above (enumeration 403, then the new-id
# BLOCKED_NOT_ON_ALLOWLIST probe). A rebind that could not verify its rollback
# exits non-zero and says so; it never reports success.
#
# Deadline recovery (differs from r1_gate.sh on purpose)
# ------------------------------------------------------
# A gate deadline can leave only a single key behind, and writing it back to
# "closed" is self-evidently safe. A rebind deadline can leave a rewritten
# binding pair on disk while the process runs the old one (or the reverse), and
# neither state is self-evidently safe, so the deadline exit here is a recovery:
# the backups are restored, the service is reloaded once more under a separate
# recovery clock (R1_RECOVERY_TIMEOUT, default 45 s - the operation clock is
# already spent), and the result is verified with health + the two scope-safe
# checks. Exit code is still 8 (a deadline is never a success), but the receipt
# records whether the old configuration was actually reloaded, the service is
# healthy and the gate is closed - or, if even the recovery failed, that manual
# action is required.
#
# Usage:
#   r1_rebind.sh --plist P --config-file C --token-file T --out O
#                --old-list-id OLD --new-list-id NEW --new-source-id SID
#                [--endpoint E] [--purpose TEXT] [--lock-wait SECONDS]
#                [--op-timeout SECONDS] [--dry-run]
#     (deadline recovery budget: env R1_RECOVERY_TIMEOUT, default 45 s)
#
# Exit codes: 0 verified success, 2 usage, 3 write/backup/check/verification
#             failure (rollback attempted and verified where possible), 4
#             reload failure (rollback attempted), 5 configuration
#             precondition (sources split, keys absent, allowlist not exactly
#             the old id), 6 evidence directory unusable, 7 mutex busy or
#             lost, 8 deadline (backups restored, recovery reload + health +
#             scope-safe verification attempted under a separate clock; the
#             receipt records the recovery verdict).

set -uo pipefail

PLIST=""; CONFIG_FILE=""; TOKEN_FILE=""; ENDPOINT="http://127.0.0.1:18765"; OUT=""
OLD_ID=""; NEW_ID=""; NEW_SOURCE_ID=""; DRY=0; PURPOSE="unspecified"; LOCK_WAIT=20
OP_TIMEOUT="${R1_OP_TIMEOUT:-30}"
LAUNCHCTL="${LAUNCHCTL_BIN:-launchctl}"
PLUTIL="${PLUTIL_BIN:-plutil}"
PYTHON="${PYTHON_BIN:-python3}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLIENT="$HERE/r1_bridge_client.py"
LABEL="${BRIDGE_LABEL:-com.muse.macserver-eventkit}"

ALLOW_KEY="EnvironmentVariables.EVENTKIT_BRIDGE_ALLOWED_LIST_IDS"
BIND_KEY="EnvironmentVariables.EVENTKIT_BRIDGE_BINDINGS"

usage() { echo "usage: r1_rebind.sh --plist P --config-file C --token-file T --out O --old-list-id OLD --new-list-id NEW --new-source-id SID [--endpoint E] [--dry-run]" >&2; exit 2; }

while [ $# -gt 0 ]; do
  case "$1" in
    --plist) PLIST="$2"; shift 2 ;;
    --config-file) CONFIG_FILE="$2"; shift 2 ;;
    --token-file) TOKEN_FILE="$2"; shift 2 ;;
    --endpoint) ENDPOINT="$2"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    --old-list-id) OLD_ID="$2"; shift 2 ;;
    --new-list-id) NEW_ID="$2"; shift 2 ;;
    --new-source-id) NEW_SOURCE_ID="$2"; shift 2 ;;
    --purpose) PURPOSE="$2"; shift 2 ;;
    --lock-wait) LOCK_WAIT="$2"; shift 2 ;;
    --op-timeout) OP_TIMEOUT="$2"; shift 2 ;;
    --dry-run) DRY=1; shift ;;
    *) echo "unknown argument: $1" >&2; usage ;;
  esac
done

[ -n "$PLIST" ] && [ -f "$PLIST" ] || { echo "PRECONDITION: --plist must be an existing file" >&2; exit 2; }
[ -n "$CONFIG_FILE" ] || { echo "PRECONDITION: --config-file required" >&2; exit 2; }
[ -n "$TOKEN_FILE" ] || { echo "PRECONDITION: --token-file required" >&2; exit 2; }
[ -n "$OLD_ID" ] && [ -n "$NEW_ID" ] && [ -n "$NEW_SOURCE_ID" ] || { echo "PRECONDITION: --old-list-id, --new-list-id and --new-source-id are all required" >&2; exit 2; }
[ "$DRY" -eq 1 ] || [ -n "$OUT" ] || { echo "PRECONDITION: --out required" >&2; exit 2; }
[ "$OLD_ID" != "$NEW_ID" ] || { echo "PRECONDITION: --new-list-id must differ from --old-list-id" >&2; exit 2; }
case "$NEW_ID$NEW_SOURCE_ID" in
  *[!A-Za-z0-9\-]*) echo "PRECONDITION: list/source ids must not contain ':' or ';' (they would corrupt EVENTKIT_BRIDGE_BINDINGS)" >&2; exit 2 ;;
esac
case "$OP_TIMEOUT" in ''|*[!0-9]*) echo "PRECONDITION: --op-timeout must be a whole number of seconds" >&2; exit 2 ;; esac
[ "$OP_TIMEOUT" -ge 1 ] || { echo "PRECONDITION: --op-timeout must be at least 1" >&2; exit 2; }
case "$LOCK_WAIT" in ''|*[!0-9]*) echo "PRECONDITION: --lock-wait must be a whole number of seconds" >&2; exit 2 ;; esac

# --- 1. which source actually holds BOTH keys --------------------------------
# The pair must move as one. If the two keys are split across the plist and the
# config file, editing either side alone desynchronises the pair - the exact
# failure this script exists to prevent - so that state is refused outright.
plist_allowed=0; plist_bindings=0
"$PLUTIL" -extract "$ALLOW_KEY" raw "$PLIST" >/dev/null 2>&1 && plist_allowed=1
"$PLUTIL" -extract "$BIND_KEY" raw "$PLIST" >/dev/null 2>&1 && plist_bindings=1

cfg_allowed=0; cfg_bindings=0
if [ -f "$CONFIG_FILE" ]; then
  grep -Eq '^[[:space:]]*EVENTKIT_BRIDGE_ALLOWED_LIST_IDS[[:space:]]*=' "$CONFIG_FILE" 2>/dev/null && cfg_allowed=1
  grep -Eq '^[[:space:]]*EVENTKIT_BRIDGE_BINDINGS[[:space:]]*=' "$CONFIG_FILE" 2>/dev/null && cfg_bindings=1
fi

if [ "$plist_allowed" -eq 1 ] && [ "$plist_bindings" -eq 1 ]; then
  SOURCE="launchd_env"; RELOAD="bootout_bootstrap"
  OLD_ALLOWED="$("$PLUTIL" -extract "$ALLOW_KEY" raw "$PLIST" 2>/dev/null || true)"
  OLD_BINDINGS="$("$PLUTIL" -extract "$BIND_KEY" raw "$PLIST" 2>/dev/null || true)"
elif [ "$cfg_allowed" -eq 1 ] && [ "$cfg_bindings" -eq 1 ]; then
  if [ "$plist_allowed" -eq 1 ] || [ "$plist_bindings" -eq 1 ]; then
    echo "[r1_rebind] REFUSED: the binding pair is split across the plist and the config file; editing either side alone would desynchronise it" >&2
    exit 5
  fi
  SOURCE="config_file"; RELOAD="kickstart"
  OLD_ALLOWED="$(awk -F= '/^[[:space:]]*EVENTKIT_BRIDGE_ALLOWED_LIST_IDS[[:space:]]*=/{v=$2; gsub(/[[:space:]"]/,"",v); print v; exit}' "$CONFIG_FILE" 2>/dev/null || true)"
  OLD_BINDINGS="$(awk -F= '/^[[:space:]]*EVENTKIT_BRIDGE_BINDINGS[[:space:]]*=/{v=$2; gsub(/[[:space:]"]/,"",v); print v; exit}' "$CONFIG_FILE" 2>/dev/null || true)"
else
  echo "[r1_rebind] REFUSED: the binding pair is not defined together in one authoritative source (plist allowed=$plist_allowed bindings=$plist_bindings; config allowed=$cfg_allowed bindings=$cfg_bindings)" >&2
  exit 5
fi

# Precondition: the allowlist is exactly the one old list, and the old binding
# is a calDAV/iCloud entry for that id. Anything else is a configuration this
# script does not understand well enough to rewrite.
OLD_ALLOWED_TRIM="$(printf '%s' "$OLD_ALLOWED" | tr -d '[:space:]')"
[ "$OLD_ALLOWED_TRIM" = "$OLD_ID" ] || {
  echo "[r1_rebind] REFUSED: the allowlist is not exactly the old list id (observed: ${OLD_ALLOWED_TRIM:-empty})" >&2
  exit 5
}
OLD_SOURCE_ID=""
while IFS= read -r entry; do
  [ -n "$entry" ] || continue
  case "$entry" in
    "$OLD_ID":*)
      OLD_SOURCE_ID="$(printf '%s' "$entry" | awk -F: '{print $2}')"
      ;;
  esac
done <<EOF2
$(printf '%s' "$OLD_BINDINGS" | tr ';' '\n')
EOF2
if [ -z "$OLD_SOURCE_ID" ] || ! printf '%s' "$OLD_BINDINGS" | grep -q "$OLD_ID:.*:calDAV:iCloud"; then
  echo "[r1_rebind] REFUSED: no calDAV/iCloud binding entry for the old list id was found" >&2
  exit 5
fi

NEW_BINDINGS="$NEW_ID:$NEW_SOURCE_ID:calDAV:iCloud"
echo "[r1_rebind] source=$SOURCE reload=$RELOAD old_list=$(printf '%s' "$OLD_ID" | cut -c1-4)**** purpose=$PURPOSE"

if [ "$DRY" -eq 1 ]; then
  echo "[r1_rebind] DRY RUN: no pre-check, no lock, no change written"
  echo "[r1_rebind] plan: pre-check via enumeration 403 (zero item reads) -> backup -> write allowlist+bindings pair -> reload ($RELOAD) -> post-probe new id (strict); on failure: restore backups -> reload -> gate 403 + new-id BLOCKED_NOT_ON_ALLOWLIST verification"
  exit 0
fi

# --- 2. evidence directory (proven writable before anything else) -------------
OUT_DIR="$(dirname "$OUT")"
if [ ! -d "$OUT_DIR" ]; then
  echo "[r1_rebind] FAILED: evidence directory does not exist: $OUT_DIR; nothing was changed" >&2
  exit 6
fi
if ! : > "$OUT_DIR/.r1-rebind-probe.$$" 2>/dev/null; then
  echo "[r1_rebind] FAILED: evidence directory is not writable: $OUT_DIR; nothing was changed" >&2
  exit 6
fi
rm -f "$OUT_DIR/.r1-rebind-probe.$$" 2>/dev/null || true

emit_failure_receipt() {  # $1 = stage, $2 = rc, $3 = classification of last probe (optional)
  [ -n "$OUT" ] || return 0
  R1_STAGE="$1" R1_RC="$2" R1_LAST_PROBE="${3:-}" \
  R1_SOURCE="$SOURCE" R1_RELOAD="$RELOAD" R1_PURPOSE="$PURPOSE" \
  R1_ROLLED_BACK="${ROLLED_BACK:-0}" R1_DISK_WRITTEN="${DISK_WRITTEN:-0}" \
  R1_BACKUP_PLIST="${BACKUP_PLIST:-}" R1_BACKUP_CFG="${BACKUP_CFG:-}" \
  R1_VERIFY="${VERIFY_VERDICT:-FAIL}" \
  R1_DEADLINE_PHASE="${DEADLINE_PHASE:-}" R1_RELOAD_KILLED="${RELOAD_KILLED:-0}" \
  R1_RECOVERY_RELOADED="${RECOVERY_RELOADED:-0}" \
  R1_RECOVERY_HEALTH="${RECOVERY_HEALTH:-}" \
  R1_RECOVERY_GATE="${RECOVERY_GATE:-}" \
  R1_RECOVERY_PROBE="${RECOVERY_PROBE:-}" \
  R1_ROLLBACK_GATE="${ROLLBACK_GATE_CLASS:-}" \
  R1_ROLLBACK_PROBE="${ROLLBACK_PROBE_CLASS:-}" \
  "$PYTHON" - "$OUT" <<'PYEOF' || echo "[r1_rebind] WARNING: could not write the failure receipt to $OUT" >&2
import json, os, sys
env = os.environ

def mask(v):
    import re
    if not v:
        return None
    return re.sub(r"[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}",
                  lambda m: m.group(0)[:4] + "****" + m.group(0)[-4:], v)

receipt = {
  "receipt_type": "R1_REBIND_OPERATION",
  "purpose": env.get("R1_PURPOSE"),
  "gate_source_detected": env["R1_SOURCE"],
  "reload_method": env["R1_RELOAD"],
  "verification": env.get("R1_VERIFY", "FAIL"),
  "failure_stage": env["R1_STAGE"],
  "failure_exit_code": int(env["R1_RC"]),
  "last_probe_classification": env.get("R1_LAST_PROBE") or None,
  "disk_written_before_failure": env.get("R1_DISK_WRITTEN") == "1",
  "rolled_back": env.get("R1_ROLLED_BACK") == "1",
  "plist_backup_present": bool(env.get("R1_BACKUP_PLIST")),
  "config_backup_present": bool(env.get("R1_BACKUP_CFG")),
  "old_allowlist_masked": mask(os.environ.get("R1_OLD_ALLOWED", "")),
  "old_bindings_masked": mask(os.environ.get("R1_OLD_BINDINGS", "")),
  "scope_note": "this operation never requests the OLD list's item endpoint; "
                "every item read targets the new list, so an unexpectedly open "
                "gate cannot widen the read scope beyond the authorization",
}
# Rollback verification (verify-failure path): the two scope-safe checks.
if env.get("R1_ROLLBACK_GATE") or env.get("R1_ROLLBACK_PROBE"):
    receipt["rollback_verification"] = {
        "gate_check": env.get("R1_ROLLBACK_GATE") or None,
        "new_id_probe": env.get("R1_ROLLBACK_PROBE") or None,
    }
# Deadline recovery: what the bounded recovery actually re-established.
if env.get("R1_DEADLINE_PHASE"):
    recovery_verified = (env.get("R1_RECOVERY_HEALTH") == "OK"
                         and env.get("R1_RECOVERY_GATE") == "GATE_AS_EXPECTED"
                         and env.get("R1_RECOVERY_PROBE") == "BLOCKED_NOT_ON_ALLOWLIST")
    receipt.update({
        "deadline_phase": env["R1_DEADLINE_PHASE"],
        "reload_killed_at_deadline": env.get("R1_RELOAD_KILLED") == "1",
        "recovery": {
            "reloaded": env.get("R1_RECOVERY_RELOADED") == "1",
            "health": env.get("R1_RECOVERY_HEALTH") or None,
            "gate_check": env.get("R1_RECOVERY_GATE") or None,
            "new_id_probe": env.get("R1_RECOVERY_PROBE") or None,
            "verdict": "VERIFIED" if recovery_verified else "FAILED_OR_NOT_ATTEMPTED",
        },
        "note": "A deadline is never a success (exit 8). When recovery.verdict is "
                "VERIFIED, the backups were restored AND the old configuration was "
                "proven reloaded (new id refused by the old allowlist), the service "
                "is healthy and the gate is closed. Otherwise manual action is "
                "required: disk/process divergence is possible.",
    })
with open(sys.argv[1], "w", encoding="utf-8") as fh:
    json.dump(receipt, fh, indent=2, ensure_ascii=False)
    fh.write("\n")
PYEOF
}

# --- 3. pre-check: the gate is not open, proven WITHOUT touching any items ----
# The enumeration endpoint answers metadata only - it can never carry item
# content for any list, whatever the gate state is. 403 here means "gate
# closed, or TCC denied"; the second case is content-safe as well (no items can
# be served at all while TCC denies the store) and would surface at W1.
# This replaces the retired old-id pre-probe, whose item read was outside the
# authorized scope whenever the gate was unexpectedly open.
PRE_JSON="$OUT.precheck.json"
"$PYTHON" "$CLIENT" gate --endpoint "$ENDPOINT" --token-file "$TOKEN_FILE" \
  --expect 403 --out "$PRE_JSON" >/dev/null 2>&1
PRE_RC=$?
PRE_CLASS="$("$PYTHON" -c 'import json,sys;print(json.load(open(sys.argv[1])).get("classification"))' "$PRE_JSON" 2>/dev/null || echo unreadable)"
PRE_HTTP="$("$PYTHON" -c 'import json,sys;print(json.load(open(sys.argv[1])).get("http_status"))' "$PRE_JSON" 2>/dev/null || echo "?")"
if [ "$PRE_RC" -ne 0 ]; then
  echo "[r1_rebind] FAILED: pre-check did not prove a closed gate (observed=$PRE_CLASS http=$PRE_HTTP); the gate may be open - rebind refused, nothing changed" >&2
  R1_OLD_ALLOWED="$OLD_ALLOWED" R1_OLD_BINDINGS="$OLD_BINDINGS" \
    emit_failure_receipt pre_check 3 "$PRE_CLASS"
  exit 3
fi
echo "[r1_rebind] pre-check: gate not open proven without any item read ($PRE_CLASS http=$PRE_HTTP)"

# --- 4. shared mutex (copied verbatim from r1_gate.sh) ------------------------
LOCK_ROOT="${R1_LOCK_DIR:-$HOME/.muse-r1}"
LOCK="$LOCK_ROOT/gate.lock"
OWNERS="$LOCK_ROOT/owners"
LOCK_INIT_GRACE="${R1_LOCK_INIT_GRACE_SECONDS:-10}"
LOCK_HELD=0; LOCK_TOKEN=""; LK_KIND=""; LK_TARGET=""; LK_PID=""; LK_LSTART=""; LK_AGE=0
mkdir -p "$LOCK_ROOT" "$OWNERS" 2>/dev/null || true
chmod 700 "$LOCK_ROOT" "$OWNERS" 2>/dev/null || true

owner_field() { awk -F= -v k="$1" '$1==k{sub(/^[^=]*=/,""); print; exit}' "$2" 2>/dev/null; }
lock_link_target() { readlink "$LOCK" 2>/dev/null; }
lstart_of() { ps -p "$1" -o lstart= 2>/dev/null | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'; }

owner_record_path() {
  REC=""
  if [ -L "$LOCK" ]; then
    REC="$LOCK_ROOT/$(readlink "$LOCK" 2>/dev/null)"
  elif [ -d "$LOCK" ]; then
    REC="$LOCK/owner.env"
  fi
}

owner_alive() {
  local pid="$1" want="$2" why=""
  [ -n "$pid" ] || return 1
  if kill -0 "$pid" 2>/dev/null; then
    if [ -z "$want" ]; then return 0; fi
    [ "$(lstart_of "$pid")" = "$want" ] && return 0
    return 1
  fi
  why="$(kill -0 "$pid" 2>&1 || true)"
  case "$why" in
    *[Nn]ot\ permitted*|*[Oo]peration\ not\ permitted*)
      if [ -n "$want" ] && [ "$(lstart_of "$pid")" = "$want" ]; then return 0; fi
      return 1 ;;
  esac
  return 1
}

inspect_lock() {
  local mtime=0
  LK_KIND="missing"; LK_TARGET=""; LK_PID=""; LK_LSTART=""; LK_AGE=0
  owner_record_path
  if [ -L "$LOCK" ]; then
    LK_KIND="symlink"; LK_TARGET="$(readlink "$LOCK" 2>/dev/null)"
  elif [ -d "$LOCK" ]; then
    LK_KIND="dir"
  elif [ -e "$LOCK" ]; then
    LK_KIND="other"
  fi
  if [ -n "$REC" ]; then
    LK_PID="$(owner_field LOCK_PID "$REC")"
    LK_LSTART="$(owner_field LOCK_LSTART "$REC")"
  fi
  if [ "$LK_KIND" != "missing" ]; then
    mtime="$(stat -f %m "$LOCK" 2>/dev/null || echo 0)"
    LK_AGE=$(( $(date +%s) - mtime ))
  fi
  return 0
}

reclaim_lock() {
  local stale="$LOCK_ROOT/.gate.lock.stale.$$" got=""
  rm -rf "$stale" 2>/dev/null || true
  mv "$LOCK" "$stale" 2>/dev/null || return 1
  [ -L "$stale" ] && got="$(readlink "$stale" 2>/dev/null)"
  if [ "$LK_KIND" = "symlink" ] && [ "$got" != "$LK_TARGET" ]; then
    if [ ! -e "$LOCK" ] && [ ! -L "$LOCK" ] && mv "$stale" "$LOCK" 2>/dev/null; then
      echo "[r1_rebind] reclaim aborted: a newer holder published while we were inspecting; its lock was restored untouched" >&2
    else
      echo "[r1_rebind] WARNING: reclaimed artifact differs from the observed owner and could not be restored; it was kept, not deleted" >&2
    fi
    return 1
  fi
  rm -rf "$stale" 2>/dev/null || true
  echo "[r1_rebind] reclaimed a stale lock (kind=$LK_KIND owner_pid=${LK_PID:-unpublished} age=${LK_AGE}s)"
  return 0
}

publish_lock() {
  local name="$$.$(date +%s).${RANDOM}${RANDOM}.env" rec
  rec="$OWNERS/$name"
  ( umask 077; {
      echo "LOCK_PID=$$"
      echo "LOCK_LSTART=$(lstart_of $$)"
      echo "LOCK_UID=$UID"
      echo "LOCK_PURPOSE=$PURPOSE"
      echo "LOCK_MODE=rebind"
      echo "LOCK_ACQUIRED=$(date +%s)"
    } > "$rec" ) 2>/dev/null || { rm -f "$rec" 2>/dev/null; return 2; }
  chmod 600 "$rec" 2>/dev/null || true
  LOCK_TOKEN="owners/$name"
  if [ -e "$LOCK" ] || [ -L "$LOCK" ]; then
    rm -f "$rec" 2>/dev/null; LOCK_TOKEN=""
    return 1
  fi
  if ! ln -s "$LOCK_TOKEN" "$LOCK" 2>/dev/null; then
    rm -f "$rec" 2>/dev/null; LOCK_TOKEN=""
    return 1
  fi
  return 0
}

confirm_lock() { [ -n "$LOCK_TOKEN" ] && [ "$(lock_link_target)" = "$LOCK_TOKEN" ]; }
assert_lock_owned() { [ "$LOCK_HELD" -eq 1 ] && confirm_lock; }

release_lock() {
  [ "$LOCK_HELD" -eq 1 ] || return 0
  if [ -n "$LOCK_TOKEN" ] && [ "$(lock_link_target)" = "$LOCK_TOKEN" ]; then
    rm -f "$LOCK" 2>/dev/null || true
    rm -f "$OWNERS/$(basename "$LOCK_TOKEN")" 2>/dev/null || true
  fi
  LOCK_HELD=0
}

acquire_lock() {
  local start prc; start="$(date +%s)"
  while :; do
    publish_lock; prc=$?
    if [ "$prc" -eq 0 ]; then
      if confirm_lock; then
        LOCK_HELD=1
        trap release_lock EXIT
        return 0
      fi
      if [ -d "$LOCK" ] && [ ! -L "$LOCK" ] && [ -L "$LOCK/$(basename "$LOCK_TOKEN")" ]; then
        rm -f "$LOCK/$(basename "$LOCK_TOKEN")" 2>/dev/null || true
      fi
      rm -f "$OWNERS/$(basename "$LOCK_TOKEN")" 2>/dev/null || true
      LOCK_TOKEN=""
      echo "[r1_rebind] lost the lock right after publishing it; waiting again" >&2
    elif [ "$prc" -eq 2 ]; then
      echo "[r1_rebind] FAILED: cannot write the lock owner record in $OWNERS" >&2
      return 2
    else
      inspect_lock
      if [ "$LK_KIND" = "missing" ]; then
        sleep 0.2
        continue
      fi
      if [ "$LK_KIND" = "symlink" ] || [ "$LK_KIND" = "dir" ]; then
        if owner_alive "$LK_PID" "$LK_LSTART"; then
          :
        elif [ -n "$LK_PID" ]; then
          if reclaim_lock; then continue; fi
        elif [ "$LK_AGE" -lt "$LOCK_INIT_GRACE" ]; then
          :
        else
          if reclaim_lock; then continue; fi
        fi
      elif [ "$LK_AGE" -ge "$LOCK_INIT_GRACE" ]; then
        if reclaim_lock; then continue; fi
      fi
    fi
    [ $(( $(date +%s) - start )) -ge "$LOCK_WAIT" ] && return 1
    sleep 0.5
  done
}

LOCK_RC=0
acquire_lock || LOCK_RC=$?
if [ "$LOCK_RC" -ne 0 ]; then
  inspect_lock
  echo "[r1_rebind] FAILED: could not take the gate mutex within ${LOCK_WAIT}s (holder pid=${LK_PID:-none}); not forcing it" >&2
  R1_OLD_ALLOWED="$OLD_ALLOWED" R1_OLD_BINDINGS="$OLD_BINDINGS" \
    emit_failure_receipt lock 7
  [ "$LOCK_RC" -eq 2 ] && exit 6
  exit 7
fi

# --- 5. operation clock (copied verbatim from r1_gate.sh) ---------------------
OP_START="$(date +%s)"
DEADLINE_KILLED=0; ROLLED_BACK=0; RELOAD_KILLED=0; DEADLINE_PHASE=""
DISK_WRITTEN=0; BACKUP_PLIST=""; BACKUP_CFG=""

op_remaining() {
  local used left
  used=$(( $(date +%s) - OP_START ))
  left=$(( OP_TIMEOUT - used ))
  [ "$left" -lt 0 ] && left=0
  printf '%s' "$left"
}

kill_tree() {   # $1 = pid, $2 = depth (internal)
  local pid="$1" depth="${2:-0}" child waited=0
  case "$pid" in ''|*[!0-9]*) return 0 ;; esac
  [ "$pid" -gt 1 ] || return 0
  if [ "$depth" -lt 8 ]; then
    for child in $(pgrep -P "$pid" 2>/dev/null); do
      case "$child" in ''|*[!0-9]*) continue ;; esac
      [ "$child" = "$pid" ] && continue
      kill_tree "$child" $((depth + 1))
    done
  fi
  kill -TERM "$pid" 2>/dev/null || true
  while kill -0 "$pid" 2>/dev/null && [ "$waited" -lt 5 ]; do sleep 0.2; waited=$((waited + 1)); done
  kill -KILL "$pid" 2>/dev/null || true
}

run_bounded() {
  local limit="$1" pid started rc=0; shift
  if [ "$limit" -le 0 ]; then DEADLINE_KILLED=1; return 124; fi
  "$@" &
  pid=$!
  started="$(date +%s)"
  while kill -0 "$pid" 2>/dev/null; do
    if [ $(( $(date +%s) - started )) -ge "$limit" ]; then
      kill_tree "$pid"
      wait "$pid" 2>/dev/null
      DEADLINE_KILLED=1
      return 124
    fi
    sleep 0.2
  done
  wait "$pid" 2>/dev/null
  rc=$?
  return "$rc"
}

op_guard() {
  if [ "$(op_remaining)" -le 0 ]; then deadline_exit "$1"; fi
  return 0
}

# The recovery clock: the operation clock is already spent when a deadline
# fires, so the recovery gets its own bounded budget - never unbounded, or a
# stuck reload would hold the gate mutex forever.
RECOVERY_TIMEOUT="${R1_RECOVERY_TIMEOUT:-45}"
RECOVERY_START=0
rec_remaining() {
  local left=$(( RECOVERY_TIMEOUT - $(date +%s) + RECOVERY_START ))
  [ "$left" -lt 0 ] && left=0
  printf '%s' "$left"
}

# One reload of the authoritative source, bounded by the remaining budget of
# the clock whose name is passed in ($1: op_remaining or rec_remaining). Used
# by the rollback paths and the deadline recovery alike, so a rollback can
# never be a different, weaker reload than the forward one.
do_reload_bounded() {  # $1 = name of the remaining-seconds function
  local rem="$1" rc=0
  if [ "$SOURCE" = "launchd_env" ]; then
    run_bounded "$($rem)" "$LAUNCHCTL" bootout "gui/$(id -u)/$LABEL" >/dev/null 2>&1 || true
    run_bounded "$($rem)" sleep 1 || true
    run_bounded "$($rem)" "$LAUNCHCTL" bootstrap "gui/$(id -u)" "$PLIST" || rc=$?
  else
    run_bounded "$($rem)" "$LAUNCHCTL" kickstart -k "gui/$(id -u)/$LABEL" || rc=$?
  fi
  return "$rc"
}

# Scope-safe proof that a rollback actually took effect: (1) the gate is
# closed (enumeration 403 - metadata only, zero item content), and (2) the
# OLD allowlist is live in the process - the NEW id must be refused by the
# allowlist BEFORE the gate is consulted, so LIST_NOT_ALLOWED proves the old
# configuration was reloaded. The OLD list id is never requested here.
# Leaves ROLLBACK_GATE_CLASS / ROLLBACK_PROBE_CLASS for the receipt. Returns
# 0 verified, 1 not verified, 124 a check hit its clock.
verify_rollback_state() {  # $1 = gate json, $2 = probe json, $3 = remaining fn
  local rem="$3" grc=0 prc=0
  ROLLBACK_GATE_CLASS="FAIL"; ROLLBACK_PROBE_CLASS="FAIL"
  run_bounded "$($rem)" "$PYTHON" "$CLIENT" gate --endpoint "$ENDPOINT" \
    --token-file "$TOKEN_FILE" --expect 403 --out "$1" >/dev/null 2>&1 || grc=$?
  [ "$grc" -ne 0 ] && { [ "$grc" -eq 124 ] && return 124; return 1; }
  ROLLBACK_GATE_CLASS="$("$PYTHON" -c 'import json,sys;print(json.load(open(sys.argv[1])).get("classification"))' "$1" 2>/dev/null || echo unreadable)"
  run_bounded "$($rem)" "$PYTHON" "$CLIENT" probe --endpoint "$ENDPOINT" \
    --token-file "$TOKEN_FILE" --list-id "$NEW_ID" --phase post \
    --expect BLOCKED_NOT_ON_ALLOWLIST --out "$2" >/dev/null 2>&1 || prc=$?
  [ "$prc" -ne 0 ] && { [ "$prc" -eq 124 ] && return 124; return 1; }
  ROLLBACK_PROBE_CLASS="$("$PYTHON" -c 'import json,sys;print(json.load(open(sys.argv[1])).get("classification"))' "$2" 2>/dev/null || echo unreadable)"
  return 0
}

# Deadline exit differs from r1_gate.sh on purpose. A gate deadline leaves one
# key whose safe value is self-evident ("false"); a rebind deadline can leave a
# rewritten binding pair on disk while the process runs the old one, and that
# divergence is not self-evidently safe. So this exit RECOVERS: restore the
# backups, reload once more under the recovery clock, then verify health, gate
# closed, and the old allowlist live - with the two scope-safe checks above.
# Exit 8 either way (a deadline is never a success); the receipt records what
# the recovery actually re-established.
deadline_exit() {
  DEADLINE_PHASE="$1"
  RELOAD_KILLED="$DEADLINE_KILLED"
  RECOVERY_RELOADED=0; RECOVERY_HEALTH=""; RECOVERY_GATE=""; RECOVERY_PROBE=""
  echo "[r1_rebind] DEADLINE EXCEEDED in $1: ${OP_TIMEOUT}s budget gone; entering bounded recovery" >&2
  if [ "$DISK_WRITTEN" -eq 1 ]; then
    restore_backups
    RECOVERY_START="$(date +%s)"
    REC_RELOAD_RC=0
    do_reload_bounded rec_remaining || REC_RELOAD_RC=$?
    if [ "$REC_RELOAD_RC" -eq 0 ]; then
      RECOVERY_RELOADED=1
      echo "[r1_rebind] recovery: the restored (old) configuration was reloaded" >&2
    else
      echo "[r1_rebind] CRITICAL: recovery reload failed (rc=$REC_RELOAD_RC); disk holds the OLD pair, the process state is unknown - manual action required" >&2
    fi
    if [ "$RECOVERY_RELOADED" -eq 1 ]; then
      HC=0
      run_bounded "$(rec_remaining)" "$PYTHON" "$CLIENT" health --endpoint "$ENDPOINT" \
        --out "$OUT.recovery-health.json" >/dev/null 2>&1 || HC=$?
      [ "$HC" -eq 0 ] && RECOVERY_HEALTH="OK" || RECOVERY_HEALTH="FAIL"
      VRC=0
      verify_rollback_state "$OUT.recovery-gate.json" "$OUT.recovery-probe.json" rec_remaining || VRC=$?
      RECOVERY_GATE="$ROLLBACK_GATE_CLASS"
      RECOVERY_PROBE="$ROLLBACK_PROBE_CLASS"
      if [ "$RECOVERY_HEALTH" = "OK" ] && [ "$RECOVERY_GATE" = "GATE_AS_EXPECTED" ] \
         && [ "$RECOVERY_PROBE" = "BLOCKED_NOT_ON_ALLOWLIST" ]; then
        echo "[r1_rebind] recovery VERIFIED: old configuration reloaded, service healthy, gate closed" >&2
      else
        echo "[r1_rebind] CRITICAL: recovery NOT verified (health=$RECOVERY_HEALTH gate=$RECOVERY_GATE probe=$RECOVERY_PROBE); manual action required" >&2
      fi
    fi
  else
    echo "[r1_rebind] nothing had been written; no recovery needed" >&2
  fi
  R1_OLD_ALLOWED="$OLD_ALLOWED" R1_OLD_BINDINGS="$OLD_BINDINGS" \
    emit_failure_receipt op_timeout 8
  exit 8
}

# --- 6. backups ---------------------------------------------------------------
if [ "$SOURCE" = "launchd_env" ]; then
  BACKUP_PLIST="$OUT.plist-backup"
  cp -p "$PLIST" "$BACKUP_PLIST" 2>/dev/null && chmod 600 "$BACKUP_PLIST" 2>/dev/null || {
    BACKUP_PLIST=""
    echo "[r1_rebind] FAILED: could not create a 0600 backup of the plist; refusing to edit it" >&2
    R1_OLD_ALLOWED="$OLD_ALLOWED" R1_OLD_BINDINGS="$OLD_BINDINGS" emit_failure_receipt backup 3
    exit 3
  }
  echo "[r1_rebind] plist backed up to a 0600 file inside the restricted evidence dir"
else
  BACKUP_CFG="$OUT.config-backup"
  cp -p "$CONFIG_FILE" "$BACKUP_CFG" 2>/dev/null && chmod 600 "$BACKUP_CFG" 2>/dev/null || {
    BACKUP_CFG=""
    echo "[r1_rebind] FAILED: could not create a 0600 backup of the config file; refusing to edit it" >&2
    R1_OLD_ALLOWED="$OLD_ALLOWED" R1_OLD_BINDINGS="$OLD_BINDINGS" emit_failure_receipt backup 3
    exit 3
  }
  echo "[r1_rebind] config file backed up to a 0600 file; only the binding pair will change"
fi

# --- 7. write the pair, atomically per file -----------------------------------
set_config_pair() {  # $1 = new allowlist, $2 = new bindings
  [ -n "$CONFIG_FILE" ] && [ -f "$CONFIG_FILE" ] || return 7
  "$PYTHON" - "$CONFIG_FILE" "$1" "$2" <<'PYEOF'
import os, re, sys, tempfile
path, allowed, bindings = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path, encoding="utf-8") as fh:
    text = fh.read()
p_allowed = re.compile(r'^([ \t]*EVENTKIT_BRIDGE_ALLOWED_LIST_IDS[ \t]*=).*$', re.M)
p_bind = re.compile(r'^([ \t]*EVENTKIT_BRIDGE_BINDINGS[ \t]*=).*$', re.M)
if not p_allowed.search(text) or not p_bind.search(text):
    sys.exit(9)
text = p_allowed.sub(lambda m: f"{m.group(1)}{allowed}", text)
text = p_bind.sub(lambda m: f"{m.group(1)}{bindings}", text)
mode = os.stat(path).st_mode & 0o777
directory = os.path.dirname(os.path.abspath(path))
fd, tmp = tempfile.mkstemp(prefix=".r1-rebind-", dir=directory)
try:
    with os.fdopen(fd, "w", encoding="utf-8") as fh:
        fh.write(text)
    os.chmod(tmp, mode)
    os.replace(tmp, path)
finally:
    if os.path.exists(tmp):
        os.unlink(tmp)
PYEOF
}

restore_backups() {
  local ok=1
  if [ -n "$BACKUP_PLIST" ]; then cp -p "$BACKUP_PLIST" "$PLIST" 2>/dev/null || ok=0; fi
  if [ -n "$BACKUP_CFG" ]; then cp -p "$BACKUP_CFG" "$CONFIG_FILE" 2>/dev/null || ok=0; fi
  [ "$ok" -eq 1 ] && ROLLED_BACK=1
  return 0
}

if ! assert_lock_owned; then
  echo "[r1_rebind] FAILED: this process no longer owns the gate mutex; refusing to write" >&2
  R1_OLD_ALLOWED="$OLD_ALLOWED" R1_OLD_BINDINGS="$OLD_BINDINGS" emit_failure_receipt lock_lost 7
  exit 7
fi
op_guard write
WRITE_RC=0
if [ "$SOURCE" = "launchd_env" ]; then
  "$PLUTIL" -replace "$ALLOW_KEY" -string "$NEW_ID" "$PLIST" || WRITE_RC=$?
  if [ "$WRITE_RC" -eq 0 ]; then
    "$PLUTIL" -replace "$BIND_KEY" -string "$NEW_BINDINGS" "$PLIST" || WRITE_RC=$?
  fi
else
  set_config_pair "$NEW_ID" "$NEW_BINDINGS" || WRITE_RC=$?
fi
if [ "$WRITE_RC" -ne 0 ]; then
  echo "[r1_rebind] FAILED: writing the binding pair returned $WRITE_RC; restoring backups (no reload happened, the running process never saw the new pair)" >&2
  restore_backups
  R1_OLD_ALLOWED="$OLD_ALLOWED" R1_OLD_BINDINGS="$OLD_BINDINGS" emit_failure_receipt write 3
  exit 3
fi
DISK_WRITTEN=1
echo "[r1_rebind] pair written: allowlist and bindings now name the new list"

# --- 8. reload (one reload for both keys) --------------------------------------
if ! assert_lock_owned; then
  echo "[r1_rebind] FAILED: this process no longer owns the gate mutex; the pair was written but will not be reloaded here" >&2
  restore_backups
  R1_OLD_ALLOWED="$OLD_ALLOWED" R1_OLD_BINDINGS="$OLD_BINDINGS" emit_failure_receipt lock_lost 7
  exit 7
fi
BEFORE_PID="$(pgrep -x EventKitBridgeServer 2>/dev/null | head -1 || true)"
RELOAD_RC=0
if [ "$SOURCE" = "launchd_env" ]; then
  op_guard reload
  BOOTOUT_RC=0
  run_bounded "$(op_remaining)" "$LAUNCHCTL" bootout "gui/$(id -u)/$LABEL" 2>/dev/null || BOOTOUT_RC=$?
  [ "$BOOTOUT_RC" -eq 124 ] && deadline_exit reload
  if [ "$BOOTOUT_RC" -ne 0 ]; then
    PRINT_RC=0
    run_bounded "$(op_remaining)" "$LAUNCHCTL" print "gui/$(id -u)/$LABEL" >/dev/null 2>&1 || PRINT_RC=$?
    [ "$PRINT_RC" -eq 124 ] && deadline_exit reload
    if [ "$PRINT_RC" -eq 0 ]; then
      echo "[r1_rebind] FAILED: bootout returned $BOOTOUT_RC but the job is still loaded" >&2
      restore_backups
      AFTER_PID="$(pgrep -x EventKitBridgeServer 2>/dev/null | head -1 || true)"
      R1_OLD_ALLOWED="$OLD_ALLOWED" R1_OLD_BINDINGS="$OLD_BINDINGS" emit_failure_receipt bootout 4
      exit 4
    fi
    echo "[r1_rebind] bootout reported $BOOTOUT_RC and the job is not loaded; continuing"
  fi
  SETTLE_STOP=0
  run_bounded "$(op_remaining)" sleep 1 || SETTLE_STOP=$?
  [ "$SETTLE_STOP" -eq 124 ] && deadline_exit reload
  run_bounded "$(op_remaining)" "$LAUNCHCTL" bootstrap "gui/$(id -u)" "$PLIST" || RELOAD_RC=$?
  [ "$RELOAD_RC" -eq 124 ] && deadline_exit reload
else
  op_guard reload
  run_bounded "$(op_remaining)" "$LAUNCHCTL" kickstart -k "gui/$(id -u)/$LABEL" || RELOAD_RC=$?
  [ "$RELOAD_RC" -eq 124 ] && deadline_exit reload
fi
if [ "$RELOAD_RC" -ne 0 ]; then
  echo "[r1_rebind] FAILED: reload returned $RELOAD_RC; restoring backups and reloading again" >&2
  restore_backups
  ROLLBACK_RELOAD_RC=0
  op_guard rollback_reload
  do_reload_bounded op_remaining || ROLLBACK_RELOAD_RC=$?
  [ "$ROLLBACK_RELOAD_RC" -eq 124 ] && deadline_exit rollback_reload
  AFTER_PID="$(pgrep -x EventKitBridgeServer 2>/dev/null | head -1 || true)"
  # Verify what the rollback actually re-established (scope-safe checks).
  VRC=0
  verify_rollback_state "$OUT.rollbackgate.json" "$OUT.rollbackprobe.json" op_remaining || VRC=$?
  [ "$VRC" -eq 124 ] && deadline_exit rollback_verify
  R1_OLD_ALLOWED="$OLD_ALLOWED" R1_OLD_BINDINGS="$OLD_BINDINGS" emit_failure_receipt reload 4
  if [ "$VRC" -eq 0 ]; then
    echo "[r1_rebind] rollback verified: old allowlist live, gate closed" >&2
  else
    echo "[r1_rebind] CRITICAL: rollback NOT verified (gate=$ROLLBACK_GATE_CLASS probe=$ROLLBACK_PROBE_CLASS); manual action required" >&2
  fi
  exit 4
fi

# --- 9. post-probe: the gate is closed against the NEW binding -----------------
SETTLE_RC=0
run_bounded "$(op_remaining)" sleep "${R1_SETTLE_SECONDS:-3}" || SETTLE_RC=$?
[ "$SETTLE_RC" -eq 124 ] && deadline_exit verify
AFTER_PID="$(pgrep -x EventKitBridgeServer 2>/dev/null | head -1 || true)"

VERIFY_RC=0
HEALTH_JSON="$OUT.health.json"
run_bounded "$(op_remaining)" "$PYTHON" "$CLIENT" health --endpoint "$ENDPOINT" --out "$HEALTH_JSON" >/dev/null 2>&1 || VERIFY_RC=$?
[ "$VERIFY_RC" -eq 124 ] && deadline_exit verify

POST_JSON="$OUT.postprobe.json"
if [ "$VERIFY_RC" -eq 0 ]; then
  run_bounded "$(op_remaining)" "$PYTHON" "$CLIENT" probe --endpoint "$ENDPOINT" \
    --token-file "$TOKEN_FILE" --list-id "$NEW_ID" --phase post \
    --expect GATE_RESTORED_CLOSED --out "$POST_JSON" >/dev/null 2>&1 || VERIFY_RC=$?
  [ "$VERIFY_RC" -eq 124 ] && deadline_exit verify
fi

POST_CLASS="$("$PYTHON" -c 'import json,sys;print(json.load(open(sys.argv[1])).get("classification"))' "$POST_JSON" 2>/dev/null || echo unreadable)"

if [ "$VERIFY_RC" -ne 0 ]; then
  echo "[r1_rebind] FAILED: post-probe did not prove the closed gate against the new binding (observed=$POST_CLASS); rolling back" >&2
  restore_backups
  ROLLBACK_RELOAD_RC=0
  op_guard rollback_reload
  do_reload_bounded op_remaining || ROLLBACK_RELOAD_RC=$?
  [ "$ROLLBACK_RELOAD_RC" -eq 124 ] && deadline_exit rollback_reload
  if [ "$ROLLBACK_RELOAD_RC" -ne 0 ]; then
    echo "[r1_rebind] CRITICAL: rollback reload failed ($ROLLBACK_RELOAD_RC); disk holds the OLD pair but the running process may hold the new one - manual action required" >&2
    R1_OLD_ALLOWED="$OLD_ALLOWED" R1_OLD_BINDINGS="$OLD_BINDINGS" emit_failure_receipt rollback_reload 4 "$POST_CLASS"
    exit 4
  fi
  # Verify the rollback with the two scope-safe checks: the gate is closed
  # (enumeration 403) and the OLD allowlist is live in the process (the NEW id
  # refused by the allowlist). The old list id is never requested.
  VRC=0
  verify_rollback_state "$OUT.rollbackgate.json" "$OUT.rollbackprobe.json" op_remaining || VRC=$?
  [ "$VRC" -eq 124 ] && deadline_exit rollback_verify
  R1_OLD_ALLOWED="$OLD_ALLOWED" R1_OLD_BINDINGS="$OLD_BINDINGS" \
    emit_failure_receipt verify_rolled_back 3 "$POST_CLASS"
  if [ "$VRC" -eq 0 ]; then
    echo "[r1_rebind] rollback verified: old allowlist live, gate closed (gate=$ROLLBACK_GATE_CLASS probe=$ROLLBACK_PROBE_CLASS)"
  else
    echo "[r1_rebind] CRITICAL: rollback NOT verified (gate=$ROLLBACK_GATE_CLASS probe=$ROLLBACK_PROBE_CLASS); manual verification required" >&2
  fi
  exit 3
fi

# --- 10. receipt ----------------------------------------------------------------
VERIFY_VERDICT="PASS"
"$PYTHON" - "$OUT" "$HERE" <<PYEOF
import json, os, sys
sys.path.insert(0, sys.argv[2])
import r1_bridge_client as client
out = sys.argv[1]
def load(p):
    try:
        with open(p, encoding="utf-8") as fh:
            return json.load(fh)
    except Exception:
        return {}
health = load(out + ".health.json")
post = load(out + ".postprobe.json")
pre = load(out + ".precheck.json")
receipt = {
  "receipt_type": "R1_REBIND_OPERATION",
  "purpose": "$PURPOSE",
  "gate_source_detected": "$SOURCE",
  "reload_method": "$RELOAD",
  "verification": "PASS",
  "verification_basis": "pre-check proves the gate is not open via the enumeration endpoint (metadata only, zero item content); the post-probe proves the closed gate against the NEW binding; never the file value",
  "old_allowlist_masked": client.mask_uuid("$OLD_ALLOWED") or None,
  "old_bindings_masked": client.mask_uuid("$OLD_BINDINGS") or None,
  "new_allowlist_masked": client.mask_uuid("$NEW_ID") or None,
  "new_bindings_masked": client.mask_uuid("$NEW_BINDINGS") or None,
  "old_source_id_masked": client.mask_uuid("$OLD_SOURCE_ID") or None,
  "new_source_id_masked": client.mask_uuid("$NEW_SOURCE_ID") or None,
  "pre_check_classification": "$PRE_CLASS",
  "pre_check_http_status": pre.get("http_status"),
  "post_probe_classification": "$POST_CLASS",
  "scope_note": "this operation never requests the OLD list's item endpoint; every item read targets the new list only",
  "before_pid": "${BEFORE_PID:-none}",
  "after_pid": "${AFTER_PID:-none}",
  "process_restarted": bool("${BEFORE_PID:-}" and "${AFTER_PID:-}" and "${BEFORE_PID}" != "${AFTER_PID}"),
  "operation_timeout_seconds": $OP_TIMEOUT,
  "operation_duration_seconds": $(( $(date +%s) - OP_START )),
  "plist_backup": "${BACKUP_PLIST}" or None,
  "plist_backup_mode": "0600" if "${BACKUP_PLIST}" else None,
  "config_backup": "${BACKUP_CFG}" or None,
  "config_backup_mode": "0600" if "${BACKUP_CFG}" else None,
  "binding_persistence": "on success the NEW binding is kept; it is not reverted by this script",
  "evidence_files": [out + ".precheck.json", out + ".health.json", out + ".postprobe.json"],
}
with open(out, "w", encoding="utf-8") as fh:
    json.dump(receipt, fh, indent=2, ensure_ascii=False)
    fh.write("\n")
print("[r1_rebind] verification: PASS pre=%s post=%s pid %s -> %s" % (
    receipt["pre_check_classification"], receipt["post_probe_classification"],
    receipt["before_pid"], receipt["after_pid"]))
PYEOF
RECEIPT_RC=$?
[ "$RECEIPT_RC" -eq 0 ] || { echo "[r1_rebind] FAILED: could not write the success receipt" >&2; exit 3; }
exit 0
