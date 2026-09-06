#!/usr/bin/env python3
"""Validate and rank normalized Trash Truck candidate evidence."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any


WEIGHTS = {
    "boundary": 0.10,
    "code": 0.15,
    "history": 0.20,
    "real_world": 0.35,
    "consumers": 0.10,
    "recurrence": 0.10,
}


def confidence(candidate: dict[str, Any]) -> float:
    checks = candidate["checks"]
    unknown = set(checks) - set(WEIGHTS)
    if unknown:
        raise ValueError(f"unknown confidence checks: {sorted(unknown)}")
    value = sum(WEIGHTS[check] for check in set(checks))
    value -= 0.25 * int(candidate.get("unresolved_contradictions", 0))
    value = max(0.0, min(1.0, value))
    if "real_world" not in checks:
        value = min(value, 0.65)
    if candidate.get("failed_decisive_source"):
        value = min(value, 0.50)
    if "recurrence" not in checks:
        value = min(value, 0.69)
    return round(value, 2)


def score(candidate: dict[str, Any]) -> float:
    return round(
        confidence(candidate) * int(candidate["payoff"])
        - 0.25 * int(candidate["effort"])
        - 0.5 * int(candidate["risk"]),
        2,
    )


def validate(candidate: dict[str, Any]) -> None:
    required = {"fingerprint", "checks", "payoff", "effort", "risk", "corroborated"}
    missing = required - set(candidate)
    if missing:
        raise ValueError(f"{candidate.get('fingerprint', '<unknown>')}: missing {sorted(missing)}")
    if not isinstance(candidate["checks"], list):
        raise ValueError(f"{candidate['fingerprint']}: checks must be a list")
    for field in ("payoff", "effort", "risk"):
        value = candidate[field]
        if not isinstance(value, int) or isinstance(value, bool) or not 0 <= value <= 4:
            raise ValueError(f"{candidate['fingerprint']}: {field} must be an integer from 0 to 4")
    if not isinstance(candidate["corroborated"], bool):
        raise ValueError(f"{candidate['fingerprint']}: corroborated must be boolean")
    for field in ("positive_use", "failed_decisive_source"):
        if field in candidate and not isinstance(candidate[field], bool):
            raise ValueError(f"{candidate['fingerprint']}: {field} must be boolean")
    if int(candidate.get("unresolved_contradictions", 0)) < 0:
        raise ValueError(f"{candidate['fingerprint']}: unresolved_contradictions cannot be negative")
    confidence(candidate)


def rank(candidates: list[dict[str, Any]]) -> list[dict[str, Any]]:
    for candidate in candidates:
        validate(candidate)
    eligible = [
        candidate
        for candidate in candidates
        if candidate["corroborated"]
        and not candidate.get("positive_use", False)
        and candidate["payoff"] >= 2
        and confidence(candidate) >= 0.70
        and score(candidate) > 0
    ]
    eligible.sort(
        key=lambda candidate: (
            -score(candidate),
            -confidence(candidate),
            -candidate["payoff"],
            candidate["fingerprint"],
        )
    )
    return [
        {**candidate, "confidence": confidence(candidate), "score": score(candidate)}
        for candidate in eligible[:3]
    ]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("input", nargs="?", help="JSON file; stdin when omitted")
    args = parser.parse_args()
    try:
        raw = Path(args.input).read_text() if args.input else sys.stdin.read()
        payload = json.loads(raw)
        candidates = payload["candidates"] if isinstance(payload, dict) else payload
        if not isinstance(candidates, list):
            raise ValueError("input must be a candidate list or an object with candidates")
        print(json.dumps({"candidates": rank(candidates)}, sort_keys=True))
        return 0
    except (OSError, json.JSONDecodeError, KeyError, TypeError, ValueError) as exc:
        print(json.dumps({"error": str(exc)}, sort_keys=True), file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
