#!/usr/bin/env python3
"""Check an issue-to-prd spec against the output contract in stages/06-ask-or-structure.

Usage: check_spec.py specs/<issue>-<slug>/spec.md
Exit 0 when the spec meets the contract; exit 1 and list every problem otherwise.
Checks structure only; it cannot judge whether the content is right.
"""
import re
import sys
from pathlib import Path

PRD_SECTIONS = [
    "Problem Statement",
    "User Stories",
    "Success Metrics",
    "Smallest version that works",
    "Measurable Impact",
    "Scope",
    "What this lets us delete",
    "Technical Requirements",
    "Implementation Constraints",
    "Testing Strategy",
    "Questions for the owner",
]
PLACEHOLDERS = ["[Feature Name]", "[option]", "[letter]", "[reason]", "{option}", "{letter}"]
QUESTIONS = "Questions for the owner"


def check(text):
    problems = []
    lines = text.splitlines()
    if not lines or not lines[0].startswith("# "):
        problems.append("first line must be the '# ' title")
    status = re.search(r"^\*\*Status:\*\* (\S+)\s*$", text, re.M)
    if not status or status.group(1) not in ("awaiting-owner-decisions", "decided"):
        problems.append("missing status line '**Status:** awaiting-owner-decisions|decided'")

    headings = re.findall(r"^## (.+?)\s*$", text, re.M)
    if QUESTIONS not in headings:
        problems.append(f"missing '## {QUESTIONS}'")
    elif headings[-1] != QUESTIONS:
        problems.append(f"'## {QUESTIONS}' must be the last section")
    if "Triage verdict" not in headings:
        for name in PRD_SECTIONS:
            if name not in headings:
                problems.append(f"missing '## {name}'")

    for token in ("TBD", "TODO"):
        if re.search(rf"\b{token}\b", text):
            problems.append(f"unresolved {token}")
    for placeholder in PLACEHOLDERS:
        if placeholder in text:
            problems.append(f"template placeholder left in: {placeholder}")

    section = text.split(f"## {QUESTIONS}", 1)[1] if f"## {QUESTIONS}" in text else ""
    blocks = re.split(r"^### ", section, flags=re.M)[1:]
    numbers, unanswered = [], []
    for block in blocks:
        head = block.splitlines()[0]
        match = re.match(r"Q(\d+)\. \S", head)
        if not match:
            problems.append(f"question heading must be '### Q<n>. <question>': {head!r}")
            continue
        n = int(match.group(1))
        numbers.append(n)
        options = re.findall(r"^\s+- ([A-Z])\. \S", block, re.M)
        if "**Options:**" not in block or len(options) < 2:
            problems.append(f"Q{n}: needs '**Options:**' with at least two lettered options")
        rec = re.search(r"^- \*\*Recommended:\*\* ([A-Z])\b[ \t]*[—-]+[ \t]*\S", block, re.M)
        if not rec:
            problems.append(f"Q{n}: needs '**Recommended:** <letter> — <reason>'")
        elif rec.group(1) not in options:
            problems.append(f"Q{n}: recommended {rec.group(1)} is not one of the options")
        if not re.search(r"^- \*\*Blocks implementation:\*\* (yes|no)\s*$", block, re.M):
            problems.append(f"Q{n}: needs '**Blocks implementation:** yes|no'")
        if not re.search(r"^- \*\*Owner answer:\*\* \S", block, re.M):
            unanswered.append(n)
    if numbers != list(range(1, len(numbers) + 1)):
        problems.append(f"questions must be numbered Q1..Qn in order, got {numbers}")
    if not blocks and not re.search(r"^None — \S", section, re.M):
        problems.append("no questions: write 'None — <why every decision is settled>'")

    for n in sorted({int(p) for p in re.findall(r"\(pending Q(\d+)\)", text)}):
        if n not in numbers:
            problems.append(f"'(pending Q{n})' refers to a question that does not exist")
        elif n not in unanswered:
            problems.append(f"Q{n} is answered but the body still says '(pending Q{n})'")

    if status:
        expected = "awaiting-owner-decisions" if unanswered else "decided"
        if status.group(1) != expected:
            problems.append(f"status must be '{expected}' ({len(unanswered)} unanswered)")
    return problems


def main(argv):
    if len(argv) != 2:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    problems = check(Path(argv[1]).read_text())
    for problem in problems:
        print(f"FAIL {argv[1]}: {problem}")
    if not problems:
        print(f"PASS {argv[1]}")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
