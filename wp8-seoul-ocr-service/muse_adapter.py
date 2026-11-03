#!/usr/bin/env python3
"""Muse adapter: call Seoul OCR via existing SSH, parse fields, draft only.

Usage: muse_adapter.py <image_path>
  - Runs Seoul CLI via ssh-seoul.sh, image bytes on stdin to Seoul,
    Seoul CLI reads AK/SK locally, calls Baidu, returns OCR JSON on stdout.
  - Converts words_result to package OcrResult blocks, runs
    extract_primary_customer + map_to_icloud_fields.
  - Prints only status, counts, presence booleans, review reasons.
    Never prints a full ID number, full mobile, Token, AK, or SK.
  - Never writes iCloud. Draft file is written only when mapping is ready,
    to a local draft path given by --draft-out, labelled fictitious.
"""
import sys, json, subprocess, uuid
from pathlib import Path
sys.path.insert(0, "/home/hatch/workspace/wp7b-ocr-checkout/integrations/muse-customer-card-ocr/src")
from muse_customer_card_ocr.models import OcrBlock, OcrResult
from muse_customer_card_ocr.fields import extract_primary_customer
from muse_customer_card_ocr.icloud_mapping import map_to_icloud_fields
from muse_customer_card_ocr.errors import ManualReviewRequiredError
from PIL import Image

def main() -> int:
    import argparse
    p = argparse.ArgumentParser()
    p.add_argument("image")
    p.add_argument("--draft-out", default=None)
    p.add_argument("--ssh-script", default="/home/hatch/workspace/server/ssh-seoul.sh")
    p.add_argument("--seoul-service", default="/home/ubuntu/baidu-ocr-service/baidu_ocr_service.py")
    args = p.parse_args()
    image_path = Path(args.image)
    image_bytes = image_path.read_bytes()
    with Image.open(image_path) as im:
        w, h = im.size
    cmd = [args.ssh_script, f"python3 {args.seoul_service} --stdin-image"]
    completed = subprocess.run(cmd, input=image_bytes, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=120)
    if completed.returncode != 0:
        print("SEOUL_CLI_FAILED returncode:", completed.returncode)
        print("SEOUL_CLI_STDERR_LEN:", len(completed.stderr))
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
    try:
        draft = map_to_icloud_fields(extraction)
        print("CONTACT_DRAFT: ready")
        print("NAME_PRESENT:", bool(draft.name_full))
        print("MOBILE_PRESENT:", bool(draft.phone_mobile))
        print("BIRTHDAY:", draft.birthday.isoformat() if draft.birthday else "")
        print("NOTE_LINES:", len(draft.note.splitlines()) if draft.note else 0)
        if args.draft_out:
            text = ("虚构测试联系人草稿 请勿导入 请勿写入 iCloud\n"
                    f"姓名：{draft.name_full}\n"
                    f"手机：{draft.phone_mobile}\n"
                    f"生日：{draft.birthday.isoformat() if draft.birthday else ''}\n"
                    f"备注：\n{draft.note if draft.note else ''}\n"
                    f"草稿状态：ready\n")
            Path(args.draft_out).write_text(text, encoding="utf-8")
            print("DRAFT_FILE:", args.draft_out)
    except ManualReviewRequiredError:
        print("CONTACT_DRAFT: needs_manual_review")
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
