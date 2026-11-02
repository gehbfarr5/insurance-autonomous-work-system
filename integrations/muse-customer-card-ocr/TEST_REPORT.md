# Offline test report

- Date: 2026-11-02
- Package version: 0.1.0
- Branch: codex/wp2-muse-customer-card-ocr
- Runtime: macOS host, Python 3.14.7, Pillow 12.2.0, Requests 2.34.2
- Command: `PYTHONPATH=src /tmp/insurance-wp2-venv/bin/python -m unittest discover -s tests -v`
- Result: PASS — 25 tests, 0 failures, 0 errors
- Package check: PASS — `python -m pip install --no-deps -e .` built and installed version 0.1.0 in the isolated temporary venv
- Test data: generated blank JPEG/PNG images and synthetic in-memory Baidu responses only
- Network: mocked; no DNS lookup or HTTP request to Baidu was made
- Not verified: MUSE VM Python 3.12.3 runtime, Baidu credentials/quota, a real Baidu call, family-card masking, OCR accuracy on cards

## Test names

Client tests:

- `test_baidu_auth_rate_and_quota_codes_are_classified`
- `test_expired_token_is_refetched`
- `test_http_429_is_rate_limited`
- `test_invalid_image_is_rejected_before_network`
- `test_invalid_ocr_json_is_classified`
- `test_invalid_parameter_provider_code_is_not_mislabeled_authentication`
- `test_invalid_token_json_is_classified`
- `test_jpeg_bytes_call_and_token_is_cached`
- `test_multiple_images_have_independent_results`
- `test_no_logs_or_repr_include_credentials_or_ocr_text`
- `test_oversized_input_and_oversized_form_are_rejected`
- `test_png_is_converted_to_jpeg_and_api_params_are_preserved`
- `test_provider_rejected_token_is_discarded_for_next_call`
- `test_structured_result_preserves_coordinates_confidence_and_candidates`
- `test_timeout_is_classified_without_echoing_transport_details`
- `test_token_request_uses_documented_url_parameters`
- `test_unverified_mask_prevents_all_network_requests`
- `test_wrong_source_digest_or_incomplete_redaction_prevents_requests`

Image tests:

- `test_exif_orientation_is_applied_before_result_dimensions`
- `test_heic_and_mime_mismatch_are_rejected`
- `test_input_byte_limit_is_enforced`
- `test_jpeg_bytes_are_accepted`
- `test_large_dimensions_are_scaled_to_provider_maximum`
- `test_path_is_confined_to_configured_attachment_root`
- `test_png_is_accepted_and_normalized_to_jpeg`

These results establish only local offline behavior. They do not establish provider authentication, cloud connectivity, OCR accuracy, or safe masking of any real card template.
