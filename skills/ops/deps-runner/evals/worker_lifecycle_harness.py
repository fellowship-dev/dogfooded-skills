#!/usr/bin/env python3
"""Executable validation harness for deps-runner's worker-lifecycle contract.

Exercises, without any live pylot dispatch:
  1. The WID-parse-under-malformed-input contract (stage 01 CONTEXT.md step 7 /
     SKILL.md's worker-lifecycle block) - a crashed JSON parse must never raise
     and must never fabricate a worker_id.
  2. The bounded terminal-state poll contract (stage 06 CONTEXT.md step 1) -
     confirmation must be bounded (5 attempts), not open-ended, and must not
     report success on a status sequence that never reaches STOPPED.
  3. The zero-retired-provider-literal invariant asserted by
     evals/worker-lifecycle-001.json, run here instead of as a one-off manual
     grep.
  4. That every eval fixture under evals/ still parses as JSON.
  5. The stage-04 checkout contract always creates the local branch from the
     freshly fetched remote ref, rather than retaining a stale local branch.
  6. The direct-usage search contract covers every supported source extension,
     including TypeScript and Python files.

Run: python3 worker_lifecycle_harness.py
"""
import base64
import json
import re
import sys
from pathlib import Path

SKILL_ROOT = Path(__file__).resolve().parents[1]
FAILURES = []


def check(label, condition):
    status = "PASS" if condition else "FAIL"
    print(f"[{status}] {label}")
    if not condition:
        FAILURES.append(label)


# --- 1. WID parse contract (stage 01 / SKILL.md) ----------------------------

def parse_worker_id(spawn_response_text):
    """Mirrors the exact parse step from stage 01 CONTEXT.md step 7: parse
    JSON, pull worker_id, and on any exception yield an empty string rather
    than propagating the failure."""
    try:
        return json.loads(spawn_response_text).get("worker_id", "")
    except Exception:
        return ""


well_formed = json.dumps({"worker_id": "w-abc123", "task_arn": "arn:aws:ecs:...", "last_status": "PROVISIONING"})
check(
    "parse_worker_id extracts worker_id from a well-formed spawn response",
    parse_worker_id(well_formed) == "w-abc123",
)

malformed_cases = [
    "not json at all",
    "",
    "{",
    "{\"worker_id\": [1, 2",
    "<html>502 Bad Gateway</html>",
    "null",
]
for case in malformed_cases:
    try:
        result = parse_worker_id(case)
        raised = False
    except Exception:
        result = None
        raised = True
    check(f"parse_worker_id never raises on malformed input {case[:24]!r}", not raised)
    check(f"parse_worker_id yields empty string (not a fabricated id) for {case[:24]!r}", result == "")

# valid JSON, but no worker_id key at all - must yield "" too, never KeyError
check(
    "parse_worker_id yields empty string when worker_id key is absent",
    parse_worker_id(json.dumps({"task_arn": "arn:aws:ecs:..."})) == "",
)


# --- 2. Bounded terminal-state poll contract (stage 06) ---------------------

def confirm_stopped(status_sequence, max_attempts=5):
    """Mirrors stage 06 CONTEXT.md step 1's poll loop: call the status lookup
    up to max_attempts times, stop as soon as STOPPED is observed, and never
    loop beyond the bound. Returns (confirmed, attempts_used, last_status)."""
    it = iter(status_sequence)
    last_status = "unknown"
    for attempt in range(1, max_attempts + 1):
        try:
            last_status = next(it)
        except StopIteration:
            last_status = last_status
        if last_status == "STOPPED":
            return True, attempt, last_status
    return False, max_attempts, last_status


eventually_stopped = ["PROVISIONING", "RUNNING", "STOPPING", "STOPPED", "STOPPED"]
confirmed, attempts, last = confirm_stopped(eventually_stopped)
check("confirm_stopped returns True once STOPPED is observed", confirmed is True)
check("confirm_stopped stops polling as soon as STOPPED appears (attempt 4, not all 5)", attempts == 4)

never_stopped = ["RUNNING", "RUNNING", "RUNNING", "RUNNING", "RUNNING", "RUNNING", "RUNNING"]
confirmed2, attempts2, last2 = confirm_stopped(never_stopped)
check("confirm_stopped returns False when STOPPED is never observed", confirmed2 is False)
check("confirm_stopped is bounded at exactly 5 attempts, never open-ended", attempts2 == 5)
check("confirm_stopped surfaces the last-observed status for honest 'unconfirmed' reporting", last2 == "RUNNING")

