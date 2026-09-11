#!/usr/bin/env python3
"""Behavioral contract checks for the owner-authority gate (#3240)."""

from __future__ import annotations

import json
from pathlib import Path

SKILL_ROOT = Path(__file__).resolve().parents[1]
REPO_ROOT = SKILL_ROOT.parents[2]
FIXTURE = Path(__file__).with_name("owner-gate-fixtures.json")

REVIEW_PR_ROOT = REPO_ROOT / "skills" / "ops" / "review-pr"

TAXONOMY = [
    "a destructive production-data change",
    "spend above the approved budget",
    "secrets/credential exposure or handling",
    "a message or action sent to an external party",
    "an organization-policy decision",
]


def check(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def gate_fired(fixture: dict) -> bool:
    """Mirrors stages/03-synthesize-act/CONTEXT.md Step 2 — the OR of two independent triggers.

    `security` never participates, regardless of whether it is present on the fixture.
    """
    return bool(fixture["human_waiting_on_owner"]) or fixture["owner_authority_class"] != "none"


def resolved_decision_line(fixture: dict) -> str:
    line = fixture["owner_decision_line"]
    if not line or line == "none":
        return "Should this PR proceed as filed, or does it need changes before merge?"
    return line


def resolved_answerer(fixture: dict) -> str:
    answerer = fixture["owner_answerer"]
    if not answerer or answerer == "none":
        return "the human who applied waiting-on-owner"
    return answerer


data = json.loads(FIXTURE.read_text())
fixtures = {f["id"]: f for f in data["fixtures"]}
check(len(fixtures) == len(data["fixtures"]), "fixture ids must be unique")

# SC-001: replaying pylot#3372 and #3408 never applies waiting-on-owner.
for fid in ("pylot-3372", "pylot-3408"):
    fx = fixtures[fid]
    check(gate_fired(fx) is False, f"{fid} must not fire the owner gate")
    check(fx["expect_gate_fired"] is False, f"{fid} fixture is mislabeled")

# SC-002: a security-labelled PR with class none reaches the merge bar, not the park.
sec_none = fixtures["security-label-class-none"]
check(sec_none["security_label_present"] is True, "fixture must actually carry the security label")
check(gate_fired(sec_none) is False, "security label alone must never fire the owner gate")

# SC-004 / US3: a human-applied waiting-on-owner with class none still parks, naming a human.
human_only = fixtures["human-label-class-none"]
check(gate_fired(human_only) is True, "human-applied waiting-on-owner must hard-block independent of the classifier")
check(resolved_decision_line(human_only) != "none", "a park must always carry a non-none decision line")
check(resolved_answerer(human_only) != "none", "a park must always name a non-none answerer")

# One fixture per taxonomy class parks with a populated decision line and answerer.
CLASS_IDS = [
    "class-destructive-prod-data",
    "class-spend-above-budget",
    "class-secrets-handling",
    "class-external-send",
    "class-org-policy",
]
seen_classes = set()
for fid in CLASS_IDS:
    fx = fixtures[fid]
    check(fx["owner_authority_class"] != "none", f"{fid} must carry a real taxonomy class")
    seen_classes.add(fx["owner_authority_class"])
    check(gate_fired(fx) is True, f"{fid} must fire the owner gate")
    check(fx["owner_decision_line"] != "none", f"{fid} must carry a real decision line")
    check(fx["owner_answerer"] != "none", f"{fid} must carry a named answerer")
    check(fx["owner_authority_evidence"] != "none", f"{fid} must carry quotable evidence")
    check(":" in fx["owner_authority_evidence"], f"{fid} evidence must look like file:line, not a bare name")
check(len(seen_classes) == 5, "exactly five distinct taxonomy classes must be exercised")

# Every fixture's expectation matches the reimplemented gate (no silent drift between the two).
for fid, fx in fixtures.items():
    check(gate_fired(fx) == fx["expect_gate_fired"], f"{fid}: gate_fired mismatch with fixture expectation")
    check((not gate_fired(fx)) == fx["expect_reaches_merge_bar"], f"{fid}: merge-bar reachability mismatch")

# --- Static text invariants over the edited skill Markdown ---

synth = (SKILL_ROOT / "stages" / "03-synthesize-act" / "CONTEXT.md").read_text()
review = (SKILL_ROOT / "stages" / "02-review" / "CONTEXT.md").read_text()
cto_skill = (SKILL_ROOT / "SKILL.md").read_text()
post = (REVIEW_PR_ROOT / "stages" / "02-post" / "CONTEXT.md").read_text()
ctx0 = (REVIEW_PR_ROOT / "stages" / "00-context" / "CONTEXT.md").read_text()
review_pr_skill = (REVIEW_PR_ROOT / "SKILL.md").read_text()

# AC1: no site describes `security` as a hold or block by itself.
check("security\" hold signal" not in post, "review-pr must not call security a hold signal")
check('carries label(s) **${GATE_REASON}**' not in synth, "the old generic label sentence must be gone")
check("`security` and `waiting-on-owner` are the ONLY two trigger labels" not in synth, "security must be removed from the trigger set")
check('if echo "$LIVE_LABELS" | grep -qE \'"security"\'' not in synth, "security must no longer be read as a gate trigger")
check("security` is never a trigger by itself" in synth, "03-synthesize-act must state security is never a trigger")
check("`security` is never a trigger by itself" in review, "02-review must state security is never a trigger")
check("`security` is never a trigger by itself" in cto_skill, "cto-review/SKILL.md must state security is never a trigger")
check("The `security` label does NOT gate cto-review's merge decision" in post, "review-pr 02-post must disclaim gating power")
check("not a merge hold" in ctx0, "review-pr 00-context must call the label metadata, not a hold")
check("classification metadata, never a merge hold" in review_pr_skill, "review-pr/SKILL.md must call the label metadata")

# Regression guard: no edited file may reintroduce "security"-as-hold language via a stray
# sentence the line-numbered task scoping missed (found in review — "owner-gated by default"
# survived one line below the AC1 rewrite in review-pr's 02-post/CONTEXT.md).
HOLD_DRIFT_PHRASES = ("owner-gated", "owner gated")
for label, text in (
    ("cto-review/SKILL.md", cto_skill),
    ("cto-review/02-review/CONTEXT.md", review),
    ("cto-review/03-synthesize-act/CONTEXT.md", synth),
    ("review-pr/SKILL.md", review_pr_skill),
    ("review-pr/00-context/CONTEXT.md", ctx0),
    ("review-pr/02-post/CONTEXT.md", post),
):
    lowered = text.lower()
    for phrase in HOLD_DRIFT_PHRASES:
        check(phrase not in lowered, f"{label} must not describe security/auth-surface as '{phrase}'")

# AC3: the five-class taxonomy is verbatim and closed at exactly five, in the classifier step.
for cls in TAXONOMY:
    check(cls in review, f"02-review/CONTEXT.md is missing taxonomy class verbatim: {cls}")
check(review.count("a destructive production-data change") == 1, "taxonomy must not be duplicated/drifted in 02-review")
check("sixth class" in review, "02-review must state the taxonomy is closed (no sixth class)")

# AC5: the generic "carries label(s) X" sentence is gone; every park carries a decision line + answerer.
check("carries label(s)" not in synth, "the generic carries-label(s) sentence must be fully removed")
check("**Decision needed:**" in synth, "park template must always render a Decision needed line")
check("**Who can answer:**" in synth, "park template must always render a Who can answer line")

# CI registration.
workflow = (REPO_ROOT / ".github" / "workflows" / "tests.yml").read_text()
entrypoint = "./skills/ops/cto-review/tests/test_owner_gate_contract.py"
check(entrypoint in workflow, "contract test must be registered in CI")

print("Owner-authority gate contract passed.")
