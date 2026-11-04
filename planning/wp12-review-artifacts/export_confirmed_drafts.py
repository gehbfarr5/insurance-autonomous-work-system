import csv
import json
import os
import re
from pathlib import Path

csv_path = Path("/Users/jin/Library/Mobile Documents/com~apple~CloudDocs/00_Inbox_临时收件箱/OCR 30 测试/00_人工验收核对表_reviewed.csv")
out_dir = Path("/tmp/wp12-confirmed-drafts")
out_dir.mkdir(parents=True, exist_ok=True)

with open(csv_path, 'r', encoding='utf-8-sig') as f:
    rows = list(csv.reader(f))

header = rows[0]
data_rows = rows[1:]

success_count = 0
for r in data_rows:
    img_name, name, gender, mobile, id_num, address, bday, status = r
    
    # normalize birthday to YYYY-MM-DD
    # e.g. 1964年08月22日 -> 1964-08-22
    bday_clean = bday.replace(" ", "")
    m = re.search(r"(\d{4})年(\d{1,2})月(\d{1,2})日", bday_clean)
    if m:
        bday_norm = f"{m.group(1)}-{int(m.group(2)):02d}-{int(m.group(3)):02d}"
    else:
        bday_norm = bday_clean

    draft_payload = {
        "extraction_status": "MANUALLY_REVIEWED",
        "review_status": "USER_CONFIRMED" if status == "PASS" else "REJECTED",
        "address_book_id": "icloud-family-card-main",
        "name": name,
        "gender": gender,
        "mobile": mobile,
        "birthday": bday_norm,
        "identity_number": id_num,
        "address": address,
        "other_phones": [],
        "review_reasons": []
    }
    
    stem = Path(img_name).stem
    draft_file = out_dir / f"{stem}_draft.json"
    with open(draft_file, "w", encoding="utf-8") as fp:
        json.dump(draft_payload, fp, indent=2, ensure_ascii=False)
    os.chmod(draft_file, 0o600)
    success_count += 1

print(f"Successfully generated {success_count} USER_CONFIRMED drafts in {out_dir}")
