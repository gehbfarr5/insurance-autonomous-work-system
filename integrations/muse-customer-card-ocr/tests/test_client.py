from __future__ import annotations

import base64
import io
import logging
import unittest
from urllib.parse import parse_qs

import requests
from PIL import Image

from muse_customer_card_ocr import (
    AuthenticationError,
    BaiduCredentials,
    BaiduOcrClient,
    ImageInputError,
    ImageTooLargeError,
    InvalidResponseError,
    MaskStatus,
    OcrResult,
    PrivacyMaskResult,
    PrivacyMaskUnverifiedError,
    ProviderError,
    QuotaExceededError,
    RateLimitError,
    RequestTimeoutError,
    REQUIRED_REDACTED_REGIONS,
    source_sha256,
)
from muse_customer_card_ocr.client import (
    BAIDU_HANDWRITING_URL,
    BAIDU_TOKEN_URL,
    BAIDU_FORM_BODY_MAX_BYTES,
)
from muse_customer_card_ocr.images import MAX_INPUT_BYTES, PreparedImage


def make_image_bytes(
    image_format: str = "JPEG",
    *,
    size: tuple[int, int] = (80, 40),
    orientation: int | None = None,
) -> bytes:
    image = Image.new("RGB", size, "white")
    output = io.BytesIO()
    kwargs = {}
    if orientation is not None:
        exif = Image.Exif()
        exif[274] = orientation
        kwargs["exif"] = exif
    image.save(output, format=image_format, **kwargs)
    return output.getvalue()


def make_privacy_mask(
    source: bytes,
    *,
    masked: bytes | None = None,
    mime_type: str = "image/jpeg",
    status: MaskStatus = MaskStatus.VERIFIED,
    redacted_regions: frozenset[str] = REQUIRED_REDACTED_REGIONS,
    policy_id: str = "synthetic-test-v1",
) -> PrivacyMaskResult:
    return PrivacyMaskResult(
        status=status,
        source_sha256=source_sha256(source),
        masked_image_bytes=masked if masked is not None else source,
        masked_mime_type=mime_type,
        policy_id=policy_id,
        redacted_regions=redacted_regions,
    )


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


class FakeResponse:
    def __init__(self, payload=None, *, status_code: int = 200, invalid_json=False):
        self.payload = payload
        self.status_code = status_code
        self.invalid_json = invalid_json

    def json(self):
        if self.invalid_json:
            raise ValueError("synthetic invalid JSON")
        return self.payload


class FakeSession:
    def __init__(self, responses):
        self.responses = list(responses)
        self.calls = []
        self.closed = False

    def post(self, url, **kwargs):
        self.calls.append((url, kwargs))
        if not self.responses:
            raise AssertionError("unexpected HTTP request")
        response = self.responses.pop(0)
        if isinstance(response, BaseException):
            raise response
        return response

    def close(self):
        self.closed = True


def make_client(responses, *, clock=lambda: 100.0):
    session = FakeSession(responses)
    client = BaiduOcrClient(
        BaiduCredentials("synthetic-ak", "synthetic-sk"),
        session=session,
        clock=clock,
    )
    return client, session


