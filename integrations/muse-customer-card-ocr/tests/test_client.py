from __future__ import annotations

import base64
import io
import json
import logging
import unittest
from urllib.parse import parse_qs

from PIL import Image

from muse_customer_card_ocr import (
    AuthenticationError,
    BaiduOcrClient,
    BearerOcrResponse,
    FullImageOcrNotAuthorizedError,
    HttpError,
    ImageInputError,
    ImageTooLargeError,
    InvalidResponseError,
    MissingSecureConnectorError,
    NetworkError,
    OcrResult,
    PermissionDeniedError,
    ProviderError,
    QuotaExceededError,
    RateLimitError,
    RequestTimeoutError,
    SecureConnectorFailure,
    SecureConnectorTimeout,
    recognize_customer_card,
)
from muse_customer_card_ocr.client import (
    BAIDU_FORM_BODY_MAX_BYTES,
    BAIDU_HANDWRITING_URL,
)
from muse_customer_card_ocr.images import MAX_INPUT_BYTES, PreparedImage


def make_image_bytes(
    image_format: str = "JPEG",
    *,
    size: tuple[int, int] = (80, 40),
) -> bytes:
    image = Image.new("RGB", size, "white")
    output = io.BytesIO()
    image.save(output, format=image_format)
    return output.getvalue()


def successful_ocr(text: str, *, log_id: int = 12345) -> dict:
    return {
        "log_id": log_id,
        "words_result_num": 1,
        "words_result": [
            {
                "words": text,
                "location": {"left": 3, "top": 4, "width": 24, "height": 8},
                "probability": {"average": 0.98, "variance": 0.01, "min": 0.94},
                "chars": [
                    {
                        "char": "S",
                        "location": {"left": 3, "top": 4, "width": 5, "height": 8},
                        "candidates": [{"word": "S", "prob": "0.99"}],
                    }
                ],
            }
        ],
    }


def response(payload=None, *, status_code: int = 200, invalid_json=False):
    if invalid_json:
        body = b"{not-json"
    else:
        body = json.dumps(payload).encode("utf-8")
    return BearerOcrResponse(status_code=status_code, body=body)


class MockSecureBearerConnector:
    def __init__(self, replies):
        self.replies = list(replies)
        self.requests = []
        self.closed = False

    def send(self, request):
        self.requests.append(request)
        if not self.replies:
            raise AssertionError("unexpected connector call")
        reply = self.replies.pop(0)
        if isinstance(reply, BaseException):
            raise reply
        return reply

    def close(self):
        self.closed = True


def make_client(replies, *, timeout=45.0):
    connector = MockSecureBearerConnector(replies)
    return BaiduOcrClient(connector, timeout=timeout), connector


