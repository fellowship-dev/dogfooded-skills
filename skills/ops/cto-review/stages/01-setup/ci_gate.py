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

    All three sources must be collected successfully.  `expected_checks` combines
    branch-protection/ruleset contexts; `pr_workflows` contains only workflow files
    that declare a pull-request trigger at the reviewed head.
    """
    for source in ("check_runs", "expected_checks", "pr_workflows"):
        if not payload.get(f"{source}_ok", False):
            return {"classification": BLOCK, "reason": f"{source} lookup failed"}

    runs = payload.get("check_runs")
    expected = payload.get("expected_checks")
    workflows = payload.get("pr_workflows")
    if not isinstance(runs, list) or not isinstance(expected, list) or not isinstance(workflows, list):
        return {"classification": BLOCK, "reason": "CI evidence has an invalid shape"}

    if not all(isinstance(name, str) for name in expected) or not all(isinstance(path, str) for path in workflows):
        return {"classification": BLOCK, "reason": "expected CI evidence has an invalid shape"}

    observed = {run.get("name") for run in runs if isinstance(run, dict) and isinstance(run.get("name"), str)}
    missing = [name for name in expected if name not in observed]
    if missing:
        return {"classification": BLOCK, "reason": f"expected check missing: {missing[0]}"}

    if not runs:
        if expected or workflows:
            source = "expected check" if expected else "pull-request workflow"
            return {"classification": BLOCK, "reason": f"no check runs returned despite configured {source}"}
        return {"classification": NA, "reason": RECEIPT_NA}

    for run in runs:
        if not isinstance(run, dict):
            return {"classification": BLOCK, "reason": "invalid check-run record"}
        name = run.get("name", "unnamed check")
        if run.get("status") != "completed":
            return {"classification": BLOCK, "reason": f"check pending: {name}"}
        if run.get("conclusion") != "success":
            return {"classification": BLOCK, "reason": f"check not successful: {name}"}
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
