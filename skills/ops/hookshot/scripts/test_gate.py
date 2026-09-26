#!/usr/bin/env python3
"""Tests for hookshot's gate.py and preflight.py. Run: python3 test_gate.py"""
from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
GATE = HERE / "gate.py"
PREFLIGHT = HERE / "preflight.py"

STRUCTURED = """# Outcome contract: demo

Mode: Deliver

## Deliverables

1. The parser module exists.
   - Evidence: `src/parser.py`
2. A receipt line is posted.
   - Evidence: receipt: "parser shipped"
3. The report is written.
   - Evidence: `reports/out.md`

## Standards

- Tests green.

## Non-goals

- Nothing else.

## Expected end state

- `DELIVERED`: all three exist.
"""

LOOSE = """# Wednesday packet
Mode: Communicate. Execution: local.

Deliverables: sealed capture and manifest; weekly control; review PR. Evidence lives in artifacts/ and its review PR.

Standards: editorial contract; owner author.

Expected end: AWAITING OWNER ACTION with packet verified.
"""


def run(script, stdin_obj=None, args=(), env=None, cwd=None):
    e = dict(os.environ)
    e.update(env or {})
    proc = subprocess.run(
        [sys.executable, str(script), *args],
        input=json.dumps(stdin_obj) if stdin_obj is not None else "",
        text=True, capture_output=True, env=e, cwd=cwd, timeout=30,
    )
    return proc


