"""WP11-B reproduction: Baidu-style character candidates.

Fictitious table only. No real customer data.

Each character carries ten candidates: the first candidate equals the
character itself and the remaining candidates differ, matching Baidu
handwriting output shape. Under the current ``_has_ambiguous_character``
rule (any differing candidate means ambiguous) this table extracts
nothing and returns REVIEW_REQUIRED. After the WP11-B fix, this test
is expected to pass with DECISION READY and all four fields present.
It is intentionally a failing test on the 0.6.0 baseline.
"""
import unittest

from muse_customer_card_ocr import (
    BoundingBox,
    CharacterCandidate,
    OcrBlock,
    OcrCharacter,
    OcrResult,
    extract_primary_customer,
)


def _chars(text):
    out = []
    for ch in text:
        candidates = [CharacterCandidate(text=ch)]
        for dummy in ("X", "Y", "Z", "W", "V", "U", "T", "S", "R"):
            candidates.append(CharacterCandidate(text=dummy))
        out.append(OcrCharacter(text=ch, candidates=tuple(candidates)))
    return tuple(out)


def _block(text, left, top, width):
    return OcrBlock(
        text=text,
        location=BoundingBox(left=left, top=top, width=width, height=20),
        characters=_chars(text),
    )


class Wp11bAmbiguousCharReproTests(unittest.TestCase):
    def test_baidu_style_candidates_do_not_block_table_extraction(self):
        blocks = [
            _block("姓名", 40, 20, 40),
            _block("手机", 230, 20, 40),
            _block("身份证号", 430, 20, 80),
            _block("出生日期", 750, 20, 80),
            _block("虚构客户甲", 40, 50, 120),
            _block("13800001111", 230, 50, 110),
            _block("110101199001010015", 430, 50, 190),
            _block("1990年1月1日", 750, 50, 110),
        ]
        result = OcrResult(
            status="success",
            blocks=tuple(blocks),
            request_id="synthetic-wp11b-repro",
            service_log_id=None,
            image_mime_type="image/jpeg",
            image_width=1200,
            image_height=1800,
            upload_mode="full_image_authorized",
        )
        extraction = extract_primary_customer(result)
        self.assertEqual(extraction.decision, "READY")
        self.assertEqual(extraction.status, "ready")
        self.assertEqual(extraction.review_reasons, ())
        self.assertTrue(extraction.fields.name)
        self.assertTrue(extraction.fields.mobile)
        self.assertTrue(extraction.fields.birthday)
        self.assertTrue(extraction.fields.identity_number)


if __name__ == "__main__":
    unittest.main()
