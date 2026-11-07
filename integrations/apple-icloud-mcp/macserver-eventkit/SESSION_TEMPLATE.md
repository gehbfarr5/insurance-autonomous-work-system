# SESSION_TEMPLATE.md
<!-- AG-01-B | MacServer EventKit Readonly Candidate | 2026-11-07 -->
<!-- Template only — NO real credentials. Fill in at runtime from secure config store. -->

## Session Overview

This template describes how to configure, start, stop, and resume a MacServer EventKit Bridge session.
All configuration is unified across the daemon and LaunchAgent definitions via standard `EVENTKIT_BRIDGE_*` environment variables.
**All `<PLACEHOLDER>` values must be supplied at runtime from a secure credential store.**
**Do NOT commit real values to this file.**

---

## Prerequisites

1. macOS 13.0+, Swift 6.0+
2. Target platform: Intel MacServer (`x86_64`) or Apple Silicon (`arm64`)
3. GUI Login Session Domain: Daemon must run in the active graphical user domain (`gui/$(id -u)`) to access `kTCCServiceReminders`.
4. Production activation requires explicit human authorization (`EVENTKIT_BRIDGE_PRODUCTION_AUTHORIZED=true`). Default is false.

---

## Canonical Configuration Variables

All variables are strictly unified under the `EVENTKIT_BRIDGE_*` namespace:

| Variable | Type | Default | Description |
|---|---|---|---|
| `EVENTKIT_BRIDGE_MODE` | String | `TEST` | Operating mode: `TEST` (safe offline fake store) or `PRODUCTION` (gated EventKit) |
| `EVENTKIT_BRIDGE_PORT` | Int | `18765` | Bound loopback port (127.0.0.1) |
| `EVENTKIT_BRIDGE_ALLOWED_LIST_IDS` | String | *required* | Comma-separated list IDs (e.g. `UUID1,UUID2`) |
| `EVENTKIT_BRIDGE_BINDINGS` | String | *required* | Semicolon-separated `listID:sourceID:sourceType:sourceTitle` bindings |
| `EVENTKIT_BRIDGE_BEARER_TOKEN` | String | *required* | Session Bearer token (cryptographically random, runtime generated) |
| `EVENTKIT_BRIDGE_MAX_CONCURRENT` | Int | `10` | Maximum concurrent business requests (health check unblocked) |
| `EVENTKIT_BRIDGE_MAX_STORE_OPS` | Int | `10` | Maximum concurrent store operations (quarantines hanging tasks) |
| `EVENTKIT_BRIDGE_TIMEOUT` | Double | `5.0` | Overall request timeout in seconds |
| `EVENTKIT_BRIDGE_HEADER_TIMEOUT` | Double | `3.0` | Deadline for reading HTTP request headers |
| `EVENTKIT_BRIDGE_BODY_TIMEOUT` | Double | `3.0` | Deadline for reading HTTP request body |
| `EVENTKIT_BRIDGE_SEND_TIMEOUT` | Double | `5.0` | Deadline for complete socket response flush |
| `EVENTKIT_BRIDGE_PRODUCTION_AUTHORIZED` | Bool | `false` | Explicit production activation gate |

---

## Canonical LaunchAgent Template Generation

The daemon executable includes a built-in template generator to guarantee complete configuration consistency:

```bash
# Generate canonical plist from program definition
./EventKitBridgeServer --generate-plist-template > ~/Library/LaunchAgents/com.muse.macserver-eventkit.plist
```

Or copy the pre-generated template:
```bash
cp com.muse.macserver-eventkit.plist.template ~/Library/LaunchAgents/com.muse.macserver-eventkit.plist
```

---

## Start Session (Daemon Mode)

```bash
# 1. Ensure log and binary directories exist
mkdir -p /Users/shared/bin /Users/shared/log

# 2. Install binary with standard permissions
install -m 755 .build-x86_64/out/Products/Release/EventKitBridgeServer /Users/shared/bin/EventKitBridgeServer

# 3. Apply ad-hoc Hardened Runtime code signature
codesign --force --sign - \
  --identifier "com.muse.macserver-eventkit" \
  --options runtime \
  /Users/shared/bin/EventKitBridgeServer

# 4. Bootstrap daemon into user GUI session
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.muse.macserver-eventkit.plist

# 5. Verify health endpoint
curl -s http://127.0.0.1:18765/health
```

---

## Stop Session

```bash
# Boot out daemon from user GUI session
launchctl bootout gui/$(id -u) ~/Library/LaunchAgents/com.muse.macserver-eventkit.plist

# Verify port is released
lsof -i :18765 || echo "Port 18765 is clear."
```

---

## Resume Session

```bash
# Re-bootstrap daemon into user GUI session
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.muse.macserver-eventkit.plist

# Check health
curl -s http://127.0.0.1:18765/health
```

---

*Verified canonical template specification | AG-01 Engineering Agent | 2026-11-07*
