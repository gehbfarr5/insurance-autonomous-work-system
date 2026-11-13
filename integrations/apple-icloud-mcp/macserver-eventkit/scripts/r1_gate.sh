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
#              [--list-id ID] [--canary-id CID] [--require-no-enumeration]
#              [--config-file F] [--endpoint E] [--purpose TEXT]
#              [--lock-wait SECONDS] [--op-timeout SECONDS] [--dry-run]
#
# Operation deadline
# ------------------
# --op-timeout bounds the time this operation spends holding the mutex: it
# starts when the lock is taken, and it is checked before every step that can
# wait - the reload, the settle, each HTTP request - each of which is killed
# together with its children once the budget is gone. --lock-wait bounds the
# waiting for the lock instead; waiting holds nothing.
#
# The deadline exists because the operation reloads while holding the gate
# mutex, and a reload can block. An unbounded open holds the lock past the
# window's open budget, and every restore then fails at the lock instead of
# closing the gate - that is measured, not hypothesised (application v5, test
# scenario 10: the watchdog gave up while the gate was still open, and the gate
# was shut 46 s after the budget by the window's own close).
#
# When the deadline passes: the in-flight command is killed, the one key this
# operation wrote is put back to closed, the observed value is read back and
# recorded, and the operation exits 8 without reloading a second time. Putting
# the key back matters - a disk value of "the gate is open" that no process is
# running is itself a hazard, because the next restart of the service would
# honour it. The lock is released on the way out, which is what lets the
# recovery path take it and close the gate for real.
#
# Only local file writes are not interrupted mid-flight (a plutil -replace, a
# temp-file rename). They wait on nothing, and the check that precedes them
# bounds when they start.
#
# Verification mode
# -----------------
# With --list-id the gate is verified through one bound ID on the item endpoint
# (r1_bridge_client.py probe). probe cannot construct /reminders/lists - the URL
# builder asserts a five-segment item path - so this mode enumerates nothing.
# Without --list-id the legacy enumeration check runs, kept only to replay R1.
# --require-no-enumeration refuses to run without --list-id rather than falling
# back silently.
#
# `--expect` is still accepted for backwards compatibility but is ignored: the
# expected status is derived from the mode and verification always runs.
#
# The evidence directory is validated before anything else happens, because the
# receipt of a failed operation is the only artefact that operation leaves.
#
# Exit codes: 0 verified success, 2 precondition, 3 write/backup/verification
#             failure, 4 reload failure, 5 no authoritative source, 6 evidence
#             directory or lock record unusable, 7 mutex busy or mutex lost,
#             8 operation deadline exceeded (key set back to closed, the
#               in-flight command killed, no second reload).

set -uo pipefail

MODE="${1:-}"; shift || true
[ "$MODE" = "open" ] || [ "$MODE" = "close" ] || { echo "usage: r1_gate.sh open|close ..." >&2; exit 2; }

PLIST=""; CONFIG_FILE=""; TOKEN_FILE=""; ENDPOINT="http://127.0.0.1:18765"; OUT=""
DRY=0; PURPOSE="unspecified"; LOCK_WAIT=20
# Default: comfortably longer than a normal open (R1 measured ~8 s) and shorter
# than the recovery's own lock budget (--lock-wait 15 x 3 attempts = 45 s), so a
# stalled open always ends before the restore that has to follow it gives up.
OP_TIMEOUT="${R1_OP_TIMEOUT:-30}"
LIST_ID=""; CANARY_ID=""; NO_ENUM=0
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
    --op-timeout) OP_TIMEOUT="$2"; shift 2 ;;
    --list-id) LIST_ID="$2"; shift 2 ;;
    --canary-id) CANARY_ID="$2"; shift 2 ;;
    --require-no-enumeration) NO_ENUM=1; shift ;;
    --dry-run) DRY=1; shift ;;
    --expect) shift 2 ;;   # deprecated: verification is unconditional
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

