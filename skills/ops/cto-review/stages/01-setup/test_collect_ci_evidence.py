#!/usr/bin/env python3
"""Regression coverage for fail-closed evidence collection."""

from __future__ import annotations

import json
import os
import subprocess
import tempfile
from pathlib import Path


SCRIPT = Path(__file__).with_name("collect_ci_evidence.sh")
GATE = Path(__file__).with_name("ci_gate.py")
SETUP_CONTEXT = Path(__file__).with_name("CONTEXT.md")


def run_collector(fake_gh: str) -> dict:
    with tempfile.TemporaryDirectory() as tempdir:
        fake_bin = Path(tempdir)
        gh = fake_bin / "gh"
        gh.write_text("#!/usr/bin/env bash\n" + fake_gh)
        gh.chmod(0o755)
        env = {**os.environ, "PATH": f"{fake_bin}:{os.environ['PATH']}"}
        result = subprocess.run(
            ["bash", str(SCRIPT), "example/repo", "a" * 40, "develop"],
            check=True,
            capture_output=True,
            text=True,
            env=env,
        )
    return json.loads(result.stdout)


def classify(evidence: dict) -> dict:
    result = subprocess.run(
        ["python3", str(GATE)],
        input=json.dumps(evidence),
        check=True,
        capture_output=True,
        text=True,
    )
    return json.loads(result.stdout)


def assert_ruleset_failure(name: str, rulesets: str) -> None:
    evidence = run_collector(f'''case "$*" in
  *check-runs*) echo '{{"total_count":0,"check_runs":[]}}' ;;
  */status*) echo '{{"total_count":0,"statuses":[]}}' ;;
  *required_status_checks*) echo '{{"contexts":[]}}' ;;
  *rules/branches*) printf '%s\\n' '{rulesets}' ;;
  *git/trees*) echo '{{"truncated":false,"tree":[]}}' ;;
  *) exit 1 ;;
esac
''')
    assert evidence["expected_checks_ok"] is False, f"{name}: {evidence}"
    result = classify(evidence)
    assert result == {
        "classification": "block",
        "reason": "expected_checks lookup failed",
    }, f"{name}: {result}"


