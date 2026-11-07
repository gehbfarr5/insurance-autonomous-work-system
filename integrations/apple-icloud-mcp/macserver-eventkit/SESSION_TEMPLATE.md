# SESSION_TEMPLATE.md
<!-- AG-01-B | MacServer EventKit Readonly Candidate | 2026-11-07 -->
<!-- Template only — NO real credentials. Fill in at runtime from secure config store. -->

## Session Overview

This template describes how to start, stop, and resume a MacServer EventKit Bridge session.
**All `<PLACEHOLDER>` values must be supplied at runtime from a secure credential store.**
**Do NOT commit real values to this file.**

---

## Prerequisites

1. macOS 14.0+, Swift 6.0+
2. Package builds and tests pass (`swift build && swift test`)
3. Session config file created (see §Configuration below)
4. For production mode: TCC permission granted + human authorization (AGENTS.md §1.3)

---

## Configuration

Create a local config file (NOT committed to git):

```json
{
  "port": 18765,
  "maxConcurrentRequests": 10,
  "allowedListIDs": [
    "<YOUR_ICLOUD_LIST_ID_1>",
    "<YOUR_ICLOUD_LIST_ID_2>"
  ],
  "allowedSources": ["iCloud"],
  "validTokens": [
    "<YOUR_SESSION_TOKEN>"
  ],
  "rateLimitRPS": 5,
  "useFakeStore": true
}
```

**Notes:**
- `allowedListIDs`: Obtain from EventKit (`EKCalendar.calendarIdentifier`), not display names.
- `validTokens`: Generate a cryptographically random token at runtime. Store in Keychain.
- Set `useFakeStore: false` ONLY after human authorization for production activation.

---

## Start Session

```bash
# Navigate to package directory
cd integrations/apple-icloud-mcp/macserver-eventkit

# Test mode (no TCC, no real credentials required)
swift run EventKitBridgeServer --config /path/to/config.json

# Verify bridge is running (test mode)
curl -s -H "Authorization: Bearer <YOUR_SESSION_TOKEN>" \
     http://localhost:18765/reminders/lists
```

---

## Stop Session

```bash
# Find the bridge process
pgrep -f EventKitBridgeServer

# Graceful stop
pkill -SIGTERM -f EventKitBridgeServer

# Verify stopped
pgrep -f EventKitBridgeServer || echo "Bridge stopped."
```

---

## Resume Session

```bash
# Verify config file still exists and is unchanged
cat /path/to/config.json | python3 -m json.tool > /dev/null && echo "Config valid"

# Restart
swift run EventKitBridgeServer --config /path/to/config.json
```

---

## Session Resident State

The bridge is **stateless** between requests. Stopping and resuming does not affect:
- iCloud reminder data (read-only, never modified)
- Allowlist (loaded from config file at startup)
- Token validity (tokens are session-local; re-generate if needed)

---

## Security Reminders

> [!CAUTION]
> - Never store `validTokens` in this file or any git-tracked file.
> - Never set `useFakeStore: false` without human authorization.
> - Rotate session tokens on each resume if the previous session was more than 1 hour ago.
> - `allowedListIDs` must use exact EKCalendar identifiers, not display names (FIX-R4A-01).

---

*Template only — AG-01 Engineering Agent | 2026-11-07*
