from __future__ import annotations

import base64
import io
import json
import subprocess
import unittest
from contextlib import redirect_stderr
from dataclasses import replace
from urllib.parse import parse_qs, urlencode, urlsplit, urlunsplit
from unittest.mock import Mock

from PIL import Image

from muse_customer_card_ocr import (
    AuthenticationError,
    BaiduOcrClient,
    HttpError,
    NetworkError,
    RateLimitError,
    RequestTimeoutError,
    SecureConnectorFailure,
)
from muse_customer_card_ocr.access_token_connector import (
    QueryParamAccessTokenOcrRequest,
    QueryParamAccessTokenOcrResponse,
)
from muse_customer_card_ocr.client import (
    BAIDU_FORM_BODY_MAX_BYTES,
    BAIDU_HANDWRITING_URL,
)
from muse_customer_card_ocr.muse_baidu_token_helper import (
    BAIDU_ACCESS_TOKEN_CREDENTIAL_SLOT,
    MAX_OCR_RESPONSE_BYTES,
    MAX_STDIO_ENVELOPE_BYTES,
    BaiduQueryParamHandwritingHelper,
    TokenHelperHttpResponse,
    TokenHelperNetworkError,
    TokenHelperRequestError,
    TokenHelperResponseError,
    TokenHelperTimeoutError,
    serve_one_stdio_token_request,
)
from muse_customer_card_ocr.muse_secure_connector import (
    HelperInvocationTimeout,
    SubprocessStdioHelperInvoker,
)
from muse_customer_card_ocr.muse_token_query_connector import (
    SecureQueryParamAccessTokenConnectorAdapter,
)


MOCK_ACCESS_TOKEN = "MOCK_ONLY_ACCESS_TOKEN_PLACEHOLDER"
MOCK_OCR_TEXT = "SYNTHETIC_OCR_TEXT_MUST_NOT_BE_LOGGED"
MOCK_IMAGE_MARKER = b"SYNTHETIC_IMAGE_BYTES_MUST_NOT_BE_LOGGED"
MOCK_PRIVATE_ERROR = b"SYNTHETIC_PROVIDER_ERROR_MUST_NOT_BE_LOGGED"


def make_jpeg() -> bytes:
    image = Image.new("RGB", (32, 24), "white")
    output = io.BytesIO()
    image.save(output, format="JPEG")
    return output.getvalue()


def success_payload(text: str = MOCK_OCR_TEXT) -> bytes:
    return json.dumps(
        {
            "log_id": "synthetic-log-id",
            "words_result_num": 1,
            "words_result": [{"words": text}],
        },
        separators=(",", ":"),
    ).encode("utf-8")


def make_request(**overrides) -> QueryParamAccessTokenOcrRequest:
    request = QueryParamAccessTokenOcrRequest(
        request_id="synthetic-request-007",
        method="POST",
        url=BAIDU_HANDWRITING_URL,
        auth_mode="query_param:access_token",
        headers={"Content-Type": "application/x-www-form-urlencoded"},
        body=b"image=synthetic-form-body",
        timeout_seconds=17.0,
    )
    return replace(request, **overrides)


class MockVaultQueryTransport:
    """Test-only Secure Vault placeholder injection outside Python requests."""

    def __init__(self, reply: TokenHelperHttpResponse | BaseException):
        self.reply = reply
        self.calls: list[tuple[bytes, dict[str, object]]] = []
        self.final_urls: list[str] = []

    def post_baidu_handwriting(self, body: bytes, **kwargs):
        self.calls.append((body, kwargs))
        if kwargs.get("credential_slot") != BAIDU_ACCESS_TOKEN_CREDENTIAL_SLOT:
            raise AssertionError("unexpected logical credential slot")
        if kwargs.get("auth_mode") != "query_param:access_token":
            raise AssertionError("unexpected query authentication mode")
        # Simulate connector-side token substitution; Python never receives it.
        parts = urlsplit(kwargs["url"])
        query = urlencode({"access_token": MOCK_ACCESS_TOKEN})
        self.final_urls.append(
            urlunsplit((parts.scheme, parts.netloc, parts.path, query, ""))
        )
        if isinstance(self.reply, BaseException):
            raise self.reply
        return self.reply


