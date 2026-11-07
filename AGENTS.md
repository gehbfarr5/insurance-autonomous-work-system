# AGENTS.md — Agent Operation Charter
<!-- AG-01 | insurance-autonomous-work-system | Created: 2026-11-07 -->

This file defines the operational rules, permission boundaries, and conventions for all AI agents
operating in this repository. Every agent MUST read and comply with this charter before taking any
action.

---

## 1. Permission Boundaries

### 1.1 Permitted Actions
- Read any file in the repository.
- Create new files and branches in accordance with the branch naming convention (§4).
- Modify code within the agent's assigned scope (as specified in the task issue or message).
- Run `swift build`, `swift test`, `python3 -m pytest` in designated integration directories.
- Create GitHub PRs from feature/reconcile branches to `main`.
- Push to `origin` on branches matching the naming convention.

### 1.2 Explicitly Prohibited Actions
- **NO** direct commits or pushes to `main` or `origin/main`.
- **NO** access to production Apple ID, iCloud credentials, tokens, cookies, or CalDAV/CardDAV sessions.
- **NO** calls to live Apple APIs (iCloud, CalDAV, CardDAV, iCloud Drive) during automated runs.
- **NO** storing, logging, or transmitting real user data, PII, or authentication secrets.
- **NO** activating `ProductionEventKitStore` without explicit human authorization (TCC gate).
- **NO** write operations to any real calendar, reminder list, or contact store.
- **NO** re-implementation of SOURCE_MISSING components without explicit written authorization.
- **NO** merging PRs without human review and approval.
- **NO** modifying this `AGENTS.md` file without a separate PR with human approval.

### 1.3 Conditional Actions (Require Authorization)
The following require explicit authorization documented in the task or PR:
- Activating M5 retirement steps (see `m5-retirement/RETIREMENT_CHECKLIST.md`).
- Enabling production EventKit TCC requests.
- Implementing SOURCE_MISSING components (Calendar ETag, MUSE SafeWriteManager).

---

## 2. Desensitization (Redaction) Requirements

All agent-generated output MUST comply with the following:

| Data Type | Required Treatment |
|-----------|-------------------|
| Apple ID / iCloud email | Never log, hardcode, or echo. Use `<APPLE_ID>` placeholder. |
| Auth tokens / cookies | Never include in code, logs, or docs. Use `<TOKEN>` placeholder. |
| CalDAV/CardDAV URLs with account path | Redact account segment. Use `<ACCOUNT>` placeholder. |
| Real reminder/calendar content | Never log content fields. Metadata (list name, ID) only. |
| Real contact PII | Never log. Use synthetic test data only in tests. |
| File paths with username | Use `<HOME>` placeholder in public docs. |

Build evidence files (`BUILD_EVIDENCE.md`, `PYTHON_TEST_EVIDENCE.md`) MUST NOT contain any of the
above. Command output may include Swift compiler diagnostics and test pass/fail results only.

---

## 3. Branch Naming Convention

```
<type>/<scope>-<description>-[YYYYMMDD]
```

| Type | Usage |
|------|-------|
| `feat/` | New capability or implementation |
| `fix/` | Bug fix |
| `docs/` | Documentation only |
| `reconcile/` | Source reconciliation / audit work |
| `test/` | Test-only changes |
| `chore/` | Maintenance, dependency updates |
| `audit/` | Audit snapshots (read-only, no production data) |

**Examples**:
- `feat/macserver-eventkit-readonly`
- `reconcile/icloud-source-baseline`
- `fix/allowlist-exact-match-20261107`

**Rules**:
- Branch names must be lowercase with hyphens only (no underscores, no spaces).
- Date suffix `YYYYMMDD` is required for `reconcile/` and `audit/` branches.
- Agents must not reuse branch names; append date if collision occurs.

---

## 4. PR Merge Conditions

A PR created by an agent may only be merged by a human reviewer when ALL of the following are met:

1. **Build passes**: `swift build` exits with code 0 (for Swift packages).
2. **Tests pass**: All test targets pass with 0 failures.
3. **Desensitization verified**: No real credentials, PII, or account data in any file.
4. **Scope confirmed**: PR touches only the directories listed in its description.
5. **SOURCE_MISSING acknowledged**: Any SOURCE_MISSING items are explicitly noted in the PR body.
6. **Human review**: At least one human reviewer has approved.
7. **MUSE sign-off** (for MUSE-scoped changes): MUSE independent verification task is complete.

Agent-created PRs are tagged with `[AG-01-A]` or `[AG-01-B]` in the title to identify their origin.

---

## 5. Incident / Anomaly Reporting

If an agent detects any of the following, it MUST immediately halt further actions and report to the
calling human/orchestrator:

- Real credentials or PII discovered in repository files.
- A test unexpectedly accesses a live network endpoint.
- A build step attempts to activate `ProductionEventKitStore`.
- A `git push` or `gh pr create` fails with an authentication error referencing real accounts.
- Any command output containing an Apple ID, real email, or token string.

Reporting format:
```
AGENT_ANOMALY: <short description>
ACTION_TAKEN: HALTED
REQUIRES: <human decision>
```

---

## 6. Test Standards

- All tests must use Fake/Mock implementations only. No real sessions.
- Synthetic test data must be clearly synthetic (e.g., `"Test List"`, `"mock-id-001"`).
- Tests must be deterministic: same input → same output, no network, no filesystem side effects.
- Minimum coverage: 10 test cases per major module.
- Swift test targets must compile and pass under `swift test` with 0 warnings about actor isolation
  (Swift 6 strict concurrency mode is enforced).

---

*This charter was established by the AG-01 Engineering Agent on 2026-11-07.*  
*Modifications require a separate PR with human approval.*