[ -n "$PLIST" ] || { echo "PRECONDITION: --plist required" >&2; exit 2; }
[ "$DRY" -eq 1 ] || [ -n "$OUT" ] || { echo "PRECONDITION: --out required" >&2; exit 2; }
# The deadline is the only thing that keeps this operation from holding the
# mutex indefinitely, so a malformed value is refused rather than coerced into
# something that looks like it works.
case "$OP_TIMEOUT" in
  ''|*[!0-9]*) echo "PRECONDITION: --op-timeout must be a whole number of seconds" >&2; exit 2 ;;
esac
[ "$OP_TIMEOUT" -ge 1 ] || { echo "PRECONDITION: --op-timeout must be at least 1" >&2; exit 2; }
case "$LOCK_WAIT" in
  ''|*[!0-9]*) echo "PRECONDITION: --lock-wait must be a whole number of seconds" >&2; exit 2 ;;
esac

# Two verification modes. `probe` reads one bound ID through the item endpoint
# and cannot construct the enumeration URL at all; the legacy mode asserts the
# enumeration endpoint's status and is kept only so the R1 window can still be
# replayed. Any window that must not enumerate passes --require-no-enumeration
# and is refused here rather than silently falling back.
if [ -n "$LIST_ID" ]; then
  VERIFY_MODE="probe"
elif [ "$NO_ENUM" -eq 1 ]; then
  echo "PRECONDITION: --require-no-enumeration needs --list-id (the legacy verification enumerates)" >&2
  exit 2
else
  VERIFY_MODE="legacy_enumeration"
fi

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

echo "[r1_gate] mode=$MODE source=$SOURCE current=${EFFECTIVE:-unknown} reload=$RELOAD verify=$VERIFY_MODE purpose=$PURPOSE"

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

# --- 2. evidence directory ---------------------------------------------------
# A failed gate operation leaves exactly one artefact: the receipt. So the
# ability to write it must be proven *before* anything production-facing
# happens; otherwise a close can reload the service and then die without a
# record of what it did. The emergency path is where this bites, because it is
# typed by hand, possibly with an --out under a directory nobody created yet.
if [ "$DRY" -eq 0 ]; then
  OUT_DIR="$(dirname "$OUT")"
  if [ ! -d "$OUT_DIR" ]; then
    echo "[r1_gate] FAILED: evidence directory does not exist: $OUT_DIR" >&2
    echo "[r1_gate] create it first (mkdir -p -m 700) or point --out at an existing 0700 directory; nothing was changed" >&2
    exit 6
  fi
  if ! : > "$OUT_DIR/.r1-gate-probe.$$" 2>/dev/null; then
    echo "[r1_gate] FAILED: evidence directory is not writable: $OUT_DIR; nothing was changed" >&2
    exit 6
  fi
  rm -f "$OUT_DIR/.r1-gate-probe.$$" 2>/dev/null || true
fi

BACKUP=""; CFG_BACKUP=""; DISK_WRITTEN=0

emit_failure_receipt() {
  local stage="$1" rc="$2"
  [ -n "$OUT" ] || return 0
  R1_OUT="$OUT" R1_MODE="$MODE" R1_SOURCE="$SOURCE" R1_RELOAD="$RELOAD" \
  R1_WANT="$WANT" R1_STAGE="$stage" R1_RC="$rc" \
  R1_BEFORE="${BEFORE_PID:-}" R1_AFTER="${AFTER_PID:-}" R1_CFG="$CONFIG_FILE" \
  R1_PLIST="$PLIST" R1_BACKUP="${BACKUP:-}" R1_PURPOSE="$PURPOSE" \
  R1_CFG_BACKUP="${CFG_BACKUP:-}" R1_DISK_WRITTEN="$DISK_WRITTEN" \
  R1_ROLLED_BACK="${ROLLED_BACK:-0}" R1_OP_TIMEOUT="${OP_TIMEOUT:-0}" \
  R1_RELOAD_KILLED="${RELOAD_KILLED:-0}" R1_DEADLINE_PHASE="${DEADLINE_PHASE:-}" \
  R1_VALUE_BEFORE="${EFFECTIVE:-}" R1_VALUE_AFTER="${GATE_KEY_AFTER:-}" \
  "$PYTHON" - <<'PYEOF' || echo "[r1_gate] WARNING: could not write the failure receipt to $OUT" >&2
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
  "disk_written_before_failure": env.get("R1_DISK_WRITTEN") == "1",
  # An operation that ran out of time must say what it left behind: which step
  # it was in, whether the in-flight command was killed, which value the key had
  # before, which value the file holds now (read back, not assumed), and whether
  # a reload is still pending anywhere in this process (it is not).
  "operation_timeout_seconds": int(env.get("R1_OP_TIMEOUT") or 0),
  "deadline_phase": env.get("R1_DEADLINE_PHASE") or None,
  "reload_killed": env.get("R1_RELOAD_KILLED") == "1",
  "gate_key_before_operation": env.get("R1_VALUE_BEFORE") or None,
  "gate_key_after_deadline": env.get("R1_VALUE_AFTER") or None,
  "gate_key_left_closed": (env.get("R1_ROLLED_BACK") == "1"
                           and env.get("R1_VALUE_AFTER") == "false"),
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
print("[r1_gate] FAILURE RECEIPT written: stage=%s rc=%s key_left_closed=%s"
      % (env["R1_STAGE"], env["R1_RC"], receipt["gate_key_left_closed"]))
PYEOF
}

