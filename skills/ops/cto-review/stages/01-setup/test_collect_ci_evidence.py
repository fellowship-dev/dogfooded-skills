#!/usr/bin/env python3
"""Regression coverage for fail-closed evidence collection."""

from __future__ import annotations

import json
import os
import subprocess
import tempfile
from pathlib import Path


SCRIPT = Path(__file__).with_name("collect_ci_evidence.sh")


def main() -> None:
    with tempfile.TemporaryDirectory() as tempdir:
        fake_bin = Path(tempdir)
        gh = fake_bin / "gh"
        gh.write_text("""#!/usr/bin/env bash
case "$*" in
  *check-runs*) echo '{"check_runs":[]}' ;;
  */status*) echo '{"statuses":[]}' ;;
  *required_status_checks*) echo '{"contexts":[]}' ;;
  *rules/branches*) echo '[]' ;;
  *git/trees*) echo '{"truncated":true,"tree":[]}' ;;
  *) exit 1 ;;
esac
""")
        gh.chmod(0o755)
        env = {**os.environ, "PATH": f"{fake_bin}:{os.environ['PATH']}"}
        result = subprocess.run(
            ["bash", str(SCRIPT), "example/repo", "a" * 40, "develop"],
            check=True,
            capture_output=True,
            text=True,
            env=env,
        )
    evidence = json.loads(result.stdout)
    assert evidence["pr_workflows_ok"] is False, evidence
    print("collect_ci_evidence: truncated tree blocks")


if __name__ == "__main__":
    main()