class StdioHarness:
    def __init__(self, helper: BaiduQueryParamHandwritingHelper):
        self.helper = helper
        self.requests: list[bytes] = []
        self.timeouts: list[float] = []

    def __call__(self, stdin_payload: bytes, *, timeout_seconds: float) -> bytes:
        self.requests.append(stdin_payload)
        self.timeouts.append(timeout_seconds)
        stdout = io.BytesIO()
        serve_one_stdio_token_request(io.BytesIO(stdin_payload), stdout, self.helper)
        return stdout.getvalue()


def make_adapter(reply: TokenHelperHttpResponse | BaseException):
    transport = MockVaultQueryTransport(reply)
    helper = BaiduQueryParamHandwritingHelper(transport)
    harness = StdioHarness(helper)
    return SecureQueryParamAccessTokenConnectorAdapter(harness), transport, harness


class MuseTokenQueryConnectorTests(unittest.TestCase):
    def test_client_uses_fixed_endpoint_and_mock_vault_injects_only_access_token(self):
        adapter, transport, harness = make_adapter(TokenHelperHttpResponse(200, success_payload()))
        client = BaiduOcrClient(
            adapter,
            auth_mode="query_param:access_token",
            timeout=17.0,
        )

        result = client.recognize(
            make_jpeg(),
            full_image_authorized=True,
            mime_type="image/jpeg",
        )

        self.assertEqual(result.blocks[0].text, MOCK_OCR_TEXT)
        self.assertEqual(len(transport.calls), 1)
        request_body, call = transport.calls[0]
        self.assertEqual(call["url"], BAIDU_HANDWRITING_URL)
        self.assertEqual(call["method"], "POST")
        self.assertEqual(call["content_type"], "application/x-www-form-urlencoded")
        self.assertEqual(call["auth_mode"], "query_param:access_token")
        self.assertEqual(call["credential_slot"], BAIDU_ACCESS_TOKEN_CREDENTIAL_SLOT)
        self.assertEqual(call["allow_redirects"], False)
        self.assertEqual(call["timeout_seconds"], 17.0)
        self.assertEqual(call["max_request_bytes"], BAIDU_FORM_BODY_MAX_BYTES)
        self.assertEqual(call["max_response_bytes"], MAX_OCR_RESPONSE_BYTES)

        parsed_url = urlsplit(transport.final_urls[0])
        self.assertEqual(parsed_url.scheme, "https")
        self.assertEqual(parsed_url.hostname, "aip.baidubce.com")
        self.assertEqual(parsed_url.path, "/rest/2.0/ocr/v1/handwriting")
        self.assertEqual(parse_qs(parsed_url.query), {"access_token": [MOCK_ACCESS_TOKEN]})

        envelope = json.loads(harness.requests[0])
        self.assertEqual(set(envelope), {"request_id", "body_b64", "timeout_seconds"})
        self.assertEqual(base64.b64decode(envelope["body_b64"]), request_body)
        self.assertNotIn("access_token", envelope)
        self.assertNotIn("query", envelope)
        self.assertNotIn("url", envelope)
        self.assertNotIn("method", envelope)
        self.assertNotIn(MOCK_ACCESS_TOKEN.encode(), harness.requests[0])
        self.assertEqual(harness.timeouts, [22.0])

    def test_query_auth_request_has_no_token_field_or_secret_repr(self):
        request = make_request()
        response = QueryParamAccessTokenOcrResponse(200, success_payload())

        self.assertFalse(hasattr(request, "access_token"))
        self.assertFalse(hasattr(request, "token"))
        self.assertFalse(hasattr(request, "api_key"))
        self.assertNotIn(MOCK_ACCESS_TOKEN, repr(request))
        self.assertNotIn(MOCK_OCR_TEXT, repr(response))
        self.assertNotIn("access_token=", repr(request))

    def test_401_is_classified_and_private_error_body_is_suppressed(self):
        adapter, transport, _ = make_adapter(TokenHelperHttpResponse(401, MOCK_PRIVATE_ERROR))
        client = BaiduOcrClient(adapter, auth_mode="query_param:access_token")

        with self.assertRaises(AuthenticationError) as caught:
            client.recognize(make_jpeg(), full_image_authorized=True, mime_type="image/jpeg")

        self.assertEqual(caught.exception.http_status, 401)
        self.assertEqual(transport.calls[0][1]["allow_redirects"], False)
        self.assertNotIn(MOCK_PRIVATE_ERROR.decode(), str(caught.exception))

    def test_429_is_classified_and_private_error_body_is_suppressed(self):
        adapter, _, _ = make_adapter(TokenHelperHttpResponse(429, MOCK_PRIVATE_ERROR))
        client = BaiduOcrClient(adapter, auth_mode="query_param:access_token")

        with self.assertRaises(RateLimitError) as caught:
            client.recognize(make_jpeg(), full_image_authorized=True, mime_type="image/jpeg")

        self.assertEqual(caught.exception.http_status, 429)
        self.assertNotIn(MOCK_PRIVATE_ERROR.decode(), str(caught.exception))

    def test_redirect_response_is_not_followed_and_body_is_suppressed(self):
        adapter, transport, _ = make_adapter(TokenHelperHttpResponse(302, MOCK_PRIVATE_ERROR))
        client = BaiduOcrClient(adapter, auth_mode="query_param:access_token")

        with self.assertRaises(HttpError) as caught:
            client.recognize(make_jpeg(), full_image_authorized=True, mime_type="image/jpeg")

        self.assertEqual(caught.exception.http_status, 302)
        self.assertEqual(len(transport.calls), 1)
        self.assertEqual(transport.calls[0][1]["allow_redirects"], False)
        self.assertNotIn(MOCK_PRIVATE_ERROR.decode(), str(caught.exception))

    def test_transport_timeout_maps_to_request_timeout(self):
        adapter, _, _ = make_adapter(TokenHelperTimeoutError())
        client = BaiduOcrClient(adapter, auth_mode="query_param:access_token")

        with self.assertRaises(RequestTimeoutError):
            client.recognize(make_jpeg(), full_image_authorized=True, mime_type="image/jpeg")

    def test_helper_process_timeout_maps_to_request_timeout(self):
        def timeout_invoker(_payload: bytes, *, timeout_seconds: float) -> bytes:
            raise HelperInvocationTimeout()

        client = BaiduOcrClient(
            SecureQueryParamAccessTokenConnectorAdapter(timeout_invoker),
            auth_mode="query_param:access_token",
        )

        with self.assertRaises(RequestTimeoutError):
            client.recognize(make_jpeg(), full_image_authorized=True, mime_type="image/jpeg")

    def test_network_and_unexpected_transport_exceptions_are_safely_mapped(self):
        for failure in (OSError("MOCK_PRIVATE_NETWORK_DETAIL"), RuntimeError("MOCK_PRIVATE_RUNTIME_DETAIL")):
            with self.subTest(failure=type(failure).__name__):
                adapter, _, _ = make_adapter(failure)
                client = BaiduOcrClient(adapter, auth_mode="query_param:access_token")
                with self.assertRaises(NetworkError) as caught:
                    client.recognize(
                        make_jpeg(), full_image_authorized=True, mime_type="image/jpeg"
                    )
                self.assertNotIn("MOCK_PRIVATE", str(caught.exception))

    def test_rejects_caller_url_method_query_auth_or_header_overrides(self):
        adapter, _, harness = make_adapter(TokenHelperHttpResponse(200, success_payload()))
        invalid_requests = (
            make_request(url="https://example.invalid/rest/2.0/ocr/v1/handwriting"),
            make_request(url="https://aip.baidubce.com/other"),
            make_request(url=BAIDU_HANDWRITING_URL + "?access_token=CALLER_VALUE"),
            make_request(url=BAIDU_HANDWRITING_URL + "?redirect=1"),
            make_request(method="GET"),
            make_request(auth_mode="bearer"),
            make_request(headers={"Content-Type": "application/x-www-form-urlencoded", "X-Test": "x"}),
            make_request(headers={"Authorization": "Bearer caller-value"}),
        )

        for request in invalid_requests:
            with self.subTest(method=request.method, url=request.url, auth_mode=request.auth_mode):
                with self.assertRaises(SecureConnectorFailure):
                    adapter.send(request)
        self.assertEqual(harness.requests, [])

    def test_rejects_oversize_body_and_invalid_timeout_before_helper(self):
        adapter, _, harness = make_adapter(TokenHelperHttpResponse(200, success_payload()))
        invalid_requests = (
            make_request(body=b"x" * (BAIDU_FORM_BODY_MAX_BYTES + 1)),
            make_request(timeout_seconds=0),
            make_request(timeout_seconds=60.1),
        )
        for request in invalid_requests:
            with self.subTest(body_size=len(request.body), timeout=request.timeout_seconds):
                with self.assertRaises(SecureConnectorFailure):
                    adapter.send(request)
        self.assertEqual(harness.requests, [])

    def test_helper_rejects_oversize_response_without_exposing_body(self):
        transport = MockVaultQueryTransport(
            TokenHelperHttpResponse(200, b"x" * (MAX_OCR_RESPONSE_BYTES + 1))
        )
        helper = BaiduQueryParamHandwritingHelper(transport)

        with self.assertRaises(TokenHelperResponseError):
            helper.recognize(
                b"image=synthetic",
                request_id="synthetic-request-007",
                timeout_seconds=5.0,
            )

    def test_helper_rejects_oversize_input_without_transport_call(self):
        transport = MockVaultQueryTransport(TokenHelperHttpResponse(200, success_payload()))
        helper = BaiduQueryParamHandwritingHelper(transport)

        with self.assertRaises(TokenHelperRequestError):
            helper.recognize(
                b"x" * (BAIDU_FORM_BODY_MAX_BYTES + 1),
                request_id="synthetic-request-007",
                timeout_seconds=5.0,
            )
        self.assertEqual(transport.calls, [])

    def test_stdio_error_is_structured_and_does_not_print_token_image_or_error(self):
        transport = MockVaultQueryTransport(TokenHelperNetworkError())
        helper = BaiduQueryParamHandwritingHelper(transport)
        request_body = b"image=" + base64.b64encode(MOCK_IMAGE_MARKER)
        payload = json.dumps(
            {
                "request_id": "synthetic-request-007",
                "body_b64": base64.b64encode(request_body).decode("ascii"),
                "timeout_seconds": 5,
            },
            separators=(",", ":"),
        ).encode("ascii")
        stdout = io.BytesIO()
        stderr = io.StringIO()

        with redirect_stderr(stderr):
            serve_one_stdio_token_request(io.BytesIO(payload), stdout, helper)

        output = stdout.getvalue()
        envelope = json.loads(output)
        self.assertEqual(envelope["error"]["category"], "network")
        self.assertNotIn(MOCK_ACCESS_TOKEN.encode(), output)
        self.assertNotIn(MOCK_IMAGE_MARKER, output)
        self.assertNotIn(base64.b64encode(request_body), output)
        self.assertNotIn(MOCK_PRIVATE_ERROR, output)
        self.assertEqual(stderr.getvalue(), "")

    def test_stdio_rejects_caller_endpoint_and_credential_fields(self):
        transport = MockVaultQueryTransport(TokenHelperHttpResponse(200, success_payload()))
        helper = BaiduQueryParamHandwritingHelper(transport)
        payload = json.dumps(
            {
                "request_id": "synthetic-request-007",
                "body_b64": base64.b64encode(b"image=synthetic").decode("ascii"),
                "timeout_seconds": 5,
                "url": "https://example.invalid/redirect",
                "query_params": {"access_token": MOCK_ACCESS_TOKEN},
                "method": "GET",
            },
            separators=(",", ":"),
        ).encode("ascii")
        stdout = io.BytesIO()

        serve_one_stdio_token_request(io.BytesIO(payload), stdout, helper)

        result = stdout.getvalue()
        envelope = json.loads(result)
        self.assertEqual(envelope["error"]["category"], "invalid_request")
        self.assertEqual(transport.calls, [])
        self.assertNotIn(MOCK_ACCESS_TOKEN.encode(), result)

    def test_helper_success_stdout_contains_only_structured_response_envelope(self):
        body = success_payload()
        transport = MockVaultQueryTransport(TokenHelperHttpResponse(200, body))
        helper = BaiduQueryParamHandwritingHelper(transport)
        form_body = b"image=" + base64.b64encode(MOCK_IMAGE_MARKER)
        payload = json.dumps(
            {
                "request_id": "synthetic-request-007",
                "body_b64": base64.b64encode(form_body).decode("ascii"),
                "timeout_seconds": 5,
            },
            separators=(",", ":"),
        ).encode("ascii")
        stdout = io.BytesIO()
        stderr = io.StringIO()

        with redirect_stderr(stderr):
            serve_one_stdio_token_request(io.BytesIO(payload), stdout, helper)

        output = stdout.getvalue()
        envelope = json.loads(output)
        self.assertEqual(set(envelope), {"ok", "request_id", "status_code", "body_b64"})
        self.assertEqual(base64.b64decode(envelope["body_b64"]), body)
        self.assertNotIn(MOCK_OCR_TEXT.encode(), output)
        self.assertNotIn(MOCK_ACCESS_TOKEN.encode(), output)
        self.assertNotIn(MOCK_IMAGE_MARKER, output)
        self.assertEqual(stderr.getvalue(), "")

    def test_stdio_envelope_size_limit_is_shared_with_existing_helper(self):
        self.assertEqual(MAX_STDIO_ENVELOPE_BYTES, 12 * 1024 * 1024)

    def test_existing_bearer_default_and_adapter_remain_available(self):
        client = BaiduOcrClient(None)
        self.assertIsNone(client._connector)
        self.assertEqual(client._auth_mode, "bearer")

    def test_subprocess_invoker_is_reused_without_shell_or_environment(self):
        runner = Mock(
            return_value=subprocess.CompletedProcess(
                args=("/usr/bin/helper",),
                returncode=0,
                stdout=b'{"ok":true}',
                stderr=b"MOCK_PRIVATE_STDERR",
            )
        )
        invoker = SubprocessStdioHelperInvoker(("/usr/bin/helper",), run=runner)

        result = invoker(b'{"request":"synthetic"}', timeout_seconds=7.0)

        self.assertEqual(result, b'{"ok":true}')
        self.assertEqual(runner.call_args.kwargs["shell"], False)
        self.assertEqual(runner.call_args.kwargs["env"], {})

    def test_subprocess_invoker_accepts_helper_deadline_plus_grace(self):
        runner = Mock(
            return_value=subprocess.CompletedProcess(
                args=("/usr/bin/helper",),
                returncode=0,
                stdout=b'{"ok":true}',
                stderr=b"",
            )
        )
        invoker = SubprocessStdioHelperInvoker(("/usr/bin/helper",), run=runner)

        invoker(b'{"request":"synthetic"}', timeout_seconds=65.0)

        self.assertEqual(runner.call_args.kwargs["timeout"], 65.0)

    def test_invalid_helper_response_is_classified_without_details(self):
        adapter, _, _ = make_adapter(TokenHelperHttpResponse(200, success_payload()))

        def bad_response_invoker(_payload: bytes, *, timeout_seconds: float) -> bytes:
            return b"MOCK_PRIVATE_RAW_HELPER_RESPONSE"

        adapter = SecureQueryParamAccessTokenConnectorAdapter(bad_response_invoker)
        with self.assertRaises(SecureConnectorFailure) as caught:
            adapter.send(make_request())
        self.assertNotIn("MOCK_PRIVATE", str(caught.exception))


if __name__ == "__main__":
    unittest.main()