# --- 3. shared mutex ---------------------------------------------------------
# Callers must not race: two overlapping restores would interleave a write with
# a reload and could leave the process running an older value than the disk.
#
# The lock is a symlink whose target names an owner record that is written
# *before* the link is published. `ln -s` fails if the name exists, so
# publication is a single atomic step and the name never exists without its
# owner. This is exactly what the previous mkdir-then-write version got wrong: a
# second process could read the still-empty owner file of a lock that was being
# initialised, conclude "no live owner", rename the lock away, and then both
# processes were in the critical section at once.
#
# Staleness is decided by two independent rules:
#   * a lock whose owner is alive (same pid *and* same start time) is never
#     reclaimed, whatever its age;
#   * a lock without a readable owner is not called stale until it is older than
#     R1_LOCK_INIT_GRACE_SECONDS (default 10). "Owner has not published yet" and
#     "owner died before publishing" look identical, so the first case has to be
#     given time to finish instead of being taken.
#
# The lock is never taken by force. If it cannot be taken within the bound, the
# operation fails with evidence instead of proceeding.
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

# Where the owner record of the *currently published* lock lives, if anywhere.
owner_record_path() {
  REC=""
  if [ -L "$LOCK" ]; then
    REC="$LOCK_ROOT/$(readlink "$LOCK" 2>/dev/null)"
  elif [ -d "$LOCK" ]; then
    REC="$LOCK/owner.env"     # legacy layout from an older harness; still read
  fi
}

# Is the recorded owner still running? `kill -0` is the primary check because it
# cannot be faked by a pid that merely looks familiar; the recorded start time
# then rules out pid reuse. EPERM means "exists, but not mine to signal", which
# is a live owner too.
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

# Read the published lock without changing anything. Fields are left empty when
# there is no owner record, which is the "initialising" case, not "stale".
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

# Rename first, then look at what was actually taken. Two reclaimers cannot both
# win the rename, and a reclaimer that grabbed a *newer* holder's link - one
# published between our read and our rename - puts it back instead of deleting
# it. The artifact is never deleted when it turns out not to be the one we
# judged, so a live holder cannot lose its lock to a stale-lock cleanup.
reclaim_lock() {
  local stale="$LOCK_ROOT/.gate.lock.stale.$$" got=""
  rm -rf "$stale" 2>/dev/null || true
  mv "$LOCK" "$stale" 2>/dev/null || return 1
  [ -L "$stale" ] && got="$(readlink "$stale" 2>/dev/null)"
  if [ "$LK_KIND" = "symlink" ] && [ "$got" != "$LK_TARGET" ]; then
    if [ ! -e "$LOCK" ] && [ ! -L "$LOCK" ] && mv "$stale" "$LOCK" 2>/dev/null; then
      echo "[r1_gate] reclaim aborted: a newer holder published while we were inspecting; its lock was restored untouched" >&2
    else
      echo "[r1_gate] WARNING: reclaimed artifact $stale differs from the observed owner and could not be restored; it was kept, not deleted" >&2
    fi
    return 1
  fi
  rm -rf "$stale" 2>/dev/null || true
  echo "[r1_gate] reclaimed a stale lock (kind=$LK_KIND owner_pid=${LK_PID:-unpublished} age=${LK_AGE}s)"
  return 0
}

