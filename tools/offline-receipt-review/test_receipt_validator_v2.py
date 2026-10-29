"""Counterexample tests for receipt_validator_v2. Offline, synthetic tokens only.
Tokens are abstract letters (A/B, P/N) used only for equality, never printed as
values by the validator; test output prints verdict + reason codes only.
Run: python3 test_receipt_validator_v2.py
"""
import sys
sys.path.insert(0, __file__.rsplit("/", 1)[0])
from receipt_validator_v2 import validate_ai_receipt, validate_success_empty

def base_ai():
    return {
        "question_token": "Q", "answer_question_token": "Q",
        "question_conversation_token": "C", "answer_conversation_token": "C",
        "previous_record_token": "P", "baseline_record_tokens": ["P", "OLDER"],
        "answer_list": [{"record_token": "N", "endAnswerFlag": True, "question_token":"Q", "conversation_token":"C"}],
        "isAnswering": False, "contentLoading": False, "error": False,
        "stopped": False, "paused": False, "parser_status": "02",
        "customer_selected": False,
    }

def check(name, got, exp_verdict):
    verdict, reasons = got
    ok = verdict == exp_verdict
    print(f"{name}: verdict={verdict} expected={exp_verdict} reasons={reasons} {'PASS' if ok else 'FAIL'}")
    assert ok, name

