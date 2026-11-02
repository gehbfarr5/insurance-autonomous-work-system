"""MUSE customer-card OCR client.

The public entry point refuses external OCR unless a verified privacy-mask
result is supplied. This package does not yet contain a family-card mask
processor.
"""

from .client import (
    BAIDU_HANDWRITING_URL,
    BaiduCredentials,
    BaiduOcrClient,
    recognize_customer_card,
)
from .errors import (
    AuthenticationError,
    HttpError,
    ImageInputError,
    ImageTooLargeError,
    InvalidResponseError,
    MissingCredentialsError,
    NetworkError,
    OcrError,
    PermissionDeniedError,
    PrivacyMaskUnverifiedError,
    ProviderError,
    QuotaExceededError,
    RateLimitError,
    RequestTimeoutError,
)
from .models import (
    BoundingBox,
    CharacterCandidate,
    OcrBlock,
    OcrCharacter,
    OcrResult,
    ProbabilityStats,
)
from .privacy import (
    REQUIRED_REDACTED_REGIONS,
    MaskStatus,
    PrivacyMaskResult,
    source_sha256,
)

__all__ = [
    "BAIDU_HANDWRITING_URL",
    "AuthenticationError",
    "BaiduCredentials",
    "BaiduOcrClient",
    "BoundingBox",
    "CharacterCandidate",
    "HttpError",
    "ImageInputError",
    "ImageTooLargeError",
    "InvalidResponseError",
    "MaskStatus",
    "MissingCredentialsError",
    "NetworkError",
    "OcrBlock",
    "OcrCharacter",
    "OcrError",
    "OcrResult",
    "PermissionDeniedError",
    "PrivacyMaskResult",
    "PrivacyMaskUnverifiedError",
    "ProviderError",
    "ProbabilityStats",
    "QuotaExceededError",
    "RateLimitError",
    "REQUIRED_REDACTED_REGIONS",
    "RequestTimeoutError",
    "recognize_customer_card",
    "source_sha256",
]
