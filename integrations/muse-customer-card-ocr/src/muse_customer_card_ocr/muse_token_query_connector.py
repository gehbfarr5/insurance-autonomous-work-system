from __future__ import annotations

import base64
import binascii
import json
import math
import subprocess
from collections.abc import Mapping
from urllib.parse import urlsplit

from .access_token_connector import (
    QueryParamAccessTokenOcrRequest,
    QueryParamAccessTokenOcrResponse,
    SecureQueryParamAccessTokenConnector,
)
from .client import BAIDU_FORM_BODY_MAX_BYTES, BAIDU_HANDWRITING_URL
from .errors import SecureConnectorFailure, SecureConnectorTimeout
from .muse_baidu_token_helper import (
    MAX_HELPER_TIMEOUT_SECONDS,
    MAX_OCR_RESPONSE_BYTES,
    MAX_STDIO_ENVELOPE_BYTES,
    _valid_request_id,
)
from .muse_secure_connector import (
    HELPER_PROCESS_GRACE_SECONDS,
    HelperInvocationFailure,
    HelperInvocationTimeout,
    StdioHelperInvoker,
    SubprocessStdioHelperInvoker,
)


_CONTENT_TYPE = "application/x-www-form-urlencoded"


class SecureQueryParamAccessTokenConnectorAdapter(
    SecureQueryParamAccessTokenConnector
):
    """Adapt the package OCR request to the token-query helper's stdio port."""

    def __init__(self, invoke_helper: StdioHelperInvoker) -> None:
        self._invoke_helper = invoke_helper

    def send(
        self, request: QueryParamAccessTokenOcrRequest
    ) -> QueryParamAccessTokenOcrResponse:
        _validate_query_token_request(request)
        envelope = {
            "request_id": request.request_id,
            "body_b64": base64.b64encode(request.body).decode("ascii"),
            "timeout_seconds": request.timeout_seconds,
        }
        stdin_payload = json.dumps(envelope, separators=(",", ":")).encode("ascii")
        if len(stdin_payload) > MAX_STDIO_ENVELOPE_BYTES:
            raise SecureConnectorFailure("invalid helper request") from None

        try:
            stdout_payload = self._invoke_helper(
                stdin_payload,
                timeout_seconds=request.timeout_seconds + HELPER_PROCESS_GRACE_SECONDS,
            )
        except (HelperInvocationTimeout, subprocess.TimeoutExpired, TimeoutError):
            raise SecureConnectorTimeout() from None
        except (HelperInvocationFailure, OSError):
            raise SecureConnectorFailure("helper invocation failed") from None
        except Exception:
            raise SecureConnectorFailure("helper invocation failed") from None

        return _parse_token_helper_response(
            stdout_payload,
            expected_request_id=request.request_id,
        )


def _validate_query_token_request(request: QueryParamAccessTokenOcrRequest) -> None:
    if not isinstance(request, QueryParamAccessTokenOcrRequest):
        raise SecureConnectorFailure("invalid helper request") from None
    try:
        parts = urlsplit(request.url)
        port = parts.port
    except (TypeError, ValueError):
        raise SecureConnectorFailure("invalid helper request") from None
    if (
        request.method != "POST"
        or request.url != BAIDU_HANDWRITING_URL
        or parts.scheme != "https"
        or parts.hostname != "aip.baidubce.com"
        or parts.path != "/rest/2.0/ocr/v1/handwriting"
        or port is not None
        or parts.username is not None
        or parts.password is not None
        or parts.query
        or parts.fragment
        or request.auth_mode != "query_param:access_token"
        or not _valid_request_id(request.request_id)
        or not isinstance(request.body, bytes)
        or not request.body
        or len(request.body) > BAIDU_FORM_BODY_MAX_BYTES
        or not _valid_timeout(request.timeout_seconds)
    ):
        raise SecureConnectorFailure("invalid helper request") from None

    if not isinstance(request.headers, Mapping):
        raise SecureConnectorFailure("invalid helper request") from None
    try:
        items = list(request.headers.items())
    except Exception:
        raise SecureConnectorFailure("invalid helper request") from None
    if any(not isinstance(key, str) or not isinstance(value, str) for key, value in items):
        raise SecureConnectorFailure("invalid helper request") from None
    headers = {key.lower(): value for key, value in items}
    if (
        len(headers) != len(items)
        or set(headers) != {"content-type"}
        or headers.get("content-type") != _CONTENT_TYPE
    ):
        raise SecureConnectorFailure("invalid helper request") from None


def _parse_token_helper_response(
    stdout_payload: bytes,
    *,
    expected_request_id: str,
) -> QueryParamAccessTokenOcrResponse:
    if not isinstance(stdout_payload, bytes) or len(stdout_payload) > MAX_STDIO_ENVELOPE_BYTES:
        raise SecureConnectorFailure("invalid helper response") from None
    try:
        payload = json.loads(stdout_payload.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError):
        raise SecureConnectorFailure("invalid helper response") from None
    if not isinstance(payload, dict) or payload.get("request_id") != expected_request_id:
        raise SecureConnectorFailure("invalid helper response") from None

    if payload.get("ok") is False:
        error = payload.get("error")
        category = error.get("category") if isinstance(error, dict) else None
        if category == "timeout":
            raise SecureConnectorTimeout() from None
        raise SecureConnectorFailure("helper request failed") from None

    if payload.get("ok") is not True:
        raise SecureConnectorFailure("invalid helper response") from None
    status_code = payload.get("status_code")
    body_b64 = payload.get("body_b64")
    if (
        type(status_code) is not int
        or not 100 <= status_code <= 599
        or not isinstance(body_b64, str)
    ):
        raise SecureConnectorFailure("invalid helper response") from None
    try:
        body = base64.b64decode(body_b64, validate=True)
    except (ValueError, binascii.Error):
        raise SecureConnectorFailure("invalid helper response") from None
    if len(body) > MAX_OCR_RESPONSE_BYTES or (not 200 <= status_code < 300 and body):
        raise SecureConnectorFailure("invalid helper response") from None
    return QueryParamAccessTokenOcrResponse(status_code=status_code, body=body)


def _valid_timeout(value: object) -> bool:
    if type(value) is int:
        return 0 < value <= MAX_HELPER_TIMEOUT_SECONDS
    return (
        type(value) is float
        and math.isfinite(value)
        and 0 < value <= MAX_HELPER_TIMEOUT_SECONDS
    )
