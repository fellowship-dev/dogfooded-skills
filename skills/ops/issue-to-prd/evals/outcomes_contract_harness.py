#!/usr/bin/env python3
"""Executable validation harness for issue-to-prd's outcomes-baseline /
causal-contract logic (stage 05c CONTEXT.md).

Exercises, without any live outcomes API call:
  1. The envelope row-selection algorithm (step 2), against the real fixture
     data embedded in evals/linked-metric-001.json - including that a
     same-envelope, differently-named metric row (pr_merged) is never
     selected in place of the named metric.
  2. The fail-open path against evals/outcomes-api-failure-001.json's
     curl-timeout string - must not raise, must yield a placeholder with
     placeholder_reason "unreachable".
  3. The full placeholder_reason branch set (auth / unreachable /
     no-matching-metric) documented in stage 05c CONTEXT.md, via synthetic
     HTTP responses that exercise branches the fixtures don't each cover.
  4. The no-causal-contract API-call gate against
     evals/no-causal-contract-001.json.

Run: python3 outcomes_contract_harness.py
"""
import json
import re
import sys
from pathlib import Path

EVAL_DIR = Path(__file__).resolve().parent
FAILURES = []


def check(label, condition):
    status = "PASS" if condition else "FAIL"
    print(f"[{status}] {label}")
    if not condition:
        FAILURES.append(label)


# --- envelope row-selection algorithm (stage 05c CONTEXT.md step 2) --------

def select_baseline(response_text, metric_name):
    """response_text is the raw evalTurn.text: "<http-status> <json-body>",
    or a bare curl-failure string with no HTTP status line at all. Mirrors
    stage 05c's placeholder_reason branches exactly."""
    m = re.match(r"^(\d{3})\s+(.*)$", response_text, re.DOTALL)
    if not m:
        # curl failed outright (non-zero exit) - no HTTP status line at all
        return {"status": "placeholder", "placeholder_reason": "unreachable"}

    http_status, body = m.group(1), m.group(2)
    if http_status in ("401", "403"):
        return {"status": "placeholder", "placeholder_reason": "auth"}
    if http_status != "200":
        return {"status": "placeholder", "placeholder_reason": "unreachable"}

    try:
        envelope = json.loads(body)
    except Exception:
        return {"status": "placeholder", "placeholder_reason": "unreachable"}

    rows = envelope.get("metrics", [])
    match = next((r for r in rows if r.get("metric") == metric_name), None)
    if match is None or match.get("sample_count", 0) == 0:
        return {"status": "placeholder", "placeholder_reason": "no-matching-metric"}

    return {
        "status": "fetched",
        "baseline": match.get("avg_value"),
        "source": envelope.get("source"),
        "window": (envelope.get("days"), match.get("first_day"), match.get("last_day")),
        "cohort": (match.get("scope"), envelope.get("org")),
        "sample_count": match.get("sample_count"),
    }


def should_fetch_baseline(contract):
    """Mirrors stage 05c step 2's gate: the outcomes API is called only when
    a linked-metric contract was detected in step 1."""
    return contract == "linked-metric"


# --- 1. real fixture: linked-metric-001.json --------------------------------

linked_metric_fixture = json.loads((EVAL_DIR / "linked-metric-001.json").read_text())
check(
    "linked-metric-001.json id matches expected scenario",
    linked_metric_fixture["id"] == "issue-to-prd-linked-metric-001",
)

scoped_fetch_turn = next(t for t in linked_metric_fixture["turns"] if t["id"] == "scoped-baseline-fetch")
api_response_text = scoped_fetch_turn["evalTurn"]["text"]

