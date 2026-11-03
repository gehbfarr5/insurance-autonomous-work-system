from __future__ import annotations

import io
import tempfile
import unittest
from pathlib import Path

from PIL import Image

from muse_customer_card_ocr import ImageInputError, ImageTooLargeError
from muse_customer_card_ocr.images import (
    MAX_IMAGE_SIDE,
    MAX_INPUT_BYTES,
    prepare_ocr_image,
    read_image_source,
)


def make_image_bytes(
    image_format: str = "JPEG",
    *,
    size: tuple[int, int] = (80, 40),
    orientation: int | None = None,
) -> bytes:
    image = Image.new("RGB", size, "white")
    output = io.BytesIO()
    kwargs = {}
    if orientation is not None:
        exif = Image.Exif()
        exif[274] = orientation
        kwargs["exif"] = exif
    image.save(output, format=image_format, **kwargs)
    return output.getvalue()


class ImagePreparationTests(unittest.TestCase):
    def test_jpeg_bytes_are_accepted(self):
        result = read_image_source(
            make_image_bytes(),
            mime_type="image/jpeg",
            allowed_root=None,
            request_id="synthetic-request",
        )
        self.assertEqual(result.mime_type, "image/jpeg")

    def test_png_is_accepted_and_normalized_to_jpeg(self):
        source = make_image_bytes("PNG")
        result = prepare_ocr_image(
            source,
            mime_type="image/png",
            request_id="synthetic-request",
        )
        self.assertEqual(result.mime_type, "image/jpeg")
        with Image.open(io.BytesIO(result.image_bytes)) as normalized:
            self.assertEqual(normalized.format, "JPEG")

    def test_large_dimensions_are_scaled_to_provider_maximum(self):
        result = prepare_ocr_image(
            make_image_bytes(size=(5000, 2500)),
            mime_type="image/jpeg",
            request_id="synthetic-request",
        )
        self.assertLessEqual(max(result.width, result.height), MAX_IMAGE_SIDE)
        self.assertEqual((result.width, result.height), (MAX_IMAGE_SIDE, 2048))

    def test_exif_orientation_is_applied_before_result_dimensions(self):
        result = prepare_ocr_image(
            make_image_bytes(size=(40, 20), orientation=6),
            mime_type="image/jpeg",
            request_id="synthetic-request",
        )
        self.assertEqual((result.width, result.height), (20, 40))
        with Image.open(io.BytesIO(result.image_bytes)) as normalized:
            self.assertNotIn(274, normalized.getexif())

    def test_path_is_confined_to_configured_attachment_root(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp) / "files"
            root.mkdir()
            allowed_file = root / "synthetic.jpg"
            allowed_file.write_bytes(make_image_bytes())
            outside_file = Path(temp) / "outside.jpg"
            outside_file.write_bytes(make_image_bytes())

            allowed = read_image_source(
                allowed_file,
                mime_type="image/jpeg",
                allowed_root=root,
                request_id="synthetic-request",
            )
            self.assertTrue(allowed.image_bytes)
            with self.assertRaises(ImageInputError):
                read_image_source(
                    outside_file,
                    mime_type="image/jpeg",
                    allowed_root=root,
                    request_id="synthetic-request",
                )
            self.assertTrue(allowed_file.exists())

    def test_heic_and_mime_mismatch_are_rejected(self):
        source = make_image_bytes()
        with self.assertRaises(ImageInputError):
            read_image_source(
                source,
                mime_type="image/png",
                allowed_root=None,
                request_id="synthetic-request",
            )
        with self.assertRaises(ImageInputError):
            prepare_ocr_image(
                source,
                mime_type="image/heic",
                request_id="synthetic-request",
            )

    def test_input_byte_limit_is_enforced(self):
        with self.assertRaises(ImageTooLargeError):
            read_image_source(
                b"x" * (MAX_INPUT_BYTES + 1),
                mime_type=None,
                allowed_root=None,
                request_id="synthetic-request",
            )


if __name__ == "__main__":
    unittest.main()
