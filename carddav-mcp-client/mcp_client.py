#!/usr/bin/env python3
"""Minimal Streamable HTTP MCP client for the Seoul iCloud CardDAV MCP (muse-personal).

Stdlib only. This speaks MCP JSON-RPC + OAuth DCR/PKCE only; it does NOT
reimplement Apple CardDAV and does NOT build a second CardDAV service.

State (client_id, PKCE verifier, tokens) lives under the user's protected
configuration directory, outside the source repository (directory 0700,
file 0600). Set MUSE_PERSONAL_MCP_ORIGIN to the private HTTPS origin through
protected runtime configuration. Secrets and tool results are never printed.

Usage:
  python3 mcp_client.py register         # dynamic client registration (DCR)
  python3 mcp_client.py authorize-url    # print the browser authorize URL
  python3 mcp_client.py exchange CODE    # code -> access/refresh tokens
  python3 mcp_client.py initialize       # MCP initialize (needs tokens)
  python3 mcp_client.py tools            # tools/list
  python3 mcp_client.py call TOOL [JSON] # tools/call
"""

import base64
import hashlib
import json
import os
import pathlib
import secrets
import sys
import urllib.error
import urllib.parse
import urllib.request

CONFIG_HOME = os.environ.get("XDG_CONFIG_HOME") or os.path.join(pathlib.Path.home(), ".config")
STATE_DIR = os.path.join(CONFIG_HOME, "muse-personal")
STATE = os.path.join(STATE_DIR, "oauth.json")
REDIRECT_URI = "http://127.0.0.1:8765/callback"
CLIENT_NAME = "muse-personal"
SCOPE = "mcp"


class McpSessionError(RuntimeError):
    """A session rejection safe to use for bounded read-only reconnection."""


def _configured_origin():
    raw = os.environ.get("MUSE_PERSONAL_MCP_ORIGIN")
    if not raw:
        raise RuntimeError("MCP_ORIGIN_NOT_CONFIGURED")
    try:
        parsed = urllib.parse.urlsplit(raw)
        port = parsed.port
        valid = (
            parsed.scheme == "https"
            and bool(parsed.hostname)
            and parsed.username is None
            and parsed.password is None
            and parsed.path in ("", "/")
            and not parsed.query
            and not parsed.fragment
            and (port is None or 1 <= port <= 65535)
        )
    except ValueError as exc:
        raise RuntimeError("MCP_ORIGIN_INVALID") from exc
    if not valid:
        raise RuntimeError("MCP_ORIGIN_INVALID")
    return "https://" + parsed.netloc


def _check_state_location():
    state_dir = pathlib.Path(STATE_DIR).expanduser().resolve()
    for candidate in pathlib.Path(__file__).resolve().parents:
        if (candidate / ".git").exists() and (
            state_dir == candidate or candidate in state_dir.parents
        ):
            raise RuntimeError("OAUTH_STATE_MUST_BE_OUTSIDE_REPOSITORY")


def _save_state(d):
    _check_state_location()
    os.makedirs(STATE_DIR, mode=0o700, exist_ok=True)
    os.chmod(STATE_DIR, 0o700)
    if os.path.islink(STATE):
        raise RuntimeError("OAUTH_STATE_PERMISSIONS_INVALID")
    flags = os.O_WRONLY | os.O_CREAT | os.O_TRUNC
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    fd = os.open(STATE, flags, 0o600)
    with os.fdopen(fd, "w") as f:
        json.dump(d, f, indent=2)
    os.chmod(STATE, 0o600)


def _load_state():
    _check_state_location()
    if os.path.islink(STATE) or os.stat(STATE).st_mode & 0o077:
        raise RuntimeError("OAUTH_STATE_PERMISSIONS_INVALID")
    with open(STATE) as f:
        return json.load(f)


