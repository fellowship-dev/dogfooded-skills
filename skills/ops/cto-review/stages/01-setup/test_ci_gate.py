#!/usr/bin/env python3
"""Executable regression corpus for cto-review's three-state CI gate."""

from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from ci_gate import BLOCK, NA, PASS, RECEIPT_NA, classify_ci  # noqa: E402


GREEN = {"name": "test", "status": "completed", "conclusion": "success"}


def evidence(**overrides):
    result = {
        "check_runs_ok": True,
        "expected_checks_ok": True,
        "pr_workflows_ok": True,
        "check_runs": [],
        "expected_checks": [],
        "pr_workflows": [],
    }
    result.update(overrides)
    return result


def expect(name, expected, **payload):
    result = classify_ci(evidence(**payload))
    assert result["classification"] == expected, f"{name}: {result}"
    return result


def main() -> None:
    # Empty successful evidence is the only N/A path. This replays pylot PR #3176.
    replay = expect(
        "#3176 replay at 287675ba092984550cc8cfaf5c588bcdb56f0f20",
        NA,
        check_runs=[],
        expected_checks=[],
        pr_workflows=[],
    )
    assert replay["reason"] == RECEIPT_NA

    expect("configured green", PASS, check_runs=[GREEN], expected_checks=["test"])
    for conclusion in ("failure", "cancelled", "skipped", "neutral", "timed_out", "unknown"):
        expect(f"non-success conclusion {conclusion}", BLOCK,
               check_runs=[{**GREEN, "conclusion": conclusion}])
    expect("pending", BLOCK, check_runs=[{**GREEN, "status": "in_progress", "conclusion": None}])
    expect("expected but absent", BLOCK, check_runs=[GREEN], expected_checks=["required-lint"])
    expect("workflow configured but no run", BLOCK, pr_workflows=[".github/workflows/ci.yml"])
    for source in ("check_runs", "expected_checks", "pr_workflows"):
        expect(f"{source} lookup failure", BLOCK, **{f"{source}_ok": False})
    expect("malformed collection", BLOCK, check_runs={"total_count": 0})
    expect("malformed expected check", BLOCK, expected_checks=[{"context": "test"}])
    print("ci_gate: 16 fixtures passed")


if __name__ == "__main__":
    main()
