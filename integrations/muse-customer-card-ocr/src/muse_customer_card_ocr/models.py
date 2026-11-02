from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any


@dataclass(frozen=True)
class BoundingBox:
    """Coordinates reported by Baidu, relative to the normalized JPEG sent."""

    left: int
    top: int
    width: int
    height: int

    def to_dict(self) -> dict[str, int]:
        return {
            "left": self.left,
            "top": self.top,
            "width": self.width,
            "height": self.height,
        }


@dataclass(frozen=True, repr=False)
class CharacterCandidate:
    text: str = field(repr=False)
    probability: str | int | float | None = None

    def __repr__(self) -> str:
        return "CharacterCandidate(text=<redacted>)"

    def to_dict(self) -> dict[str, str | int | float]:
        result: dict[str, str | int | float] = {"text": self.text}
        if self.probability is not None:
            result["probability"] = self.probability
        return result


@dataclass(frozen=True, repr=False)
class OcrCharacter:
    text: str | None = field(default=None, repr=False)
    location: BoundingBox | None = None
    candidates: tuple[CharacterCandidate, ...] = ()

    def __repr__(self) -> str:
        return "OcrCharacter(text=<redacted>)"

    def to_dict(self) -> dict[str, Any]:
        result: dict[str, Any] = {}
        if self.text is not None:
            result["text"] = self.text
        if self.location is not None:
            result["location"] = self.location.to_dict()
        if self.candidates:
            result["candidates"] = [item.to_dict() for item in self.candidates]
        return result


@dataclass(frozen=True)
class ProbabilityStats:
    """Only statistics actually returned by the OCR service are populated."""

    average: str | int | float | None = None
    variance: str | int | float | None = None
    minimum: str | int | float | None = None

    def to_dict(self) -> dict[str, str | int | float]:
        result: dict[str, str | int | float] = {}
        if self.average is not None:
            result["average"] = self.average
        if self.variance is not None:
            result["variance"] = self.variance
        if self.minimum is not None:
            result["min"] = self.minimum
        return result


@dataclass(frozen=True, repr=False)
class OcrBlock:
    text: str = field(repr=False)
    location: BoundingBox | None = None
    probability: ProbabilityStats | None = None
    characters: tuple[OcrCharacter, ...] = ()

    def __repr__(self) -> str:
        return (
            "OcrBlock(text=<redacted>, "
            f"location={self.location!r}, characters={len(self.characters)})"
        )

    def to_dict(self) -> dict[str, Any]:
        result: dict[str, Any] = {"text": self.text}
        if self.location is not None:
            result["location"] = self.location.to_dict()
        if self.probability is not None:
            result["probability"] = self.probability.to_dict()
        if self.characters:
            result["characters"] = [item.to_dict() for item in self.characters]
        return result


@dataclass(frozen=True, repr=False)
class OcrResult:
    status: str
    blocks: tuple[OcrBlock, ...]
    request_id: str
    service_log_id: str | None
    image_mime_type: str
    image_width: int
    image_height: int
    mask_policy_id: str

    @property
    def text(self) -> str:
        return "\n".join(block.text for block in self.blocks if block.text)

    def __repr__(self) -> str:
        return (
            "OcrResult("
            f"status={self.status!r}, block_count={len(self.blocks)}, "
            f"request_id={self.request_id!r}, text=<redacted>)"
        )

    def to_dict(self) -> dict[str, Any]:
        """Return OCR text for the caller; callers must treat it as sensitive."""
        result: dict[str, Any] = {
            "status": self.status,
            "text": self.text,
            "blocks": [block.to_dict() for block in self.blocks],
            "request_id": self.request_id,
            "image": {
                "mime_type": self.image_mime_type,
                "width": self.image_width,
                "height": self.image_height,
            },
            "privacy": {
                "status": "verified",
                "mask_policy_id": self.mask_policy_id,
            },
        }
        if self.service_log_id is not None:
            result["service_log_id"] = self.service_log_id
        return result
