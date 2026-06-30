#!/usr/bin/env python3
"""Fixture harness for the cto-review staging-evidence gate FORMAT layer.

Mirrors the format-parsing in CONTEXT.md step 5.5 — the heading detector and the
`staging_build_id` extractor — byte-equivalent to the regexes deployed there. The
gate's SUBSTANCE (calling /admin/build-worker and requiring SUCCEEDED + build sha
== PR HEAD) is NOT modelled here: it needs the live build record and is exercised
end-to-end. Loosening the format never loosens that check.

Why this harness exists (2026-06-29): the previous version tested an OLD
`deployed_sha` string-compare gate that the deployed gate had already replaced with
`staging_build_id` build-record verification — so it green-lit nothing real and
masked the format brittleness that froze PRs (lowercase "## Staging evidence", a
sha without backticks, an emoji in the heading). This version tests the ACTUAL
format layer and is verified red-on-mutant (tighten either regex -> a fixture fails).

Run: python3 test_evidence_gate.py   (exit 0 = all green)
"""
import re
import sys

# -- byte-equivalent to the regexes in CONTEXT.md step 5.5 ---------------------
# Heading: bash `grep -iE '^#{1,4}[[:space:]].*[Ss]taging[[:space:]]+[Ee]vidence'`
HEADING_RE = re.compile(r"^#{1,4}\s.*staging\s+evidence", re.I | re.M)
# Build id: bash `staging[_ ]build[_ ]id\s*[:=]?\s*`?([A-Za-z0-9][A-Za-z0-9:/_-]+)`?` (-i)
BUILD_ID_RE = re.compile(
    r"staging[_ ]build[_ ]id\s*[:=]?\s*`?([A-Za-z0-9][A-Za-z0-9:/_-]+)`?", re.I
)


def heading_present(body: str) -> bool:
    return HEADING_RE.search(body) is not None


def section(body: str, n: int) -> str:
    """The heading line + next n lines (mirrors `grep -A{n}` context)."""
    lines = body.splitlines()
    for i, ln in enumerate(lines):
        if HEADING_RE.search(ln):
            return "\n".join(lines[i : i + 1 + n])
    return ""


def is_pending(body: str) -> bool:
    return re.search(r">\s*pending", section(body, 2)) is not None


def is_na(body: str) -> bool:
    return "n/a" in section(body, 3).lower()


def extract_build_id(body: str) -> str:
    m = BUILD_ID_RE.search(body)
    return m.group(1) if m else ""


# (label, body, heading, pending, na, build_id)
FIXTURES = [
    (
        "a) lowercase heading + clean build_id (the #1863 shape)",
        "## Staging evidence\nstaging_build_id: `pylot-builder:abc-123`\n",
        True, False, False, "pylot-builder:abc-123",
    ),
    (
        "b) emoji + PR-cycle suffix heading (the auto-pylot shape)",
        "## ✅ Staging Evidence — PR cycle (feat-x)\nstaging_build_id: `pylot-builder:d-4`\n",
        True, False, False, "pylot-builder:d-4",
    ),
    (
        "c) build id WITHOUT backticks",
        "## Staging Evidence\nstaging_build_id: pylot-builder-staging:e5f6\n",
        True, False, False, "pylot-builder-staging:e5f6",
    ),
    (
        "d) 'staging build id' spaced, '=' separator",
        "## Staging Evidence\n- staging build id = `pylot:g7`\n",
        True, False, False, "pylot:g7",
    ),
    (
        "e) ### (h3) heading",
        "### Staging Evidence\nstaging_build_id: `x:y-9`\n",
        True, False, False, "x:y-9",
    ),
    (
        "f) pending placeholder still blocks",
        "## Staging Evidence\n> pending\n",
        True, True, False, "",
    ),
    (
        "g) N/A docs-only bypass",
        "## Staging Evidence\nN/A — docs-only PR\n",
        True, False, True, "",
    ),
    (
        "h) no staging-evidence heading at all",
        "## Summary\nsome other content\n",
        False, False, False, "",
    ),
]


def main() -> int:
    ok = True
    for label, body, h, pend, na, bid in FIXTURES:
        got = (heading_present(body), is_pending(body), is_na(body), extract_build_id(body))
        want = (h, pend, na, bid)
        passed = got == want
        ok = ok and passed
        flag = "green" if passed else "RED  "
        print(f"[{flag}] {label}")
        if not passed:
            print(f"        want {want}\n        got  {got}")
    print()
    print("ALL GREEN" if ok else "FAILURES PRESENT")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
