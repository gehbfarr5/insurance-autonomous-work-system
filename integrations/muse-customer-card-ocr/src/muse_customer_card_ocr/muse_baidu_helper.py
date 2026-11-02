from __future__ import annotations

import base64
import binascii
import json
import math
import re
from dataclasses import dataclass, field
from typing import BinaryIO, Literal, Protocol

from .client import BAIDU_FORM_BODY_MAX_BYTES, BAIDU_HANDWRITING_URL


BAIDU_HANDWRITING_HOST = "aip.baidubce.com"
BAIDU_HANDWRITING_PATH = "/rest/2.0/ocr/v1/handwriting"
BAIDU_BEARER_CREDENTIAL_SLOT = "baidu_ocr_bearer"
MAX_STDIO_ENVELOPE_BYTES = 12 * 1024 * 1024
MAX_OCR_RESPONSE_BYTES = 8 * 1024 * 1024
MAX_HELPER_TIMEOUT_SECONDS = 60.0
_REQUEST_ID_RE = re.compile(r"^[A-Za-z0-9_-]{1,64}$")


@dataclass(frozen=True, repr=False)
class HelperHttpResponse:
    status_code: int
    body: bytes = field(repr=False)

    def __repr__(self) -> str:
        return f"HelperHttpResponse(status_code={self.status_code}, body=<redacted>)"


@dataclass(frozen=True, repr=False)
class HelperOcrResponse:
    request_id: str
    status_code: int
    body: bytes = field(repr=False)

    def __repr__(self) -> str:
        return (
            "HelperOcrResponse("
            f"request_id={self.request_id!r}, status_code={self.status_code}, "
            "body=<redacted>)"
        )


class BaiduSecureHttpTransport(Protocol):
    """Package-owned port for a Vault-backed, fixed-endpoint HTTP sender.

    This is not a documented MUSE interface. The eventual MUSE binding must
    attach the credential referenced by ``credential_slot`` without returning
    its value to this package, and must honor ``allow_redirects=False``.
    """

    def post_baidu_handwriting(
        self,
        body: bytes,
        *,
        url: str,
        method: Literal["POST"],
        content_type: Literal["application/x-www-form-urlencoded"],
        credential_slot: Literal["baidu_ocr_bearer"],
        timeout_seconds: float,
        allow_redirects: Literal[False],
        max_request_bytes: int,
        max_response_bytes: int,
    ) -> HelperHttpResponse: ...


class HelperRequestError(Exception):
    code = "INVALID_HELPER_REQUEST"

    def __str__(self) -> str:
        return self.code

    def __repr__(self) -> str:
        return f"{type(self).__name__}(<details redacted>)"


class HelperTimeoutError(Exception):
    def __str__(self) -> str:
        return "HELPER_TIMEOUT"

    def __repr__(self) -> str:
        return "HelperTimeoutError(<details redacted>)"


class HelperNetworkError(Exception):
    def __str__(self) -> str:
        return "HELPER_NETWORK_ERROR"

    def __repr__(self) -> str:
        return "HelperNetworkError(<details redacted>)"


class HelperResponseError(Exception):
    def __str__(self) -> str:
        return "HELPER_INVALID_RESPONSE"

    def __repr__(self) -> str:
        return "HelperResponseError(<details redacted>)"


class BaiduHandwritingOcrHelper:
    """Validate a fixed OCR request and delegate to an injected secure transport."""

    def __init__(self, transport: BaiduSecureHttpTransport) -> None:
        self._transport = transport

    def recognize(
        self,
        body: bytes,
        *,
        request_id: str,
        timeout_seconds: float,
    ) -> HelperOcrResponse:
        if not _valid_request_id(request_id):
            raise HelperRequestError()
        if not isinstance(body, bytes) or not body or len(body) > BAIDU_FORM_BODY_MAX_BYTES:
            raise HelperRequestError()
        if not _valid_timeout(timeout_seconds):
            raise HelperRequestError()

        try:
            response = self._transport.post_baidu_handwriting(
                body,
                url=BAIDU_HANDWRITING_URL,
                method="POST",
                content_type="application/x-www-form-urlencoded",
                credential_slot=BAIDU_BEARER_CREDENTIAL_SLOT,
                timeout_seconds=float(timeout_seconds),
                allow_redirects=False,
                max_request_bytes=BAIDU_FORM_BODY_MAX_BYTES,
                max_response_bytes=MAX_OCR_RESPONSE_BYTES,
            )
        except (HelperTimeoutError, TimeoutError):
            raise HelperTimeoutError() from None
        except (HelperNetworkError, OSError, ConnectionError):
            raise HelperNetworkError() from None

        if not isinstance(response, HelperHttpResponse):
            raise HelperResponseError()
        if type(response.status_code) is not int or not 100 <= response.status_code <= 599:
            raise HelperResponseError()
        if not isinstance(response.body, bytes) or len(response.body) > MAX_OCR_RESPONSE_BYTES:
            raise HelperResponseError()

        # Error and redirect response bodies may contain sensitive diagnostics.
        safe_body = response.body if 200 <= response.status_code < 300 else b""
        return HelperOcrResponse(
            request_id=request_id,
            status_code=response.status_code,
            body=safe_body,
        )


