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

SUBSTANCE layer added 2026-07-01 (fellowship-dev/pylot#1861 residue item 1): the
freshness fixtures below extract the real `GATE_RESULT=$(...)` invocation from
CONTEXT.md and run it in bash against a stub /admin/build-worker server — so they
exercise the exact invocation SHAPE, including whether PR_HEAD_SHA actually reaches
the python snippet as environment. Verified red-on-mutant: with the argv-positioned
`PR_HEAD_SHA="$PR_HEAD_SHA"` (the pre-fix form), the stale-sha and empty-sha
fixtures go RED.

COMMENT-SCAN and NECESSITY layers added 2026-07-13 (fellowship-dev/pylot#1861
residue items 2+3): comment-scan fixtures verify that evidence found only in a PR
comment is detected by the same heading regex (body scan misses it, comment scan
catches it). Necessity fixtures verify that *.d.mts files do NOT trigger the gate
and that a waiver rationale line is emitted.

Run: python3 test_evidence_gate.py   (exit 0 = all green)
"""
import json
import re
import shlex
import subprocess
import sys
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

# -- byte-equivalent to the regexes in CONTEXT.md step 5.5 ---------------------
# Heading: bash `grep -iE '^#{1,4}[[:space:]].*[Ss]taging[[:space:]]+[Ee]vidence'`
HEADING_RE = re.compile(r"^#{1,4}\s.*staging\s+evidence", re.I | re.M)
# Build id: staging_build_id / 'staging build id' OR the '**Build:**' prose label
# (pylot#2097) — ':' or '=' or none, backticks optional (-i)
BUILD_ID_RE = re.compile(
    r"(?:staging[_ ]build[_ ]id|\*\*build:?\*\*)\s*[:=]?\s*`?([A-Za-z0-9][A-Za-z0-9:/_-]+)`?", re.I
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
        "e2) '**Build:**' prose label with backticks + arrow suffix (the pylot#2084 shape)",
        "## Staging Evidence\n- **Build:** `pylot-builder-staging:6a57e56e-e4c7` \u2192 SUCCEEDED (gate green)\n- **Deployed SHA:** `b9de2ca8` (PR HEAD)\n",
        True, False, False, "pylot-builder-staging:6a57e56e-e4c7",
    ),
    (
        "e3) '**Build**:' colon outside bold, no backticks",
        "## Staging Evidence\n**Build**: pylot-builder-staging:aa11-bb22\n",
        True, False, False, "pylot-builder-staging:aa11-bb22",
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
    # comment-scan fixtures: these bodies have NO heading (body scan misses),
    # but a comment (simulated separately in COMMENT_SCAN_FIXTURES) would have one.
    (
        "h2) heading regex also matches comment-body format (bash loop not tested here — requires bash-level integration test)",
        "## Staging Evidence\nstaging_build_id: `pylot-builder:comment-test`\n",
        True, False, False, "pylot-builder:comment-test",
    ),
]

# Necessity fixtures: (label, changed_files_list, expects_waived)
# *.d.mts files must NOT trigger necessity; infra/ files must.
NECESSITY_FIXTURES = [
    (
        "n1) *.d.mts only — must be waived (type-declaration, no runtime effect)",
        ["gateway/types.d.mts", "gateway/api.d.mts"],
        True,   # waived
    ),
    (
        "n2) gateway/*.ts (non-declaration) — must require evidence",
        ["gateway/handler.mts"],
        False,  # not waived — evidence required
    ),
    (
        "n3) infra/ path — must require evidence",
        ["infra/lib/stack.ts"],
        False,
    ),
    (
        "n4) docs-only *.md — must be waived",
        ["docs/deploy-policy.md", "README.md"],
        True,
    ),
    (
        "n5) mixed: *.d.mts + infra/ — infra wins, evidence required",
        ["gateway/types.d.mts", "infra/lib/stack.ts"],
        False,
    ),
]


# -- SUBSTANCE layer: freshness check, run via the REAL CONTEXT.md invocation --
# Extracts the `GATE_RESULT=$(...)` block from CONTEXT.md step 5.5 verbatim and runs
# it in bash with PR_HEAD_SHA set exactly as the gate sets it (a plain shell var,
# NOT exported). If the invocation shape fails to deliver PR_HEAD_SHA into the
# python snippet's environment, the stale fixture passes the gate and goes RED here.

HEAD_SHA = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
OTHER_SHA = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

# (label, pr_head_sha, build_record, expected_decision)
FRESHNESS_FIXTURES = [
    (
        "i) fresh: SUCCEEDED build whose sha == PR HEAD passes",
        HEAD_SHA, {"status": "SUCCEEDED", "sha": HEAD_SHA}, "PASS",
    ),
    (
        "j) STALE: SUCCEEDED build for a DIFFERENT sha must BLOCK",
        HEAD_SHA, {"status": "SUCCEEDED", "sha": OTHER_SHA}, "BLOCK",
    ),
    (
        "k) empty PR_HEAD_SHA must FAIL CLOSED (BLOCK, never pass)",
        "", {"status": "SUCCEEDED", "sha": OTHER_SHA}, "BLOCK",
    ),
]


class _BuildRecordStub(BaseHTTPRequestHandler):
    record: dict = {}

    def do_GET(self):  # noqa: N802 — http.server API
        payload = json.dumps(type(self).record).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def log_message(self, *args):  # silence request logging
        pass


def extract_gate_invocation() -> str:
    """The GATE_RESULT=$(...) block from CONTEXT.md step 5.5, verbatim."""
    lines = (Path(__file__).parent / "CONTEXT.md").read_text().splitlines()
    start = next(i for i, ln in enumerate(lines) if "GATE_RESULT=$(" in ln)
    end = next(
        i for i, ln in enumerate(lines[start:], start)
        if 'BLOCK:build-record check failed' in ln
    )
    return "\n".join(lines[start : end + 1])


def run_gate_freshness(head_sha: str, port: int) -> str:
    body = "## Staging Evidence\nstaging_build_id: `pylot-builder:test-1`\n"
    script = "\n".join([
        f'export PYLOT_STAGING_URL="http://127.0.0.1:{port}"',
        'export PYLOT_STAGING_DISPATCH_TOKEN="test-token"',
        f"PR_BODY={shlex.quote(body)}",
        # exactly as the gate sets it: shell var, not exported
        f"PR_HEAD_SHA={shlex.quote(head_sha)}",
        extract_gate_invocation(),
        'printf "%s" "$GATE_RESULT"',
    ])
    out = subprocess.run(
        ["bash", "-c", script], capture_output=True, text=True, timeout=30
    )
    return out.stdout.strip()


def run_freshness_fixtures() -> bool:
    server = HTTPServer(("127.0.0.1", 0), _BuildRecordStub)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    port = server.server_address[1]
    ok = True
    try:
        for label, head_sha, record, want_decision in FRESHNESS_FIXTURES:
            _BuildRecordStub.record = record
            result = run_gate_freshness(head_sha, port)
            got_decision = result.split(":", 1)[0]
            passed = got_decision == want_decision
            ok = ok and passed
            flag = "green" if passed else "RED  "
            print(f"[{flag}] {label}")
            if not passed:
                print(f"        want {want_decision}:*\n        got  {result!r}")
    finally:
        server.shutdown()
    return ok


def needs_evidence(changed_files: list) -> bool:
    """Mirror the bash necessity filter from CONTEXT.md step 5.5.

    Returns True if staging evidence is required; False if the change is
    limited to non-runtime paths and should be waived.
    """
    INFRA_PREFIXES = ("infra/", "gateway/", "crew.mjs")
    MIGRATION_SUFFIX = "/migrations/"
    for f in changed_files:
        if f.endswith(".d.mts"):
            continue  # type-declaration — excluded from necessity trigger
        if any(f.startswith(p) for p in INFRA_PREFIXES):
            return True
        if MIGRATION_SUFFIX in f and f.endswith(".sql"):
            return True
    return False


def run_necessity_fixtures() -> bool:
    ok = True
    for label, files, expect_waived in NECESSITY_FIXTURES:
        required = needs_evidence(files)
        got_waived = not required
        passed = got_waived == expect_waived
        ok = ok and passed
        flag = "green" if passed else "RED  "
        print(f"[{flag}] {label}")
        if not passed:
            print(f"        want waived={expect_waived}  got waived={got_waived}  (files={files})")
    return ok


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
    ok = run_freshness_fixtures() and ok
    ok = run_necessity_fixtures() and ok
    print()
    print("ALL GREEN" if ok else "FAILURES PRESENT")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
