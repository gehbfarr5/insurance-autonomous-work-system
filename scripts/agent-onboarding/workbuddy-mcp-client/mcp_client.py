#!/usr/bin/env python3
"""WorkBuddy MCP client bridge (Streamable HTTP + Bearer).

Usage:
  python mcp_client.py list
  python mcp_client.py call <tool_name> '<json args>'
  python mcp_client.py batch '<json array of {tool,args}>'
"""
import asyncio
import json
import os
import sys

import httpx2
from mcp import ClientSession
from mcp.client.streamable_http import streamable_http_client

BASE = "https://seoul-forge-01.tail4db0d9.ts.net/mcp"
HERE = os.path.dirname(os.path.abspath(__file__))


def token():
    return json.load(open(os.path.join(HERE, "token.json")))["access_token"]


def dump_result(res):
    out = {}
    if getattr(res, "content", None):
        parts = []
        for c in res.content:
            t = getattr(c, "text", None)
            if t is not None:
                try:
                    parts.append(json.loads(t))
                except Exception:
                    parts.append(t)
            else:
                parts.append(str(getattr(c, "type", "?")))
        out["content"] = parts
    if getattr(res, "structuredContent", None) is not None:
        out["structured"] = res.structuredContent
    out["isError"] = getattr(res, "isError", None)
    return out


async def run(actions):
    hc = httpx2.AsyncClient(headers={"Authorization": "Bearer " + token()}, timeout=60)
    async with streamable_http_client(BASE, http_client=hc) as streams:
        read, write = streams[0], streams[1]
        async with ClientSession(read, write) as session:
            init = await session.initialize()
            results = {"_initialize": {
                "serverInfo": init.server_info.model_dump() if getattr(init,"server_info",None) else None,
                "protocolVersion": getattr(init,"protocol_version",None),
                "capabilities": list((init.capabilities.model_dump() or {}).keys()) if getattr(init,"capabilities",None) else [],
            }}
            for act in actions:
                if act["tool"] == "__tools_list__":
                    tl = await session.list_tools()
                    results["_tools"] = [t.name for t in tl.tools]
                    continue
                r = await session.call_tool(act["tool"], act.get("args") or {})
                results[act["tool"]] = dump_result(r)
            await hc.aclose()
            return results


def main():
    mode = sys.argv[1] if len(sys.argv) > 1 else "list"
    if mode == "list":
        actions = [{"tool": "__tools_list__"}]
    elif mode == "call":
        actions = [{"tool": sys.argv[2], "args": json.loads(sys.argv[3]) if len(sys.argv) > 3 else {}}]
    elif mode == "batch":
        actions = json.loads(sys.argv[2])
    else:
        raise SystemExit("unknown mode")
    res = asyncio.run(run(actions))
    print(json.dumps(res, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
