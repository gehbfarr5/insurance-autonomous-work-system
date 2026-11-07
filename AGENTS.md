# AGENTS.md — Agent Operation Charter
<!-- AG-01 | insurance-autonomous-work-system -->

This charter defines operational conventions and permission boundaries for autonomous AI agents
operating within this repository. It is designed to safeguard production systems, credentials,
and personal data, while preserving full engineering autonomy within authorized scopes.

---

## 1. Autonomous Execution & Permission Boundaries

### 1.1 Authorized Operations
Agents are authorized to execute autonomously within task scope:
- Create, modify, and refactor code, modules, tests, and configuration templates in isolated branches.
- Run builds, test suites, benchmarks, and diagnostic commands locally.
- Use mock data, synthetic fixtures, fake transports, and loopback networking.
- Fix compilation issues, runtime errors, dependency mismatches, and test failures without returning for trivial approval.
- Perform read-only inspections of repository state, commits, branches, and authorized project artifacts.
- Commit desensitized changes, push feature/reconcile branches, and create pull requests for human review.

### 1.2 Boundary Constraints (Strictly Prohibited Without Explicit Prior Authorization)
- **NO** direct commits or force-pushes to `main`.
- **NO** automatic merging of pull requests.
- **NO** accessing or logging production credentials, Apple IDs, app-specific passwords, session cookies, OAuth tokens, or client secrets.
- **NO** mutating production services, server restarts, gateway routing changes, or modifying firewall/network rules.
- **NO** making live Apple API calls (CardDAV, CalDAV, CloudKit, EventKit TCC prompts) or mutating real Apple data.
- **NO** deleting or stopping shared infrastructure resources under the guise of milestone retirement.

### 1.3 Governance & Escalation
- When an operation falls outside explicit task scope or encounters ambiguous production dependencies, pause that specific operation and continue other independent tasks.
- Missing historical source code must be explicitly marked as `SOURCE_MISSING`. Newly implemented replacements must be marked `# NEW_IMPLEMENTATION` or `// NEW_IMPLEMENTATION`.
- User task instructions supersede general defaults within this repository.

---

## 2. Desensitization & Data Minimization

All agent-generated commits, PRs, logs, and evidence documents must comply with:
- **Zero Real Identifiers**: Never log real Apple IDs, personal emails, telephone numbers, postal addresses, or customer details.
- **Synthetic Test Data**: Use RFC 2606 reserved domains (`@example.invalid`), non-routable numbers (`+1000000000X`), and synthetic UUIDs.
- **Credential Masking**: Tokens, keys, and session artifacts must use non-functional placeholders (`<REDACTED_TOKEN>`).
- **Path Sanitization**: User directories and private hostnames must be desensitized (`<HOME>`, `<PRIVATE_HOST>`).

---

## 3. PR and Branching Conventions

- **Reconciliation Branches**: `reconcile/<scope>-baseline`
- **Feature Branches**: `feat/<component>-<descriptor>`
- **Fix Branches**: `fix/<component>-<descriptor>`
- **Stacked PRs**: When a feature branch builds upon an unmerged baseline branch, the feature PR may explicitly target the baseline branch as its base to keep review diffs isolated and clean.