def _post_json(url, payload, headers=None, timeout=60):
    """POST JSON via curl config file (0600, deleted after).

    The VM egress proxy truncates SSE responses for Python http.client
    (IncompleteRead: 0 of 194 bytes), while curl delivers them intact.
    Headers (including Bearer) go through a 0600 config file, never argv.
    """
    import subprocess
    import tempfile

    data = json.dumps(payload).encode()
    hdrs = {"Content-Type": "application/json", "Accept": "application/json, text/event-stream"}
    hdrs.update(headers or {})
    bfd, bpath = tempfile.mkstemp()
    os.close(bfd)
    hfd, hpath = tempfile.mkstemp()
    os.close(hfd)
    cfd, cpath = tempfile.mkstemp()
    os.close(cfd)
    os.chmod(cpath, 0o600)
    try:
        lines = [
            "silent = true",
            "show-error = true",
            "request = POST",
            "max-time = %d" % timeout,
            'url = "%s"' % url,
            'output = "%s"' % bpath,
            'dump-header = "%s"' % hpath,
        ]
        for k, v in hdrs.items():
            lines.append('header = "%s: %s"' % (k, v.replace('"', "")))
        with open(cpath, "w") as f:
            f.write("\n".join(lines) + "\n")
        proc = subprocess.run(
            ["curl", "-K", cpath, "--data-binary", "@-"],
            input=data,
            capture_output=True,
            timeout=timeout + 10,
        )
        with open(hpath) as f:
            htext = f.read()
        with open(bpath, "rb") as f:
            body = f.read().decode("utf-8", "replace")
    finally:
        for p in (bpath, hpath, cpath):
            try:
                os.unlink(p)
            except OSError:
                pass
    # Header file may hold the proxy CONNECT block plus the real block;
    # take the LAST HTTP status block.
    blocks = [b for b in htext.replace("\r\n", "\n").split("\n\n") if b.strip()]
    status = 0
    out_headers = {}
    for b in blocks:
        blines = b.split("\n")
        if blines and blines[0].startswith("HTTP/"):
            try:
                status = int(blines[0].split()[1])
            except (IndexError, ValueError):
                pass
            out_headers = {}
            for line in blines[1:]:
                if ":" in line:
                    k, v = line.split(":", 1)
                    out_headers[k.strip()] = v.strip()
    if proc.returncode != 0 and not body and status == 0:
        raise RuntimeError("MCP_TRANSPORT_FAILED")
    return status, out_headers, body


def _post_form(url, fields, timeout=30):
    data = urllib.parse.urlencode(fields).encode()
    req = urllib.request.Request(url, data=data, method="POST")
    req.add_header("Content-Type", "application/x-www-form-urlencoded")
    req.add_header("Accept", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return resp.status, dict(resp.headers), resp.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as e:
        return e.code, dict(e.headers), e.read().decode("utf-8", "replace")


def _rpc_message(body):
    body = body.strip()
    if body.startswith("{"):
        message = json.loads(body)
        if not isinstance(message, dict):
            raise ValueError("MCP_RESPONSE_INVALID")
        return message
    msgs = []
    for line in body.splitlines():
        line = line.strip()
        if line.startswith("data:"):
            txt = line[5:].strip()
            if txt and txt != "[DONE]":
                msgs.append(json.loads(txt))
    if not msgs:
        raise ValueError("MCP_RESPONSE_INVALID")
    if not isinstance(msgs[-1], dict):
        raise ValueError("MCP_RESPONSE_INVALID")
    return msgs[-1]


def _is_session_error(error):
    if not isinstance(error, dict):
        return False
    # Inspect the server message only inside this process. Never include it in
    # an exception or log, because an unexpected server response can contain
    # customer data.
    marker = json.dumps(error, ensure_ascii=False).lower()
    return any(token in marker for token in ("session", "unknown session", "session not found"))


def _mcp_call(method, params, token, session_id=None, msg_id=1):
    headers = {"Authorization": "Bearer " + token}
    if session_id:
        headers["Mcp-Session-Id"] = session_id
    status, hdrs, body = _post_json(
        _configured_origin() + "/mcp",
        {"jsonrpc": "2.0", "id": msg_id, "method": method, "params": params},
        headers,
    )
    lower = {k.lower(): v for k, v in hdrs.items()}
    new_session = lower.get("mcp-session-id", session_id)
    if status != 200:
        if status == 404:
            raise McpSessionError("MCP_SESSION_REJECTED")
        raise RuntimeError("MCP_HTTP_ERROR_%s" % status)
    msg = _rpc_message(body)
    if "error" in msg:
        if _is_session_error(msg["error"]):
            raise McpSessionError("MCP_SESSION_REJECTED")
        raise RuntimeError("MCP_RPC_ERROR")
    if "result" not in msg:
        raise ValueError("MCP_RESULT_MISSING")
    return msg.get("result"), new_session


def cmd_register():
    payload = {
        "redirect_uris": [REDIRECT_URI],
        "client_name": CLIENT_NAME,
        "grant_types": ["authorization_code", "refresh_token"],
        "response_types": ["code"],
        "token_endpoint_auth_method": "none",
        "scope": SCOPE,
    }
    status, _hdrs, body = _post_json(_configured_origin() + "/register", payload)
    if status not in (200, 201):
        print("REGISTER_FAILED")
        return 1
    try:
        reg = json.loads(body)
    except (TypeError, ValueError):
        print("REGISTER_RESPONSE_INVALID")
        return 1
    if not isinstance(reg, dict) or not isinstance(reg.get("client_id"), str):
        print("REGISTER_RESPONSE_INVALID")
        return 1
    verifier = secrets.token_urlsafe(64)
    challenge = (
        base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest())
        .rstrip(b"=")
        .decode()
    )
    st = {
        "client_id": reg.get("client_id"),
        "redirect_uri": REDIRECT_URI,
        "scope": SCOPE,
        "code_verifier": verifier,
        "code_challenge": challenge,
        "state": secrets.token_urlsafe(24),
    }
    if reg.get("client_secret"):
        st["client_secret"] = reg["client_secret"]
    _save_state(st)
    print("client_secret issued:", bool(reg.get("client_secret")), "(stored only, never printed)")
    print("OAUTH_STATE_SAVED: True")
    return 0


