#!/usr/bin/env python3
"""hookshot --preflight: the SessionStart hook.

Reads the SessionStart payload on stdin (Claude Code and Codex share the shape:
`session_id`, `cwd`, `source`) and returns `additionalContext` telling the
agent to run preflight for a task, its session id, and where to record the
contract pointer. Creates `<state>/contracts/` so the pointer can be written.

Usage:
    preflight.py --client claude-code|codex          (payload on stdin)

Environment:
    HOOKSHOT_STATE_DIR      state directory (default: <cwd>/.state)
    HOOKSHOT_PREFLIGHT_DOC  repo-relative doc the reminder cites (optional)

Exits 0 on every error; a broken hook must never block a session start.
"""
from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--client", default="unknown")
    args = ap.parse_args(argv)
    try:
        raw = "" if sys.stdin.isatty() else sys.stdin.read()
        payload = json.loads(raw) if raw.strip() else {}
        if not isinstance(payload, dict):
            payload = {}
    except Exception:  # noqa: BLE001
        payload = {}
    try:
        cwd = Path(payload.get("cwd") or os.getcwd())
        state = Path(os.environ.get("HOOKSHOT_STATE_DIR") or (cwd / ".state"))
        sid = payload.get("session_id") or "unknown"
        source = payload.get("source") or "startup"
        try:
            (state / "contracts").mkdir(parents=True, exist_ok=True)
        except Exception:  # noqa: BLE001
            pass
        try:
            pointer = str((state / "contracts" / sid).relative_to(cwd))
        except ValueError:
            pointer = str(state / "contracts" / sid)
        doc = (os.environ.get("HOOKSHOT_PREFLIGHT_DOC") or "").strip()
        lines = [
            f"hookshot preflight: session {sid} ({source}, {args.client}).",
            "If this session's first prompt is a task (an imperative, a handoff, an issue, a plan), run preflight before working: "
            f"write the outcome contract and record its repo-relative path as the only line of `{pointer}`. "
            "The delivery gate reads that pointer when you stop.",
        ]
        if doc:
            lines.append(f"Read `{doc}` for the preflight decision and the contract format.")
        print(json.dumps({"hookSpecificOutput": {"hookEventName": "SessionStart", "additionalContext": " ".join(lines[:2]) + ("\n" + lines[2] if doc else "")}}))
    except Exception:  # noqa: BLE001
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
