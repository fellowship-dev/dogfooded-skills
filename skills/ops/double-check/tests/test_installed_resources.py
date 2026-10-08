#!/usr/bin/env python3
"""Exercise copied skill resources from an unrelated working directory, without network."""
import os
import json
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class RuntimeJson(unittest.TestCase):
    HEAD = "a" * 40
    PATCH = "b" * 40

    def run_helper(self, payload, promotion=False, authors="pylot-app", gh_exit=0,
                   stage=False, expected_exit=0):
        with tempfile.TemporaryDirectory(prefix="receipt json ") as tmp:
            tmp = Path(tmp)
            response = tmp / "response.json"
            response.write_text(payload)
            bin_dir = tmp / "bin"
            bin_dir.mkdir()
            # Any external jq use fails and leaves evidence, even if swallowed by a pipeline.
            jq = bin_dir / "jq"
            jq.write_text('#!/bin/sh\ntouch "$JQ_CALLED"\nexit 127\n')
            jq.chmod(0o755)
            marker = tmp / "jq-called"
            script = '''source "$1"
gh() { cat "$RESPONSE"; return "$GH_EXIT"; }
if [ "$PROMOTION" = 1 ]; then
  dc_live_promotion_decision 1 o/r "$HEAD" 0 "$OUTPUT"
else
  dc_latest_verdict_receipt 1 o/r
fi'''
            if stage:
                body = (ROOT / "stages/04-post/CONTEXT.md").read_text()
                snippet = re.search(r'```bash\n(# Do not use local checkout state.*?)(?:\n```)', body, re.S)
                self.assertIsNotNone(snippet)
                # Relocate only the fixture's cached file, preserving the executable gate.
                live_gate = snippet.group(1).replace('> /tmp/dc-pr-$PR.json', '> "$OUTPUT"').replace('/tmp/dc-pr-$PR.json', '$OUTPUT')
                script = 'source "$1"\ngh() { cat "$RESPONSE"; return "$GH_EXIT"; }\n' + live_gate
                (tmp / "setup.md").write_text(f"- Setup patch-id: {self.PATCH}\n")
            env = dict(os.environ, PATH=str(bin_dir) + os.pathsep + os.environ["PATH"],
                       RESPONSE=str(response), OUTPUT=str(tmp / "output.json"),
                       JQ_CALLED=str(marker), GH_EXIT=str(gh_exit), HEAD=self.HEAD,
                       PR="1", REPO="o/r", REVIEWED_HEAD_SHA=self.HEAD,
                       SETUP_HANDOFF=str(tmp / "setup.md"), RESTART_COUNT="0",
                       PROMOTION=str(int(promotion)), DC_RECEIPT_AUTHORS=authors)
            result = subprocess.run(["bash", "-eu", "-o", "pipefail", "-c", script,
                                     "bash", str(ROOT / "shared/exact-head-receipt.sh")],
                                    env=env, cwd=tmp, text=True, capture_output=True)
            self.assertEqual(result.returncode, expected_exit, result.stderr)
            self.assertFalse(marker.exists(), "helper must not invoke external jq")
            self.assertFalse((tmp / "injected").exists())
            return result.stdout.strip()

    def test_live_head_json_without_external_jq(self):
        self.assertEqual(self.run_helper(json.dumps({"headRefOid": self.HEAD}), True), "promote")
        for payload in ["", "{", "null", "[]", "{}", '{"headRefOid":null}',
                        '{"headRefOid":42}', json.dumps({"headRefOid": self.HEAD + "\n"}),
                        json.dumps({"headRefOid": '$(touch injected)'}),
                        json.dumps({"headRefOid": "a" * 39})]:
            with self.subTest(payload=payload):
                self.assertEqual(self.run_helper(payload, True), "blocked")
        self.assertEqual(self.run_helper(json.dumps({"headRefOid": self.HEAD}), True, gh_exit=1), "blocked")

    def test_receipt_author_and_legacy_semantics_without_external_jq(self):
        def comment(login, body):
            return {"author": {"login": login}, "body": body}
        legacy = f"<!-- pylot:exact-head-promoted head={self.HEAD} -->"
        ready = f"<!-- pylot:exact-head-promoted head={self.HEAD} patch_id={self.PATCH} verdict=ready -->"
        forged = f"<!-- pylot:exact-head-promoted head={'c' * 40} verdict=ready -->"
        payload = json.dumps({"comments": [comment("pylot-app", legacy), comment("pylot-app", ready), comment("someone", forged)]})
        self.assertEqual(self.run_helper(payload), f"{self.HEAD} {self.PATCH} ready")
        self.assertEqual(self.run_helper(json.dumps({"comments": [comment("pylot-app", legacy)]})), f"{self.HEAD} - -")
        self.assertEqual(self.run_helper(payload, authors="someone"), f"{'c' * 40} - ready")
        self.assertEqual(self.run_helper(payload, authors='$(touch injected) nobody'), "")
        self.assertEqual(self.run_helper(payload, authors="pylot"), "")

    def test_unreadable_receipts_never_carry_without_external_jq(self):
        valid = {"author": {"login": "pylot-app"}, "body": f"pylot:exact-head-promoted head={self.HEAD}"}
        for payload in ["", "{", "null", "[]", "{}", '{"comments":null}',
                        '{"comments":{}}', json.dumps({"comments": [valid, None]}),
                        json.dumps({"comments": [{"author": None, "body": "marker"}]}),
                        json.dumps({"comments": [{"author": {"login": "pylot-app"}, "body": 42}]}),
                        json.dumps({"comments": [{"author": {"login": "pylot-app"}, "body": "pylot:exact-head-promoted head=aaa"}]})]:
            with self.subTest(payload=payload):
                self.assertEqual(self.run_helper(payload), "")
        self.assertEqual(self.run_helper(json.dumps({"comments": [valid]}), gh_exit=1), "")

    def test_actual_stage_live_json_snippet_without_external_jq(self):
        valid = {"headRefOid": self.HEAD, "additions": 3, "deletions": 2,
                 "files": [{"path": "a b.rb"}, {"path": '$(touch injected).rb'}]}
        result = self.run_helper(json.dumps(valid), stage=True)
        self.assertIn("live diff: +3/-2, 2 files", result)
        self.assertIn('$(touch injected).rb', result)
        for payload in ["", "{", "null", json.dumps({**valid, "headRefOid": 42}),
                        json.dumps({**valid, "additions": "3"}),
                        json.dumps({**valid, "deletions": True}),
                        json.dumps({**valid, "files": None}),
                        json.dumps({**valid, "files": [{"path": 42}]}),
                        json.dumps({**valid, "files": [{"path": "a\nfake"}]})]:
            with self.subTest(payload=payload):
                self.assertIn("blocked:", self.run_helper(payload, stage=True, expected_exit=2))
        self.assertIn("live PR read failed", self.run_helper(json.dumps(valid), stage=True,
                                                           gh_exit=1, expected_exit=2))


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
