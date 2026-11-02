from __future__ import annotations

import base64
import os
import re
import threading
import time
import uuid
from dataclasses import dataclass, field
from typing import Any, Callable
from urllib.parse import urlencode

import requests

from .errors import (
    AuthenticationError,
    HttpError,
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
from .images import (
    ImageSource,
    PreparedImage,
    read_image_source,
    prepare_ocr_image,
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
    MaskStatus,
    PrivacyMaskResult,
    assert_mask_verified,
)


BAIDU_TOKEN_URL = "https://aip.baidubce.com/oauth/2.0/token"
BAIDU_HANDWRITING_URL = "https://aip.baidubce.com/rest/2.0/ocr/v1/handwriting"
BAIDU_FORM_BODY_MAX_BYTES = 8 * 1024 * 1024
_SERVICE_LOG_ID_RE = re.compile(r"^[A-Za-z0-9_-]{1,64}$")
_AUTH_PROVIDER_CODES = frozenset({110, 111})
_RATE_LIMIT_PROVIDER_CODES = frozenset({4, 18})
_QUOTA_PROVIDER_CODES = frozenset({17, 19})


@dataclass(frozen=True, repr=False)
class BaiduCredentials:
    api_key: str = field(repr=False)
    secret_key: str = field(repr=False)

    @classmethod
    def from_environment(cls) -> BaiduCredentials:
        api_key = os.environ.get("BAIDU_OCR_AK", "").strip()
        secret_key = os.environ.get("BAIDU_OCR_SK", "").strip()
        if not api_key or not secret_key:
            raise MissingCredentialsError()
        return cls(api_key=api_key, secret_key=secret_key)

    def __repr__(self) -> str:
        return "BaiduCredentials(<redacted>)"


class BaiduOcrClient:
    """Direct HTTP client for Baidu handwriting OCR.

    No request/response bodies or credentials are logged or persisted. The
    client fails closed unless a matching verified mask result is supplied.
    """

    def __init__(
        self,
        credentials: BaiduCredentials | None = None,
        *,
        session: Any | None = None,
        timeout: float = 45.0,
        clock: Callable[[], float] = time.monotonic,
    ) -> None:
        if timeout <= 0:
            raise ValueError("timeout must be positive")
        self._credentials = credentials
        if session is None:
            session = requests.Session()
            # Do not silently route customer images through an ambient proxy.
            session.trust_env = False
        self._session = session
        self._timeout = timeout
        self._clock = clock
        self._token: str | None = None
        self._token_expires_at = 0.0
        self._token_lock = threading.Lock()

    def close(self) -> None:
        close = getattr(self._session, "close", None)
        if callable(close):
            close()

    def recognize(
        self,
        image: ImageSource,
        *,
        mime_type: str | None = None,
        privacy_mask: PrivacyMaskResult | None = None,
        allowed_root: str | os.PathLike[str] | None = None,
    ) -> OcrResult:
        request_id = uuid.uuid4().hex
        if privacy_mask is None or privacy_mask.status != MaskStatus.VERIFIED:
            raise PrivacyMaskUnverifiedError(request_id=request_id)

        source = read_image_source(
            image,
            mime_type=mime_type,
            allowed_root=allowed_root,
            request_id=request_id,
        )
        masked_bytes, masked_mime, policy_id = assert_mask_verified(
            source.image_bytes,
            privacy_mask,
            request_id=request_id,
        )
        prepared = prepare_ocr_image(
            masked_bytes,
            mime_type=masked_mime,
            request_id=request_id,
        )
        body = self._build_form_body(prepared, request_id=request_id)
        token = self._access_token(request_id=request_id)
        try:
            response = self._post(
                BAIDU_HANDWRITING_URL,
                request_id=request_id,
                params={"access_token": token},
                data=body,
                headers={"Content-Type": "application/x-www-form-urlencoded"},
            )
            payload = self._json_payload(response, request_id=request_id)
            blocks, service_log_id = _parse_ocr_payload(payload, request_id=request_id)
        except AuthenticationError:
            self._invalidate_access_token(token)
            raise
        return OcrResult(
            status="success",
            blocks=blocks,
            request_id=request_id,
            service_log_id=service_log_id,
            image_mime_type=prepared.mime_type,
            image_width=prepared.width,
            image_height=prepared.height,
            mask_policy_id=policy_id,
        )

    def _build_form_body(self, image: PreparedImage, *, request_id: str) -> bytes:
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

    def _access_token(self, *, request_id: str) -> str:
        with self._token_lock:
            now = self._clock()
            if self._token and now < self._token_expires_at - 60:
                return self._token

            credentials = self._credentials
            if credentials is None:
                credentials = BaiduCredentials.from_environment()
                self._credentials = credentials
            response = self._post(
                BAIDU_TOKEN_URL,
                request_id=request_id,
                params={
                    "grant_type": "client_credentials",
                    "client_id": credentials.api_key,
                    "client_secret": credentials.secret_key,
                },
                data=None,
                headers={},
            )
            payload = self._json_payload(response, request_id=request_id)
            if payload.get("error"):
                raise AuthenticationError(request_id=request_id) from None

            token = payload.get("access_token")
            expires_in = payload.get("expires_in")
            try:
                expires_seconds = int(expires_in)
            except (TypeError, ValueError):
                expires_seconds = 0
            if (
                not isinstance(token, str)
                or not token
                or expires_seconds <= 0
            ):
                raise InvalidResponseError(request_id=request_id)

            self._token = token
            self._token_expires_at = self._clock() + expires_seconds
            return token

    def _invalidate_access_token(self, token: str) -> None:
        with self._token_lock:
            if self._token == token:
                self._token = None
                self._token_expires_at = 0.0

    def _post(
        self,
        url: str,
        *,
        request_id: str,
        params: dict[str, str] | None = None,
        data: dict[str, str] | bytes | None,
        headers: dict[str, str],
    ) -> Any:
        try:
            response = self._session.post(
                url,
                params=params,
                data=data,
                headers=headers,
                timeout=self._timeout,
                allow_redirects=False,
            )
        except requests.Timeout:
            raise RequestTimeoutError(request_id=request_id) from None
        except requests.RequestException:
            raise NetworkError(request_id=request_id) from None
        except TimeoutError:
            raise RequestTimeoutError(request_id=request_id) from None
        except OSError:
            raise NetworkError(request_id=request_id) from None

        status = getattr(response, "status_code", None)
        if not isinstance(status, int):
            raise InvalidResponseError(request_id=request_id)
        if 200 <= status < 300:
            return response
        if status in (401, 403):
            raise AuthenticationError(
                request_id=request_id,
                http_status=status,
            )
        if status == 429:
            raise RateLimitError(request_id=request_id, http_status=status)
        if status == 408:
            raise RequestTimeoutError(request_id=request_id, http_status=status)
        raise HttpError(request_id=request_id, http_status=status)

    @staticmethod
    def _json_payload(response: Any, *, request_id: str) -> dict[str, Any]:
        try:
            payload = response.json()
        except (ValueError, requests.exceptions.JSONDecodeError):
            raise InvalidResponseError(request_id=request_id) from None
        if not isinstance(payload, dict):
            raise InvalidResponseError(request_id=request_id)
        return payload


def recognize_customer_card(
    image: ImageSource,
    *,
    mime_type: str | None = None,
    privacy_mask: PrivacyMaskResult | None = None,
    allowed_root: str | os.PathLike[str] | None = None,
    client: BaiduOcrClient | None = None,
) -> OcrResult:
    """Recognize one already-masked image without writing files or logs."""
    own_client = client is None
    active_client = client or BaiduOcrClient()
    try:
        return active_client.recognize(
            image,
            mime_type=mime_type,
            privacy_mask=privacy_mask,
            allowed_root=allowed_root,
        )
    finally:
        if own_client:
            active_client.close()


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
