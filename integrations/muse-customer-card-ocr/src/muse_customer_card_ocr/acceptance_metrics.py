"""Privacy-preserving aggregation for the real-card OCR acceptance run.

The input deliberately accepts only booleans and closed status/reason codes.
It never accepts OCR text, contact values, sample identifiers, or free-form
notes, and the output contains aggregate counts only.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any


SCHEMA_VERSION = "1.0"
MINIMUM_ELIGIBLE_SAMPLES = 30
FIELD_NAMES = (
    "main_customer",
    "name",
    "mobile",
    "identity_number",
    "gender",
    "explicit_birthday",
    "address",
    "other_phone",
)
CORE_ACCURACY_FIELDS = frozenset(
    {"main_customer", "name", "mobile", "identity_number"}
)
ACCURACY_STATES = frozenset({"PASS", "FAIL", "NOT_TESTED", "NOT_APPLICABLE"})
FAILURE_REASON_CODES = frozenset(
    {
        "OUT_OF_SCOPE_SAMPLE",
        "DUPLICATE_SAMPLE",
        "PRE_OCR_INPUT_CORRUPT",
        "OCR_SERVICE_ERROR",
        "OCR_NO_TEXT",
        "OCR_LOW_CONFIDENCE",
        "TABLE_LAYOUT_UNCERTAIN",
        "MAIN_CUSTOMER_UNCLEAR",
        "NAME_MISSING",
        "MOBILE_MISSING",
        "IDENTITY_NUMBER_MISSING",
        "GENDER_UNCERTAIN",
        "BIRTHDAY_UNCERTAIN",
        "ADDRESS_UNCERTAIN",
        "OTHER_PHONE_UNCERTAIN",
        "FIELD_CONFLICT",
        "FIELD_AMBIGUOUS",
        "MANUAL_CORRECTION_REQUIRED",
        "NO_DRAFT",
        "OTHER_REVIEW_REASON",
    }
)
EXCLUSION_REASON_CODES = frozenset(
    {"OUT_OF_SCOPE_SAMPLE", "DUPLICATE_SAMPLE", "PRE_OCR_INPUT_CORRUPT"}
)


class AcceptanceInputError(ValueError):
    """Raised when input is malformed or contains fields outside the schema."""


def _reject_duplicate_json_keys(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise AcceptanceInputError("Input JSON contains a duplicate property.")
        result[key] = value
    return result


def _require_object(value: Any, path: str, keys: set[str]) -> dict[str, Any]:
    if type(value) is not dict or set(value) != keys:
        raise AcceptanceInputError(f"{path} must contain exactly the documented fields.")
    return value


def _require_bool(value: Any, path: str) -> bool:
    if type(value) is not bool:
        raise AcceptanceInputError(f"{path} must be a boolean.")
    return value


def _require_string(value: Any, path: str, allowed: frozenset[str]) -> str:
    if type(value) is not str or value not in allowed:
        raise AcceptanceInputError(f"{path} must use one of the documented codes.")
    return value


def _empty_metric(status: str, denominator: int | None = None) -> dict[str, Any]:
    return {
        "numerator": None,
        "denominator": denominator,
        "rate_percent": None,
        "status": status,
    }


def _blocked_summary(blocking_reasons: list[str], study: dict[str, Any]) -> dict[str, Any]:
    return {
        "schema_version": SCHEMA_VERSION,
        "scope": "real-card OCR and reviewed-label metrics only",
        "real_card_ocr_result": "BLOCKED",
        "sample_gate": {
            "status": "BLOCKED",
            "authorization_confirmed": study["authorization_confirmed"],
            "distinct_real_cards_verified": study["distinct_real_cards_verified"],
            "reference_annotations_reviewed": study["reference_annotations_reviewed"],
            "minimum_eligible_samples": MINIMUM_ELIGIBLE_SAMPLES,
            "total_records": None,
            "eligible_samples": None,
            "excluded_samples": None,
            "blocking_reasons": blocking_reasons,
        },
        "auto_usable_drafts": _empty_metric("NOT_TESTED"),
        "manual_review_required": _empty_metric("NOT_TESTED"),
        "released_drafts": None,
        "released_draft_accuracy": {
            field: {
                "correct": None,
                "incorrect": None,
                "not_tested": None,
                "denominator": None,
                "accuracy_percent": None,
                "target": "100%" if field in CORE_ACCURACY_FIELDS else None,
                "status": "NOT_TESTED",
            }
            for field in FIELD_NAMES
        },
        "failure_reason_counts": {},
        "contact_safety": _contact_safety_not_tested(),
        "v1_0_stable_status": "VALIDATION_PENDING",
    }


def _contact_safety_not_tested() -> dict[str, dict[str, str]]:
    reason = "CONTACT_OPERATIONS_OUT_OF_SCOPE"
    return {
        "duplicate_miss": {"status": "NOT_TESTED", "reason_code": reason},
        "unconfirmed_create": {"status": "NOT_TESTED", "reason_code": reason},
        "existing_contact_overwrite_or_delete": {
            "status": "NOT_TESTED",
            "reason_code": reason,
        },
        "create_readback": {"status": "NOT_TESTED", "reason_code": reason},
    }


def _validate_sample(value: Any, index: int) -> dict[str, Any]:
    path = f"sample_results[{index}]"
    sample = _require_object(
        value,
        path,
        {
            "eligible",
            "auto_usable_draft",
            "manual_review_required",
            "released_for_confirmation",
            "field_accuracy",
            "failure_reason_codes",
        },
    )
    eligible = _require_bool(sample["eligible"], f"{path}.eligible")
    if type(sample["failure_reason_codes"]) is not list:
        raise AcceptanceInputError(f"{path}.failure_reason_codes must be a list.")
    failure_codes = [
        _require_string(code, f"{path}.failure_reason_codes", FAILURE_REASON_CODES)
        for code in sample["failure_reason_codes"]
    ]
    if len(failure_codes) != len(set(failure_codes)):
        raise AcceptanceInputError(f"{path}.failure_reason_codes must not contain duplicates.")
    if type(sample["released_for_confirmation"]) is not bool:
        raise AcceptanceInputError(f"{path}.released_for_confirmation must be a boolean.")
    released = sample["released_for_confirmation"]
    field_accuracy = _require_object(
        sample["field_accuracy"],
        f"{path}.field_accuracy",
        set(FIELD_NAMES),
    )

    if eligible:
        auto_usable = _require_bool(
            sample["auto_usable_draft"], f"{path}.auto_usable_draft"
        )
        review_required = _require_bool(
            sample["manual_review_required"], f"{path}.manual_review_required"
        )
        if auto_usable == review_required:
            raise AcceptanceInputError(
                f"{path} must be either auto-usable or require manual review."
            )
        if released and not (auto_usable or review_required):
            raise AcceptanceInputError(f"{path}.released_for_confirmation is inconsistent.")
        if any(code in EXCLUSION_REASON_CODES for code in failure_codes):
            raise AcceptanceInputError(f"{path} uses an exclusion reason for an eligible sample.")
        if released:
            normalized_accuracy = {
                field: _require_string(
                    field_accuracy[field],
                    f"{path}.field_accuracy.{field}",
                    ACCURACY_STATES - {"NOT_APPLICABLE"},
                )
                for field in FIELD_NAMES
            }
        else:
            normalized_accuracy = {
                field: _require_string(
                    field_accuracy[field],
                    f"{path}.field_accuracy.{field}",
                    frozenset({"NOT_APPLICABLE"}),
                )
                for field in FIELD_NAMES
            }
        return {
            "eligible": True,
            "auto_usable_draft": auto_usable,
            "manual_review_required": review_required,
            "released_for_confirmation": released,
            "field_accuracy": normalized_accuracy,
            "failure_reason_codes": failure_codes,
        }

    if sample["auto_usable_draft"] is not None or sample["manual_review_required"] is not None:
        raise AcceptanceInputError(f"{path} excluded samples must use null draft metrics.")
    if released:
        raise AcceptanceInputError(f"{path} excluded samples cannot be released.")
    if any(
        _require_string(
            field_accuracy[field],
            f"{path}.field_accuracy.{field}",
            frozenset({"NOT_APPLICABLE"}),
        )
        != "NOT_APPLICABLE"
        for field in FIELD_NAMES
    ):
        raise AcceptanceInputError(f"{path} excluded samples cannot have accuracy metrics.")
    if len(failure_codes) != 1 or failure_codes[0] not in EXCLUSION_REASON_CODES:
        raise AcceptanceInputError(f"{path} requires one documented exclusion reason.")
    return {
        "eligible": False,
        "auto_usable_draft": None,
        "manual_review_required": None,
        "released_for_confirmation": False,
        "field_accuracy": {field: "NOT_APPLICABLE" for field in FIELD_NAMES},
        "failure_reason_codes": failure_codes,
    }


def _ratio(numerator: int, denominator: int) -> float | None:
    if denominator == 0:
        return None
    return round((numerator / denominator) * 100, 4)


def _accuracy_metric(
    samples: list[dict[str, Any]], field: str, blocked: bool
) -> dict[str, Any]:
    released = [sample for sample in samples if sample["released_for_confirmation"]]
    denominator = len(released)
    correct = sum(sample["field_accuracy"][field] == "PASS" for sample in released)
    incorrect = sum(sample["field_accuracy"][field] == "FAIL" for sample in released)
    not_tested = sum(
        sample["field_accuracy"][field] == "NOT_TESTED" for sample in released
    )
    if blocked:
        status = "BLOCKED"
    elif denominator == 0:
        status = "NOT_TESTED"
    elif incorrect:
        status = "FAIL"
    elif not_tested:
        status = "NOT_TESTED"
    else:
        status = "PASS"
    return {
        "correct": correct,
        "incorrect": incorrect,
        "not_tested": not_tested,
        "denominator": denominator,
        "accuracy_percent": _ratio(correct, denominator),
        "target": "100%" if field in CORE_ACCURACY_FIELDS else None,
        "status": status,
    }


def aggregate_30_card_acceptance(payload: Any) -> dict[str, Any]:
    """Validate sanitized labels and return aggregate-only OCR acceptance metrics."""
    root = _require_object(
        payload,
        "input",
        {"schema_version", "study", "sample_results"},
    )
    if root["schema_version"] != SCHEMA_VERSION:
        raise AcceptanceInputError("input.schema_version is unsupported.")
    study = _require_object(
        root["study"],
        "input.study",
        {
            "authorization_confirmed",
            "distinct_real_cards_verified",
            "reference_annotations_reviewed",
        },
    )
    study_flags = {
        key: _require_bool(value, f"input.study.{key}")
        for key, value in study.items()
    }
    if type(root["sample_results"]) is not list:
        raise AcceptanceInputError("input.sample_results must be a list.")

    blocking_reasons = []
    if not study_flags["authorization_confirmed"]:
        blocking_reasons.append("REAL_DATA_AUTHORIZATION_NOT_CONFIRMED")
    if not study_flags["distinct_real_cards_verified"]:
        blocking_reasons.append("DISTINCT_REAL_CARD_SET_NOT_VERIFIED")
    if not study_flags["reference_annotations_reviewed"]:
        blocking_reasons.append("REFERENCE_ANNOTATIONS_NOT_REVIEWED")
    if blocking_reasons:
        return _blocked_summary(blocking_reasons, study_flags)

    samples = [
        _validate_sample(sample, index)
        for index, sample in enumerate(root["sample_results"])
    ]
    eligible_count = sum(sample["eligible"] for sample in samples)
    excluded_count = len(samples) - eligible_count
    sample_gate_passed = eligible_count >= MINIMUM_ELIGIBLE_SAMPLES
    gate_reasons = [] if sample_gate_passed else ["MINIMUM_ELIGIBLE_SAMPLE_COUNT_NOT_MET"]
    valid_samples = [sample for sample in samples if sample["eligible"]]
    released_count = sum(sample["released_for_confirmation"] for sample in valid_samples)
    auto_usable_count = sum(sample["auto_usable_draft"] for sample in valid_samples)
    review_required_count = sum(
        sample["manual_review_required"] for sample in valid_samples
    )
    auto_rate = _ratio(auto_usable_count, eligible_count)
    review_rate = _ratio(review_required_count, eligible_count)
    auto_status = (
        "BLOCKED"
        if not sample_gate_passed
        else "PASS"
        if auto_rate is not None and auto_rate >= 90.0
        else "FAIL"
    )
    review_status = "REPORTED" if eligible_count else "NOT_TESTED"

    accuracy = {
        field: _accuracy_metric(valid_samples, field, blocked=not sample_gate_passed)
        for field in FIELD_NAMES
    }
    core_statuses = [accuracy[field]["status"] for field in CORE_ACCURACY_FIELDS]
    if not sample_gate_passed:
        overall_result = "BLOCKED"
    elif "FAIL" in [auto_status, *core_statuses]:
        overall_result = "FAIL"
    elif auto_status != "PASS" or any(status != "PASS" for status in core_statuses):
        overall_result = "NOT_TESTED"
    else:
        overall_result = "PASS"

    failure_counts: dict[str, int] = {}
    for sample in samples:
        for code in sample["failure_reason_codes"]:
            failure_counts[code] = failure_counts.get(code, 0) + 1

    return {
        "schema_version": SCHEMA_VERSION,
        "scope": "real-card OCR and reviewed-label metrics only",
        "real_card_ocr_result": overall_result,
        "sample_gate": {
            "status": "PASS" if sample_gate_passed else "BLOCKED",
            "authorization_confirmed": study_flags["authorization_confirmed"],
            "distinct_real_cards_verified": study_flags[
                "distinct_real_cards_verified"
            ],
            "reference_annotations_reviewed": study_flags[
                "reference_annotations_reviewed"
            ],
            "minimum_eligible_samples": MINIMUM_ELIGIBLE_SAMPLES,
            "total_records": len(samples),
            "eligible_samples": eligible_count,
            "excluded_samples": excluded_count,
            "blocking_reasons": gate_reasons,
        },
        "auto_usable_drafts": {
            "numerator": auto_usable_count,
            "denominator": eligible_count,
            "rate_percent": auto_rate,
            "target_percent": 90.0,
            "status": auto_status,
        },
        "manual_review_required": {
            "numerator": review_required_count,
            "denominator": eligible_count,
            "rate_percent": review_rate,
            "status": review_status,
        },
        "released_drafts": released_count,
        "released_draft_accuracy": accuracy,
        "failure_reason_counts": dict(sorted(failure_counts.items())),
        "contact_safety": _contact_safety_not_tested(),
        "v1_0_stable_status": "VALIDATION_PENDING",
    }


def _load_json(path: Path) -> Any:
    try:
        with path.open("r", encoding="utf-8") as source:
            return json.load(source, object_pairs_hook=_reject_duplicate_json_keys)
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise AcceptanceInputError("Input file could not be read as valid UTF-8 JSON.") from exc


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Aggregate sanitized Family Card OCR acceptance labels."
    )
    parser.add_argument("input_json", type=Path, help="protected JSON input file")
    args = parser.parse_args(argv)
    try:
        summary = aggregate_30_card_acceptance(_load_json(args.input_json))
    except AcceptanceInputError as exc:
        print(f"acceptance input error: {exc}", file=sys.stderr)
        return 2
    json.dump(summary, sys.stdout, ensure_ascii=False, indent=2, sort_keys=True)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
