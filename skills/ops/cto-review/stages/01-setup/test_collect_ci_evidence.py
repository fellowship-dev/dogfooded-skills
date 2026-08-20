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
    print("stage-01 CI collection: truncated tree, list trigger, and late pagination failures pass")


if __name__ == "__main__":
    main()
