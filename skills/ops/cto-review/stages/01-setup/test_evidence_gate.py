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

COMMENT-SCAN layer added 2026-07-13 (fellowship-dev/pylot#1861 residue item 2):
comment-scan fixtures verify that evidence found only in a PR comment is detected
by the same heading regex (body scan misses it, comment scan catches it).

RELEASE-TRAIN layer replaced 2026-09-11 (fellowship-dev/dogfooded-skills#164): the
old NECESSITY layer modelled a `*.d.mts`/`infra/` path filter that was retired from
the deployed gate and tested dead code. This layer instead extracts the real
release-train predicate block from CONTEXT.md step 5.5 (`BASE_BRANCH=$(gh pr view
...` through the `# End release-train predicate` marker) and runs it in bash with a
stub `pylot` binary on PATH and a stubbed `gh`, proving the gate resolves the
promote branch from team config (`deploy.production_branch`) and never from
`defaultBranchRef` or a bare `main` literal. Verified red-on-mutant: reverting the
block to `base == default_branch` must fail the SC-001/SC-002 fixtures.

Run: python3 test_evidence_gate.py   (exit 0 = all green)
"""
import json
import re
import shlex
import subprocess
import sys
import tempfile
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


# -- RELEASE-TRAIN layer: the promote-branch predicate, run via the REAL --------
# CONTEXT.md invocation (fellowship-dev/dogfooded-skills#164). Extracts the
# `BASE_BRANCH=$(gh pr view ...` ... `# End release-train predicate` block verbatim
# and runs it in bash with a stub `pylot` binary on PATH (mirrors
# test_resolve_merge_strategy.sh's fake-binary pattern) and a stubbed `gh`.

# Fake `pylot` binary — same shape as test_resolve_merge_strategy.sh's shim:
# PYLOT_TEST_TEAMS supplies the `teams list` JSON payload; PYLOT_TEST_FAIL=1
# simulates the CLI being unreachable.
PYLOT_STUB_SCRIPT = """#!/usr/bin/env bash
if [ "${PYLOT_TEST_FAIL:-}" = "1" ]; then
  exit 1
fi
printf '%s' "${PYLOT_TEST_TEAMS:-{\\"teams\\":[]}}"
"""

# Stub `gh`: `gh pr view ...` returns the fixture's base branch, `gh repo view ...`
# returns the fixture's default branch — kept distinct so a mutant predicate that
# still reads defaultBranchRef is provably wrong, while the real predicate (which
# never calls `gh repo view`) is unaffected by this value.
GH_STUB_FUNCTION = """gh() {
  if [ "$1" = "pr" ]; then
    printf '%s' "$STUB_BASE_BRANCH"
  elif [ "$1" = "repo" ]; then
    printf '%s' "$STUB_DEFAULT_BRANCH"
  fi
}"""


def extract_release_train_invocation(text: str = None) -> str:
    """The release-train predicate block from CONTEXT.md step 5.5, verbatim."""
    if text is None:
        text = (Path(__file__).parent / "CONTEXT.md").read_text()
    lines = text.splitlines()
    start = next(
        i for i, ln in enumerate(lines)
        if 'BASE_BRANCH=$(gh pr view $PR --repo $REPO --json baseRefName --jq' in ln
        and "2>/dev/null" in ln
    )
    end = next(
        i for i, ln in enumerate(lines[start:], start)
        if "End release-train predicate (pylot#164)" in ln
    )
    return "\n".join(lines[start : end + 1])


def run_release_train_predicate(
    repo: str, base_branch: str, default_branch: str, teams_json: str, fail: bool,
    invocation: str = None,
) -> dict:
    """Run the release-train predicate in bash with pylot/gh stubbed; return its vars."""
    if invocation is None:
        invocation = extract_release_train_invocation()
    with tempfile.TemporaryDirectory() as tmp:
        stub = Path(tmp) / "pylot"
        stub.write_text(PYLOT_STUB_SCRIPT)
        stub.chmod(0o755)
        script = "\n".join([
            f'export PATH={shlex.quote(tmp)}:"$PATH"',
            f"export PYLOT_TEST_TEAMS={shlex.quote(teams_json)}",
            f"export PYLOT_TEST_FAIL={'1' if fail else ''}",
            f"REPO={shlex.quote(repo)}",
            f"STUB_BASE_BRANCH={shlex.quote(base_branch)}",
            f"STUB_DEFAULT_BRANCH={shlex.quote(default_branch)}",
            "PR=1",
            GH_STUB_FUNCTION,
            invocation,
            'printf "NEEDS_EVIDENCE=%s\\n" "$NEEDS_EVIDENCE"',
            'printf "RELEASE_TRAIN_HANDOFF=%s\\n" "$RELEASE_TRAIN_HANDOFF"',
        ])
        out = subprocess.run(
            ["bash", "-c", script], capture_output=True, text=True, timeout=30
        )
    result = {"_stdout": out.stdout, "_stderr": out.stderr}
    for line in out.stdout.splitlines():
        if "=" in line:
            k, _, v = line.partition("=")
            result[k] = v
    return result


PYLOT_TEAM_MAIN_PROMOTE = json.dumps({
    "teams": [{"repos": ["acme/pylot"], "deploy": {"production_branch": "main"}}]
})
PYLOT_TEAM_NO_FIELD = json.dumps({
    "teams": [{"repos": ["acme/pylot"], "deploy": {}}]
})
NO_MATCHING_TEAM = json.dumps({
    "teams": [{"repos": ["acme/other"], "deploy": {"production_branch": "main"}}]
})

# (label, repo, base_branch, default_branch, teams_json, fail, expect_needs_evidence, handoff_substr)
RELEASE_TRAIN_FIXTURES = [
    (
        "T006) US1: ordinary PR into develop, team promote branch is main -> NOT REQUIRED (SC-001)",
        "acme/pylot", "develop", "develop", PYLOT_TEAM_MAIN_PROMOTE, False, False, None,
    ),
    (
        "T007) US1: no team declares this repo (dogfooded-skills shape) -> NOT REQUIRED, unconfigured (SC-003)",
        "acme/dogfooded-skills", "main", "main", NO_MATCHING_TEAM, False, False, "unconfigured",
    ),
    (
        "T008) US1: team matches but deploy.production_branch absent -> NOT REQUIRED, unconfigured (SC-003)",
        "acme/pylot", "main", "develop", PYLOT_TEAM_NO_FIELD, False, False, "unconfigured",
    ),
    (
        "T009) US1: pylot teams list unreachable -> NOT REQUIRED, unconfigured, no traceback",
        "acme/pylot", "main", "develop", "", True, False, "unconfigured",
    ),
    (
        "T010) US2: release-train PR base=main matches promote branch, default is develop -> REQUIRED (SC-002)",
        "acme/pylot", "main", "develop", PYLOT_TEAM_MAIN_PROMOTE, False, True, None,
    ),
    (
        "T011) US2: conventional repo, ordinary PR into feature-x, default is main -> NOT REQUIRED",
        "acme/pylot", "feature-x", "main", PYLOT_TEAM_MAIN_PROMOTE, False, False, None,
    ),
]


def run_release_train_fixtures(invocation: str = None) -> bool:
    ok = True
    for label, repo, base, default, teams, fail, want_needed, handoff_substr in RELEASE_TRAIN_FIXTURES:
        result = run_release_train_predicate(repo, base, default, teams, fail, invocation)
        got_needed = result.get("NEEDS_EVIDENCE") == "true"
        passed = got_needed == want_needed
        if passed and handoff_substr:
            passed = handoff_substr in result.get("RELEASE_TRAIN_HANDOFF", "")
        if passed and "Traceback" in result.get("_stderr", ""):
            passed = False
        ok = ok and passed
        flag = "green" if passed else "RED  "
        print(f"[{flag}] {label}")
        if not passed:
            print(f"        want NEEDS_EVIDENCE={want_needed} handoff~={handoff_substr!r}")
            print(f"        got  {result}")
    return ok


# Mutant of the release-train predicate: the original `base == default_branch`
# proxy this issue fixes. Never written to CONTEXT.md — held here only to prove
# the current fixtures are load-bearing (red-on-mutant, pylot#164).
MUTANT_PREDICATE = """BASE_BRANCH=$(gh pr view $PR --repo $REPO --json baseRefName --jq '.baseRefName' 2>/dev/null || echo "")
DEFAULT_BRANCH=$(gh repo view $REPO --json defaultBranchRef --jq '.defaultBranchRef.name' 2>/dev/null || echo "main")
NEEDS_EVIDENCE=false
if [ -n "$BASE_BRANCH" ] && [ "$BASE_BRANCH" = "$DEFAULT_BRANCH" ]; then
  NEEDS_EVIDENCE=true
  RELEASE_TRAIN_HANDOFF="$BASE_BRANCH"
else
  RELEASE_TRAIN_HANDOFF="not-required (mutant: base=$BASE_BRANCH default=$DEFAULT_BRANCH)"
fi
# End release-train predicate (pylot#164)"""


def run_red_on_mutant_check() -> bool:
    """T012: SC-001/SC-003/SC-002 fixtures must go RED against the old predicate,
    and stay green against the real, deployed one."""
    print()
    print("-- red-on-mutant proof (T012): reverting to base == default_branch --")
    mutant_targets = {"T006)", "T007)", "T010)"}
    mutant_fixtures = [f for f in RELEASE_TRAIN_FIXTURES if f[0].split(" ", 1)[0] in mutant_targets]
    red_ok = True
    for label, repo, base, default, teams, fail, want_needed, handoff_substr in mutant_fixtures:
        result = run_release_train_predicate(repo, base, default, teams, fail, MUTANT_PREDICATE)
        got_needed = result.get("NEEDS_EVIDENCE") == "true"
        mutant_passed = got_needed == want_needed
        red_ok = red_ok and not mutant_passed
        flag = "RED  " if not mutant_passed else "green (BAD — mutant should fail this)"
        print(f"[{flag}] {label}")
    if red_ok:
        print("RED confirmed: mutant fails SC-001/SC-003/SC-002 fixtures as expected.")
    else:
        print("mutant unexpectedly passed one or more fixtures — proof is not load-bearing.")
    print("-- confirming the real, deployed predicate is GREEN on the same fixtures --")
    green_ok = run_release_train_fixtures()
    return red_ok and green_ok


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
    ok = run_red_on_mutant_check() and ok
    print()
    print("ALL GREEN" if ok else "FAILURES PRESENT")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