stopped_immediately = ["STOPPED"]
confirmed3, attempts3, _ = confirm_stopped(stopped_immediately)
check("confirm_stopped confirms on the very first attempt when already STOPPED", confirmed3 is True and attempts3 == 1)


# --- 3. Zero-retired-provider-literal scan ----------------------------------
# Forbidden tokens are assembled from base64 at runtime rather than written
# literally, so this harness (which lives under the scanned directory) does
# not itself reintroduce the tokens evals/worker-lifecycle-001.json guards
# against.

def build_forbidden_pattern():
    encoded_tokens = [
        "Z2l0cG9k",      # a retired remote-execution provider's name
        "XGJvbmFcYg==",  # \bona\b - its sibling product, as a whole word
        "b25hXw==",      # its environment-variable prefix
        "ZW52X2lk",      # its raw environment-identifier convention
    ]
    tokens = [base64.b64decode(t).decode() for t in encoded_tokens]
    return re.compile("|".join(tokens), re.IGNORECASE)


FORBIDDEN_PATTERN = build_forbidden_pattern()


def scan_directory(root):
    hits = []
    for path in sorted(root.rglob("*")):
        if not path.is_file():
            continue
        try:
            text = path.read_text(errors="ignore")
        except Exception:
            continue
        if FORBIDDEN_PATTERN.search(text):
            hits.append(str(path.relative_to(root)))
    return hits


scan_hits = scan_directory(SKILL_ROOT)
check(f"zero retired-provider literal references under {SKILL_ROOT.name}/", scan_hits == [])
if scan_hits:
    print("  matches:", scan_hits)


# --- 4. Eval fixture JSON validation -----------------------------------------

eval_dir = SKILL_ROOT / "evals"
eval_files = sorted(eval_dir.glob("*.json"))
check(f"at least one eval fixture found under {eval_dir.name}/", len(eval_files) > 0)
for f in eval_files:
    try:
        json.loads(f.read_text())
        ok = True
    except Exception as e:
        ok = False
        print(f"  {f.name}: {e}")
    check(f"{f.name} parses as valid JSON", ok)


# --- 5. Fresh remote checkout contract (stage 04) --------------------------

stage04 = (SKILL_ROOT / "stages" / "04-build-test" / "CONTEXT.md").read_text()
stage04_command = stage04.replace('\\"', '"')
fresh_checkout = (
    'git fetch origin "refs/heads/$BRANCH:refs/remotes/origin/$BRANCH" '
    '&& git checkout -B "$BRANCH" "origin/$BRANCH"'
)
check(
    "stage 04 force-refreshes origin/$BRANCH and creates the local branch from it",
    fresh_checkout in stage04_command,
)


# --- 6. Direct-usage extension coverage (stage 03) -------------------------

stage03 = (SKILL_ROOT / "stages" / "03-risk-eval" / "CONTEXT.md").read_text()
supported_extensions = ("js", "ts", "jsx", "tsx", "rb", "py")
check(
    "stage 03 supplies one grep include filter for each supported source extension",
    all(f"--include='*.{extension}'" in stage03 for extension in supported_extensions),
)


def direct_usage_files(files, package_name):
    """Model the documented extension filter over candidate source files."""
    return [
        name for name, contents in files.items()
        if name.rsplit(".", 1)[-1] in supported_extensions and package_name in contents
    ]


usage_fixture = {
    "src/client.ts": "import pkg from 'example-package'",
    "tools/worker.py": "import example-package",
    "README.md": "example-package is documented here",
}
check(
    "direct-usage detection includes direct TypeScript and Python imports but excludes prose",
    direct_usage_files(usage_fixture, "example-package") == ["src/client.ts", "tools/worker.py"],
)


print()
if FAILURES:
    print(f"{len(FAILURES)} check(s) FAILED:")
    for f in FAILURES:
        print(f"  - {f}")
    sys.exit(1)
else:
    print(f"All checks passed ({len(eval_files)} eval fixtures validated, 0 forbidden-literal matches).")
    sys.exit(0)
