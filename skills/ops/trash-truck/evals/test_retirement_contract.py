#!/usr/bin/env python3
"""Behavioral contract checks for the Trash Truck retirement workflow."""

from __future__ import annotations

import importlib.util
import json
import re
import subprocess
import sys
from copy import deepcopy
from pathlib import Path


SKILL_ROOT = Path(__file__).resolve().parents[1]
REPO_ROOT = SKILL_ROOT.parents[2]
FIXTURE = Path(__file__).with_name("retirement-contract.json")
RANKER_PATH = SKILL_ROOT / "scripts" / "rank_candidates.py"


def check(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("trash_truck_ranker", RANKER_PATH)
check(spec is not None and spec.loader is not None, "ranking validator must load")
ranker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ranker)


def run_cli(command: str, payload: object) -> tuple[int, dict[str, object]]:
    result = subprocess.run(
        [sys.executable, str(RANKER_PATH), command],
        input=json.dumps(payload),
        text=True,
        capture_output=True,
        check=False,
    )
    output = result.stdout if result.returncode == 0 else result.stderr
    return result.returncode, json.loads(output)


data = json.loads(FIXTURE.read_text())
skill = (SKILL_ROOT / "SKILL.md").read_text()
packet_path = SKILL_ROOT / "references" / "candidate-packet.md"
issue_path = SKILL_ROOT / "references" / "canonical-issue.md"

check(packet_path.exists(), "candidate packet reference must exist")
check(issue_path.exists(), "canonical issue reference must exist")

packet = packet_path.read_text()
issue = issue_path.read_text()

for case in data["ranking_cases"]:
    actual = [candidate["fingerprint"] for candidate in ranker.rank(case["candidates"])]
    check(actual == case["expected"], case["name"])

code, ranked = run_cli("rank", {"candidates": data["ranking_cases"][0]["candidates"]})
check(code == 0, "rank command must succeed")
check([candidate["fingerprint"] for candidate in ranked["candidates"]] == data["ranking_cases"][0]["expected"], "rank command must use production ordering")

failed_source = next(
    candidate
    for candidate in data["ranking_cases"][0]["candidates"]
    if candidate["fingerprint"].endswith(":telemetry-gap")
)
check(ranker.confidence(failed_source) == 0.50, "failed decisive telemetry must cap confidence")
check(ranker.rank([failed_source]) == [], "failed decisive telemetry cannot be nominated")

positive_use = next(
    candidate
    for candidate in data["ranking_cases"][0]["candidates"]
    if candidate["fingerprint"].endswith(":seasonal-billing")
)
check(ranker.rank([positive_use]) == [], "positive verified use must block retirement nomination")

invalid_boolean = {**positive_use, "positive_use": "false"}
try:
    ranker.rank([invalid_boolean])
except ValueError:
    pass
else:
    raise AssertionError("optional boolean fields must be type-checked")

for case in data["evidence_cases"]:
    if case["name"] == "failed telemetry remains unknown":
        check(case["source_status"] == "failed", case["name"])
        check(case["claimed_zero_usage"] is False, case["name"])
        check(case["eligible_from_static_only"] is False, case["name"])
    if case["name"] == "positive deployed usage blocks retirement":
        check(case["positive_usage"] is True and case["eligible"] is False, case["name"])

for case in data["mode_cases"]:
    code, output = run_cli("mode", {key: case[key] for key in ("mode", "candidate", "persist")})
    if code != 0:
        check(case.get("error") is True, case["name"])
    else:
        check(not case.get("error"), case["name"])
        check(output["mode"] == case["expected"], case["name"])

for case in data["approval_cases"]:
    code, output = run_cli("approval", {"selected": case["selected"], "current": case["current"]})
    check(code == 0 and output["valid"] is case["expected"], case["name"])

for case in data["persistence_cases"]:
    inputs = {key: value for key, value in case.items() if key not in {"name", "expected"}}
    code, output = run_cli("persistence", inputs)
    check(code == 0 and output["action"] == case["expected"], case["name"])

digest_packet = data["digest_case"]
digest = ranker.material_digest(digest_packet)
transport_change = deepcopy(digest_packet)
transport_change["run_timestamp"] = "2026-09-05T13:00:00Z"
transport_change["write_status"] = "verified"
transport_change["evidence_cutoff"] = "2026-09-01/2026-09-06"
transport_change["evidence"][0]["collected_at"] = "2026-09-05T13:00:00Z"
transport_change["evidence"][0]["receipt"] = "new-private-query"
transport_change["evidence"][0]["query"] = "same scope with different raw syntax"
transport_change["evidence"][0]["window"] = "2026-06-01/2026-09-06"
transport_change["evidence"][0]["fresh_until"] = "2026-09-09"
transport_change["evidence"].reverse()
check(ranker.material_digest(transport_change) == digest, "transport metadata must not change material digest")
material_change = deepcopy(digest_packet)
material_change["evidence"][0]["recurrence_adequate"] = False
check(ranker.material_digest(material_change) != digest, "recurrence adequacy changes must change material digest")
code, output = run_cli("digest", digest_packet)
check(code == 0 and output["digest"] == digest, "digest command must use production projection")

base_candidate = data["ranking_cases"][0]["candidates"][0]
for invalid in (
    {**base_candidate, "fingerprint": ""},
    {**base_candidate, "fingerprint": "Acme/App:Legacy"},
    {**base_candidate, "checks": ["boundary", "boundary"]},
    {**base_candidate, "unresolved_contradictions": True},
    {**base_candidate, "unresolved_contradictions": 0.5},
    {**base_candidate, "unresolved_contradictions": "1"},
):
    try:
        ranker.rank([invalid])
    except ValueError:
        pass
    else:
        raise AssertionError(f"malformed candidate was accepted: {invalid}")

try:
    ranker.rank([base_candidate, deepcopy(base_candidate)])
except ValueError:
    pass
else:
    raise AssertionError("duplicate fingerprints must be rejected")

required_skill_contracts = [
    "mode:interactive",
    "mode:scheduled",
    "STOP",
    "zero to three",
    "candidate:\"<description>\"",
    "persist:github",
    "not-requested",
    "not-needed",
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
check("confidence >= 0.70" in packet, "minimum proposal confidence drifted")
check("Boundary | 0.10" in packet and "Real-world use | 0.35" in packet, "confidence rubric drifted")
check("<!-- trash-truck:retirement-review:v1 repo=OWNER/REPO -->" in issue, "canonical issue marker drifted")
check("stop all writes" in issue, "duplicate canonical issues must fail closed")
check("For `keep` or `insufficient evidence`" in skill, "non-retirement verdicts need a terminal path")
check("without offering an execution choice" in skill, "keep/insufficient verdicts must not request deletion approval")
check("scripts/rank_candidates.py" in skill, "skill must route deterministic ranking through its validator")
check("Report persistence and readback outside the comment" in issue, "comment receipt must not be circular")
check("repository-scoped scheduler serialization" in issue, "initial issue creation must be serialized")

workflow = (REPO_ROOT / ".github" / "workflows" / "tests.yml").read_text()
entrypoint = "./skills/ops/trash-truck/evals/test_retirement_contract.py"
check(entrypoint in workflow, "contract test must be registered in CI")

print("Trash Truck retirement contract passed.")