result = select_baseline(api_response_text, "time_to_merge_hours")
check("linked-metric fixture: status is fetched", result["status"] == "fetched")
check("linked-metric fixture: avg_value selected is 4.2, not pr_merged's 0.78", result.get("baseline") == 4.2)
check("linked-metric fixture: sample_count is 142", result.get("sample_count") == 142)
check("linked-metric fixture: source is outcomes_daily_rollup", result.get("source") == "outcomes_daily_rollup")
check(
    "linked-metric fixture: window carries days/first_day/last_day",
    result.get("window") == (30, "2026-07-28", "2026-08-26"),
)
check(
    "linked-metric fixture: cohort carries row scope + envelope org",
    result.get("cohort") == ("pr", "fellowship-dev"),
)

pr_merged_result = select_baseline(api_response_text, "pr_merged")
check(
    "linked-metric fixture: selecting pr_merged independently still ignores time_to_merge_hours",
    pr_merged_result.get("baseline") == 0.78,
)


# --- 2. real fixture: outcomes-api-failure-001.json (fail-open path) -------

api_failure_fixture = json.loads((EVAL_DIR / "outcomes-api-failure-001.json").read_text())
check(
    "outcomes-api-failure-001.json id matches expected scenario",
    api_failure_fixture["id"] == "issue-to-prd-outcomes-api-failure-001",
)

failure_turn = next(t for t in api_failure_fixture["turns"] if t["id"] == "contract-valid-api-down")
timeout_text = failure_turn["evalTurn"]["text"]

try:
    failure_result = select_baseline(timeout_text, "dashboard_load_ms")
    raised = False
except Exception:
    failure_result = {}
    raised = True
check("outcomes-api-failure fixture: select_baseline never raises on a curl timeout string", not raised)
check("outcomes-api-failure fixture: status is placeholder (fail-open, not blocked)", failure_result.get("status") == "placeholder")
check(
    "outcomes-api-failure fixture: placeholder_reason is unreachable (curl timeout, not auth)",
    failure_result.get("placeholder_reason") == "unreachable",
)


# --- 3. synthetic branch coverage for reasons the fixtures don't each hit --

auth_401 = select_baseline("401 Unauthorized", "time_to_merge_hours")
check("synthetic 401 response: placeholder_reason is auth", auth_401.get("placeholder_reason") == "auth")

auth_403 = select_baseline("403 Forbidden", "time_to_merge_hours")
check("synthetic 403 response: placeholder_reason is auth", auth_403.get("placeholder_reason") == "auth")

empty_metrics = select_baseline(
    '200 {"org":"fellowship-dev","days":30,"source":"outcomes_daily_rollup","metrics":[]}',
    "time_to_merge_hours",
)
check("synthetic empty metrics[]: placeholder_reason is no-matching-metric", empty_metrics.get("placeholder_reason") == "no-matching-metric")

sample_zero = select_baseline(
    '200 {"org":"fellowship-dev","days":30,"source":"outcomes_daily_rollup",'
    '"metrics":[{"scope":"pr","metric":"time_to_merge_hours","sample_count":0,'
    '"avg_value":4.2,"first_day":"2026-07-28","last_day":"2026-08-26"}]}',
    "time_to_merge_hours",
)
check("synthetic sample_count=0 row: placeholder_reason is no-matching-metric", sample_zero.get("placeholder_reason") == "no-matching-metric")


# --- 4. no-causal-contract gate (no-causal-contract-001.json) --------------

no_contract_fixture = json.loads((EVAL_DIR / "no-causal-contract-001.json").read_text())
check(
    "no-causal-contract-001.json id matches expected scenario",
    no_contract_fixture["id"] == "issue-to-prd-no-causal-contract-001",
)
check("should_fetch_baseline is False for contract=none", should_fetch_baseline("none") is False)
check("should_fetch_baseline is True for contract=linked-metric", should_fetch_baseline("linked-metric") is True)


print()
if FAILURES:
    print(f"{len(FAILURES)} check(s) FAILED:")
    for f in FAILURES:
        print(f"  - {f}")
    sys.exit(1)
else:
    print("All checks passed.")
    sys.exit(0)
