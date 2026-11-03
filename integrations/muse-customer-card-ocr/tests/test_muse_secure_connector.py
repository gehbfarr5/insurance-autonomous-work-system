from __future__ import annotations

import base64
import io
import json
import subprocess
import unittest
from contextlib import redirect_stderr
from dataclasses import replace
from unittest.mock import Mock

from PIL import Image

from muse_customer_card_ocr import (
    AuthenticationError,
    BaiduOcrClient,
    BearerOcrRequest,
    HttpError,
    RateLimitError,
    RequestTimeoutError,
    SecureConnectorFailure,
    SecureConnectorTimeout,
)
from muse_customer_card_ocr.client import BAIDU_HANDWRITING_URL
from muse_customer_card_ocr.muse_baidu_helper import (
    BAIDU_BEARER_CREDENTIAL_SLOT,
    BAIDU_FORM_BODY_MAX_BYTES,
    BAIDU_HANDWRITING_HOST,
    BAIDU_HANDWRITING_PATH,
    MAX_STDIO_ENVELOPE_BYTES,
    BaiduHandwritingOcrHelper,
    HelperHttpResponse,
    HelperRequestError,
    serve_one_stdio_request,
)
from muse_customer_card_ocr.muse_secure_connector import (
    HelperInvocationTimeout,
    SecureBearerConnectorAdapter,
    SubprocessStdioHelperInvoker,
)


MOCK_BEARER_VALUE = "MOCK_ONLY_BEARER_PLACEHOLDER_VALUE"
MOCK_OCR_TEXT = "MOCK_ONLY_OCR_TEXT_MUST_NOT_BE_LOGGED"
MOCK_IMAGE_MARKER = b"MOCK_ONLY_IMAGE_BYTES_MUST_NOT_BE_LOGGED"


def make_jpeg() -> bytes:
    image = Image.new("RGB", (32, 24), "white")
    output = io.BytesIO()
    image.save(output, format="JPEG")
    return output.getvalue()


def make_request(**overrides) -> BearerOcrRequest:
    request = BearerOcrRequest(
        request_id="synthetic-request-001",
        method="POST",
        url=BAIDU_HANDWRITING_URL,
        auth_scheme="bearer",
        headers={"Content-Type": "application/x-www-form-urlencoded"},
        body=b"image=synthetic-form-body",
        timeout_seconds=17.0,
    )
    return replace(request, **overrides)


class MockVaultTransport:
    """Mocks MUSE placeholder replacement entirely inside the transport seam."""

    def __init__(self, reply: HelperHttpResponse | BaseException):
        self.reply = reply
        self.calls: list[tuple[bytes, dict[str, object]]] = []
        self.injected_authorization: list[str] = []

    def post_baidu_handwriting(self, body: bytes, **kwargs):
        self.calls.append((body, kwargs))
        if kwargs.get("credential_slot") != BAIDU_BEARER_CREDENTIAL_SLOT:
            raise AssertionError("unexpected credential slot")
        # Test-only stand-in for a Vault replacing its logical reference.
        self.injected_authorization.append(f"Bearer {MOCK_BEARER_VALUE}")
        if isinstance(self.reply, BaseException):
            raise self.reply
        return self.reply


class StdioHarness:
    def __init__(self, helper: BaiduHandwritingOcrHelper):
        self.helper = helper
        self.requests: list[bytes] = []
        self.timeouts: list[float] = []

    def __call__(self, stdin_payload: bytes, *, timeout_seconds: float) -> bytes:
        self.requests.append(stdin_payload)
        self.timeouts.append(timeout_seconds)
        stdout = io.BytesIO()
        serve_one_stdio_request(io.BytesIO(stdin_payload), stdout, self.helper)
        return stdout.getvalue()


def make_adapter(reply: HelperHttpResponse | BaseException):
    transport = MockVaultTransport(reply)
    helper = BaiduHandwritingOcrHelper(transport)
    harness = StdioHarness(helper)
    return SecureBearerConnectorAdapter(harness), transport, harness