class GateHarness(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.state = self.root / ".state"
        (self.state / "contracts").mkdir(parents=True)
        self.env = {"HOOKSHOT_STATE_DIR": str(self.state), "HOOKSHOT_GATE_MODE": "shadow",
                    "HOOKSHOT_NO_NETWORK": "1"}

    def tearDown(self):
        self.tmp.cleanup()

    def contract(self, text, sid="sid-1", name="specs/contracts/c.md"):
        p = self.root / name
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(text)
        (self.state / "contracts" / sid).write_text(name + "\n")
        return p

    def stop(self, msg="All done. DELIVERED", sid="sid-1", active=False, args=("--client", "codex"), mode=None):
        env = dict(self.env)
        if mode:
            env["HOOKSHOT_GATE_MODE"] = mode
        return run(GATE, {"session_id": sid, "cwd": str(self.root), "stop_hook_active": active,
                          "last_assistant_message": msg, "hook_event_name": "Stop"},
                   args=args, env=env, cwd=str(self.root))

    def log_lines(self):
        p = self.state / "hookshot" / "gate-shadow.jsonl"
        if not p.exists():
            return []
        return [json.loads(l) for l in p.read_text().splitlines() if l.strip()]


class GateTests(GateHarness):
    def test_clean_contract_logs_no_miss(self):
        self.contract(STRUCTURED)
        (self.root / "src").mkdir(); (self.root / "src/parser.py").write_text("x")
        (self.root / "reports").mkdir(); (self.root / "reports/out.md").write_text("x")
        p = self.stop("parser shipped. DELIVERED")
        self.assertEqual(0, p.returncode, p.stderr)
        self.assertEqual("", p.stdout.strip())
        lines = self.log_lines()
        self.assertEqual(1, len(lines))
        self.assertEqual([], lines[0]["misses"])
        self.assertFalse(lines[0]["would_block"])
        self.assertEqual("structured", lines[0]["format"])
        self.assertEqual("none", lines[0]["judge"])

    def test_missing_path_is_claim_without_evidence(self):
        self.contract(STRUCTURED)
        (self.root / "src").mkdir(); (self.root / "src/parser.py").write_text("x")
        p = self.stop("parser shipped. DELIVERED")
        self.assertEqual(0, p.returncode, p.stderr)
        line = self.log_lines()[0]
        types = [(m["type"], m["item"]) for m in line["misses"]]
        self.assertIn(("claim_without_evidence", 3), types)
        self.assertNotIn(("claim_without_evidence", 1), types)
        self.assertTrue(line["would_block"])

    def test_receipt_absent_is_a_miss(self):
        self.contract(STRUCTURED)
        (self.root / "src").mkdir(); (self.root / "src/parser.py").write_text("x")
        (self.root / "reports").mkdir(); (self.root / "reports/out.md").write_text("x")
        p = self.stop("DELIVERED")
        types = [(m["type"], m["item"]) for m in self.log_lines()[0]["misses"]]
        self.assertIn(("claim_without_evidence", 2), types)

    def test_receipt_found_in_result_section(self):
        self.contract(STRUCTURED + "\n## Result\n\n`DELIVERED` on 2026-09-16.\n- 1: DELIVERED\n- 2: DELIVERED parser shipped\n- 3: DELIVERED\n")
        (self.root / "src").mkdir(); (self.root / "src/parser.py").write_text("x")
        (self.root / "reports").mkdir(); (self.root / "reports/out.md").write_text("x")
        p = self.stop("DELIVERED")
        self.assertEqual([], self.log_lines()[0]["misses"])

    def test_short_count_when_result_lists_fewer_items(self):
        self.contract(STRUCTURED + "\n## Result\n\n`DELIVERED`.\n- 1: DELIVERED\n- 2: DELIVERED parser shipped\n")
        (self.root / "src").mkdir(); (self.root / "src/parser.py").write_text("x")
        (self.root / "reports").mkdir(); (self.root / "reports/out.md").write_text("x")
        self.stop("DELIVERED")
        types = [(m["type"], m["item"]) for m in self.log_lines()[0]["misses"]]
        self.assertIn(("short_count", 3), types)

    def test_no_status_word(self):
        self.contract(STRUCTURED)
        self.stop("I finished everything, bye")
        types = [m["type"] for m in self.log_lines()[0]["misses"]]
        self.assertIn("no_status_word", types)

    def test_stop_hook_active_is_silent(self):
        self.contract(STRUCTURED)
        p = self.stop("no status", active=True)
        self.assertEqual(0, p.returncode)
        self.assertEqual("", p.stdout.strip())
        self.assertEqual([], self.log_lines())

    def test_no_pointer_logs_no_contract(self):
        p = self.stop("hi", sid="nobody")
        self.assertEqual(0, p.returncode, p.stderr)
        self.assertEqual("", p.stdout.strip())
        lines = self.log_lines()
        self.assertEqual("no_contract", lines[0]["kind"])
        self.assertFalse(lines[0]["would_block"])

    def test_loose_contract_goes_to_judge(self):
        self.contract(LOOSE)
        self.stop("AWAITING OWNER ACTION")
        line = self.log_lines()[0]
        self.assertEqual("loose", line["format"])
        self.assertEqual([], [m for m in line["misses"] if m["type"] != "no_status_word"])
        self.assertGreaterEqual(line["judge_items"], 1)

    def test_blocked_with_dependency_exempts_item(self):
        self.contract(STRUCTURED + "\n## Result\n\n`BLOCKED`.\n- 1: DELIVERED\n- 2: DELIVERED parser shipped\n- 3: BLOCKED — report generator depends on the vendor API key the owner holds\n")
        (self.root / "src").mkdir(); (self.root / "src/parser.py").write_text("x")
        self.stop("BLOCKED on the vendor key")
        types = [(m["type"], m["item"]) for m in self.log_lines()[0]["misses"]]
        self.assertNotIn(("claim_without_evidence", 3), types)

    def test_bare_blocked_is_still_a_miss(self):
        self.contract(STRUCTURED + "\n## Result\n\n`BLOCKED`.\n- 1: DELIVERED\n- 2: DELIVERED parser shipped\n- 3: BLOCKED\n")
        (self.root / "src").mkdir(); (self.root / "src/parser.py").write_text("x")
        self.stop("BLOCKED")
        types = [(m["type"], m["item"]) for m in self.log_lines()[0]["misses"]]
        self.assertIn(("bare_status", 3), types)

    def test_enforce_mode_blocks_with_reasons(self):
        self.contract(STRUCTURED)
        p = self.stop("DELIVERED", mode="enforce")
        self.assertEqual(0, p.returncode, p.stderr)
        out = json.loads(p.stdout)
        self.assertEqual("block", out["decision"])
        self.assertIn("claim_without_evidence", out["reason"])

    def test_enforce_mode_never_blocks_when_stop_hook_active(self):
        self.contract(STRUCTURED)
        p = self.stop("DELIVERED", mode="enforce", active=True)
        self.assertEqual("", p.stdout.strip())

    def test_malformed_stdin_exits_zero_and_logs_error(self):
        proc = subprocess.run([sys.executable, str(GATE), "--client", "codex"], input="{not json",
                              text=True, capture_output=True, env={**os.environ, **self.env}, cwd=str(self.root))
        self.assertEqual(0, proc.returncode)
        self.assertEqual("", proc.stdout.strip())
        self.assertEqual("error", self.log_lines()[0]["kind"])

    def test_log_never_contains_message_text(self):
        self.contract(STRUCTURED)
        secret = "ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
        self.stop(f"token {secret} and a long story about what I did. DELIVERED")
        raw = (self.state / "hookshot" / "gate-shadow.jsonl").read_text()
        self.assertNotIn(secret, raw)
        self.assertNotIn("long story", raw)

    def test_claude_client_writes_judge_packet(self):
        self.contract(STRUCTURED)
        self.stop("DELIVERED", args=("--client", "claude-code"))
        line = self.log_lines()[0]
        self.assertEqual("native", line["judge"])
        packet = self.state / "hookshot" / "judge" / "sid-1.json"
        self.assertTrue(packet.exists())
        d = json.loads(packet.read_text())
        self.assertIn("contract", d)
        self.assertIn("last_assistant_message", d)

    def test_background_tasks_in_payload_is_work_still_running(self):
        self.contract(STRUCTURED)
        (self.root / "src").mkdir(); (self.root / "src/parser.py").write_text("x")
        (self.root / "reports").mkdir(); (self.root / "reports/out.md").write_text("x")
        p = run(GATE, {"session_id": "sid-1", "cwd": str(self.root), "stop_hook_active": False,
                       "last_assistant_message": "parser shipped DELIVERED", "background_tasks": [{"id": "t1"}]},
                args=("--client", "claude-code"), env=self.env, cwd=str(self.root))
        self.assertEqual(0, p.returncode, p.stderr)
        types = [m["type"] for m in self.log_lines()[0]["misses"]]
        self.assertIn("work_still_running", types)

    def test_org_repo_token_is_not_a_path(self):
        self.contract(STRUCTURED.replace("`src/parser.py`", "PR merged in `fellowship-dev/dogfooded-skills`"))
        (self.root / "reports").mkdir(); (self.root / "reports/out.md").write_text("x")
        self.stop("parser shipped DELIVERED")
        types = [(m["type"], m["item"]) for m in self.log_lines()[0]["misses"]]
        self.assertNotIn(("claim_without_evidence", 1), types)

    def test_runner_mode_reads_last_message_file(self):
        self.contract(STRUCTURED, sid="run-7")
        (self.root / "last.txt").write_text("parser shipped DELIVERED")
        proc = subprocess.run([sys.executable, str(GATE), "--client", "codex-exec", "--session-id", "run-7",
                               "--last-message", str(self.root / "last.txt"), "--cwd", str(self.root)],
                              input="", text=True, capture_output=True, env={**os.environ, **self.env})
        self.assertEqual(0, proc.returncode, proc.stderr)
        line = self.log_lines()[0]
        self.assertEqual("codex-exec", line["client"])
        self.assertEqual("run-7", line["session_id"])

    def test_explicit_contract_arg_wins_over_pointer(self):
        alt = self.root / "alt.md"; alt.write_text(STRUCTURED)
        proc = subprocess.run([sys.executable, str(GATE), "--client", "codex-exec", "--session-id", "x",
                               "--contract", str(alt), "--last-message", "/dev/null", "--cwd", str(self.root)],
                              input="", text=True, capture_output=True, env={**os.environ, **self.env})
        self.assertEqual(0, proc.returncode, proc.stderr)
        self.assertTrue(self.log_lines()[0]["contract"].endswith("alt.md"))


class PreflightTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def start(self, env=None, source="startup"):
        return run(PREFLIGHT, {"session_id": "s-9", "cwd": str(self.root), "source": source,
                               "hook_event_name": "SessionStart"},
                   args=("--client", "claude-code"), env=env or {}, cwd=str(self.root))

    def test_injects_session_id_pointer_path_and_doc(self):
        p = self.start({"HOOKSHOT_PREFLIGHT_DOC": "docs/preflight.md"})
        self.assertEqual(0, p.returncode, p.stderr)
        out = json.loads(p.stdout)
        ctx = out["hookSpecificOutput"]["additionalContext"]
        self.assertEqual("SessionStart", out["hookSpecificOutput"]["hookEventName"])
        self.assertIn("s-9", ctx)
        self.assertIn(".state/contracts/s-9", ctx)
        self.assertIn("docs/preflight.md", ctx)
        self.assertTrue((self.root / ".state" / "contracts").is_dir())

    def test_omits_doc_line_when_unset(self):
        p = self.start({"HOOKSHOT_PREFLIGHT_DOC": ""})
        ctx = json.loads(p.stdout)["hookSpecificOutput"]["additionalContext"]
        self.assertNotIn("Read ", ctx)

    def test_malformed_stdin_exits_zero(self):
        proc = subprocess.run([sys.executable, str(PREFLIGHT), "--client", "codex"], input="nope",
                              text=True, capture_output=True, cwd=str(self.root))
        self.assertEqual(0, proc.returncode)


if __name__ == "__main__":
    unittest.main(verbosity=1)
