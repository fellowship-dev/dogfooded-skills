#!/usr/bin/env python3
"""Execute the documented triage label commands; does not evaluate agent judgment."""
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[4]
SOURCE = ROOT / "skills/ops/issue-to-prd/stages/01b-triage-challenge/CONTEXT.md"
blocks = re.findall(r"```bash\n(.*?)\n```", SOURCE.read_text(), re.S)
candidates = [block for block in blocks if 'case "$TRIAGE_VERDICT" in' in block]
assert len(candidates) == 1, "expected one actual triage label snippet"
# Substitute documented invocation parameters, not the decision logic.
shell = candidates[0].replace("{repo}", "example/repository").replace("{number}", "512")
with tempfile.TemporaryDirectory(prefix="triage-label-contract-") as directory:
    tmp = Path(directory)
    gh = tmp / "gh"
    gh.write_text('''#!/usr/bin/env python3
import json, os, sys
args = sys.argv[1:]
with open(os.environ["GH_LOG"], "a") as log:
    log.write(json.dumps(args) + "\\n")
if args[:2] == ["label", "create"]:
    sys.exit(1 if os.environ.get("LABEL_EXISTS") == "1" else 0)
if args[:2] == ["issue", "edit"]:
    sys.exit(1 if os.environ.get("EDIT_FAIL") == "1" else 0)
sys.exit(64)
''')
    gh.chmod(0o755)
    log = tmp / "calls.jsonl"
    for verdict, expected in [("delete-retire", "wontfix"), ("close", "wontfix"), ("re-scope", "needs-rescope"), ("prd", None), ("invalid", None), ("", None)]:
        for exists in (False, True):
            log.write_text("")
            env = dict(os.environ, PATH=f"{tmp}:{os.environ['PATH']}", GH_LOG=str(log), TRIAGE_VERDICT=verdict, LABEL_EXISTS="1" if exists else "0")
            result = subprocess.run(["bash", "-c", shell], env=env, capture_output=True, text=True)
            calls = [json.loads(line) for line in log.read_text().splitlines()]
            if expected is None:
                assert result.returncode != 0 and not calls, f"{verdict!r}: invalid non-PRD invocation had effects"
            else:
                assert result.returncode == 0, f"{verdict}: {result.stderr}"
                assert len(calls) == 2, (verdict, calls)
                assert calls[0][:3] == ["label", "create", expected], calls
                assert calls[1] == ["issue", "edit", "512", "--repo", "example/repository", "--add-label", expected], calls
                assert calls[0][calls[0].index("--repo") + 1] == "example/repository", calls
            print(f"PASS actual triage label {verdict!r}, label_exists={exists}")
    log.write_text("")
    env = dict(env, TRIAGE_VERDICT="re-scope", EDIT_FAIL="1")
    failed = subprocess.run(["bash", "-c", shell], env=env, capture_output=True, text=True)
    assert failed.returncode != 0, "label-application failure must propagate"
    print("PASS label application failure propagates")
print("Triage label source contract passed; agent verdict quality is not tested.")
