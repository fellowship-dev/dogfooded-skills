#!/usr/bin/env python3
"""Behavioral contract checks for the Trash Truck retirement workflow."""

from __future__ import annotations

import json
import re
from pathlib import Path


SKILL_ROOT = Path(__file__).resolve().parents[1]
REPO_ROOT = SKILL_ROOT.parents[2]
FIXTURE = Path(__file__).with_name("retirement-contract.json")


def check(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def score(candidate: dict[str, object]) -> float:
    return (
        float(candidate["confidence"]) * int(candidate["payoff"])
        - 0.25 * int(candidate["effort"])
        - 0.5 * int(candidate["risk"])
    )


def rank(candidates: list[dict[str, object]]) -> list[str]:
    eligible = [
        candidate
        for candidate in candidates
        if candidate["eligible"] and int(candidate["payoff"]) >= 2
    ]
    eligible.sort(
        key=lambda candidate: (
            -score(candidate),
            -float(candidate["confidence"]),
            -int(candidate["payoff"]),
            str(candidate["fingerprint"]),
        )
    )
    return [str(candidate["fingerprint"]) for candidate in eligible[:3]]


data = json.loads(FIXTURE.read_text())
skill = (SKILL_ROOT / "SKILL.md").read_text()
packet_path = SKILL_ROOT / "references" / "candidate-packet.md"
issue_path = SKILL_ROOT / "references" / "canonical-issue.md"

check(packet_path.exists(), "candidate packet reference must exist")
check(issue_path.exists(), "canonical issue reference must exist")

packet = packet_path.read_text()
issue = issue_path.read_text()

for case in data["ranking_cases"]:
    check(rank(case["candidates"]) == case["expected"], case["name"])

for case in data["evidence_cases"]:
    if case["name"] == "failed telemetry remains unknown":
        check(case["source_status"] == "failed", case["name"])
        check(case["claimed_zero_usage"] is False, case["name"])
        check(case["eligible_from_static_only"] is False, case["name"])
    if case["name"] == "positive deployed usage blocks retirement":
        check(case["positive_usage"] is True and case["eligible"] is False, case["name"])

for case in data["mode_cases"]:
    if case["mode"] == "scheduled":
        check(case["may_execute"] is False, case["name"])
        check(case["may_open_retirement_pr"] is False, case["name"])
    if case.get("selection_stale"):
        check(case["may_execute"] is False, case["name"])
    if case.get("pr_open"):
        check(case["state"] != "retired", case["name"])
    if case["mode"] == "interactive-target":
        check(case.get("may_nominate_unrelated", False) is False, case["name"])

for case in data["issue_cases"]:
    if case["name"] == "repeated schedules converge":
        check(case["matching_markers"] == case["canonical_issues_after"] == 1, case["name"])
    if case["name"] == "first no-candidate run creates nothing":
        check(case["should_write"] is False, case["name"])
    if case["name"] == "owner prose is preserved":
        check(case["owner_text_before"] == case["owner_text_after"], case["name"])

required_skill_contracts = [
    "mode:interactive",
    "mode:scheduled",
    "STOP",
    "zero to three",
    "candidate:<description>",
]
for contract in required_skill_contracts:
    check(contract in skill, f"SKILL.md is missing contract: {contract}")

check("pre-scan.sh" not in skill, "retired pre-scan must not remain in the workflow")
check("allowed-tools:" not in skill, "provider-specific tool whitelist must be removed")
check("user-invocable:" not in skill, "nonstandard frontmatter must be removed")
check("argument-hint:" not in skill, "nonstandard frontmatter must be removed")

for status in ("observed", "unavailable", "failed", "not-applicable"):
    check(re.search(rf"`{status}`", packet) is not None, f"missing evidence status: {status}")

for state in ("proposed", "selected", "retired", "kept", "insufficient", "superseded"):
    check(re.search(rf"`{state}`", issue) is not None, f"missing candidate state: {state}")

check("confidence * payoff - 0.25 * effort - 0.5 * risk" in packet, "ranking formula drifted")
check("<!-- trash-truck:retirement-review:v1 repo=OWNER/REPO -->" in issue, "canonical issue marker drifted")

workflow = (REPO_ROOT / ".github" / "workflows" / "tests.yml").read_text()
entrypoint = "./skills/ops/trash-truck/evals/test_retirement_contract.py"
check(entrypoint in workflow, "contract test must be registered in CI")

print("Trash Truck retirement contract passed.")