class BaiduOcrClientTests(unittest.TestCase):
    def test_full_image_requires_explicit_authorization_before_connector(self):
        client, connector = make_client([])

        with self.assertRaises(FullImageOcrNotAuthorizedError) as caught:
            client.recognize(make_image_bytes(), mime_type="image/jpeg")

        self.assertEqual(caught.exception.code, "FULL_IMAGE_OCR_NOT_AUTHORIZED")
        self.assertEqual(connector.requests, [])

    def test_missing_secure_connector_fails_before_reading_image(self):
        client = BaiduOcrClient(None)

        with self.assertRaises(MissingSecureConnectorError):
            client.recognize(
                b"not-an-image",
                full_image_authorized=True,
                mime_type="image/jpeg",
            )

    def test_bearer_connector_request_has_no_secret_or_authorization_header(self):
        client, connector = make_client([response(successful_ocr("SYNTHETIC OCR"))])

        client.recognize(
            make_image_bytes(),
            full_image_authorized=True,
            mime_type="image/jpeg",
        )

        request = connector.requests[0]
        self.assertEqual(len(connector.requests), 1)
        self.assertEqual(request.method, "POST")
        self.assertEqual(request.auth_scheme, "bearer")
        self.assertEqual(request.url, BAIDU_HANDWRITING_URL)
        self.assertEqual(request.timeout_seconds, 45.0)
        self.assertNotIn("Authorization", request.headers)
        self.assertNotIn("access_token", request.url)
        self.assertFalse(hasattr(request, "token"))
        self.assertFalse(hasattr(request, "api_key"))

    def test_form_parameters_and_normalized_image_are_preserved(self):
        client, connector = make_client([response(successful_ocr("PNG SAMPLE"))])
        source = make_image_bytes("PNG")

        result = client.recognize(
            source,
            full_image_authorized=True,
            mime_type="image/png",
        )

        request = connector.requests[0]
        form = parse_qs(request.body.decode("ascii"))
        self.assertEqual(form["recognize_granularity"], ["small"])
        self.assertEqual(form["probability"], ["true"])
        normalized = base64.b64decode(form["image"][0])
        with Image.open(io.BytesIO(normalized)) as uploaded:
            self.assertEqual(uploaded.format, "JPEG")
        self.assertEqual(result.image_mime_type, "image/jpeg")
        self.assertEqual(result.to_dict()["upload"]["mode"], "full_image_authorized")

    def test_structured_result_preserves_coordinates_confidence_and_candidates(self):
        client, _ = make_client([response(successful_ocr("STRUCTURED SAMPLE"))])

        result = client.recognize(
            make_image_bytes(),
            full_image_authorized=True,
            mime_type="image/jpeg",
        )
        block = result.blocks[0]
        data = result.to_dict()

        self.assertIsInstance(result, OcrResult)
        self.assertEqual(block.location.left, 3)
        self.assertEqual(block.probability.average, 0.98)
        self.assertEqual(block.characters[0].text, "S")
        self.assertEqual(block.characters[0].candidates[0].probability, "0.99")
        self.assertEqual(data["service_log_id"], "12345")
        self.assertEqual(data["text"], "STRUCTURED SAMPLE")
        self.assertEqual(data["blocks"][0]["location"]["height"], 8)
        self.assertEqual(data["blocks"][0]["characters"][0]["candidates"][0]["text"], "S")

    def test_http_status_errors_are_classified_without_response_body(self):
        for status_code, error_type, code in (
            (401, AuthenticationError, "BAIDU_AUTHENTICATION_FAILED"),
            (403, AuthenticationError, "BAIDU_AUTHENTICATION_FAILED"),
            (429, RateLimitError, "BAIDU_RATE_LIMITED"),
            (408, RequestTimeoutError, "REQUEST_TIMEOUT"),
            (503, HttpError, "HTTP_ERROR"),
        ):
            client, connector = make_client(
                [response({"customer_text": "SYNTHETIC-PRIVATE-RESPONSE"}, status_code=status_code)]
            )
            with self.subTest(status_code=status_code):
                with self.assertRaises(error_type) as caught:
                    client.recognize(
                        make_image_bytes(),
                        full_image_authorized=True,
                        mime_type="image/jpeg",
                    )
                self.assertEqual(caught.exception.code, code)
                self.assertNotIn("SYNTHETIC-PRIVATE-RESPONSE", str(caught.exception))
                self.assertEqual(len(connector.requests), 1)

    def test_connector_timeout_and_failure_are_classified(self):
        for raised, error_type in (
            (SecureConnectorTimeout("synthetic timeout"), RequestTimeoutError),
            (SecureConnectorFailure("synthetic connector detail"), NetworkError),
        ):
            client, connector = make_client([raised])
            with self.subTest(error=type(raised).__name__):
                with self.assertRaises(error_type) as caught:
                    client.recognize(
                        make_image_bytes(),
                        full_image_authorized=True,
                        mime_type="image/jpeg",
                    )
                self.assertNotIn(str(raised), str(caught.exception))
                self.assertEqual(len(connector.requests), 1)

    def test_baidu_error_codes_are_classified(self):
        for provider_code, error_type in (
            (110, AuthenticationError),
            (18, RateLimitError),
            (17, QuotaExceededError),
            (6, PermissionDeniedError),
            (100, ProviderError),
        ):
            client, _ = make_client(
                [response({"error_code": provider_code, "error_msg": "SYNTHETIC-DETAIL"})]
            )
            with self.subTest(provider_code=provider_code):
                with self.assertRaises(error_type) as caught:
                    client.recognize(
                        make_image_bytes(),
                        full_image_authorized=True,
                        mime_type="image/jpeg",
                    )
                self.assertEqual(caught.exception.provider_code, provider_code)
                self.assertNotIn("SYNTHETIC-DETAIL", str(caught.exception))

    def test_invalid_response_and_json_are_classified(self):
        for reply in (
            response(invalid_json=True),
            response([]),
            object(),
        ):
            client, _ = make_client([reply])
            with self.subTest(reply=type(reply).__name__):
                with self.assertRaises(InvalidResponseError):
                    client.recognize(
                        make_image_bytes(),
                        full_image_authorized=True,
                        mime_type="image/jpeg",
                    )

    def test_invalid_image_and_oversize_are_rejected_before_connector(self):
        client, connector = make_client([])
        with self.assertRaises(ImageInputError):
            client.recognize(
                b"not-an-image",
                full_image_authorized=True,
                mime_type="image/jpeg",
            )
        self.assertEqual(connector.requests, [])

        too_large = b"x" * (MAX_INPUT_BYTES + 1)
        with self.assertRaises(ImageTooLargeError):
            client.recognize(too_large, full_image_authorized=True)
        self.assertEqual(connector.requests, [])

    def test_oversized_form_is_rejected(self):
        prepared = PreparedImage(
            image_bytes=b"x" * (BAIDU_FORM_BODY_MAX_BYTES * 3 // 4 + 1),
            mime_type="image/jpeg",
            width=100,
            height=100,
        )
        from muse_customer_card_ocr.client import _build_form_body

        with self.assertRaises(ImageTooLargeError):
            _build_form_body(prepared, request_id="synthetic-request")

    def test_multiple_images_have_independent_results(self):
        client, connector = make_client(
            [
                response(successful_ocr("FIRST IMAGE")),
                response(successful_ocr("SECOND IMAGE", log_id=54321)),
            ]
        )

        results = [
            client.recognize(
                image,
                full_image_authorized=True,
                mime_type=mime_type,
            )
            for image, mime_type in (
                (make_image_bytes(), "image/jpeg"),
                (make_image_bytes("PNG", size=(100, 50)), "image/png"),
            )
        ]

        self.assertEqual([item.text for item in results], ["FIRST IMAGE", "SECOND IMAGE"])
        self.assertNotEqual(results[0].request_id, results[1].request_id)
        self.assertNotEqual(results[0].service_log_id, results[1].service_log_id)
        self.assertEqual(len(connector.requests), 2)

    def test_logs_and_repr_do_not_expose_ocr_text_or_request_body(self):
        private_text = "SYNTHETIC-PRIVATE-TEXT"
        client, connector = make_client([response(successful_ocr(private_text))])

        with self.assertNoLogs(level=logging.DEBUG):
            result = client.recognize(
                make_image_bytes(),
                full_image_authorized=True,
                mime_type="image/jpeg",
            )

        self.assertNotIn(private_text, repr(result))
        self.assertNotIn(private_text, repr(connector.requests[0]))
        self.assertNotIn(base64.b64encode(make_image_bytes()).decode("ascii"), repr(connector.requests[0]))


if __name__ == "__main__":
    unittest.main()