class MuseSecureConnectorTests(unittest.TestCase):
    def test_form_body_crosses_stdin_and_mock_vault_injects_bearer(self):
        provider_body = b'{"words_result":[{"words":"SYNTHETIC OCR RESULT"}]}'
        adapter, transport, harness = make_adapter(HelperHttpResponse(200, provider_body))
        request = make_request()

        result = adapter.send(request)

        self.assertEqual(result.status_code, 200)
        self.assertEqual(result.body, provider_body)
        self.assertEqual(transport.calls[0][0], request.body)
        transport_kwargs = transport.calls[0][1]
        self.assertEqual(transport_kwargs["url"], BAIDU_HANDWRITING_URL)
        self.assertEqual(transport_kwargs["method"], "POST")
        self.assertEqual(transport_kwargs["content_type"], "application/x-www-form-urlencoded")
        self.assertEqual(transport_kwargs["allow_redirects"], False)
        self.assertEqual(transport_kwargs["timeout_seconds"], request.timeout_seconds)
        self.assertEqual(transport_kwargs["max_request_bytes"], BAIDU_FORM_BODY_MAX_BYTES)
        self.assertEqual(
            transport.injected_authorization,
            [f"Bearer {MOCK_BEARER_VALUE}"],
        )
        stdio_envelope = json.loads(harness.requests[0])
        self.assertEqual(
            set(stdio_envelope), {"request_id", "body_b64", "timeout_seconds"}
        )
        self.assertEqual(base64.b64decode(stdio_envelope["body_b64"]), request.body)
        self.assertEqual(harness.timeouts, [request.timeout_seconds + 5.0])
        self.assertNotIn("Authorization", stdio_envelope)
        self.assertNotIn("url", stdio_envelope)
        self.assertNotIn("method", stdio_envelope)

    def test_rejects_wrong_url_host_path_method_auth_and_headers_before_helper(self):
        invalid_requests = (
            make_request(url="https://example.invalid/rest/2.0/ocr/v1/handwriting"),
            make_request(url=f"https://{BAIDU_HANDWRITING_HOST}/other"),
            make_request(url=f"http://{BAIDU_HANDWRITING_HOST}{BAIDU_HANDWRITING_PATH}"),
            make_request(url=BAIDU_HANDWRITING_URL + "?redirect=1"),
            make_request(method="GET"),
            make_request(auth_scheme="none"),
            make_request(
                headers={
                    "Content-Type": "application/x-www-form-urlencoded",
                    "Authorization": "Bearer MOCK_ONLY_VALUE",
                }
            ),
            make_request(headers={"Content-Type": "text/plain"}),
        )
        adapter, transport, harness = make_adapter(HelperHttpResponse(200, b"{}"))

        for request in invalid_requests:
            with self.subTest(request=request.request_id, url=request.url, method=request.method):
                with self.assertRaises(SecureConnectorFailure):
                    adapter.send(request)

        self.assertEqual(transport.calls, [])
        self.assertEqual(harness.requests, [])

    def test_stdio_envelope_cannot_override_endpoint_or_method(self):
        transport = MockVaultTransport(HelperHttpResponse(200, b"{}"))
        helper = BaiduHandwritingOcrHelper(transport)
        payload = {
            "request_id": "synthetic-request-001",
            "body_b64": base64.b64encode(b"safe body").decode("ascii"),
            "timeout_seconds": 4,
            "url": "https://attacker.invalid/collect",
            "method": "GET",
        }
        stdout = io.BytesIO()

        serve_one_stdio_request(io.BytesIO(json.dumps(payload).encode()), stdout, helper)

        response = json.loads(stdout.getvalue())
        self.assertFalse(response["ok"])
        self.assertEqual(response["error"]["category"], "invalid_request")
        self.assertEqual(transport.calls, [])

    def test_redirect_is_not_followed_and_error_body_is_discarded(self):
        adapter, transport, _ = make_adapter(
            HelperHttpResponse(302, b"MOCK_REDIRECT_BODY_WITH_PRIVATE_TEXT")
        )

        result = adapter.send(make_request())

        self.assertEqual(result.status_code, 302)
        self.assertEqual(result.body, b"")
        self.assertEqual(len(transport.calls), 1)
        self.assertIs(transport.calls[0][1]["allow_redirects"], False)

    def test_timeout_and_network_errors_map_to_safe_connector_exceptions(self):
        cases = (
            (TimeoutError("MOCK_TIMEOUT_DETAIL"), SecureConnectorTimeout),
            (OSError("MOCK_NETWORK_DETAIL"), SecureConnectorFailure),
        )
        for raised, expected in cases:
            adapter, _, _ = make_adapter(raised)
            with self.subTest(expected=expected.__name__):
                with self.assertRaises(expected) as caught:
                    adapter.send(make_request())
                self.assertNotIn("MOCK_", str(caught.exception))

    def test_http_statuses_reach_existing_error_classification(self):
        cases = (
            (401, AuthenticationError),
            (403, AuthenticationError),
            (408, RequestTimeoutError),
            (429, RateLimitError),
            (503, HttpError),
        )
        for status, error_type in cases:
            adapter, _, _ = make_adapter(
                HelperHttpResponse(status, b"MOCK_RAW_PROVIDER_ERROR_BODY")
            )
            client = BaiduOcrClient(adapter)
            with self.subTest(status=status):
                with self.assertRaises(error_type) as caught:
                    client.recognize(
                        make_jpeg(),
                        full_image_authorized=True,
                        mime_type="image/jpeg",
                    )
                self.assertNotIn("MOCK_RAW_PROVIDER_ERROR_BODY", str(caught.exception))
                self.assertEqual(caught.exception.http_status, status)

    def test_raw_http_error_body_is_not_returned_on_stdio(self):
        private_error = b"MOCK_PROVIDER_ERROR_BODY_MUST_NOT_LEAVE_HELPER"
        transport = MockVaultTransport(HelperHttpResponse(401, private_error))
        helper = BaiduHandwritingOcrHelper(transport)
        request_body = b"synthetic form body"
        input_payload = json.dumps(
            {
                "request_id": "synthetic-request-001",
                "body_b64": base64.b64encode(request_body).decode("ascii"),
                "timeout_seconds": 8,
            }
        ).encode()
        stdout = io.BytesIO()

        serve_one_stdio_request(io.BytesIO(input_payload), stdout, helper)

        output = json.loads(stdout.getvalue())
        self.assertEqual(output["status_code"], 401)
        self.assertEqual(output["body_b64"], "")
        self.assertNotIn(private_error, stdout.getvalue())

    def test_stdout_is_structured_only_and_stderr_stays_empty(self):
        ocr_json = json.dumps(
            {"words_result": [{"words": MOCK_OCR_TEXT}]}, separators=(",", ":")
        ).encode()
        transport = MockVaultTransport(HelperHttpResponse(200, ocr_json))
        helper = BaiduHandwritingOcrHelper(transport)
        request_body = b"image=" + base64.b64encode(MOCK_IMAGE_MARKER)
        input_payload = json.dumps(
            {
                "request_id": "synthetic-request-001",
                "body_b64": base64.b64encode(request_body).decode("ascii"),
                "timeout_seconds": 8,
            },
            separators=(",", ":"),
        ).encode()
        stdout = io.BytesIO()
        stderr = io.StringIO()

        with redirect_stderr(stderr):
            serve_one_stdio_request(io.BytesIO(input_payload), stdout, helper)

        output_bytes = stdout.getvalue()
        output = json.loads(output_bytes)
        self.assertEqual(output["status_code"], 200)
        self.assertEqual(base64.b64decode(output["body_b64"]), ocr_json)
        self.assertNotIn(MOCK_OCR_TEXT.encode(), output_bytes)
        self.assertNotIn(MOCK_IMAGE_MARKER, output_bytes)
        self.assertNotIn(base64.b64encode(request_body), output_bytes)
        self.assertNotIn(MOCK_BEARER_VALUE.encode(), output_bytes)
        self.assertEqual(stderr.getvalue(), "")

    def test_helper_rejects_empty_oversize_and_invalid_timeout(self):
        transport = MockVaultTransport(HelperHttpResponse(200, b"{}"))
        helper = BaiduHandwritingOcrHelper(transport)

        invalid = (
            (b"", 4),
            (b"x" * (BAIDU_FORM_BODY_MAX_BYTES + 1), 4),
            (b"safe", 0),
            (b"safe", True),
        )
        for body, timeout in invalid:
            with self.subTest(body_length=len(body), timeout=timeout):
                with self.assertRaises(HelperRequestError):
                    helper.recognize(
                        body,
                        request_id="synthetic-request-001",
                        timeout_seconds=timeout,
                    )
        self.assertEqual(transport.calls, [])

    def test_subprocess_invoker_uses_stdin_no_shell_and_discards_stderr(self):
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
        call = runner.call_args
        self.assertEqual(call.args[0], ("/usr/bin/helper",))
        self.assertEqual(call.kwargs["input"], b'{"request":"synthetic"}')
        self.assertIs(call.kwargs["shell"], False)
        self.assertEqual(call.kwargs["env"], {})
        self.assertEqual(call.kwargs["stderr"], subprocess.PIPE)
        self.assertNotIn(b"MOCK_PRIVATE_STDERR", result)

    def test_subprocess_timeout_is_classified_without_stderr_details(self):
        runner = Mock(side_effect=subprocess.TimeoutExpired("/usr/bin/helper", 2))
        invoker = SubprocessStdioHelperInvoker(("/usr/bin/helper",), run=runner)
        with self.assertRaises(HelperInvocationTimeout):
            invoker(b"synthetic", timeout_seconds=2.0)

    def test_stdio_oversize_input_returns_structured_error(self):
        transport = MockVaultTransport(HelperHttpResponse(200, b"{}"))
        helper = BaiduHandwritingOcrHelper(transport)
        stdout = io.BytesIO()
        oversized = b" " * (MAX_STDIO_ENVELOPE_BYTES + 1)

        serve_one_stdio_request(io.BytesIO(oversized), stdout, helper)

        output = json.loads(stdout.getvalue())
        self.assertFalse(output["ok"])
        self.assertEqual(output["error"]["category"], "invalid_request")
        self.assertEqual(transport.calls, [])


if __name__ == "__main__":
    unittest.main()
