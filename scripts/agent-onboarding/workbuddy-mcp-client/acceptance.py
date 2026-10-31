#!/usr/bin/env python3
"""WorkBuddy real functional acceptance for iCloud CardDAV/CalDAV MCP.

Read-only. Prints structural evidence only (counts/flags), never customer content.
"""
import asyncio
import json
import os
import random
import string
import time

import httpx2
from mcp import ClientSession
from mcp.client.streamable_http import streamable_http_client

BASE = "https://seoul-forge-01.tail4db0d9.ts.net/mcp"
HERE = os.path.dirname(os.path.abspath(__file__))
EVID = {}


def payload(res):
    for c in res.content or []:
        t = getattr(c, "text", None)
        if t is None:
            continue
        try:
            return json.loads(t)
        except Exception:
            return t
    return None


def summarize_cal_list(d):
    cals = d.get("calendars", d) if isinstance(d, dict) else d
    if isinstance(cals, list):
        return {"calendar_count": len(cals),
                "writable_true": sum(1 for c in cals if isinstance(c, dict) and c.get("writable") is True),
                "writable_false": sum(1 for c in cals if isinstance(c, dict) and c.get("writable") is False),
                "keys": sorted({k for c in cals if isinstance(c, dict) for k in c})}
    return {"raw_type": type(d).__name__}


def summarize_events(d):
    if not isinstance(d, dict):
        return {"raw_type": type(d).__name__}
    ev = d.get("events") or []
    return {"event_count": len(ev),
            "truncated": d.get("truncated"),
            "partial_failures": d.get("partial_failures"),
            "extra_flags": sorted(k for k in d if k not in ("events",))}


def summarize_rem_lists(d):
    lists = d.get("lists", d) if isinstance(d, dict) else d
    if isinstance(lists, list):
        return {"list_count": len(lists),
                "writable_true": sum(1 for x in lists if isinstance(x, dict) and x.get("writable") is True)}
    return {"raw_type": type(d).__name__}


def summarize_rem_items(d):
    if not isinstance(d, dict):
        return {"raw_type": type(d).__name__}
    items = d.get("reminders") or d.get("items") or []
    completed = sum(1 for x in items if isinstance(x, dict) and x.get("completed") is True)
    return {"item_count": len(items), "completed_true": completed,
            "truncated": d.get("truncated"), "partial_failures": d.get("partial_failures"),
            "extra_flags": sorted(k for k in d if k not in ("reminders", "items"))}


async def main():
    tok = json.load(open(os.path.join(HERE, "token.json")))["access_token"]
    hc = httpx2.AsyncClient(headers={"Authorization": "Bearer " + tok}, timeout=90)
    probe = "zz-accept-" + "".join(random.choices(string.ascii_lowercase + string.digits, k=8))
    async with streamable_http_client(BASE, http_client=hc) as s:
        async with ClientSession(s[0], s[1]) as sess:
            init = await sess.initialize()
            tools = [t.name for t in (await sess.list_tools()).tools]
            EVID["initialize"] = {"server": init.server_info.model_dump() if init.server_info else None,
                                  "protocol": init.protocol_version, "tool_count": len(tools)}

            login = payload(await sess.call_tool("apple_login", {}))
            sid = login.get("session_id") if isinstance(login, dict) else None
            EVID["apple_login"] = {"ok": bool(sid), "account": login.get("account"),
                                   "capabilities": login.get("capabilities")} if isinstance(login, dict) else login

            # Contacts: safe zero-match probe
            probe_res = payload(await sess.call_tool("contacts_search",
                                                     {"session_id": sid, "query": probe, "limit": 5}))
            n = len(probe_res.get("contacts", probe_res)) if isinstance(probe_res, (dict, list)) else None
            EVID["contacts_search_probe"] = {"probe": probe, "result_count": n,
                                             "is_error": probe_res.get("error") if isinstance(probe_res, dict) else None}

            # contacts_read path: deliberately non-existent id (no real record touched)
            fake = "acceptance-nonexistent-" + probe
            try:
                rr = payload(await sess.call_tool("contacts_read", {"session_id": sid, "contact_id": fake}))
                EVID["contacts_read_bogus_id"] = {"handled": True, "response": rr if isinstance(rr, str) else
                                                  {k: rr.get(k) for k in list(rr)[:4]} if isinstance(rr, dict) else rr}
            except Exception as e:
                EVID["contacts_read_bogus_id"] = {"handled": True, "raised": f"{type(e).__name__}: {str(e)[:160]}"}

            # Calendar
            cal = payload(await sess.call_tool("calendar_list", {"session_id": sid}))
            EVID["calendar_list"] = summarize_cal_list(cal)

            start = time.strftime("%Y-%m-%dT00:00:00", time.localtime(time.time() - 7 * 86400))
            end = time.strftime("%Y-%m-%dT23:59:59", time.localtime(time.time() + 7 * 86400))
            ev = payload(await sess.call_tool("calendar_list_events",
                                              {"session_id": sid, "start": start, "end": end}))
            EVID["calendar_list_events"] = dict([("window", f"{start} .. {end}")] + list(summarize_events(ev).items()))

            # Reminders
            rl = payload(await sess.call_tool("reminders_lists", {"session_id": sid}))
            EVID["reminders_lists"] = summarize_rem_lists(rl)
            ri = payload(await sess.call_tool("reminders_list", {"session_id": sid, "limit": 50}))
            EVID["reminders_list"] = summarize_rem_items(ri)

            # Session close
            wd = payload(await sess.call_tool("work_done", {"session_id": sid}))
            EVID["work_done"] = wd if isinstance(wd, (dict, list)) else str(wd)[:200]

    await hc.aclose()
    out = os.path.join(HERE, "evidence.json")
    json.dump(EVID, open(out, "w"), ensure_ascii=False, indent=2)
    print(json.dumps(EVID, ensure_ascii=False, indent=2))


asyncio.run(main())
