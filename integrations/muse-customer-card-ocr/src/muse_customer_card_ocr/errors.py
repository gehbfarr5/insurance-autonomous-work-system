from __future__ import annotations

import uuid
from typing import ClassVar


class OcrError(RuntimeError):
    """Safe-to-display OCR failure; never includes request or image contents."""

    code: ClassVar[str] = "OCR_ERROR"
    category: ClassVar[str] = "ocr"

    def __init__(
        self,
        *,
        request_id: str | None = None,
        http_status: int | None = None,
        provider_code: int | None = None,
    ) -> None:
        self.request_id = request_id or uuid.uuid4().hex
        self.http_status = http_status
        self.provider_code = provider_code
        parts = [self.code, f"request_id={self.request_id}"]
        if http_status is not None:
            parts.append(f"http_status={http_status}")
        if provider_code is not None:
            parts.append(f"provider_code={provider_code}")
        super().__init__(" ".join(parts))

    def as_dict(self) -> dict[str, str | int]:
        result: dict[str, str | int] = {
            "status": "error",
            "error_category": self.category,
            "error_code": self.code,
            "request_id": self.request_id,
        }
        if self.http_status is not None:
            result["http_status"] = self.http_status
        if self.provider_code is not None:
            result["provider_code"] = self.provider_code
        return result


class MissingCredentialsError(OcrError):
    code = "BAIDU_CREDENTIALS_MISSING"
    category = "configuration"


class PrivacyMaskUnverifiedError(OcrError):
    code = "PRIVACY_MASK_UNVERIFIED"
    category = "privacy"


class ImageInputError(OcrError):
    code = "INVALID_IMAGE"
    category = "input"


class ImageTooLargeError(OcrError):
    code = "IMAGE_TOO_LARGE"
    category = "input"


class RequestTimeoutError(OcrError):
    code = "REQUEST_TIMEOUT"
    category = "network"


class NetworkError(OcrError):
    code = "NETWORK_ERROR"
    category = "network"


class HttpError(OcrError):
    code = "HTTP_ERROR"
    category = "http"


class AuthenticationError(OcrError):
    code = "BAIDU_AUTHENTICATION_FAILED"
    category = "authentication"


class RateLimitError(OcrError):
    code = "BAIDU_RATE_LIMITED"
    category = "rate_limit"


class QuotaExceededError(OcrError):
    code = "BAIDU_QUOTA_EXCEEDED"
    category = "quota"


class PermissionDeniedError(OcrError):
    code = "BAIDU_PERMISSION_DENIED"
    category = "permission"


class InvalidResponseError(OcrError):
    code = "BAIDU_INVALID_RESPONSE"
    category = "response"


class ProviderError(OcrError):
    code = "BAIDU_OCR_FAILED"
    category = "provider"