def cmd_refresh():
    """Refresh grant: exchange the stored refresh_token for new tokens.

    Only overwrites the state file on HTTP 200. Caller should back up the
    state file first (refresh grants usually rotate the refresh token).
    """
    st = _load_state()
    if not st.get("refresh_token"):
        print("NO_REFRESH_TOKEN")
        return 1
    fields = {
        "grant_type": "refresh_token",
        "refresh_token": st["refresh_token"],
        "client_id": st["client_id"],
        "scope": st.get("scope", "mcp"),
    }
    if st.get("client_secret"):
        fields["client_secret"] = st["client_secret"]
    status, _hdrs, body = _post_form(_configured_origin() + "/token", fields)
    print("refresh token HTTP:", status)
    if status != 200:
        print("REFRESH_FAILED (stored tokens untouched)")
        return 1
    try:
        tok = json.loads(body)
    except (TypeError, ValueError):
        print("REFRESH_RESPONSE_INVALID (stored tokens untouched)")
        return 1
    if not isinstance(tok, dict) or not isinstance(tok.get("access_token"), str):
        print("REFRESH_RESPONSE_INVALID (stored tokens untouched)")
        return 1
    st["access_token"] = tok.get("access_token")
    if tok.get("refresh_token"):
        st["refresh_token"] = tok["refresh_token"]
    st["expires_in"] = tok.get("expires_in")
    st["scope_granted"] = tok.get("scope")
    st["mcp_session_id"] = None
    _save_state(st)
    print("REFRESH_OK: True")
    print("refresh_token stored:", bool(st.get("refresh_token")))
    print("scope granted:", st.get("scope_granted"))
    return 0


def cmd_authorize_url():
    st = _load_state()
    q = urllib.parse.urlencode(
        {
            "response_type": "code",
            "client_id": st["client_id"],
            "redirect_uri": st["redirect_uri"],
            "scope": st["scope"],
            "state": st["state"],
            "code_challenge": st["code_challenge"],
            "code_challenge_method": "S256",
        }
    )
    print(_configured_origin() + "/authorize?" + q)
    return 0


def cmd_exchange(code):
    st = _load_state()
    fields = {
        "grant_type": "authorization_code",
        "code": code,
        "redirect_uri": st["redirect_uri"],
        "client_id": st["client_id"],
        "code_verifier": st["code_verifier"],
    }
    if st.get("client_secret"):
        fields["client_secret"] = st["client_secret"]
    status, _hdrs, body = _post_form(_configured_origin() + "/token", fields)
    print("token HTTP:", status)
    if status != 200:
        print("EXCHANGE_FAILED")
        return 1
    try:
        tok = json.loads(body)
    except (TypeError, ValueError):
        print("TOKEN_RESPONSE_INVALID")
        return 1
    if not isinstance(tok, dict) or not isinstance(tok.get("access_token"), str):
        print("TOKEN_RESPONSE_INVALID")
        return 1
    st["access_token"] = tok.get("access_token")
    if tok.get("refresh_token"):
        st["refresh_token"] = tok["refresh_token"]
    st["token_type"] = tok.get("token_type")
    st["expires_in"] = tok.get("expires_in")
    st["scope_granted"] = tok.get("scope")
    _save_state(st)
    print("TOKEN_EXCHANGE_OK: True")
    print("refresh_token stored:", bool(st.get("refresh_token")))
    print("scope granted:", st.get("scope_granted"))
    return 0


