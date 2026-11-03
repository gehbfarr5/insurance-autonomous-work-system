#!/usr/bin/env python3
"""WP10 Phase 4: confirmed-draft create + readback only.
Reads confirmed fields from stdin JSON (no values hard-coded in this file).
Never prints name, mobile, ID, address, session_id, or contact_id values.
Never calls contacts_update or contacts_delete. Creates exactly one contact
only when dedup decision is ALLOW_CREATE; otherwise stops without creating.
"""
import sys, json, re
sys.path.insert(0, "/home/hatch/workspace/carddav-mcp-client")
import mcp_client

def norm_mobile(m):
    d = re.sub(r"\D", "", m or "")
    if len(d) == 13 and d.startswith("86"):
        d = d[2:]
    return d

def mcp_call(tool, args, mid):
    res = mcp_client._mcp_call_resilient("tools/call", {"name": tool, "arguments": args}, mid)
    txt = res["content"][0]["text"]
    return json.loads(txt)

def get_name(c):
    if not isinstance(c, dict):
        return ""
    n = c.get("name") or {}
    return n.get("full") if isinstance(n, dict) else str(n)

def get_phones(c):
    out = []
    if not isinstance(c, dict):
        return out
    for p in c.get("phones", []) or []:
        if isinstance(p, dict) and p.get("value"):
            out.append(p.get("value"))
        elif isinstance(p, str):
            out.append(p)
    return out

def main():
    data = json.load(sys.stdin)
    name = data["name"]
    mobile = data["mobile"]
    gender = data["gender"]
    birthday = data["birthday"]
    identity = data["identity_number"]
    note_lines = [f"性别：{gender}", f"身份证号：{identity}"]
    note_text = "\n".join(note_lines)
    login = mcp_call("apple_login", {}, 70)
    sid = login.get("session_id")
    caps = login.get("capabilities", {})
    print("LOGIN_OK:", bool(sid))
    print("CAP_CONTACTS_WRITE:", bool(caps.get("contactsWrite")))
    if not sid or not caps.get("contactsWrite"):
        print("CREATE_RUN: False")
        print("FINAL_RESULT: FAIL")
        return 1
    r_name = mcp_call("contacts_search", {"session_id": sid, "query": name, "limit": 50}, 71)
    r_mobile = mcp_call("contacts_search", {"session_id": sid, "query": mobile, "limit": 50}, 72)
    pre_name = r_name.get("contacts", []) if isinstance(r_name, dict) else []
    pre_mobile = r_mobile.get("contacts", []) if isinstance(r_mobile, dict) else []
    seen = {}
    for c in pre_name + pre_mobile:
        key = c.get("contact_id") if isinstance(c, dict) else None
        if key is None:
            key = (get_name(c), tuple(get_phones(c)))
        seen[key] = c
    candidates = list(seen.values())
    dn = name.strip()
    dm = norm_mobile(mobile)
    matching = []
    for c in candidates:
        cn = get_name(c).strip()
        cm_list = [norm_mobile(v) for v in get_phones(c)]
        if cn == dn or dm in cm_list:
            matching.append(c)
    if not matching:
        dec = "ALLOW_CREATE"
    elif len(matching) > 1:
        dec = "MANUAL_REVIEW"
    else:
        c0 = matching[0]
        if get_name(c0).strip() == dn and dm in [norm_mobile(v) for v in get_phones(c0)]:
            dec = "EXISTS_SKIP"
        else:
            dec = "MANUAL_REVIEW"
    print("PRE_NAME_COUNT:", len(pre_name))
    print("PRE_MOBILE_COUNT:", len(pre_mobile))
    print("PRE_UNIQUE_CANDIDATES:", len(candidates))
    print("DEDUP_DECISION:", dec)
    if dec != "ALLOW_CREATE":
        print("CREATE_RUN: False")
        print("FINAL_RESULT: FAIL")
        return 1
    contact = {
        "name": {"full": name},
        "phones": [{"value": mobile, "type": ["cell"], "primary": True}],
        "birthday": birthday,
        "note": note_text,
    }
    created = mcp_call("contacts_create", {"session_id": sid, "contact": contact}, 73)
    contact_id = None
    if isinstance(created, dict):
        contact_id = created.get("contact_id") or created.get("id")
        if not contact_id and isinstance(created.get("contact"), dict):
            contact_id = created["contact"].get("contact_id")
    print("CREATE_RUN: True")
    print("CREATE_OK:", bool(contact_id))
    if not contact_id:
        print("FINAL_RESULT: FAIL")
        return 1
    read = mcp_call("contacts_read", {"session_id": sid, "contact_id": contact_id}, 74)
    read_contact = read
    if isinstance(read, dict) and "contact" in read and isinstance(read["contact"], dict):
        read_contact = read["contact"]
    name_match = get_name(read_contact).strip() == name
    phones = get_phones(read_contact)
    mobile_match = dm in [norm_mobile(v) for v in phones]
    # Primary check: read back phones with primary flag, if present
    primary_match = mobile_match
    if isinstance(read_contact, dict) and isinstance(read_contact.get("phones"), list):
        prim_vals = []
        for p in read_contact["phones"]:
            if isinstance(p, dict) and p.get("primary") is True:
                prim_vals.append(p.get("value"))
        if prim_vals:
            primary_match = dm in [norm_mobile(v) for v in prim_vals]
    birthday_match = (read_contact.get("birthday") if isinstance(read_contact, dict) else None) == birthday
    note_val = read_contact.get("note") if isinstance(read_contact, dict) else None
    note_lines_read = note_val.splitlines() if isinstance(note_val, str) else []
    note_has_gender = any(l == note_lines[0] for l in note_lines_read)
    note_has_id = any(l == note_lines[1] for l in note_lines_read)
    note_forbidden = False
    if isinstance(note_val, str):
        for bad in ["保单", "金额", "家庭成员", "虚构", "WP9测试", "父亲", "母亲", "配偶", "子女"]:
            if bad in note_val:
                note_forbidden = True
    address_present = False
    if isinstance(read_contact, dict) and read_contact.get("addresses"):
        address_present = bool(read_contact["addresses"])
    print("READBACK_NAME_MATCH:", name_match)
    print("READBACK_MOBILE_MATCH:", mobile_match)
    print("READBACK_PRIMARY_MATCH:", primary_match)
    print("READBACK_BIRTHDAY_MATCH:", birthday_match)
    print("READBACK_NOTE_LINES:", len(note_lines_read))
    print("READBACK_NOTE_HAS_GENDER:", note_has_gender)
    print("READBACK_NOTE_HAS_ID:", note_has_id)
    print("READBACK_NOTE_FORBIDDEN:", note_forbidden)
    print("READBACK_ADDRESS_PRESENT:", address_present)
    readback_ok = name_match and mobile_match and primary_match and birthday_match and note_has_gender and note_has_id and not note_forbidden and not address_present
    print("READBACK_OK:", readback_ok)
    print("FINAL_RESULT:", "PASS" if readback_ok else "FAIL")
    return 0 if readback_ok else 1

if __name__ == "__main__":
    raise SystemExit(main())
