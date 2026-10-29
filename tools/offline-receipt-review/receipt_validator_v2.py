"""Strict offline receipt / success-empty validator, v2. Pure, no device, no network.
v1 (synthetic-receipt-test.py, SHA256 1f41488625753c5f3871d60ffcf10d8bf2b1e84a0b40bd4c758d6e91c09e3880)
is retained unchanged; this file does not modify it. Candidate remains offline only: no collector binds these inputs to production.
Local review further binds last-answer tokens and all baseline records, and
request/response/assignment cycle tokens. This is not a live receipt implementation.
v1 bugs fixed here:
- error=None / error=str was accepted (v1 only rejected error is True)
- stopped=None / paused=None was accepted (v1 only rejected truthy)
- assigned="yes" (truthy str) was accepted for success-empty
- no same-question / last-answer / new-record / conversation / unselected-customer checks

Verdicts, desensitised reason codes only, never token values:
- ACCEPT: all required fields present, strict types, values match, associations match.
- REVIEW: a required field is missing (key absent). Evidence incomplete, not a failure.
- FAIL: a present field has wrong type/value, an association mismatches,
  a record is not new, a customer is selected, or the flow was stopped/paused.

Strict type rules:
- bool fields must be exactly bool (True/False), not 0/1, not "true"/"false", not None.
- parser_status and code must be exactly str "02" / "200", not int, not "DONE".
- endAnswerFlag must be exactly True (bool).
- tokens (question / conversation / record) are opaque: only presence (non-empty str),
  equality, and newness (new != previous) are checked; token values are never
  returned in any reason or output.
- answer_list must be a list; last answer must be the element at index len-1.
"""

def _missing(d, key):
    return key not in d

def _is_bool(v):
    return isinstance(v, bool)

def _is_nonempty_str(v):
    return isinstance(v, str) and len(v) > 0