def serve_one_stdio_request(
    stdin: BinaryIO,
    stdout: BinaryIO,
    helper: BaiduHandwritingOcrHelper,
) -> None:
    """Handle one package-defined JSON request from stdin; write JSON only.

    The envelope accepts request ID, encoded form body, and timeout only. It
    intentionally has no URL, host, path, method, headers, or credential value.
    """
    request_id: str | None = None
    try:
        raw = stdin.read(MAX_STDIO_ENVELOPE_BYTES + 1)
        if not isinstance(raw, bytes) or len(raw) > MAX_STDIO_ENVELOPE_BYTES:
            raise HelperRequestError()
        payload = json.loads(raw.decode("utf-8"))
        if not isinstance(payload, dict) or set(payload) != {
            "request_id",
            "body_b64",
            "timeout_seconds",
        }:
            raise HelperRequestError()
        candidate_id = payload.get("request_id")
        if not _valid_request_id(candidate_id):
            raise HelperRequestError()
        request_id = candidate_id
        body_b64 = payload.get("body_b64")
        maximum_b64_size = ((BAIDU_FORM_BODY_MAX_BYTES + 2) // 3) * 4
        if not isinstance(body_b64, str) or len(body_b64) > maximum_b64_size:
            raise HelperRequestError()
        try:
            body = base64.b64decode(body_b64, validate=True)
        except (ValueError, binascii.Error):
            raise HelperRequestError() from None
        timeout_seconds = payload.get("timeout_seconds")
        if not _valid_timeout(timeout_seconds):
            raise HelperRequestError()

        result = helper.recognize(
            body,
            request_id=request_id,
            timeout_seconds=float(timeout_seconds),
        )
        response_envelope = {
            "ok": True,
            "request_id": result.request_id,
            "status_code": result.status_code,
            "body_b64": base64.b64encode(result.body).decode("ascii"),
        }
    except HelperTimeoutError:
        response_envelope = _error_envelope("timeout", request_id)
    except HelperNetworkError:
        response_envelope = _error_envelope("network", request_id)
    except HelperResponseError:
        response_envelope = _error_envelope("invalid_response", request_id)
    except (HelperRequestError, UnicodeDecodeError, json.JSONDecodeError):
        response_envelope = _error_envelope("invalid_request", request_id)

    stdout.write(
        json.dumps(response_envelope, separators=(",", ":"), ensure_ascii=True).encode("ascii")
        + b"\n"
    )
    stdout.flush()


def _error_envelope(category: str, request_id: str | None) -> dict[str, object]:
    return {
        "ok": False,
        "request_id": request_id,
        "error": {"category": category},
    }


def _valid_request_id(value: object) -> bool:
    return isinstance(value, str) and _REQUEST_ID_RE.fullmatch(value) is not None


def _valid_timeout(value: object) -> bool:
    if type(value) is int:
        return 0 < value <= MAX_HELPER_TIMEOUT_SECONDS
    return (
        type(value) is float
        and math.isfinite(value)
        and 0 < value <= MAX_HELPER_TIMEOUT_SECONDS
    )


if BAIDU_HANDWRITING_URL != f"https://{BAIDU_HANDWRITING_HOST}{BAIDU_HANDWRITING_PATH}":
    raise RuntimeError("Baidu handwriting endpoint constant mismatch")
