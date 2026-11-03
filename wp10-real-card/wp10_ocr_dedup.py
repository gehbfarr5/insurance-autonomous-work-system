#!/usr/bin/env python3
"""WP10 real card: Seoul OCR -> field parsing -> iCloud dedup search only.
No iCloud create/update/delete. No draft file. Prints only status, counts,
decisions, review reasons, and presence booleans. Never prints name, mobile,
ID, address values, session_id, contact_id, Token, AK, or SK, or full OCR text.
"""
import sys, json, re, subprocess, uuid
from pathlib import Path
sys.path.insert(0, "/home/hatch/workspace/wp7b-ocr-checkout/integrations/muse-customer-card-ocr/src")
sys.path.insert(0, "/home/hatch/workspace/carddav-mcp-client")
from muse_customer_card_ocr.models import OcrBlock, OcrResult
from muse_customer_card_ocr.fields import extract_primary_customer
from PIL import Image
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
    image_path = Path(sys.argv[1])
    image_bytes = image_path.read_bytes()
    with Image.open(image_path) as im:
        w, h = im.size
    cmd = ["/home/hatch/workspace/server/ssh-seoul.sh", "python3 /home/ubuntu/baidu-ocr-service/baidu_ocr_service.py --stdin-image"]
    completed = subprocess.run(cmd, input=image_bytes, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=120)
    if completed.returncode != 0:
        print("SEOUL_CLI_FAILED returncode:", completed.returncode)
        return 1
    try:
        payload = json.loads(completed.stdout.decode("utf-8"))
    except Exception:
        print("SEOUL_CLI_INVALID_JSON")
        return 1
    print("SEOUL_OK:", payload.get("ok"))
    print("HTTP_STATUS:", payload.get("http_status"))
    print("ERROR_CODE:", payload.get("error_code"))
    print("FIRST_BYTE_MS:", payload.get("first_byte_ms"))
    print("TOTAL_MS:", payload.get("total_ms"))
    print("TOKEN_REFRESHED:", payload.get("token_refreshed"))
    if not payload.get("ok"):
        print("OCR_ERROR:", payload.get("error"))
        return 1
    words = payload.get("words_result") or []
    print("WORDS_COUNT:", len(words))
    blocks = tuple(OcrBlock(text=(item.get("words") or "")) for item in words if isinstance(item, dict))
    result = OcrResult(status="success", blocks=blocks, request_id=uuid.uuid4().hex,
                       service_log_id=None, image_mime_type="image/jpeg",
                       image_width=w, image_height=h, upload_mode="seoul_ocr_service")
    extraction = extract_primary_customer(result)
    print("EXTRACTION_STATUS:", extraction.status)
    print("REVIEW_REASONS:", [r.value for r in extraction.review_reasons])
    f = extraction.fields
    print("NAME_PRESENT:", bool(f.name))
    print("MOBILE_PRESENT:", bool(f.mobile))
    print("BIRTHDAY_PRESENT:", bool(f.birthday))
    print("GENDER_PRESENT:", f.gender is not None)
    print("ID_PRESENT:", bool(f.identity_number))
    print("ADDRESS_PRESENT:", bool(f.address))
    if extraction.status != "ready" or extraction.review_reasons:
        print("DEDUP_DECISION: MANUAL_REVIEW")
        print("DEDUP_REASON: EXTRACTION_NEEDS_REVIEW")
        print("ICLOUD_SEARCH_RUN: False")
        return 0
    # Dedup search only, using parsed name/mobile in memory, never printed
    try:
        login = mcp_call("apple_login", {}, 60)
        sid = login.get("session_id")
        caps = login.get("capabilities", {})
        print("LOGIN_OK:", bool(sid))
        print("CAP_CONTACTS_READ:", bool(caps.get("contactsRead")))
        if not sid or not caps.get("contactsRead"):
            print("DEDUP_DECISION: STOP")
            print("DEDUP_REASON: SEARCH_LOGIN_FAIL")
            return 1
        r_name = mcp_call("contacts_search", {"session_id": sid, "query": f.name, "limit": 50}, 61)
        r_mobile = mcp_call("contacts_search", {"session_id": sid, "query": f.mobile, "limit": 50}, 62)
        pre_name = r_name.get("contacts", []) if isinstance(r_name, dict) else []
        pre_mobile = r_mobile.get("contacts", []) if isinstance(r_mobile, dict) else []
        seen = {}
        for c in pre_name + pre_mobile:
            key = c.get("contact_id") if isinstance(c, dict) else None
            if key is None:
                key = (get_name(c), tuple(get_phones(c)))
            seen[key] = c
        candidates = list(seen.values())
        dn = f.name.strip()
        dm = norm_mobile(f.mobile)
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
            cn0 = get_name(c0).strip()
            cm0 = [norm_mobile(v) for v in get_phones(c0)]
            if cn0 == dn and dm in cm0:
                dec = "EXISTS_SKIP"
            else:
                dec = "MANUAL_REVIEW"
        print("PRE_NAME_COUNT:", len(pre_name))
        print("PRE_MOBILE_COUNT:", len(pre_mobile))
        print("PRE_UNIQUE_CANDIDATES:", len(candidates))
        print("DEDUP_DECISION:", dec)
        print("ICLOUD_SEARCH_RUN: True")
    except Exception as e:
        print("DEDUP_DECISION: STOP")
        print("DEDUP_REASON: SEARCH_FAILED")
        print("SEARCH_ERROR_TYPE:", type(e).__name__)
        return 1
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
