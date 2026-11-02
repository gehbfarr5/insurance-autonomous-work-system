from __future__ import annotations

import io
from dataclasses import dataclass
from pathlib import Path
from typing import TypeAlias

from PIL import Image, ImageOps, UnidentifiedImageError

from .errors import ImageInputError, ImageTooLargeError


ImageSource: TypeAlias = bytes | bytearray | memoryview | str | Path
DEFAULT_ATTACHMENT_ROOT = Path.home() / "workspace" / "user" / "files"
MAX_INPUT_BYTES = 32 * 1024 * 1024
MAX_IMAGE_PIXELS = 50_000_000
MAX_IMAGE_SIDE = 4096
MIN_IMAGE_SIDE = 15
JPEG_QUALITY = 92
SUPPORTED_MIME_TYPES = frozenset({"image/jpeg", "image/png"})


@dataclass(frozen=True)
class ImageData:
    image_bytes: bytes
    mime_type: str


@dataclass(frozen=True)
class PreparedImage:
    image_bytes: bytes
    mime_type: str
    width: int
    height: int


def normalize_mime_type(mime_type: str | None) -> str | None:
    if mime_type is None:
        return None
    value = mime_type.split(";", 1)[0].strip().lower()
    if value == "image/jpg":
        value = "image/jpeg"
    return value


def read_image_source(
    source: ImageSource,
    *,
    mime_type: str | None,
    allowed_root: str | Path | None,
    request_id: str,
) -> ImageData:
    if isinstance(source, (bytes, bytearray, memoryview)):
        image_bytes = bytes(source)
    elif isinstance(source, (str, Path)):
        image_bytes = _read_controlled_path(
            Path(source),
            allowed_root=Path(allowed_root) if allowed_root is not None else DEFAULT_ATTACHMENT_ROOT,
            request_id=request_id,
        )
    else:
        raise ImageInputError(request_id=request_id)

    if not image_bytes:
        raise ImageInputError(request_id=request_id)
    if len(image_bytes) > MAX_INPUT_BYTES:
        raise ImageTooLargeError(request_id=request_id)
    detected_mime = _inspect_image(image_bytes, request_id=request_id)
    declared_mime = normalize_mime_type(mime_type)
    if declared_mime is not None:
        if declared_mime not in SUPPORTED_MIME_TYPES or declared_mime != detected_mime:
            raise ImageInputError(request_id=request_id)
    return ImageData(image_bytes=image_bytes, mime_type=detected_mime)


def prepare_ocr_image(
    image_bytes: bytes,
    *,
    mime_type: str | None,
    request_id: str,
) -> PreparedImage:
    detected_mime = _inspect_image(image_bytes, request_id=request_id)
    declared_mime = normalize_mime_type(mime_type)
    if declared_mime is not None and declared_mime != detected_mime:
        raise ImageInputError(request_id=request_id)

    try:
        with Image.open(io.BytesIO(image_bytes)) as opened:
            image = ImageOps.exif_transpose(opened)
            image.load()
            width, height = image.size
            if width < MIN_IMAGE_SIDE or height < MIN_IMAGE_SIDE:
                raise ImageInputError(request_id=request_id)
            if width * height > MAX_IMAGE_PIXELS:
                raise ImageTooLargeError(request_id=request_id)
            scale = min(1.0, MAX_IMAGE_SIDE / max(width, height))
            if scale < 1.0:
                target = (max(1, round(width * scale)), max(1, round(height * scale)))
                image = image.resize(target, Image.Resampling.LANCZOS)
            rgb = _to_rgb_on_white(image)
            output = io.BytesIO()
            rgb.save(
                output,
                format="JPEG",
                quality=JPEG_QUALITY,
                optimize=True,
            )
            normalized = output.getvalue()
            normalized_width, normalized_height = rgb.size
    except (ImageInputError, ImageTooLargeError):
        raise
    except (UnidentifiedImageError, Image.DecompressionBombError, OSError, ValueError):
        raise ImageInputError(request_id=request_id) from None

    if max(normalized_width, normalized_height) > MAX_IMAGE_SIDE:
        raise ImageInputError(request_id=request_id)
    if min(normalized_width, normalized_height) < MIN_IMAGE_SIDE:
        raise ImageInputError(request_id=request_id)
    if len(normalized) > MAX_INPUT_BYTES:
        raise ImageTooLargeError(request_id=request_id)
    return PreparedImage(
        image_bytes=normalized,
        mime_type="image/jpeg",
        width=normalized_width,
        height=normalized_height,
    )


def _read_controlled_path(
    path: Path,
    *,
    allowed_root: Path,
    request_id: str,
) -> bytes:
    try:
        root = allowed_root.expanduser().resolve()
        resolved_path = path.expanduser().resolve(strict=True)
        resolved_path.relative_to(root)
        size = resolved_path.stat().st_size
        if size > MAX_INPUT_BYTES:
            raise ImageTooLargeError(request_id=request_id)
        return resolved_path.read_bytes()
    except ImageTooLargeError:
        raise
    except (OSError, ValueError):
        raise ImageInputError(request_id=request_id) from None


def _inspect_image(image_bytes: bytes, *, request_id: str) -> str:
    try:
        with Image.open(io.BytesIO(image_bytes)) as image:
            if image.format == "JPEG":
                mime_type = "image/jpeg"
            elif image.format == "PNG":
                mime_type = "image/png"
            else:
                raise ImageInputError(request_id=request_id)
            width, height = image.size
            if width < MIN_IMAGE_SIDE or height < MIN_IMAGE_SIDE:
                raise ImageInputError(request_id=request_id)
            if width * height > MAX_IMAGE_PIXELS:
                raise ImageTooLargeError(request_id=request_id)
            image.verify()
            return mime_type
    except (ImageInputError, ImageTooLargeError):
        raise
    except (UnidentifiedImageError, Image.DecompressionBombError, OSError, ValueError):
        raise ImageInputError(request_id=request_id) from None


def _to_rgb_on_white(image: Image.Image) -> Image.Image:
    if image.mode in ("RGBA", "LA") or "transparency" in image.info:
        rgba = image.convert("RGBA")
        background = Image.new("RGB", rgba.size, "white")
        background.paste(rgba, mask=rgba.getchannel("A"))
        return background
    if image.mode in ("RGB", "L"):
        return image.convert("RGB")
    return image.convert("RGB")