def main():
    # Positive
    check("AI_POSITIVE", validate_ai_receipt(base_ai()), "ACCEPT")
    # v1 bugs -> v2 must reject
    d = base_ai(); d["error"] = None; check("AI_ERROR_NONE_v1_bug", validate_ai_receipt(d), "FAIL")
    d = base_ai(); d["error"] = "some error text"; check("AI_ERROR_STR_v1_bug", validate_ai_receipt(d), "FAIL")
    d = base_ai(); d["stopped"] = None; check("AI_STOPPED_NONE_v1_bug", validate_ai_receipt(d), "FAIL")
    d = base_ai(); d["paused"] = None; check("AI_PAUSED_NONE_v1_bug", validate_ai_receipt(d), "FAIL")
    d = base_ai(); d["error"] = 0; check("AI_ERROR_INT_0", validate_ai_receipt(d), "FAIL")
    d = base_ai(); d["isAnswering"] = 0; check("AI_ISANSWERING_INT_0", validate_ai_receipt(d), "FAIL")
    # Missing -> REVIEW, not FAIL
    d = base_ai(); del d["isAnswering"]; check("AI_MISSING_ISANSWERING", validate_ai_receipt(d), "REVIEW")
    d = base_ai(); del d["question_token"]; check("AI_MISSING_QUESTION", validate_ai_receipt(d), "REVIEW")
    d = base_ai(); del d["previous_record_token"]; check("AI_MISSING_PREVIOUS_RECORD", validate_ai_receipt(d), "REVIEW")
    # Association failures -> FAIL
    d = base_ai(); d["answer_question_token"] = "OTHER"; check("AI_QUESTION_MISMATCH", validate_ai_receipt(d), "FAIL")
    d = base_ai(); d["answer_conversation_token"] = "OTHER"; check("AI_CONVERSATION_MISMATCH", validate_ai_receipt(d), "FAIL")
    d = base_ai(); d["answer_list"] = [{"record_token": "P", "endAnswerFlag": True, "question_token":"Q", "conversation_token":"C"}]; check("AI_NOT_NEW_RECORD", validate_ai_receipt(d), "FAIL")
    d = base_ai(); d["answer_list"] = [{"record_token": "N", "endAnswerFlag": 1, "question_token":"Q", "conversation_token":"C"}]; check("AI_ENDFLAG_INT_1", validate_ai_receipt(d), "FAIL")
    d = base_ai(); d["parser_status"] = "DONE"; check("AI_PARSER_DONE_NOT_02", validate_ai_receipt(d), "FAIL")
    d = base_ai(); d["parser_status"] = 2; check("AI_PARSER_INT_2", validate_ai_receipt(d), "FAIL")
    d = base_ai(); d["customer_selected"] = True; check("AI_CUSTOMER_SELECTED", validate_ai_receipt(d), "FAIL")
    d = base_ai(); del d["customer_selected"]; check("AI_CUSTOMER_MISSING", validate_ai_receipt(d), "REVIEW")
    d = base_ai(); d["stopped"] = True; check("AI_STOPPED_TRUE", validate_ai_receipt(d), "FAIL")
    d = base_ai(); d["paused"] = True; check("AI_PAUSED_TRUE", validate_ai_receipt(d), "FAIL")
    d = base_ai(); d["answer_list"] = []; check("AI_EMPTY_LIST", validate_ai_receipt(d), "FAIL")
    # Last-answer structural: validator takes alist[-1] as last; a caller that
    # passes a non-last item separately is not accepted by construction.
    # Here alist has two items, last is the new one -> ACCEPT; if last is old -> FAIL
    d = base_ai(); d["answer_list"] = [{"record_token": "OLD", "endAnswerFlag": True, "question_token":"Q", "conversation_token":"C"}, {"record_token": "N", "endAnswerFlag": True, "question_token":"Q", "conversation_token":"C"}]; check("AI_LAST_IS_NEW", validate_ai_receipt(d), "ACCEPT")
    d = base_ai(); d["answer_list"] = [{"record_token": "N", "endAnswerFlag": True, "question_token":"Q", "conversation_token":"C"}, {"record_token": "P", "endAnswerFlag": True, "question_token":"Q", "conversation_token":"C"}]; check("AI_LAST_IS_PREVIOUS", validate_ai_receipt(d), "FAIL")

    d = base_ai(); d["answer_list"][-1]["record_token"] = "OLDER"; check("AI_OLDER_BASELINE_RECORD", validate_ai_receipt(d), "FAIL")
    d = base_ai(); d["answer_list"][-1]["question_token"] = "OTHER"; check("AI_LAST_QUESTION_MISMATCH", validate_ai_receipt(d), "FAIL")
    d = base_ai(); d["answer_list"][-1]["conversation_token"] = "OTHER"; check("AI_LAST_CONVERSATION_MISMATCH", validate_ai_receipt(d), "FAIL")
    d = base_ai(); del d["baseline_record_tokens"]; check("AI_BASELINE_MISSING", validate_ai_receipt(d), "REVIEW")
    # Success-empty
    def base_empty():
        return {"code": "200", "assigned": True, "assigned_from_content": True, "final_customers": [], "requested": True, "request_cycle": "R", "response_cycle": "R", "assignment_cycle": "R"}
    check("EMPTY_POSITIVE", validate_success_empty(base_empty()), "ACCEPT")
    e = base_empty(); e["assigned"] = "yes"; check("EMPTY_ASSIGNED_STR_v1_bug", validate_success_empty(e), "FAIL")
    e = base_empty(); e["assigned"] = 1; check("EMPTY_ASSIGNED_INT_1", validate_success_empty(e), "FAIL")
    e = base_empty(); e["assigned"] = None; check("EMPTY_ASSIGNED_NONE", validate_success_empty(e), "FAIL")
    e = base_empty(); e["code"] = 200; check("EMPTY_CODE_INT_200", validate_success_empty(e), "FAIL")
    e = base_empty(); e["code"] = "500"; check("EMPTY_CODE_500", validate_success_empty(e), "FAIL")
    e = base_empty(); del e["code"]; check("EMPTY_MISSING_CODE", validate_success_empty(e), "REVIEW")
    e = base_empty(); e["final_customers"] = ["x"]; check("EMPTY_NOT_EMPTY", validate_success_empty(e), "FAIL")
    e = base_empty(); e["requested"] = False; check("EMPTY_NOT_REQUESTED", validate_success_empty(e), "FAIL")
    e = base_empty(); e["assigned_from_content"] = "yes"; check("EMPTY_ASSIGNED_FROM_CONTENT_STR", validate_success_empty(e), "FAIL")
    e = base_empty(); e["response_cycle"] = "OLD"; check("EMPTY_STALE_RESPONSE", validate_success_empty(e), "FAIL")
    e = base_empty(); e["assignment_cycle"] = "OLD"; check("EMPTY_STALE_ASSIGNMENT", validate_success_empty(e), "FAIL")
    e = base_empty(); del e["request_cycle"]; check("EMPTY_NO_CYCLE", validate_success_empty(e), "REVIEW")
    print("ALL V2 COUNTEREXAMPLE TESTS PASS (offline, synthetic only, not a deployment)")

if __name__ == "__main__":
    main()