class BaiduOcrClientTests(unittest.TestCase):
    def test_jpeg_bytes_call_and_token_is_cached(self):
        source = make_image_bytes()
        mask = make_privacy_mask(source)
        client, session = make_client(
            [
                FakeResponse({"access_token": "synthetic-token", "expires_in": 3600}),
                FakeResponse(successful_ocr("FIRST SAMPLE")),
                FakeResponse(successful_ocr("SECOND SAMPLE", log_id=12346)),
            ]
        )

        first = client.recognize(source, mime_type="image/jpeg", privacy_mask=mask)
        second = client.recognize(source, mime_type="image/jpeg", privacy_mask=mask)

        self.assertEqual(first.text, "FIRST SAMPLE")
        self.assertEqual(second.text, "SECOND SAMPLE")
        self.assertEqual(len(session.calls), 3)
        self.assertEqual(session.calls[0][0], BAIDU_TOKEN_URL)
        self.assertEqual(session.calls[1][0], BAIDU_HANDWRITING_URL)
        self.assertEqual(
            session.calls[0][1]["params"],
            {
                "grant_type": "client_credentials",
                "client_id": "synthetic-ak",
                "client_secret": "synthetic-sk",
            },
        )
        self.assertNotIn("synthetic-sk", session.calls[0][0])
        client.close()

    def test_png_is_converted_to_jpeg_and_api_params_are_preserved(self):
        source = make_image_bytes("PNG")
        mask = make_privacy_mask(source, mime_type="image/png")
        client, session = make_client(
            [
                FakeResponse({"access_token": "synthetic-token", "expires_in": 3600}),
                FakeResponse(successful_ocr("PNG SAMPLE")),
            ]
        )

        result = client.recognize(source, mime_type="image/png", privacy_mask=mask)

        self.assertIsInstance(result, OcrResult)
        ocr_call = session.calls[1][1]
        self.assertEqual(ocr_call["params"], {"access_token": "synthetic-token"})
        form = parse_qs(ocr_call["data"].decode("ascii"))
        self.assertEqual(form["recognize_granularity"], ["small"])
        self.assertEqual(form["probability"], ["true"])
        normalized = base64.b64decode(form["image"][0])
        with Image.open(io.BytesIO(normalized)) as uploaded:
            self.assertEqual(uploaded.format, "JPEG")
        self.assertEqual(result.image_mime_type, "image/jpeg")

    def test_structured_result_preserves_coordinates_confidence_and_candidates(self):
        source = make_image_bytes()
        client, _ = make_client(
            [
                FakeResponse({"access_token": "synthetic-token", "expires_in": 3600}),
                FakeResponse(successful_ocr("STRUCTURED SAMPLE")),
            ]
        )

        result = client.recognize(
            source,
            mime_type="image/jpeg",
            privacy_mask=make_privacy_mask(source),
        )
        block = result.blocks[0]
        data = result.to_dict()

        self.assertEqual(block.location.left, 3)
        self.assertEqual(block.probability.average, 0.98)
        self.assertEqual(block.characters[0].text, "S")
        self.assertEqual(block.characters[0].candidates[0].probability, "0.99")
        self.assertEqual(data["service_log_id"], "12345")
        self.assertEqual(data["text"], "STRUCTURED SAMPLE")
        self.assertEqual(data["blocks"][0]["location"]["height"], 8)
        self.assertEqual(data["blocks"][0]["characters"][0]["candidates"][0]["text"], "S")

    def test_expired_token_is_refetched(self):
        now = [100.0]
        client, session = make_client(
            [
                FakeResponse({"access_token": "old-token", "expires_in": 3600}),
                FakeResponse(successful_ocr("FIRST")),
                FakeResponse({"access_token": "new-token", "expires_in": 3600}),
                FakeResponse(successful_ocr("SECOND")),
            ],
            clock=lambda: now[0],
        )

        first = make_image_bytes()
        client.recognize(
            first,
            mime_type="image/jpeg",
            privacy_mask=make_privacy_mask(first),
        )
        now[0] += 4000
        second = make_image_bytes()
        client.recognize(
            second,
            mime_type="image/jpeg",
            privacy_mask=make_privacy_mask(second),
        )

        self.assertEqual([call[0] for call in session.calls].count(BAIDU_TOKEN_URL), 2)
        self.assertEqual(session.calls[3][1]["params"], {"access_token": "new-token"})

    def test_provider_rejected_token_is_discarded_for_next_call(self):
        first = make_image_bytes()
        second = make_image_bytes(size=(90, 50))
        client, session = make_client(
            [
                FakeResponse({"access_token": "old-token", "expires_in": 3600}),
                FakeResponse({"error_code": 111, "error_msg": "synthetic"}),
                FakeResponse({"access_token": "fresh-token", "expires_in": 3600}),
                FakeResponse(successful_ocr("FRESH TOKEN")),
            ]
        )

        with self.assertRaises(AuthenticationError):
            client.recognize(
                first,
                mime_type="image/jpeg",
                privacy_mask=make_privacy_mask(first),
            )
        result = client.recognize(
            second,
            mime_type="image/jpeg",
            privacy_mask=make_privacy_mask(second),
        )

        self.assertEqual(result.text, "FRESH TOKEN")
        self.assertEqual([call[0] for call in session.calls].count(BAIDU_TOKEN_URL), 2)

    def test_invalid_parameter_provider_code_is_not_mislabeled_authentication(self):
        source = make_image_bytes()
        client, _ = make_client(
            [
                FakeResponse({"access_token": "synthetic-token", "expires_in": 3600}),
                FakeResponse({"error_code": 100, "error_msg": "synthetic"}),
            ]
        )

        with self.assertRaises(ProviderError) as caught:
            client.recognize(
                source,
                mime_type="image/jpeg",
                privacy_mask=make_privacy_mask(source),
            )
        self.assertEqual(caught.exception.provider_code, 100)

    def test_token_request_uses_documented_url_parameters(self):
        source = make_image_bytes()
        client, session = make_client(
            [
                FakeResponse({"access_token": "synthetic-token", "expires_in": 3600}),
                FakeResponse(successful_ocr("SAFE TOKEN PLACEMENT")),
            ]
        )
        client.recognize(
            source,
            mime_type="image/jpeg",
            privacy_mask=make_privacy_mask(source),
        )
        token_url, token_call = session.calls[0]
        self.assertEqual(token_url, BAIDU_TOKEN_URL)
        self.assertEqual(
            token_call["params"],
            {
                "grant_type": "client_credentials",
                "client_id": "synthetic-ak",
                "client_secret": "synthetic-sk",
            },
        )
        self.assertIsNone(token_call["data"])

    def test_timeout_is_classified_without_echoing_transport_details(self):
        source = make_image_bytes()
        client, session = make_client([requests.Timeout("synthetic timeout detail")])

        with self.assertRaises(RequestTimeoutError) as caught:
            client.recognize(
                source,
                mime_type="image/jpeg",
                privacy_mask=make_privacy_mask(source),
            )

        self.assertEqual(caught.exception.code, "REQUEST_TIMEOUT")
        self.assertNotIn("synthetic timeout detail", str(caught.exception))
        self.assertEqual(len(session.calls), 1)

    def test_http_429_is_rate_limited(self):
        source = make_image_bytes()
        client, _ = make_client(
            [
                FakeResponse({"access_token": "synthetic-token", "expires_in": 3600}),
                FakeResponse({"error_msg": "SYNTHETIC-PRIVATE-RESPONSE"}, status_code=429),
            ]
        )

        with self.assertRaises(RateLimitError):
            client.recognize(
                source,
                mime_type="image/jpeg",
                privacy_mask=make_privacy_mask(source),
            )

    def test_baidu_auth_rate_and_quota_codes_are_classified(self):
        for provider_code, error_type in (
            (110, AuthenticationError),
            (18, RateLimitError),
            (17, QuotaExceededError),
        ):
            source = make_image_bytes()
            client, _ = make_client(
                [
                    FakeResponse({"access_token": "synthetic-token", "expires_in": 3600}),
                    FakeResponse(
                        {
                            "error_code": provider_code,
                            "error_msg": "SYNTHETIC-PRIVATE-RESPONSE",
                        }
                    ),
                ]
            )
            with self.subTest(provider_code=provider_code):
                with self.assertRaises(error_type) as caught:
                    client.recognize(
                        source,
                        mime_type="image/jpeg",
                        privacy_mask=make_privacy_mask(source),
                    )
                self.assertEqual(caught.exception.provider_code, provider_code)
                self.assertNotIn("SYNTHETIC-PRIVATE-RESPONSE", str(caught.exception))

    def test_invalid_token_json_is_classified(self):
        source = make_image_bytes()
        client, _ = make_client([FakeResponse(invalid_json=True)])
        with self.assertRaises(InvalidResponseError):
            client.recognize(
                source,
                mime_type="image/jpeg",
                privacy_mask=make_privacy_mask(source),
            )

    def test_invalid_ocr_json_is_classified(self):
        source = make_image_bytes()
        client, _ = make_client(
            [
                FakeResponse({"access_token": "synthetic-token", "expires_in": 3600}),
                FakeResponse(invalid_json=True),
            ]
        )
        with self.assertRaises(InvalidResponseError):
            client.recognize(
                source,
                mime_type="image/jpeg",
                privacy_mask=make_privacy_mask(source),
            )

    def test_unverified_mask_prevents_all_network_requests(self):
        source = make_image_bytes()
        client, session = make_client([])
        unverified = make_privacy_mask(source, status=MaskStatus.UNVERIFIED)

        with self.assertRaises(PrivacyMaskUnverifiedError) as caught:
            client.recognize(source, mime_type="image/jpeg", privacy_mask=unverified)

        self.assertEqual(caught.exception.code, "PRIVACY_MASK_UNVERIFIED")
        self.assertEqual(session.calls, [])

    def test_wrong_source_digest_or_incomplete_redaction_prevents_requests(self):
        source = make_image_bytes()
        other_source = make_image_bytes(size=(90, 40))
        client, session = make_client([])

        with self.assertRaises(PrivacyMaskUnverifiedError):
            client.recognize(
                other_source,
                mime_type="image/jpeg",
                privacy_mask=make_privacy_mask(source),
            )
        incomplete = make_privacy_mask(
            source,
            redacted_regions=frozenset({"identity_number"}),
        )
        with self.assertRaises(PrivacyMaskUnverifiedError):
            client.recognize(source, mime_type="image/jpeg", privacy_mask=incomplete)
        self.assertEqual(session.calls, [])

    def test_invalid_image_is_rejected_before_network(self):
        source = b"not an image"
        client, session = make_client([])
        mask = make_privacy_mask(source, masked=make_image_bytes())

        with self.assertRaises(ImageInputError):
            client.recognize(source, mime_type="image/jpeg", privacy_mask=mask)
        self.assertEqual(session.calls, [])

    def test_oversized_input_and_oversized_form_are_rejected(self):
        source = b"x" * (MAX_INPUT_BYTES + 1)
        client, session = make_client([])
        mask = make_privacy_mask(source, masked=make_image_bytes())
        with self.assertRaises(ImageTooLargeError):
            client.recognize(source, privacy_mask=mask)
        self.assertEqual(session.calls, [])

        large_prepared = PreparedImage(
            image_bytes=b"x" * (BAIDU_FORM_BODY_MAX_BYTES * 3 // 4 + 1),
            mime_type="image/jpeg",
            width=100,
            height=100,
        )
        with self.assertRaises(ImageTooLargeError):
            client._build_form_body(large_prepared, request_id="synthetic-request")

    def test_multiple_images_have_independent_results(self):
        first = make_image_bytes()
        second = make_image_bytes("PNG", size=(100, 50))
        client, session = make_client(
            [
                FakeResponse({"access_token": "synthetic-token", "expires_in": 3600}),
                FakeResponse(successful_ocr("FIRST IMAGE")),
                FakeResponse(successful_ocr("SECOND IMAGE", log_id=54321)),
            ]
        )

        results = [
            client.recognize(
                image,
                mime_type=mime,
                privacy_mask=make_privacy_mask(image, mime_type=mime),
            )
            for image, mime in ((first, "image/jpeg"), (second, "image/png"))
        ]

        self.assertEqual([item.text for item in results], ["FIRST IMAGE", "SECOND IMAGE"])
        self.assertNotEqual(results[0].request_id, results[1].request_id)
        self.assertNotEqual(results[0].service_log_id, results[1].service_log_id)
        self.assertEqual(len(session.calls), 3)

    def test_no_logs_or_repr_include_credentials_or_ocr_text(self):
        source = make_image_bytes()
        sensitive_text = "SYNTHETIC-PRIVATE-TEXT"
        client, _ = make_client(
            [
                FakeResponse({"access_token": "synthetic-token", "expires_in": 3600}),
                FakeResponse(successful_ocr(sensitive_text)),
            ]
        )

        with self.assertNoLogs(level=logging.DEBUG):
            result = client.recognize(
                source,
                mime_type="image/jpeg",
                privacy_mask=make_privacy_mask(source),
            )
        self.assertNotIn("synthetic-ak", repr(client._credentials))
        self.assertNotIn("synthetic-sk", repr(client._credentials))
        self.assertNotIn("synthetic-token", repr(client))
        self.assertNotIn(sensitive_text, repr(result))


if __name__ == "__main__":
    unittest.main()
