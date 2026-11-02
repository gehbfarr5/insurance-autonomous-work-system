from __future__ import annotations

import hashlib
import hmac
import re
from dataclasses import dataclass, field
from enum import Enum

from .errors import PrivacyMaskUnverifiedError


class MaskStatus(str, Enum):
    VERIFIED = "verified"
    UNVERIFIED = "unverified"


REQUIRED_REDACTED_REGIONS = frozenset(
    {
        "identity_number",
        "family_member_data",
        "policy_data",
        "premium_data",
    }
)
_POLICY_ID_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:-]{0,63}$")
_SHA256_RE = re.compile(r"^[a-f0-9]{64}$")


@dataclass(frozen=True, repr=False)
class PrivacyMaskResult:
    """Output contract for a separately reviewed privacy-mask processor.

    This package intentionally does not implement a family-card mask. The
    caller must not set VERIFIED until a template-specific masker has passed
    visual and adversarial boundary checks.
    """

    status: MaskStatus
    source_sha256: str | None
    masked_image_bytes: bytes | None = field(repr=False)
    masked_mime_type: str | None
    policy_id: str | None
    redacted_regions: frozenset[str] = frozenset()

    def __repr__(self) -> str:
        return f"PrivacyMaskResult(status={self.status.value!r}, image=<redacted>)"


def source_sha256(image_bytes: bytes) -> str:
    """Return an in-memory source-image digest without retaining the image."""
    return hashlib.sha256(image_bytes).hexdigest()


def assert_mask_verified(
    source_bytes: bytes,
    result: PrivacyMaskResult | None,
    *,
    request_id: str,
) -> tuple[bytes, str, str]:
    if result is None or result.status != MaskStatus.VERIFIED:
        raise PrivacyMaskUnverifiedError(request_id=request_id)
    if (
        result.source_sha256 is None
        or not _SHA256_RE.fullmatch(result.source_sha256)
        or not hmac.compare_digest(result.source_sha256, source_sha256(source_bytes))
    ):
        raise PrivacyMaskUnverifiedError(request_id=request_id)
    if (
        not isinstance(result.masked_image_bytes, bytes)
        or not result.masked_image_bytes
        or not isinstance(result.masked_mime_type, str)
        or not isinstance(result.policy_id, str)
        or not _POLICY_ID_RE.fullmatch(result.policy_id)
        or not REQUIRED_REDACTED_REGIONS.issubset(result.redacted_regions)
    ):
        raise PrivacyMaskUnverifiedError(request_id=request_id)
    return result.masked_image_bytes, result.masked_mime_type, result.policy_id
