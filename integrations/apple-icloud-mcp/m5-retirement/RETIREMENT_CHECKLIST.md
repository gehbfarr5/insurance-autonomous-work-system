# M5 Retirement Checklist
<!-- AG-01 | m5-retirement | 2026-11-07 -->
<!-- ALL ITEMS MARKED: RETIREMENT_PENDING_AUTHORIZATION -->
<!-- No retirement action may be taken without explicit human authorization for each item. -->

> [!CAUTION]
> **ALL ITEMS IN THIS CHECKLIST ARE `RETIREMENT_PENDING_AUTHORIZATION`.**
> No action may be taken on any item until the named authorizer explicitly approves it
> in writing (GitHub comment or signed message). This document is a planning artifact only.

---

## Retirement Scope

M5 refers to the previous iCloud integration milestone that is superseded by the MacServer
EventKit Read-Only Candidate (AG-01-B). The retirement scope includes:

- pyicloud-based session handling (replaced by EventKit native)
- Any M5 credential/token rotation requirements
- M5-specific configuration files
- M5 test harness cleanup

---

## Checklist

### Group A — Service Deactivation

| # | Item | Status | Authorizer |
|---|------|--------|-----------|
| A1 | Verify no live traffic is routed to M5 pyicloud session handler | RETIREMENT_PENDING_AUTHORIZATION | Human reviewer |
| A2 | Confirm M5 HTTP bridge process is not running on any machine | RETIREMENT_PENDING_AUTHORIZATION | Human reviewer |
| A3 | Confirm all M5 scheduled jobs / cron tasks are disabled | RETIREMENT_PENDING_AUTHORIZATION | Human reviewer |
| A4 | Verify M5 endpoints return 503/404 (not 200) before credential revocation | RETIREMENT_PENDING_AUTHORIZATION | Human reviewer |

### Group B — Credential Revocation

| # | Item | Status | Authorizer |
|---|------|--------|-----------|
| B1 | Revoke M5 iCloud app-specific password (if used) | RETIREMENT_PENDING_AUTHORIZATION | Account owner |
| B2 | Rotate any shared session tokens issued for M5 | RETIREMENT_PENDING_AUTHORIZATION | Account owner |
| B3 | Confirm no other service shares the M5 credential set | RETIREMENT_PENDING_AUTHORIZATION | Human reviewer |
| B4 | Delete M5 session cookie / token from any keychain entries | RETIREMENT_PENDING_AUTHORIZATION | Account owner |

### Group C — Code and Configuration Cleanup

| # | Item | Status | Authorizer |
|---|------|--------|-----------|
| C1 | Archive or delete M5-specific config files from deployment | RETIREMENT_PENDING_AUTHORIZATION | Human reviewer |
| C2 | Remove M5 pyicloud session handler from active codebase (keep in archive branch) | RETIREMENT_PENDING_AUTHORIZATION | Human reviewer |
| C3 | Confirm no imports of M5 modules remain in active code paths | RETIREMENT_PENDING_AUTHORIZATION | Human reviewer |
| C4 | Update README/docs to remove M5 references | RETIREMENT_PENDING_AUTHORIZATION | Human reviewer |

### Group D — Verification

| # | Item | Status | Authorizer |
|---|------|--------|-----------|
| D1 | Run full test suite after M5 removal; confirm 0 regressions | RETIREMENT_PENDING_AUTHORIZATION | Human reviewer |
| D2 | Verify EventKit candidate (AG-01-B) handles all use cases previously covered by M5 | RETIREMENT_PENDING_AUTHORIZATION | MUSE verifier |
| D3 | Confirm desensitization: no M5 credential remnants in git history (use `git log -S`) | RETIREMENT_PENDING_AUTHORIZATION | Human reviewer |
| D4 | Record retirement completion with SHA of final cleanup commit | RETIREMENT_PENDING_AUTHORIZATION | Human reviewer |

### Group E — Recovery Plan

| # | Item | Status | Description |
|---|------|--------|-------------|
| E1 | Archive M5 code to `archive/m5-pyicloud-YYYYMMDD` branch | RETIREMENT_PENDING_AUTHORIZATION | Preserves code for rollback |
| E2 | Document rollback procedure: re-enable M5 from archive branch | RETIREMENT_PENDING_AUTHORIZATION | Max rollback time: <30min |
| E3 | Confirm rollback has been tested (dry run) before final retirement | RETIREMENT_PENDING_AUTHORIZATION | Human reviewer |

---

## Authorization Gate

This checklist may only be executed after ALL of the following are confirmed:
1. AG-01-B (MacServer EventKit Candidate) has passed MUSE independent verification.
2. AG-01-B is live and handling production traffic successfully for ≥48h.
3. The named authorizer for each Group has provided written approval.

---

*Prepared by AG-01 Engineering Agent | 2026-11-07*  
*All items: RETIREMENT_PENDING_AUTHORIZATION*
