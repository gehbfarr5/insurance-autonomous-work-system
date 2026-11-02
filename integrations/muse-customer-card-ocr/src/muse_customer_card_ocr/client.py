from __future__ import annotations

import base64
import json
import re
import uuid
from os import PathLike
from typing import Any
from urllib.parse import urlencode

from .errors import (
    AuthenticationError,
    FullImageOcrNotAuthorizedError,
    HttpError,
    ImageTooLargeError,
    InvalidResponseError,
    MissingSecureConnectorError,
    NetworkError,
    PermissionDeniedError,
    ProviderError,
    QuotaExceededError,
    RateLimitError,
    RequestTimeoutError,
    SecureConnectorFailure,
    SecureConnectorTimeout,
)
from .images import ImageSource, PreparedImage, prepare_ocr_image, read_image_source
from .models import (
    BoundingBox,
    CharacterCandidate,
    OcrBlock,
    OcrCharacter,
    OcrResult,
    ProbabilityStats,
)
from .secure_connector import (
    BearerOcrRequest,
    BearerOcrResponse,
    SecureBearerConnector,
)


BAIDU_HANDWRITING_URL = "https://aip.baidubce.com/rest/2.0/ocr/v1/handwriting"
BAIDU_FORM_BODY_MAX_BYTES = 8 * 1024 * 1024
_SERVICE_LOG_ID_RE = re.compile(r"^[A-Za-z0-9_-]{1,64}$")
_AUTH_PROVIDER_CODES = frozenset({110, 111})
_RATE_LIMIT_PROVIDER_CODES = frozenset({4, 18})
_QUOTA_PROVIDER_CODES = frozenset({17, 19})


class BaiduOcrClient:
    """Image preparation and response parsing behind an injected Bearer port.

    This client has no direct network session and never reads or stores an API
    key. The injected connector is responsible for protected Bearer auth.
    """

    def __init__(
        self,
        connector: SecureBearerConnector | None,
        *,
        timeout: float = 45.0,
    ) -> None:
        if timeout <= 0:
            raise ValueError("timeout must be positive")
        self._connector = connector
        self._timeout = timeout

    def close(self) -> None:
        close = getattr(self._connector, "close", None)
        if callable(close):
            close()

    def recognize(
        self,
        image: ImageSource,
        *,
        full_image_authorized: bool = False,
        mime_type: str | None = None,
        allowed_root: str | PathLike[str] | None = None,
    ) -> OcrResult:
        request_id = uuid.uuid4().hex
        if full_image_authorized is not True:
            raise FullImageOcrNotAuthorizedError(request_id=request_id)
        if self._connector is None:
            raise MissingSecureConnectorError(request_id=request_id)

        source = read_image_source(
            image,
            mime_type=mime_type,
            allowed_root=allowed_root,
            request_id=request_id,
        )
        prepared = prepare_ocr_image(
            source.image_bytes,
            mime_type=source.mime_type,
            request_id=request_id,
        )
        body = _build_form_body(prepared, request_id=request_id)
        request = BearerOcrRequest(
            request_id=request_id,
            method="POST",
            url=BAIDU_HANDWRITING_URL,
            auth_scheme="bearer",
            headers={"Content-Type": "application/x-www-form-urlencoded"},
            body=body,
            timeout_seconds=self._timeout,
        )

        try:
            response = self._connector.send(request)
        except SecureConnectorTimeout:
            raise RequestTimeoutError(request_id=request_id) from None
        except SecureConnectorFailure:
            raise NetworkError(request_id=request_id) from None

        if not isinstance(response, BearerOcrResponse):
            raise InvalidResponseError(request_id=request_id)
        _raise_for_http_status(response.status_code, request_id=request_id)
        payload = _json_payload(response.body, request_id=request_id)
        blocks, service_log_id = _parse_ocr_payload(payload, request_id=request_id)
        return OcrResult(
            status="success",
            blocks=blocks,
            request_id=request_id,
            service_log_id=service_log_id,
            image_mime_type=prepared.mime_type,
            image_width=prepared.width,
            image_height=prepared.height,
            upload_mode="full_image_authorized",
        )


def recognize_customer_card(
    image: ImageSource,
    *,
    full_image_authorized: bool = False,
    mime_type: str | None = None,
    allowed_root: str | PathLike[str] | None = None,
    connector: SecureBearerConnector | None = None,
    client: BaiduOcrClient | None = None,
) -> OcrResult:
    """Recognize one complete image after an explicit call-site opt-in.

    ``full_image_authorized`` is a caller attestation, not a substitute for
    MUSE's consent/authorization policy. No image is cropped or masked here.
    """
    own_client = client is None
    active_client = client or BaiduOcrClient(connector)
    try:
        return active_client.recognize(
            image,
            full_image_authorized=full_image_authorized,
            mime_type=mime_type,
            allowed_root=allowed_root,
        )
    finally:
        if own_client:
            active_client.close()


def _build_form_body(image: PreparedImage, *, request_id: str) -> bytes:
    encoded_image = base64.b64encode(image.image_bytes).decode("ascii")
    form = urlencode(
        {
            "image": encoded_image,
            "recognize_granularity": "small",
            "probability": "true",
        }
    ).encode("ascii")
    if len(form) > BAIDU_FORM_BODY_MAX_BYTES:
        raise ImageTooLargeError(request_id=request_id)
    return form


