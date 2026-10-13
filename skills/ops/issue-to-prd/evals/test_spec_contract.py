#!/usr/bin/env python3
"""issue-to-prd output and procedure contract.

1. scripts/check_spec.py accepts the good fixtures and rejects each contract break.
2. The procedure files carry no retired Pylot wiring and write nothing to GitHub.
3. SKILL.md's stage list matches the stage folders on disk.
Does not evaluate agent judgment.
"""
import importlib.util
import re
from pathlib import Path

SKILL = Path(__file__).resolve().parents[1]
FIXTURES = SKILL / "evals/fixtures"
spec = importlib.util.spec_from_file_location("check_spec", SKILL / "scripts/check_spec.py")
check_spec = importlib.util.module_from_spec(spec)
spec.loader.exec_module(check_spec)
check = check_spec.check

good = (FIXTURES / "prd-awaiting.md").read_text()
triage = (FIXTURES / "triage.md").read_text()
for name, text in [("prd-awaiting", good), ("triage", triage)]:
    assert check(text) == [], (name, check(text))
    print(f"PASS fixture {name} meets the contract")

decided = (
    good.replace("**Status:** awaiting-owner-decisions", "**Status:** decided")
    .replace(" (pending Q1)", "")
    .replace("- **Blocks implementation:** yes", "- **Blocks implementation:** yes\n- **Owner answer:** A")
)
assert check(decided) == [], check(decided)
print("PASS answered spec with status decided meets the contract")

none_questions = re.sub(r"### Q1\..*", "None — the issue and the codebase settle every decision.\n", good, flags=re.S)
none_questions = none_questions.replace("awaiting-owner-decisions", "decided").replace(" (pending Q1)", "")
assert check(none_questions) == [], check(none_questions)
print("PASS explicit 'None —' with status decided meets the contract")

BREAKS = {
    "no owner questions section": (good.replace("## Questions for the owner", "## Open Questions"), "Questions for the owner"),
    "questions not last": (good + "\n## Notes\nx\n", "must be the last section"),
    "single option": (good.replace("  - B. Only before submission.\n", ""), "at least two lettered options"),
    "no recommendation": (good.replace("- **Recommended:** A", "- **Suggested:** A"), "Recommended"),
    "recommendation without reason": (re.sub(r"- \*\*Recommended:\*\* A — .*", "- **Recommended:** A", good), "Recommended"),
    "recommendation not an option": (good.replace("- **Recommended:** A", "- **Recommended:** C"), "not one of the options"),
    "no blocks line": (good.replace("- **Blocks implementation:** yes\n", ""), "Blocks implementation"),
    "missing PRD section": (good.replace("## What this lets us delete", "## Deletions"), "What this lets us delete"),
    "missing status": (good.replace("**Status:** awaiting-owner-decisions\n", ""), "status line"),
    "decided with open question": (good.replace("**Status:** awaiting-owner-decisions", "**Status:** decided"), "status must be 'awaiting-owner-decisions'"),
    "answered but still pending": (decided.replace("at every request state.", "at every request state (pending Q1)."), "still says"),
    "dangling pending": (good.replace("(pending Q1)", "(pending Q4)"), "does not exist"),
    "unresolved TBD": (good.replace("Delete button", "TBD button"), "TBD"),
    "template placeholder": (good.replace("Let requesters delete", "[Feature Name]"), "placeholder"),
    "empty questions": (re.sub(r"### Q1\..*", "", good, flags=re.S), "None —"),
    "misnumbered": (good.replace("### Q1.", "### Q2.").replace("(pending Q1)", "(pending Q2)"), "numbered Q1..Qn"),
}
for name, (text, needle) in BREAKS.items():
    problems = check(text)
    assert any(needle in p for p in problems), (name, problems)
    print(f"PASS rejects: {name}")

# 2. No retired wiring and no GitHub writes anywhere in the procedure.
BANNED = [
    r"\[pylot:", r"PYLOT_", r"pylot dispatch", r"outcomes/summary", r"gh issue (edit|comment|close)",
    r"gh label", r"gh pr ", r"ready-to-work", r"prd-ready", r"rechallenge", r"challenge-new-issue",
    r"stages/0[0-9a-z-]+/output/",
]
for path in sorted(SKILL.rglob("*.md")):
    if FIXTURES in path.parents:
        continue
    text = path.read_text()
    for pattern in BANNED:
        assert not re.search(pattern, text), f"{path.relative_to(SKILL)} still contains {pattern!r}"
print("PASS procedure carries no retired Pylot wiring or GitHub writes")

# 3. Stage list in SKILL.md matches the stage folders.
skill_md = (SKILL / "SKILL.md").read_text()
listed = re.findall(r"^\d+\. \*\*(\d+[a-z]?-[a-z-]+)\*\*", skill_md, re.M)
on_disk = sorted(p.name for p in (SKILL / "stages").iterdir() if p.is_dir())
assert listed == on_disk, (listed, on_disk)
for stage in on_disk:
    assert (SKILL / "stages" / stage / "CONTEXT.md").is_file(), stage
assert re.search(r"^metadata:\n  version: \S+", skill_md, re.M), "SKILL.md needs metadata.version"
print(f"PASS SKILL.md lists the {len(on_disk)} stages on disk, in order")
print("issue-to-prd spec contract passed; agent judgment is not tested.")