# Write the owner record first, then publish the name atomically. Returns
# non-zero only when the name is already taken; an unwritable owner record is
# reported separately by the caller as an IO failure, not as contention.
publish_lock() {
  local name="$$.$(date +%s).${RANDOM}${RANDOM}.env" rec
  rec="$OWNERS/$name"
  ( umask 077; {
      echo "LOCK_PID=$$"
      echo "LOCK_LSTART=$(lstart_of $$)"
      echo "LOCK_UID=$UID"
      echo "LOCK_PURPOSE=$PURPOSE"
      echo "LOCK_MODE=$MODE"
      echo "LOCK_ACQUIRED=$(date +%s)"
    } > "$rec" ) 2>/dev/null || { rm -f "$rec" 2>/dev/null; return 2; }
  chmod 600 "$rec" 2>/dev/null || true
  LOCK_TOKEN="owners/$name"
  # Test-only pause, placed after the record exists and before the name is
  # published: it reproduces the reported race (a lock that is "there" but has no
  # visible owner) without this implementation ever being able to reach that
  # state. Inert unless an isolated test sets it.
  if [ -n "${R1_TEST_LOCK_PAUSE_BEFORE_PUBLISH:-}" ]; then
    : > "${R1_TEST_LOCK_PAUSE_MARKER:-/dev/null}" 2>/dev/null || true
    sleep "${R1_TEST_LOCK_PAUSE_BEFORE_PUBLISH}"
  fi
  # `ln -s TARGET EXISTING_DIR` creates the link *inside* the directory instead
  # of failing, so a legacy lock directory would silently absorb our link and we
  # would keep retrying while never owning the name. Refuse explicitly; the
  # check is not the atomicity guarantee (confirm_lock is), it just keeps the
  # common case honest.
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
  # Only the owner removes it: if the name now points elsewhere, another process
  # holds the lock and deleting it would hand out a second ownership.
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
      # The name was taken between publication and confirmation. We are not the
      # holder, so we must not enter the critical section: drop the record and
      # go back to waiting.
      if [ -d "$LOCK" ] && [ ! -L "$LOCK" ] && [ -L "$LOCK/$(basename "$LOCK_TOKEN")" ]; then
        rm -f "$LOCK/$(basename "$LOCK_TOKEN")" 2>/dev/null || true   # stray link inside a legacy dir
      fi
      rm -f "$OWNERS/$(basename "$LOCK_TOKEN")" 2>/dev/null || true
      LOCK_TOKEN=""
      echo "[r1_gate] lost the lock right after publishing it; waiting again" >&2
    elif [ "$prc" -eq 2 ]; then
      echo "[r1_gate] FAILED: cannot write the lock owner record in $OWNERS" >&2
      return 2
    else
      inspect_lock
      if [ "$LK_KIND" = "missing" ]; then
        sleep 0.2
        continue
      fi
      if [ "$LK_KIND" = "symlink" ] || [ "$LK_KIND" = "dir" ]; then
        if owner_alive "$LK_PID" "$LK_LSTART"; then
          :                                  # a live owner: wait, never force
        elif [ -n "$LK_PID" ]; then
          if reclaim_lock; then continue; fi
        elif [ "$LK_AGE" -lt "$LOCK_INIT_GRACE" ]; then
          :   # no owner published yet: still initialising, so wait, never take it
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
  HOLDER_PID="$(owner_field LOCK_PID "$REC")"
  HOLDER_PURPOSE="$(owner_field LOCK_PURPOSE "$REC")"
  echo "[r1_gate] FAILED: could not take the gate mutex within ${LOCK_WAIT}s (holder pid=${HOLDER_PID:-none} purpose=${HOLDER_PURPOSE:-none} state=${LK_KIND}/age=${LK_AGE}s); not forcing it" >&2
  R1_MODE_FOR_LOCK="$MODE" R1_STAGE=lock R1_RC=7 \
  R1_LOCKHOLDER="${HOLDER_PID:-none}/${HOLDER_PURPOSE:-none}" R1_LOCK_KIND="$LK_KIND" \
  "$PYTHON" - "$OUT" <<'PYEOF' || echo "[r1_gate] WARNING: could not write the busy-lock receipt" >&2
import json, os, sys
receipt = {
  "receipt_type": "R1_GATE_OPERATION",
  "mode": os.environ.get("R1_MODE_FOR_LOCK", "unknown"),
  "verification": "FAIL",
  "failure_stage": "lock",
  "failure_exit_code": 7,
  "disk_written_before_failure": False,
  "lock_holder": os.environ.get("R1_LOCKHOLDER"),
  "lock_state": os.environ.get("R1_LOCK_KIND"),
  "note": "Another gate operation held the mutex. This operation did not write or reload anything.",
}
with open(sys.argv[1], "w", encoding="utf-8") as fh:
    json.dump(receipt, fh, indent=2, ensure_ascii=False)
    fh.write("\n")
PYEOF
  [ "$LOCK_RC" -eq 2 ] && exit 6
  exit 7
fi

# --- 3b. the operation's clock ----------------------------------------------
# The clock starts here, not at the top of the script: --lock-wait already
# bounds the waiting, and waiting holds no mutex. What has to be bounded is the
# time spent *holding* it, because that is the time a restore cannot get in.
OP_START="$(date +%s)"
# State that a deadline exit has to report. Declared up front so the receipt
# writer never has to guess whether a variable exists.
DEADLINE_KILLED=0; ROLLED_BACK=0; RELOAD_KILLED=0; DEADLINE_PHASE=""; GATE_KEY_AFTER=""

op_remaining() {
  local used left
  used=$(( $(date +%s) - OP_START ))
  left=$(( OP_TIMEOUT - used ))
  [ "$left" -lt 0 ] && left=0
  printf '%s' "$left"
}

# Kill a process and everything it started. The reload can be a wrapper script
# that sleeps in a child process, so killing only the parent would leave the
# child running - the operation would be "stopped" while its work carried on,
# which is exactly the difference this change is about.
#
# The walk is defensive on purpose: the child list comes from an external
# command, and an implementation that trusts it can recurse on a pid reported as
# its own child until the process dies of it. Anything that is not a plain
# number, a repeat of the caller, or nested deeper than any real wrapper is
# dropped instead of followed.
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

# Run one external command with at most `limit` seconds. Returns the command's
# own status, or 124 when the deadline arrived first - the sentinel `timeout(1)`
# uses, so the convention is not new. Sets DEADLINE_KILLED, which the caller
# turns into a receipt and an exit, never into a silent continuation.
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

# Read the authoritative source, not the value this process last intended. Every
# claim about "the key is closed now" is made from this, never from $WANT.
read_source_value() {
  if [ "$SOURCE" = "launchd_env" ]; then
    "$PLUTIL" -extract EnvironmentVariables.EVENTKIT_BRIDGE_PRODUCTION_AUTHORIZED raw "$PLIST" 2>/dev/null
  elif [ "$SOURCE" = "config_file" ]; then
    awk -F= '/^[[:space:]]*EVENTKIT_BRIDGE_PRODUCTION_AUTHORIZED[[:space:]]*=/{v=$2; gsub(/[[:space:]"]/,"",v); print v; exit}' "$CONFIG_FILE" 2>/dev/null
  fi
}

# --- 4. back up the authoritative source before touching it ------------------
# Both files may contain the bearer token, so neither backup may be readable by
# others and neither sits next to the original.
backup_source() {
  local src="$1" suffix="$2"
  BACKUP="$OUT.$suffix"
  cp -p "$src" "$BACKUP" 2>/dev/null && chmod 600 "$BACKUP" 2>/dev/null
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
  if ! cp -p "$CONFIG_FILE" "$OUT.config-backup" 2>/dev/null || ! chmod 600 "$OUT.config-backup" 2>/dev/null; then
    echo "[r1_gate] FAILED: could not create a 0600 backup of the config file; refusing to edit it" >&2
    emit_failure_receipt backup 3
    exit 3
  fi
  CFG_BACKUP="$OUT.config-backup"
  echo "[r1_gate] config file backed up to a 0600 file; only the gate key will change"
fi

# --- 5. write exactly the authoritative source, atomically -------------------
set_config_gate() {   # $1 = the value to write into the one gate key
  [ -n "$CONFIG_FILE" ] && [ -f "$CONFIG_FILE" ] || return 7
  # Write a sibling temp file with the original mode, then rename: a reader
  # (including the next process) never sees a half-written config, and the
  # single-key scope is enforced by the regex below.
  "$PYTHON" - "$CONFIG_FILE" "$1" <<'PYEOF'
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

# The one writer. Both the requested write and the deadline rollback go through
# it, so "put the key back" cannot end up being a different, weaker edit than
# "set the key" - the same single key, the same file, the same atomic rename.
write_gate_value() {   # $1 = value
  if [ "$SOURCE" = "launchd_env" ]; then
    "$PLUTIL" -replace EnvironmentVariables.EVENTKIT_BRIDGE_PRODUCTION_AUTHORIZED -string "$1" "$PLIST"
  elif [ "$SOURCE" = "config_file" ]; then
    set_config_gate "$1"
  else
    return 1
  fi
}

# The only way out when the clock runs out. It cannot reload: every reload site
# sits after an op_guard(), and this function exits. It does write, exactly once
# and only to `false`, because the operation that just failed must not leave the
# disk saying "open" for the next restart of the service to honour.
deadline_exit() {   # $1 = the step that ran out of time
  DEADLINE_PHASE="$1"
  RELOAD_KILLED="$DEADLINE_KILLED"
  echo "[r1_gate] DEADLINE EXCEEDED in $1: ${OP_TIMEOUT}s budget gone; this operation stops here" >&2
  if [ "$DEADLINE_KILLED" -eq 1 ]; then
    echo "[r1_gate] the in-flight command was killed together with its children; this process will not reload again" >&2
  fi
  if [ "$DISK_WRITTEN" -eq 1 ]; then
    if write_gate_value "false"; then
      ROLLED_BACK=1
      echo "[r1_gate] the gate key was put back to false (no reload: this process is done)" >&2
    else
      echo "[r1_gate] CRITICAL: could not put the gate key back to false; the disk may still say open" >&2
    fi
  fi
  GATE_KEY_AFTER="$(read_source_value)"
  echo "[r1_gate] key read back after the deadline: ${GATE_KEY_AFTER:-unreadable} (was ${EFFECTIVE:-undefined} before this operation)" >&2
  emit_failure_receipt op_timeout 8
  exit 8
}

# Checked before every step that can wait. A step that starts after the deadline
# would be a step the deadline does not bound.
op_guard() {
  if [ "$(op_remaining)" -le 0 ]; then deadline_exit "$1"; fi
  return 0
}

WRITE_RC=0
# Both production-facing steps are gated on still owning the mutex. A lock that
# was stolen or reclaimed while we were working cannot lead to a write or a
# reload from this process: if it does, two processes are editing the same
# source and the last writer wins silently.
if ! assert_lock_owned; then
  echo "[r1_gate] FAILED: this process no longer owns the gate mutex; refusing to write the gate source" >&2
  emit_failure_receipt lock_lost 7
  exit 7
fi
op_guard write
if [ "$SOURCE" = "absent" ]; then
  # absent + close: nothing to write, only the endpoint has to be proven closed.
  echo "[r1_gate] no authoritative source defines the gate; nothing to rewrite (close verifies only)"
else
  write_gate_value "$WANT" || WRITE_RC=$?
fi
if [ "$WRITE_RC" -ne 0 ]; then
  echo "[r1_gate] FAILED: writing the gate source returned $WRITE_RC" >&2
  emit_failure_receipt write "$WRITE_RC"
  exit 3
fi
[ "$SOURCE" = "absent" ] || DISK_WRITTEN=1

# --- 6. reload so a new process re-reads it ---------------------------------
if ! assert_lock_owned; then
  echo "[r1_gate] FAILED: this process no longer owns the gate mutex; the source was written but it will not be reloaded here" >&2
  emit_failure_receipt lock_lost 7
  exit 7
fi
BEFORE_PID="$(pgrep -x EventKitBridgeServer 2>/dev/null | head -1 || true)"
RELOAD_RC=0
# Every launchctl call below is bounded by what is left of the operation's
# clock, and a 124 from run_bounded leaves through deadline_exit - which cannot
# come back here, so no second reload is possible from this process.
if [ "$SOURCE" = "launchd_env" ]; then
  op_guard reload
  BOOTOUT_RC=0
  run_bounded "$(op_remaining)" "$LAUNCHCTL" bootout "gui/$(id -u)/$LABEL" 2>/dev/null || BOOTOUT_RC=$?
  [ "$BOOTOUT_RC" -eq 124 ] && deadline_exit reload
  if [ "$BOOTOUT_RC" -ne 0 ]; then
    # bootout fails when the job is not loaded; that is only acceptable if the
    # job really is not loaded. Anything else is a main-path error and must not
    # be swallowed before bootstrap.
    PRINT_RC=0
    run_bounded "$(op_remaining)" "$LAUNCHCTL" print "gui/$(id -u)/$LABEL" >/dev/null 2>&1 || PRINT_RC=$?
    [ "$PRINT_RC" -eq 124 ] && deadline_exit reload
    if [ "$PRINT_RC" -eq 0 ]; then
      echo "[r1_gate] FAILED: bootout returned $BOOTOUT_RC but the job is still loaded" >&2
      emit_failure_receipt bootout "$BOOTOUT_RC"
      exit 4
    fi
    echo "[r1_gate] bootout reported $BOOTOUT_RC and the job is not loaded; continuing"
  fi
  SETTLE_STOP=0
  run_bounded "$(op_remaining)" sleep 1 || SETTLE_STOP=$?
  [ "$SETTLE_STOP" -eq 124 ] && deadline_exit reload
  run_bounded "$(op_remaining)" "$LAUNCHCTL" bootstrap "gui/$(id -u)" "$PLIST" || RELOAD_RC=$?
  [ "$RELOAD_RC" -eq 124 ] && deadline_exit reload
elif [ "$SOURCE" = "config_file" ]; then
  op_guard reload
  run_bounded "$(op_remaining)" "$LAUNCHCTL" kickstart -k "gui/$(id -u)/$LABEL" || RELOAD_RC=$?
  [ "$RELOAD_RC" -eq 124 ] && deadline_exit reload
fi
if [ "$RELOAD_RC" -ne 0 ]; then
  echo "[r1_gate] FAILED: reload returned $RELOAD_RC" >&2
  AFTER_PID="$(pgrep -x EventKitBridgeServer 2>/dev/null | head -1 || true)"
  emit_failure_receipt reload "$RELOAD_RC"
  exit 4
fi

# --- 7. verify by behaviour and by process identity (always) ----------------
# Verification is inside the same clock: it holds the mutex too, and a probe
# that never returns would keep a restore out exactly like a stuck reload. If
# the clock runs out here the key is still put back - an operation that could
# not verify has not been shown to have happened.
SETTLE_RC=0
run_bounded "$(op_remaining)" sleep "${R1_SETTLE_SECONDS:-3}" || SETTLE_RC=$?
[ "$SETTLE_RC" -eq 124 ] && deadline_exit verify
AFTER_PID="$(pgrep -x EventKitBridgeServer 2>/dev/null | head -1 || true)"
VERIFY_RC=0
HEALTH_JSON="$OUT.health.json"
run_bounded "$(op_remaining)" "$PYTHON" "$CLIENT" health --endpoint "$ENDPOINT" --out "$HEALTH_JSON" >/dev/null 2>&1 || VERIFY_RC=$?
[ "$VERIFY_RC" -eq 124 ] && deadline_exit verify

GATE_JSON="$OUT.gate.json"
PROBE_JSON="$OUT.probe.json"
if [ "$VERIFY_RC" -eq 0 ]; then
  if [ "$VERIFY_MODE" = "probe" ]; then
    # close -> the bound ID must now be refused by the store guard.
    # open  -> any outcome that is only reachable PAST the guard proves the
    #          window is open. The observed label is kept in the receipt, so an
    #          anomalous label stays visible instead of being averaged away.
    if [ "$MODE" = "close" ]; then
      PROBE_EXPECT="GATE_RESTORED_CLOSED"
    else
      PROBE_EXPECT="NOT_RESOLVABLE,RESOLVED_SOURCE_IDENTITY_CHANGED"
      PROBE_EXPECT="$PROBE_EXPECT,RESOLVED_IDENTITY_MATCH_EMPTY,RESOLVED_WITH_ITEMS"
      PROBE_EXPECT="$PROBE_EXPECT,ANOMALOUS_SOURCE_NOT_ALLOWED,BLOCKED_TIMEOUT"
    fi
    PROBE_ARGS=(--endpoint "$ENDPOINT" --token-file "$TOKEN_FILE"
                --list-id "$LIST_ID" --phase "$([ "$MODE" = "close" ] && echo post || echo open)"
                --expect "$PROBE_EXPECT" --out "$PROBE_JSON")
    [ -n "$CANARY_ID" ] && PROBE_ARGS+=(--canary-id "$CANARY_ID")
    run_bounded "$(op_remaining)" "$PYTHON" "$CLIENT" probe "${PROBE_ARGS[@]}" >/dev/null 2>&1 || VERIFY_RC=$?
  else
    run_bounded "$(op_remaining)" "$PYTHON" "$CLIENT" gate --endpoint "$ENDPOINT" \
      --token-file "$TOKEN_FILE" --expect "$EXPECT_CODE" --out "$GATE_JSON" >/dev/null 2>&1 || VERIFY_RC=$?
  fi
  [ "$VERIFY_RC" -eq 124 ] && deadline_exit verify
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
probe = load(out + ".probe.json")
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
  "verification_mode": "$VERIFY_MODE",
  "verification": "PASS" if ("$VERIFY_RC" == "0") else "FAIL",
  "verification_basis": "http behaviour after reload + process identity; never the file value",
  # How long this operation was allowed to hold the mutex, and how long it took.
  # A reader can check the second against the first instead of trusting a claim.
  "operation_timeout_seconds": $OP_TIMEOUT,
  "operation_duration_seconds": $(( $(date +%s) - OP_START )),
  "plist_backup": "${BACKUP}" or None,
  "plist_backup_mode": "0600" if "${BACKUP}" else None,
  "config_backup": "${CFG_BACKUP}" or None,
  "config_backup_mode": "0600" if "${CFG_BACKUP}" else None,
  "evidence_files": [out + ".health.json",
                     out + (".probe.json" if "$VERIFY_MODE" == "probe" else ".gate.json")],
}
if "$VERIFY_MODE" == "probe":
  receipt.update({
    "probe_phase": probe.get("phase"),
    "probe_classification": probe.get("classification"),
    "probe_http_status": (probe.get("target") or {}).get("http_status"),
    "probe_error_code": (probe.get("target") or {}).get("error_code"),
    "probe_item_count": (probe.get("target") or {}).get("item_count"),
    "probe_enumeration_calls": (probe.get("boundary") or {}).get("list_enumerations_called"),
  })
else:
  receipt.update({
    "gate_http_status": gate.get("http_status"),
    "gate_expected_status": gate.get("expected_status"),
    "gate_classification": gate.get("classification"),
  })
with open(out, "w", encoding="utf-8") as fh:
    json.dump(receipt, fh, indent=2, ensure_ascii=False)
    fh.write("\n")
observed = receipt.get("probe_classification") or receipt.get("gate_classification")
print("[r1_gate] verification: %s mode=%s observed=%s health=%s pid %s -> %s" % (
    receipt["verification"], receipt["verification_mode"], observed,
    receipt["health_store"], receipt["before_pid"], receipt["after_pid"]))
sys.exit(0 if receipt["verification"] == "PASS" else 1)
PYEOF
RECEIPT_RC=$?

# Verification is not optional: a caller can no longer get exit 0 without it.
[ "$RECEIPT_RC" -eq 0 ] || exit 3
exit 0
