# M5 Pro A4 Experimental Resource Retirement Checklist
<!-- AG-01 | m5-retirement | 2026-11-07 -->
<!-- SCOPE STRICTLY CONFINED TO M5 PRO A4 EXPERIMENTAL ARTIFACTS -->
<!-- ALL ACTIONS MARKED: RETIREMENT_PENDING_AUTHORIZATION -->

> [!CAUTION]
> **GOVERNANCE BOUNDARY**:
> 1. Retirement scope is strictly limited to **M5 Pro A4 experimental artifacts** (local experimental bridge processes, local launchd test plists, test sockets, local debug logs).
> 2. **DO NOT** deprecate or remove the Linux PyiCloud mainline candidate. PyiCloud remains the primary candidate route once verified.
> 3. **DO NOT** rotate or revoke shared production credentials, Tailscale keys, or Apple IDs without explicit dependent evidence.
> 4. Resources not directly verified on M5 Pro are classified as `RESOURCE_STATUS_UNKNOWN`.
> 5. All retirement operations require explicit prior human authorization (`RETIREMENT_PENDING_AUTHORIZATION`).

---

## 1. Targeted Scope: M5 Pro A4 Experimental Resources Only

| Resource Category | Description | Scope Boundary | Unverified Status |
|-------------------|-------------|----------------|-------------------|
| M5 Local Bridge Process | Experimental HTTP bridge on local loopback | M5 Pro host only | `RESOURCE_STATUS_UNKNOWN` (not scanned) |
| M5 LaunchAgent Plist | Local user LaunchAgent for A4 experiment | `~/Library/LaunchAgents/` on M5 Pro | `RESOURCE_STATUS_UNKNOWN` (not scanned) |
| Local Build Artifacts | Swift build caches and debug logs | Isolated scratch workspace only | Verified in scratch workspace |
| Tailscale M5 Test ACLs | Any experimental direct route to M5 Pro | Shared network layer | **OUT OF SCOPE** (managed upstream) |
| PyiCloud Mainline | Linux PyiCloud candidate | **PROTECTED / PRESERVED** | Not subject to M5 retirement |
| Shared Apple Credentials | Production Apple ID and CardDAV keys | **PROTECTED / PRESERVED** | No unverified rotation |

---

## 2. Granular Checklist (Execution Gated)

### Group A — M5 Pro Experimental Listener & Process Check

| # | Item | Status | Verification Method | Action (Upon Approval) |
|---|------|--------|---------------------|------------------------|
| A1 | Check if experimental A4 bridge listener is active on M5 Pro | `RETIREMENT_PENDING_AUTHORIZATION` | `lsof -nP -iTCP:18765` on M5 Pro | Graceful SIGTERM; no wild kill |
| A2 | Check for resident launchd plist `com.muse.m5-bridge` on M5 Pro | `RETIREMENT_PENDING_AUTHORIZATION` | `launchctl list | grep muse` | `launchctl bootout` if present |
| A3 | Check local crontab or automated test hooks on M5 Pro | `RETIREMENT_PENDING_AUTHORIZATION` | `crontab -l` inspection | Pause experimental cron |

### Group B — Experimental Workspace & State Archival

| # | Item | Status | Verification Method | Action (Upon Approval) |
|---|------|--------|---------------------|------------------------|
| B1 | Snapshot M5 Pro experimental configuration and notes | `RETIREMENT_PENDING_AUTHORIZATION` | Tarball local config into secure archive | Preserve rollback tarball |
| B2 | Archive experimental branch state if divergent from main | `RETIREMENT_PENDING_AUTHORIZATION` | `git status` check | Tag as `archive/m5-experiment-20261107` |
| B3 | Confirm no active MUSE production traffic targets M5 Pro | `RETIREMENT_PENDING_AUTHORIZATION` | Audit Seoul gateway routing config | Verify Seoul points to MacServer |

### Group C — Dependency & Protection Enforcement

| # | Item | Status | Governance Rule |
|---|------|--------|-----------------|
| C1 | Preserve PyiCloud Linux mainline without alteration | `PRESERVED_MAINLINE` | PyiCloud remains primary candidate |
| C2 | Prohibit shared credential / Apple ID rotation | `PROHIBITED_WITHOUT_EVIDENCE` | No shared credential changes permitted |
| C3 | Prohibit deletion of shared network configurations | `PRESERVED_SHARED` | Tailscale Funnel / Seoul routing unchanged |

### Group D — Post-Retirement Regression Verification

| # | Item | Status | Acceptance Gate |
|---|------|--------|-----------------|
| D1 | Verify MacServer EventKit candidate operates independently | `PENDING_GATE_B` | Full isolation test passes on MacServer |
| D2 | Verify M5 Pro can be safely rebooted without service impact | `RETIREMENT_PENDING_AUTHORIZATION` | Host independence confirmed |
| D3 | Confirm zero broken dependencies in Seoul MCP configuration | `PENDING_GATE_B` | Health check returns 200 via Seoul |

---

## 3. Rollback & Recovery Procedure

If Seoul MCP requires fallback to M5 Pro A4 development bridge during staging:
1. Reload archived LaunchAgent on M5 Pro:  
   `launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.muse.m5-bridge.plist`
2. Validate local loopback health:  
   `curl -s http://127.0.0.1:18765/health`
3. Recovery SLA: < 15 minutes.