def _raise_for_http_status(status_code: int, *, request_id: str) -> None:
    if type(status_code) is not int:
        raise InvalidResponseError(request_id=request_id)
    if 200 <= status_code < 300:
        return
    if status_code in (401, 403):
        raise AuthenticationError(request_id=request_id, http_status=status_code)
    if status_code == 429:
        raise RateLimitError(request_id=request_id, http_status=status_code)
    if status_code == 408:
        raise RequestTimeoutError(request_id=request_id, http_status=status_code)
    raise HttpError(request_id=request_id, http_status=status_code)


def _json_payload(response_body: bytes, *, request_id: str) -> dict[str, Any]:
    if not isinstance(response_body, bytes):
        raise InvalidResponseError(request_id=request_id)
    try:
        payload = json.loads(response_body)
    except (ValueError, UnicodeDecodeError):
        raise InvalidResponseError(request_id=request_id) from None
    if not isinstance(payload, dict):
        raise InvalidResponseError(request_id=request_id)
    return payload


def _parse_ocr_payload(
    payload: dict[str, Any],
    *,
    request_id: str,
) -> tuple[tuple[OcrBlock, ...], str | None]:
    provider_code = _provider_code(payload.get("error_code"))
    if provider_code not in (None, 0):
        if provider_code in _AUTH_PROVIDER_CODES:
            raise AuthenticationError(request_id=request_id, provider_code=provider_code)
        if provider_code in _RATE_LIMIT_PROVIDER_CODES:
            raise RateLimitError(request_id=request_id, provider_code=provider_code)
        if provider_code in _QUOTA_PROVIDER_CODES:
            raise QuotaExceededError(request_id=request_id, provider_code=provider_code)
        if provider_code == 6:
            raise PermissionDeniedError(request_id=request_id, provider_code=provider_code)
        raise ProviderError(request_id=request_id, provider_code=provider_code)

    words_result = payload.get("words_result")
    if not isinstance(words_result, list):
        raise InvalidResponseError(request_id=request_id)
    blocks: list[OcrBlock] = []
    for item in words_result:
        if not isinstance(item, dict) or not isinstance(item.get("words"), str):
            raise InvalidResponseError(request_id=request_id)
        blocks.append(
            OcrBlock(
                text=item["words"],
                location=_parse_location(item.get("location")),
                probability=_parse_probability(item.get("probability")),
                characters=_parse_characters(item.get("chars"), request_id=request_id),
            )
        )
    return tuple(blocks), _safe_service_log_id(payload.get("log_id"))


def _parse_location(value: Any) -> BoundingBox | None:
    if not isinstance(value, dict):
        return None
    parsed: dict[str, int] = {}
    for key in ("left", "top", "width", "height"):
        item = value.get(key)
        if isinstance(item, bool) or not isinstance(item, int) or item < 0:
            return None
        parsed[key] = item
    return BoundingBox(**parsed)


def _parse_probability(value: Any) -> ProbabilityStats | None:
    if not isinstance(value, dict):
        return None
    average = _actual_scalar(value.get("average"))
    variance = _actual_scalar(value.get("variance"))
    minimum = _actual_scalar(value.get("min"))
    if average is None and variance is None and minimum is None:
        return None
    return ProbabilityStats(average=average, variance=variance, minimum=minimum)


def _parse_characters(value: Any, *, request_id: str) -> tuple[OcrCharacter, ...]:
    if value is None:
        return ()
    if not isinstance(value, list):
        raise InvalidResponseError(request_id=request_id)
    characters: list[OcrCharacter] = []
    for item in value:
        if not isinstance(item, dict):
            raise InvalidResponseError(request_id=request_id)
        text = item.get("char")
        if text is not None and not isinstance(text, str):
            raise InvalidResponseError(request_id=request_id)
        candidates_value = item.get("candidates")
        if candidates_value is not None and not isinstance(candidates_value, list):
            raise InvalidResponseError(request_id=request_id)
        candidates: list[CharacterCandidate] = []
        for candidate in candidates_value or []:
            if not isinstance(candidate, dict):
                raise InvalidResponseError(request_id=request_id)
            candidate_text = candidate.get("word")
            if not isinstance(candidate_text, str):
                raise InvalidResponseError(request_id=request_id)
            candidates.append(
                CharacterCandidate(
                    text=candidate_text,
                    probability=_actual_scalar(candidate.get("prob")),
                )
            )
        characters.append(
            OcrCharacter(
                text=text,
                location=_parse_location(item.get("location")),
                candidates=tuple(candidates),
            )
        )
    return tuple(characters)


def _actual_scalar(value: Any) -> str | int | float | None:
    if isinstance(value, bool):
        return None
    if isinstance(value, (str, int, float)):
        return value
    return None


def _provider_code(value: Any) -> int | None:
    if isinstance(value, bool):
        return None
    if isinstance(value, int):
        return value
    if isinstance(value, str) and value.isdigit():
        try:
            return int(value)
        except ValueError:
            return None
    return None


def _safe_service_log_id(value: Any) -> str | None:
    if isinstance(value, (str, int)) and not isinstance(value, bool):
        candidate = str(value)
        if _SERVICE_LOG_ID_RE.fullmatch(candidate):
            return candidate
    return None
