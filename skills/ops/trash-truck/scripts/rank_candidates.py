#!/usr/bin/env python3
"""Validate and rank normalized Trash Truck candidate evidence."""

from __future__ import annotations

import argparse
import hashlib
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
    if not isinstance(candidate["fingerprint"], str) or not candidate["fingerprint"].strip():
        raise ValueError("fingerprint must be a non-empty string")
    if candidate["fingerprint"] != candidate["fingerprint"].strip().lower():
        raise ValueError(f"{candidate['fingerprint']}: fingerprint must be normalized lowercase")
    if any(not isinstance(check, str) for check in candidate["checks"]):
        raise ValueError(f"{candidate['fingerprint']}: checks must contain strings")
    if len(candidate["checks"]) != len(set(candidate["checks"])):
        raise ValueError(f"{candidate['fingerprint']}: checks must be unique")
    for field in ("payoff", "effort", "risk"):
        value = candidate[field]
        if not isinstance(value, int) or isinstance(value, bool) or not 0 <= value <= 4:
            raise ValueError(f"{candidate['fingerprint']}: {field} must be an integer from 0 to 4")
    if not isinstance(candidate["corroborated"], bool):
        raise ValueError(f"{candidate['fingerprint']}: corroborated must be boolean")
    for field in ("positive_use", "failed_decisive_source"):
        if field in candidate and not isinstance(candidate[field], bool):
            raise ValueError(f"{candidate['fingerprint']}: {field} must be boolean")
    contradictions = candidate.get("unresolved_contradictions", 0)
    if not isinstance(contradictions, int) or isinstance(contradictions, bool) or contradictions < 0:
        raise ValueError(f"{candidate['fingerprint']}: unresolved_contradictions must be a non-negative integer")
    confidence(candidate)


def rank(candidates: list[dict[str, Any]]) -> list[dict[str, Any]]:
    for candidate in candidates:
        validate(candidate)
    fingerprints = [candidate["fingerprint"] for candidate in candidates]
    if len(fingerprints) != len(set(fingerprints)):
        raise ValueError("candidate fingerprints must be unique")
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


def resolve_mode(mode: str, candidate: str | None, persist: str | None) -> str:
    if not isinstance(mode, str):
        raise ValueError("mode must be a string")
    if candidate is not None and not isinstance(candidate, str):
        raise ValueError("candidate must be a string or null")
    if persist is not None and not isinstance(persist, str):
        raise ValueError("persist must be a string or null")
    if mode not in {"interactive", "scheduled"}:
        raise ValueError("mode must be interactive or scheduled")
    if candidate is not None and (mode != "interactive" or not candidate.strip()):
        raise ValueError("candidate requires interactive mode and a non-empty description")
    if persist is not None and (mode != "scheduled" or persist != "github"):
        raise ValueError("persist:github is valid only in scheduled mode")
    return "interactive-target" if candidate is not None else mode


def approval_valid(selected: dict[str, Any], current: dict[str, Any]) -> bool:
    if not isinstance(selected, dict) or not isinstance(current, dict):
        raise ValueError("selected and current approval packets must be objects")
    keys = ("fingerprint", "manifest_digest", "repo_head", "deployed_revision")
    return (
        all(key in selected and key in current and selected[key] == current[key] for key in keys)
        and current.get("eligible") is True
        and current.get("decisive_sources_current") is True
        and not current.get("invalidators")
    )


def persistence_action(
    *,
    persist_requested: bool,
    candidate_count: int,
    issue_exists: bool,
    material_change: bool,
    duplicate_count: int,
    write_authorized: bool,
    serialized: bool,
) -> str:
    boolean_fields = {
        "persist_requested": persist_requested,
        "issue_exists": issue_exists,
        "material_change": material_change,
        "write_authorized": write_authorized,
        "serialized": serialized,
    }
    if any(not isinstance(value, bool) for value in boolean_fields.values()):
        raise ValueError("persistence flags must be boolean")
    if any(not isinstance(value, int) or isinstance(value, bool) or value < 0 for value in (candidate_count, duplicate_count)):
        raise ValueError("candidate_count and duplicate_count must be non-negative integers")
    if not persist_requested:
        return "not-requested"
    if duplicate_count > 1:
        return "blocked"
    if (not issue_exists and candidate_count == 0) or (issue_exists and not material_change):
        return "not-needed"
    if not write_authorized or not serialized:
        return "blocked"
    return "update" if issue_exists else "create"


MATERIAL_TOP_LEVEL = ("repository", "repo_head", "deployed_revision")
MATERIAL_CANDIDATE = (
    "fingerprint", "state", "confidence", "payoff", "effort", "risk", "score",
    "manifest_digest", "exclusions", "unresolved_gaps",
)
MATERIAL_EVIDENCE = (
    "surface", "status", "query_scope", "environment", "identity_denominator",
    "revision", "finding", "recurrence_adequate", "freshness_status",
)


def material_digest(packet: dict[str, Any]) -> str:
    projection = {key: packet.get(key) for key in MATERIAL_TOP_LEVEL}
    projection["candidates"] = [
        {key: candidate.get(key) for key in MATERIAL_CANDIDATE}
        for candidate in sorted(packet.get("candidates", []), key=lambda item: item["fingerprint"])
    ]
    evidence_projection = [
        {key: envelope.get(key) for key in MATERIAL_EVIDENCE}
        for envelope in packet.get("evidence", [])
    ]
    projection["evidence"] = sorted(
        evidence_projection,
        key=lambda item: json.dumps(item, sort_keys=True, separators=(",", ":")),
    )
    canonical = json.dumps(projection, sort_keys=True, separators=(",", ":"))
    return hashlib.sha256(canonical.encode()).hexdigest()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("rank", "digest", "mode", "approval", "persistence"))
    parser.add_argument("input", nargs="?", help="JSON file; stdin when omitted")
    args = parser.parse_args()
    try:
        raw = Path(args.input).read_text() if args.input else sys.stdin.read()
        payload = json.loads(raw)
        if args.command != "rank" and not isinstance(payload, dict):
            raise ValueError(f"{args.command} input must be an object")
        if args.command == "rank":
            candidates = payload["candidates"] if isinstance(payload, dict) else payload
            if not isinstance(candidates, list):
                raise ValueError("input must be a candidate list or an object with candidates")
            output = {"candidates": rank(candidates)}
        elif args.command == "digest":
            output = {"digest": material_digest(payload)}
        elif args.command == "mode":
            output = {"mode": resolve_mode(payload.get("mode"), payload.get("candidate"), payload.get("persist"))}
        elif args.command == "approval":
            output = {"valid": approval_valid(payload["selected"], payload["current"])}
        else:
            output = {"action": persistence_action(**payload)}
        print(json.dumps(output, sort_keys=True))
        return 0
    except (OSError, json.JSONDecodeError, KeyError, TypeError, ValueError) as exc:
        print(json.dumps({"error": str(exc)}, sort_keys=True), file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