def validate_ai_receipt(inp):
    """inp keys: question_token, answer_question_token, question_conversation_token,
    answer_conversation_token, previous_record_token, answer_list (list of dicts with
    record_token and endAnswerFlag), isAnswering, contentLoading, error, stopped,
    paused, parser_status, customer_selected.
    Returns (verdict, reasons list of codes)."""
    reasons = []
    # Missing checks first -> REVIEW (do not also claim FAIL for missing)
    required = ["question_token", "answer_question_token", "question_conversation_token",
                "answer_conversation_token", "previous_record_token", "answer_list",
                "isAnswering", "contentLoading", "error", "stopped", "paused",
                "parser_status", "customer_selected", "baseline_record_tokens"]
    for k in required:
        if _missing(inp, k):
            reasons.append(f"MISSING:{k}")
    if reasons:
        return "REVIEW", reasons
    # answer_list structure
    alist = inp["answer_list"]
    if not isinstance(alist, list) or len(alist) == 0:
        return "FAIL", ["TYPE:answer_list_not_nonempty_list"]
    last = alist[-1]
    if not isinstance(last, dict):
        return "FAIL", ["TYPE:last_answer_not_object"]
    if any(_missing(last, key) for key in ["record_token", "endAnswerFlag", "question_token", "conversation_token"]):
        return "REVIEW", ["MISSING:last_answer_field"]
    # Token presence / types (present but wrong type -> FAIL, not REVIEW)
    for k in ["question_token", "answer_question_token", "question_conversation_token",
              "answer_conversation_token", "previous_record_token"]:
        if not _is_nonempty_str(inp[k]):
            return "FAIL", [f"TYPE:{k}_not_nonempty_str"]
    if not _is_nonempty_str(last["record_token"]):
        return "FAIL", ["TYPE:last_record_token_not_nonempty_str"]
    # Strict bool fields
    for k in ["isAnswering", "contentLoading", "error", "stopped", "paused", "customer_selected"]:
        if not _is_bool(inp[k]):
            return "FAIL", [f"TYPE:{k}_not_bool"]
    # Strict bool value for endAnswerFlag
    if last["endAnswerFlag"] is not True:
        return "FAIL", ["VALUE:endAnswerFlag_not_True"]
    # Parser
    if not isinstance(inp["parser_status"], str) or inp["parser_status"] != "02":
        return "FAIL", ["VALUE:parser_status_not_02"]
    if inp["isAnswering"] is not False:
        return "FAIL", ["VALUE:isAnswering_not_False"]
    if inp["contentLoading"] is not False:
        return "FAIL", ["VALUE:contentLoading_not_False"]
    if inp["error"] is not False:
        return "FAIL", ["VALUE:error_not_False"]
    if inp["stopped"] is not False:
        return "FAIL", ["VALUE:stopped_not_False"]
    if inp["paused"] is not False:
        return "FAIL", ["VALUE:paused_not_False"]
    if inp["customer_selected"] is not False:
        return "FAIL", ["VALUE:customer_selected_not_False"]
    # Associations
    if inp["answer_question_token"] != inp["question_token"]:
        return "FAIL", ["MISMATCH:question_token"]
    if inp["answer_conversation_token"] != inp["question_conversation_token"]:
        return "FAIL", ["MISMATCH:conversation_token"]
    if last["question_token"] != inp["question_token"] or last["conversation_token"] != inp["question_conversation_token"]:
        return "FAIL", ["MISMATCH:last_answer_association"]
    baseline = inp["baseline_record_tokens"]
    if not isinstance(baseline, list) or not all(_is_nonempty_str(token) for token in baseline):
        return "FAIL", ["TYPE:baseline_record_tokens"]
    if inp["previous_record_token"] not in baseline:
        return "FAIL", ["MISMATCH:previous_not_in_baseline"]
    if last["record_token"] in baseline:
        return "FAIL", ["NOT_NEW_RECORD"]
    # New record: must differ from previous; previous token is present (checked above)
    if last["record_token"] == inp["previous_record_token"]:
        return "FAIL", ["NOT_NEW_RECORD"]
    # Last-answer check is structural: last is alist[-1] by construction.
    # If caller passed a separate last_answer that is not alist[-1], that is a
    # caller error; this validator only accepts alist[-1] as last, so no extra flag.
    return "ACCEPT", ["OK:all_strict_checks_pass"]


def validate_success_empty(inp):
    """inp keys: code, assigned, assigned_from_content, final_customers, requested.
    assigned / assigned_from_content / requested must be exactly bool True.
    code must be exactly str "200". final_customers must be exactly []."""
    required = ["code", "assigned", "assigned_from_content", "final_customers", "requested", "request_cycle", "response_cycle", "assignment_cycle"]
    reasons = []
    for k in required:
        if _missing(inp, k):
            reasons.append(f"MISSING:{k}")
    if reasons:
        return "REVIEW", reasons
    for key in ["request_cycle", "response_cycle", "assignment_cycle"]:
        if not _is_nonempty_str(inp[key]):
            return "FAIL", ["TYPE:cycle_not_nonempty_str"]
    if not (inp["request_cycle"] == inp["response_cycle"] == inp["assignment_cycle"]):
        return "FAIL", ["MISMATCH:request_response_assignment_cycle"]
    if not isinstance(inp["code"], str) or inp["code"] != "200":
        return "FAIL", ["VALUE:code_not_200_str"]
    for k in ["assigned", "assigned_from_content", "requested"]:
        if inp[k] is not True:
            # Covers False, None, "yes", 1, etc. with one strict rule.
            return "FAIL", [f"TYPE_OR_VALUE:{k}_not_True_bool"]
    if not isinstance(inp["final_customers"], list) or inp["final_customers"] != []:
        return "FAIL", ["VALUE:final_customers_not_empty_list"]
    return "ACCEPT", ["OK:all_strict_checks_pass"]