def _session():
    """Return (state, session_id, fresh).

    A stored session is already initialized: reuse it WITHOUT re-sending
    initialize (the server rejects initialize on an existing session with
    400 'Server already initialized'). Only a missing session triggers a
    fresh initialize (no session header) + notifications/initialized.
    """
    st = _load_state()
    token = st.get("access_token")
    if not token:
        print("NO_ACCESS_TOKEN: run exchange first")
        return None, None, False
    session = st.get("mcp_session_id")
    if session:
        return st, session, False
    result, session = _mcp_call(
        "initialize",
        {
            "protocolVersion": "2025-06-18",
            "capabilities": {},
            "clientInfo": {"name": "muse-personal", "version": "0.1.0"},
        },
        token,
        None,
    )
    st["mcp_session_id"] = session
    st["server_protocol"] = (result or {}).get("protocolVersion")
    st["server_info"] = (result or {}).get("serverInfo")
    _save_state(st)
    # notifications/initialized (no id, no response expected)
    try:
        _post_json(
        _configured_origin() + "/mcp",
            {"jsonrpc": "2.0", "method": "notifications/initialized"},
            {"Authorization": "Bearer " + token, "Mcp-Session-Id": session} if session else {"Authorization": "Bearer " + token},
        )
    except Exception as exc:
        # The session ID has been durably stored. Report only the exception
        # type; never suppress protocol failure or echo its response body.
        raise RuntimeError("MCP_INITIALIZED_NOTIFICATION_FAILED") from None
    return st, session, True


def _mcp_call_resilient(method, params, msg_id):
    """Retry a rejected session once only for read-only MCP operations."""
    st = _load_state()
    token = st.get("access_token")
    if not token:
        print("NO_ACCESS_TOKEN: run exchange first")
        return None
    session = st.get("mcp_session_id")
    if not session:
        st, session, _fresh = _session()
        if st is None:
            return None
    try:
        result, _s = _mcp_call(method, params, token, session, msg_id)
        return result
    except McpSessionError:
        tool_name = params.get("name") if method == "tools/call" and isinstance(params, dict) else None
        safe_to_retry = method != "tools/call" or tool_name in {
            "apple_login",
            "contacts_search",
            "contacts_read",
        }
        if safe_to_retry:
            st["mcp_session_id"] = None
            _save_state(st)
            st, session, _fresh = _session()
            if st is None:
                return None
            result, _s = _mcp_call(method, params, token, session, msg_id)
            return result
        raise


def cmd_initialize():
    st, session, fresh = _session()
    if st is None:
        return 1
    if fresh:
        print("initialize ok; server protocol:", st.get("server_protocol"))
    else:
        print("session already initialized (reused); server protocol:", st.get("server_protocol"))
    print("server info:", json.dumps(st.get("server_info"), ensure_ascii=False))
    print("session id set:", bool(session))
    return 0


def cmd_tools():
    result = _mcp_call_resilient("tools/list", {}, 2)
    if result is None:
        return 1
    tools = result.get("tools", [])
    print("tools count:", len(tools))
    for t in tools:
        print("-", t.get("name"))
    return 0


def cmd_schemas():
    result = _mcp_call_resilient("tools/list", {}, 2)
    if result is None:
        return 1
    for t in result.get("tools", []):
        print("==", t.get("name"))
        print(json.dumps(t.get("inputSchema", {}), ensure_ascii=False)[:800])
    return 0


def cmd_call(tool, args_json="{}"):
    args = json.loads(args_json) if args_json else {}
    result = _mcp_call_resilient("tools/call", {"name": tool, "arguments": args}, 3)
    if result is None:
        return 1
    print("CALL_COMPLETE: True")
    return 0


def main(argv):
    if not argv:
        print("usage: register | authorize-url | exchange CODE | initialize | tools | call TOOL [JSON]")
        return 2
    cmd = argv[0]
    if cmd == "register":
        return cmd_register()
    if cmd == "authorize-url":
        return cmd_authorize_url()
    if cmd == "exchange" and len(argv) == 2:
        return cmd_exchange(argv[1])
    if cmd == "refresh":
        return cmd_refresh()
    if cmd == "initialize":
        return cmd_initialize()
    if cmd == "tools":
        return cmd_tools()
    if cmd == "schemas":
        return cmd_schemas()
    if cmd == "call" and len(argv) >= 2:
        return cmd_call(argv[1], argv[2] if len(argv) > 2 else "{}")
    print("bad usage")
    return 2


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except Exception as exc:
        print("MCP_CLIENT_FAILED:", type(exc).__name__)
        sys.exit(1)
