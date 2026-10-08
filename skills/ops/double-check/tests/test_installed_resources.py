#!/usr/bin/env python3
"""Exercise copied skill resources from an unrelated working directory, without network."""
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class InstalledResources(unittest.TestCase):
    def test_follow_up_contract_is_inside_each_installed_skill(self):
        companion = ROOT.parent / "create-compelling-prs"
        if not companion.is_dir():
            companion = ROOT.parents[1] / "product/create-compelling-prs"
        skills = [ROOT, companion]
        for skill in skills:
            with self.subTest(skill=skill.name), tempfile.TemporaryDirectory() as tmp:
                installed = Path(tmp) / ".agents/skills" / skill.name
                shutil.copytree(skill, installed)
                for doc in installed.rglob("*.md"):
                    for target in re.findall(r"\]\(([^)]+follow-up-issue-template\.md)\)", doc.read_text()):
                        resolved = (doc.parent / target).resolve()
                        self.assertTrue(resolved.is_relative_to(installed.resolve()), str(resolved))
                        self.assertTrue(resolved.is_file(), str(resolved))

    def test_stage_helpers_load_from_installed_root_after_cwd_changes(self):
        with tempfile.TemporaryDirectory(prefix="installed skill ") as tmp:
            installed = Path(tmp) / ".agents/skills/double-check"
            shutil.copytree(ROOT, installed)
            elsewhere = Path(tmp) / "unrelated repository"
            elsewhere.mkdir()
            for stage in ["01-setup", "04-post"]:
                with self.subTest(stage=stage):
                    body = (installed / "stages" / stage / "CONTEXT.md").read_text()
                    # Execute the documented helper-loading fragment, never the PR workflow.
                    match = re.search(r'(: "\$\{DC_SKILL_DIR.*?source "\$DC_SKILL_DIR/shared/exact-head-receipt\.sh"|for d in .*?done(?:\nsource "\$DC_SHARED/exact-head-receipt\.sh")?)', body, re.S)
                    self.assertIsNotNone(match, "missing executable helper-loading fragment")
                    env = dict(os.environ, HOME=str(elsewhere), DC_SKILL_DIR=str(installed))
                    result = subprocess.run(["bash", "-eu", "-c", match.group(0) + "\ndeclare -F dc_exact_head_decision"], cwd=elsewhere, env=env, text=True, capture_output=True)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertIn("dc_exact_head_decision", result.stdout)
                    without_root = dict(env)
                    without_root.pop("DC_SKILL_DIR")
                    result = subprocess.run(["bash", "-eu", "-c", match.group(0)], cwd=elsewhere, env=without_root, text=True, capture_output=True)
                    self.assertNotEqual(result.returncode, 0, "missing resource root must fail closed")

    def test_stage_dispatch_carries_absolute_skill_root(self):
        body = (ROOT / "SKILL.md").read_text()
        self.assertIn("{DC_SKILL_DIR}/stages/{NN}-{name}/CONTEXT.md", body)
        self.assertIn("DC_SKILL_DIR: {absolute skill directory}", body)
        self.assertNotIn("  skills/double-check/stages/", body)


if __name__ == "__main__":
    unittest.main()