def main() -> None:
    # Stage 01 must invoke this collector, rather than reimplementing a partial
    # first-page-only query before handing evidence to the shared classifier.
    setup = SETUP_CONTEXT.read_text()
    assert 'CI_EVIDENCE=$(bash "$CI_DIR/collect_ci_evidence.sh" "$REPO" "$CURRENT_HEAD_SHA" "$BASE_BRANCH")' in setup

    truncated = run_collector("""case "$*" in
  *check-runs*) echo '{"total_count":0,"check_runs":[]}' ;;
  */status*) echo '{"total_count":0,"statuses":[]}' ;;
  *required_status_checks*) echo '{"contexts":[]}' ;;
  *rules/branches*) echo '[]' ;;
  *git/trees*) echo '{"truncated":true,"tree":[]}' ;;
  *) exit 1 ;;
esac
""")
    assert truncated["pr_workflows_ok"] is False, truncated

    list_trigger = run_collector("""case "$*" in
  *check-runs*) echo '{"total_count":0,"check_runs":[]}' ;;
  */status*) echo '{"total_count":0,"statuses":[]}' ;;
  *required_status_checks*) echo '{"contexts":[]}' ;;
  *rules/branches*) echo '[]' ;;
  *git/trees*) echo '{"truncated":false,"tree":[{"path":".github/workflows/ci.yml"}]}' ;;
  *contents*) printf '%s' 'b246ICAtIHB1bGxfcmVxdWVzdAo=' ;;
  *) exit 1 ;;
esac
""")
    assert list_trigger["pr_workflows_ok"] is True, list_trigger
    assert list_trigger["pr_workflows"] == [".github/workflows/ci.yml"], list_trigger
    assert classify(list_trigger)["classification"] == "block", list_trigger

    workflow_content_failure = run_collector("""case "$*" in
  *check-runs*) echo '{"total_count":0,"check_runs":[]}' ;;
  */status*) echo '{"total_count":0,"statuses":[]}' ;;
  *required_status_checks*) echo '{"contexts":[]}' ;;
  *rules/branches*) echo '[]' ;;
  *git/trees*) echo '{"truncated":false,"tree":[{"path":".github/workflows/ci.yml"}]}' ;;
  *contents*) exit 1 ;;
  *) exit 1 ;;
esac
""")
    assert workflow_content_failure["pr_workflows_ok"] is False, workflow_content_failure
    assert classify(workflow_content_failure)["classification"] == "block", workflow_content_failure

    required_ruleset = run_collector("""case "$*" in
  *check-runs*) echo '{"total_count":1,"check_runs":[{"name":"ruleset-ci","status":"completed","conclusion":"success"}]}' ;;
  */status*) echo '{"total_count":0,"statuses":[]}' ;;
  *required_status_checks*) echo '{"contexts":[]}' ;;
  *rules/branches*) echo '[{"rules":[{"type":"required_status_checks","parameters":{"required_status_checks":[{"context":"ruleset-ci"}]}}]}]' ;;
  *git/trees*) echo '{"truncated":false,"tree":[]}' ;;
  *) exit 1 ;;
esac
""")
    assert required_ruleset["expected_checks"] == ["ruleset-ci"], required_ruleset
    assert classify(required_ruleset)["classification"] == "pass", required_ruleset

    successful_empty = run_collector("""case "$*" in
  *check-runs*) echo '{"total_count":0,"check_runs":[]}' ;;
  */status*) echo '{"total_count":0,"statuses":[]}' ;;
  *required_status_checks*) echo '{"contexts":[]}' ;;
  *rules/branches*) echo '[]' ;;
  *git/trees*) echo '{"truncated":false,"tree":[]}' ;;
  *) exit 1 ;;
esac
""")
    assert classify(successful_empty) == {
        "classification": "na-no-configured-checks",
        "reason": "CI: N/A — no configured checks",
    }, successful_empty

    malformed_required = run_collector("""case "$*" in
  *check-runs*) echo '{"total_count":0,"check_runs":[]}' ;;
  */status*) echo '{"total_count":0,"statuses":[]}' ;;
  *required_status_checks*) echo '{}' ;;
  *rules/branches*) echo '[]' ;;
  *git/trees*) echo '{"truncated":false,"tree":[]}' ;;
  *) exit 1 ;;
esac
""")
    assert malformed_required["expected_checks_ok"] is False, malformed_required
    assert classify(malformed_required)["classification"] == "block", malformed_required

    malformed_rulesets = run_collector("""case "$*" in
  *check-runs*) echo '{"total_count":0,"check_runs":[]}' ;;
  */status*) echo '{"total_count":0,"statuses":[]}' ;;
  *required_status_checks*) echo '{"contexts":[]}' ;;
  *rules/branches*) echo '{}' ;;
  *git/trees*) echo '{"truncated":false,"tree":[]}' ;;
  *) exit 1 ;;
esac
""")
    assert malformed_rulesets["expected_checks_ok"] is False, malformed_rulesets
    assert classify(malformed_rulesets)["classification"] == "block", malformed_rulesets

    # This is the sanitized live representation from the failed installed
    # replay: a ruleset array containing a string with nested ruleset-looking
    # JSON. Accessing `.rules` on this string caused the original jq crash.
    assert_ruleset_failure(
        "live string/nested ruleset response",
        '["{\\"rules\\":[{\\"type\\":\\"required_status_checks\\"}]}"]',
    )
    assert_ruleset_failure("top-level ruleset string", '"not a ruleset array"')
    assert_ruleset_failure("ruleset rules string", '[{"rules":"not an array"}]')
    assert_ruleset_failure("ruleset rule string", '[{"rules":["not an object"]}]')
    assert_ruleset_failure(
        "ruleset malformed required contexts",
        '[{"rules":[{"type":"required_status_checks","parameters":{"required_status_checks":[{"context":17}]}}]}]',
    )

    paginated = run_collector("""case "$*" in
  *check-runs*\&page=1*) python3 -c 'import json; print(json.dumps({"total_count": 101, "check_runs": [{"name": f"green-{i}", "status": "completed", "conclusion": "success"} for i in range(100)]}))' ;;
  *check-runs*\&page=2*) echo '{"total_count":101,"check_runs":[{"name":"late-failure","status":"completed","conclusion":"failure"}]}' ;;
  */status*) echo '{"total_count":0,"statuses":[]}' ;;
  *required_status_checks*) echo '{"contexts":[]}' ;;
  *rules/branches*) echo '[]' ;;
  *git/trees*) echo '{"truncated":false,"tree":[]}' ;;
  *) exit 1 ;;
esac
""")
    assert paginated["check_runs_ok"] is True, paginated
    assert len(paginated["check_runs"]) == 101, paginated
    assert paginated["check_runs"][-1]["name"] == "late-failure", paginated
    assert classify(paginated)["classification"] == "block", paginated

    incomplete = run_collector("""case "$*" in
  *check-runs*) echo '{"total_count":2,"check_runs":[]}' ;;
  */status*) echo '{"total_count":0,"statuses":[]}' ;;
  *required_status_checks*) echo '{"contexts":[]}' ;;
  *rules/branches*) echo '[]' ;;
  *git/trees*) echo '{"truncated":false,"tree":[]}' ;;
  *) exit 1 ;;
esac
""")
    assert incomplete["check_runs_ok"] is False, incomplete
    print("stage-01 CI collection: truncated tree, list trigger, workflow-content failure, malformed expected-check payloads, ruleset context, and late pagination failures pass")


if __name__ == "__main__":
    main()
