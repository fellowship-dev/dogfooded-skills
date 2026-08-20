#!/usr/bin/env python3
"""Fail-closed CI classification shared by the cto-review setup procedure and fixtures."""

from __future__ import annotations

import json
import sys
from typing import Any


NA = "na-no-configured-checks"
PASS = "pass"
BLOCK = "block"
RECEIPT_NA = "CI: N/A — no configured checks"


def classify_ci(payload: dict[str, Any]) -> dict[str, str]:
    """Classify CI evidence collected at one reviewed PR head.

    All four sources must be collected successfully.  `expected_checks` combines
    branch-protection/ruleset contexts; `pr_workflows` contains only workflow files
    that declare a pull-request trigger at the reviewed head; `commit_statuses`
    captures legacy status contexts which are not returned by the check-runs API.
    """
    for source in ("check_runs", "commit_statuses", "expected_checks", "pr_workflows"):
        if not payload.get(f"{source}_ok", False):
            return {"classification": BLOCK, "reason": f"{source} lookup failed"}

    runs = payload.get("check_runs")
    statuses = payload.get("commit_statuses")
    expected = payload.get("expected_checks")
    workflows = payload.get("pr_workflows")
    if (not isinstance(runs, list) or not isinstance(statuses, list)
            or not isinstance(expected, list) or not isinstance(workflows, list)):
        return {"classification": BLOCK, "reason": "CI evidence has an invalid shape"}

    if not all(isinstance(name, str) for name in expected) or not all(isinstance(path, str) for path in workflows):
        return {"classification": BLOCK, "reason": "expected CI evidence has an invalid shape"}

    if not all(isinstance(run, dict) and isinstance(run.get("name"), str) and run["name"] for run in runs):
        return {"classification": BLOCK, "reason": "invalid check-run record"}
    if not all(isinstance(status, dict) and isinstance(status.get("context"), str) and status["context"]
               for status in statuses):
        return {"classification": BLOCK, "reason": "invalid commit-status record"}

    observed = {run["name"] for run in runs} | {status["context"] for status in statuses}
    missing = [name for name in expected if name not in observed]
    if missing:
        return {"classification": BLOCK, "reason": f"expected check missing: {missing[0]}"}

    if not runs and not statuses:
        if expected or workflows:
            source = "expected check" if expected else "pull-request workflow"
            return {"classification": BLOCK, "reason": f"no check runs returned despite configured {source}"}
        return {"classification": NA, "reason": RECEIPT_NA}

    for run in runs:
        name = run["name"]
        if run.get("status") != "completed":
            return {"classification": BLOCK, "reason": f"check pending: {name}"}
        if run.get("conclusion") != "success":
            return {"classification": BLOCK, "reason": f"check not successful: {name}"}
    for status in statuses:
        if status.get("state") != "success":
            return {"classification": BLOCK, "reason": f"commit status not successful: {status['context']}"}
    return {"classification": PASS, "reason": "all observed checks successful"}


def main() -> None:
    try:
        payload = json.load(sys.stdin)
    except (json.JSONDecodeError, OSError) as exc:
        print(json.dumps({"classification": BLOCK, "reason": f"CI evidence parse failed: {exc}"}))
        return
    print(json.dumps(classify_ci(payload), sort_keys=True))


if __name__ == "__main__":
    main()
