#!/usr/bin/env python3
"""WorkBuddy local MCP client: OAuth 2.1 Authorization Code + PKCE (S256).

Reuses the already-stored MCP access key (~/.config/insurance-carddav-mcp/access_key).
Never prints secrets. Persists tokens to token.json (0600). Stdlib only.
"""
import base64
import hashlib
import http.cookiejar
import json
import os
import re
import secrets
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request

BASE = "https://seoul-forge-01.tail4db0d9.ts.net"
STATE_DIR = os.path.expanduser("~/.workbuddy/icloud-mcp")
KEY_PATH = os.path.expanduser("~/.config/insurance-carddav-mcp/access_key")
REDIRECT = "http://127.0.0.1:8765/callback"


def opener():
    jar = http.cookiejar.CookieJar()
    return urllib.request.build_opener(
        urllib.request.HTTPCookieProcessor(jar),
        NoRedirect(),
    )


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def request(op, url, data=None, headers=None):
    body = urllib.parse.urlencode(data).encode() if isinstance(data, dict) else data
    req = urllib.request.Request(url, data=body, headers=headers or {})
    try:
        r = op.open(req, timeout=30)
        return r.status, dict(r.headers), r.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as e:
        return e.code, dict(e.headers), e.read().decode("utf-8", "replace")


def main():
    os.makedirs(STATE_DIR, mode=0o700, exist_ok=True)
    os.chmod(STATE_DIR, 0o700)
    with open(os.path.join(STATE_DIR, "dcr.json")) as f:
        dcr = json.load(f)
    client_id = dcr["client_id"]
    access_key = open(KEY_PATH).read().strip()

    verifier = secrets.token_urlsafe(64)
    challenge = base64.urlsafe_b64encode(
        hashlib.sha256(verifier.encode()).digest()).rstrip(b"=").decode()
    state = secrets.token_urlsafe(24)
    op = opener()

    q = urllib.parse.urlencode({
        "response_type": "code", "client_id": client_id, "redirect_uri": REDIRECT,
        "scope": "mcp", "state": state,
        "code_challenge": challenge, "code_challenge_method": "S256",
    })
    st, hd, body = request(op, BASE + "/authorize?" + q, headers={"Accept": "text/html"})
    print("GET /authorize ->", st)
    m = re.search(r'name="request_id"\s+value="([^"]+)"', body)
    if not m:
        print("no request_id; excerpt:", re.sub(r"\s+", " ", re.sub(r"<[^>]+>", " ", body))[:200])
        sys.exit(1)
    request_id = m.group(1)

    st2, hd2, body2 = request(
        op, BASE + "/access-login",
        data={"request_id": request_id, "access_key": access_key},
        headers={"Content-Type": "application/x-www-form-urlencoded"})
    loc = hd2.get("Location") or hd2.get("location") or ""
    print("POST /access-login ->", st2, "| redirect:", loc.split("?")[0] if loc else "(none)")
    parsed = urllib.parse.parse_qs(urllib.parse.urlparse(loc).query)
    code = parsed.get("code", [""])[0]
    if not code:
        excerpt = re.sub(r"\s+", " ", re.sub(r"<[^>]+>", " ", body2))[:300]
        print("no authorization code. server said:", excerpt)
        sys.exit(2)
    if parsed.get("state", [""])[0] != state:
        raise SystemExit("OAuth state mismatch: authorization rejected")
    print("authorization code received | OAuth state verified")

    st3, _, body3 = request(
        op, BASE + "/token",
        data={"grant_type": "authorization_code", "code": code, "redirect_uri": REDIRECT,
              "client_id": client_id, "code_verifier": verifier},
        headers={"Content-Type": "application/x-www-form-urlencoded"})
    print("POST /token ->", st3)
    if st3 != 200:
        print(body3[:300]); sys.exit(3)
    tok = json.loads(body3)
    tok["_obtained_at"] = int(time.time())
    tok["_client_id"] = client_id
    path = os.path.join(STATE_DIR, "token.json")
    fd, staged = tempfile.mkstemp(prefix=".token-", dir=STATE_DIR)
    try:
        with os.fdopen(fd, "w") as f:
            json.dump(tok, f, indent=2)
            f.flush()
            os.fsync(f.fileno())
        os.chmod(staged, 0o600)
        os.replace(staged, path)
    finally:
        if os.path.exists(staged):
            os.unlink(staged)
    print("token stored:", path)
    print("scope:", tok.get("scope"), "| expires_in:", tok.get("expires_in"),
          "| refresh_token:", bool(tok.get("refresh_token")),
          "| token_type:", tok.get("token_type"))


if __name__ == "__main__":
    main()
