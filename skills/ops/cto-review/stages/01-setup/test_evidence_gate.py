#!/usr/bin/env python3
"""Fixture harness for the cto-review staging-evidence gate (fellowship-dev/pylot#1676, Phase 1).

Mirrors the deployed_sha extractor embedded in CONTEXT.md (step 5.5) plus the
sha-compare gate logic, and exercises the parser/emitter contract over the
canonical `/test-in-staging` output and the known failure shapes.

Run: python3 test_evidence_gate.py   (exit 0 = all green)
"""
import re
import sys

# ---- extractor: must stay byte-for-byte equivalent to the regex in CONTEXT.md ----
def extract_sha(body: str) -> str:
    ms = list(re.finditer(r'deployed[ _]sha[^`\n]*`([0-9a-f]{7,40})`', body, re.I))

    def failed(i: int) -> bool:
        s = ms[i].start()
        h = body.rfind('\n##', 0, s)
        p = ms[i - 1].end() if i > 0 else -1
        seg = body[max(h, p, 0):s]
        return bool(re.search(r'BUILD FAILED|build did not succeed', seg, re.I))

    good = [m for i, m in enumerate(ms) if not failed(i)]
    pick = good[-1] if good else (ms[-1] if ms else None)
    return pick.group(1) if pick else ''


# ---- gate: replicate the bash control flow around the extractor ----
def gate(body: str, pr_head_sha: str):
    """Returns (verdict, reason). verdict in {PASS, BLOCK}."""
    if not re.search(r'##\s*Staging Evidence', body):
        return 'BLOCK', '## Staging Evidence missing'
    # pending placeholder always blocks
    seg = '\n'.join(body.splitlines()[:_idx(body) + 3])
    if re.search(r'>\s*pending', seg):
        return 'BLOCK', 'evidence is pending'
    # N/A docs-only bypass
    if 'N/A' in '\n'.join(body.splitlines()[_idx(body):_idx(body) + 4]):
        return 'PASS', 'N/A — docs-only PR'
    evidence_sha = extract_sha(body)
    head8 = pr_head_sha[:8]
    if evidence_sha and head8:
        if evidence_sha[:8] == head8:
            return 'PASS', f'deployed_sha={evidence_sha[:8]} matches PR HEAD'
        return 'BLOCK', f'deployed_sha {evidence_sha[:8]} does not match PR HEAD {head8} (stale evidence)'
    if not evidence_sha:
        return 'BLOCK', 'deployed_sha not found in evidence block'
    return 'BLOCK', 'no PR HEAD to compare'


def _idx(body: str) -> int:
    for i, ln in enumerate(body.splitlines()):
        if re.search(r'##\s*Staging Evidence', ln):
            return i
    return 0


HEAD = 'abcdef12'  # current PR HEAD (8-char)

FIXTURES = [
    # (label, body, pr_head, expect_verdict, expect_reason_contains)
    (
        'a) canonical **Deployed SHA:** (the core bug)',
        "## Staging Evidence\n- **Branch:** `feat/x`\n- **Deployed SHA:** `abcdef1234`\n",
        HEAD, 'PASS', 'matches PR HEAD',
    ),
    (
        'b) hand-written lowercase deployed_sha:',
        "## Staging Evidence\ndeployed_sha: `abcdef1234`\n",
        HEAD, 'PASS', 'matches PR HEAD',
    ),
    (
        'c) > pending placeholder',
        "## Staging Evidence\n> pending\n",
        HEAD, 'BLOCK', 'pending',
    ),
    (
        'd) N/A docs-only bypass',
        "## Staging Evidence\nN/A — docs-only PR\n",
        HEAD, 'PASS', 'N/A',
    ),
    (
        'e) failed-build section THEN good section (#1667 shape)',
        "## Staging Evidence (attempt 1)\nBUILD FAILED (build did not succeed)\n- **Deployed SHA:** `0000bad1`\n\n"
        "## Staging Evidence\n- **Deployed SHA:** `abcdef1234`\n",
        HEAD, 'PASS', 'abcdef12',
    ),
    (
        'f) genuine stale (evidence sha != HEAD)',
        "## Staging Evidence\n- **Deployed SHA:** `99999999`\n",
        HEAD, 'BLOCK', 'stale evidence',
    ),
]


def main() -> int:
    ok = True
    for label, body, head, exp_v, exp_r in FIXTURES:
        v, r = gate(body, head)
        passed = (v == exp_v) and (exp_r.lower() in r.lower())
        ok = ok and passed
        flag = 'green' if passed else 'RED  '
        print(f"[{flag}] {label}\n        -> {v}: {r}")
    print()
    print('ALL GREEN' if ok else 'FAILURES PRESENT')
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main())
