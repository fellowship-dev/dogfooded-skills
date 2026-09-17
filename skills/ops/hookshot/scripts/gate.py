#!/usr/bin/env python3
"""hookshot --gate: the delivery gate Stop hook.

Reads the Stop hook payload on stdin (Claude Code and Codex share the shape),
finds the session's outcome contract through `<state>/contracts/<session_id>`,
diffs what exists against it, and either logs the would-be refusal (shadow
mode, the default) or returns a block decision (enforce mode).

Usage as a hook:
    gate.py --client claude-code|codex          (payload on stdin)
Usage from a runner, after a non-interactive session ends:
    gate.py --client codex-exec --session-id ID --last-message FILE [--contract PATH] [--cwd DIR]

Environment:
    HOOKSHOT_STATE_DIR   state directory (default: <cwd>/.state)
    HOOKSHOT_GATE_MODE   shadow (default) | enforce
    HOOKSHOT_NO_NETWORK  set to skip URL and PR checks (they record `unverifiable`)

Never blocks while `stop_hook_active` is true. Exits 0 on every internal error
so a broken gate can only lose a log line, never trap a session.
Format reference: ../references/contract-format.md  Log reference: ../references/shadow-log.md
"""
from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import time
import urllib.request
from pathlib import Path

STATUS_WORDS = ("AWAITING OWNER ACTION", "DELIVERED", "BLOCKED")
STATUS_RE = re.compile(r"\b(AWAITING OWNER ACTION|DELIVERED|BLOCKED)\b")
ITEM_RE = re.compile(r"^\s*(\d+)\.\s+(.*\S)\s*$")
EVIDENCE_RE = re.compile(r"^\s*(?:-\s*)?(?:\*\*)?Evidence:(?:\*\*)?\s*(.*\S)?\s*$", re.I)
RESULT_ITEM_RE = re.compile(r"^\s*(?:-\s*)?(\d+)\s*[:.)]\s*(.*)$")
HEADING_RE = re.compile(r"^(#{1,6})\s+(.*\S)\s*$")
URL_RE = re.compile(r"https?://[^\s`'\")\]>]+")
PR_URL_RE = re.compile(r"https?://github\.com/[^/\s]+/[^/\s]+/pull/\d+")
RECEIPT_RE = re.compile(r"receipt:\s*[\"“']([^\"”']+)[\"”']", re.I)
BACKTICK_RE = re.compile(r"`([^`]+)`")
JUDGE_ONLY_TYPES = ("substitution", "skipped_standard", "work_still_running")


def now_iso() -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%S%z", time.localtime())


# ---------------------------------------------------------------- parsing

def split_sections(text: str) -> dict[str, str]:
    """Map lowercase heading text -> body for every markdown heading."""
    sections: dict[str, str] = {}
    current = "_preamble"
    buf: list[str] = []
    for line in text.splitlines():
        m = HEADING_RE.match(line)
        if m:
            sections[current] = "\n".join(buf)
            current = m.group(2).strip().lower()
            buf = []
        else:
            buf.append(line)
    sections[current] = "\n".join(buf)
    return sections


def find_section(sections: dict[str, str], *names: str) -> str | None:
    for key, body in sections.items():
        for n in names:
            if key == n or key.startswith(n + " ") or key.startswith(n + ":"):
                return body
    return None


def classify_evidence(evidence: str) -> list[dict]:
    """Turn one Evidence line into typed tokens."""
    tokens: list[dict] = []
    rest = evidence
    for m in RECEIPT_RE.finditer(evidence):
        tokens.append({"kind": "receipt", "value": m.group(1).strip()})
        rest = rest.replace(m.group(0), " ")
    for m in URL_RE.finditer(rest):
        url = m.group(0).rstrip(".,;")
        tokens.append({"kind": "pr" if PR_URL_RE.match(url) else "url", "value": url})
        rest = rest.replace(m.group(0), " ")
    for m in BACKTICK_RE.finditer(rest):
        val = m.group(1).strip()
        if looks_like_path(val):
            tokens.append({"kind": "path", "value": val})
        else:
            tokens.append({"kind": "judge", "value": val})
        rest = rest.replace(m.group(0), " ")
    for piece in re.split(r"[;,]", rest):
        piece = piece.strip().strip(".")
        if not piece:
            continue
        if looks_like_path(piece) and " " not in piece:
            tokens.append({"kind": "path", "value": piece})
        else:
            tokens.append({"kind": "judge", "value": piece})
    return tokens or [{"kind": "judge", "value": evidence.strip()}]


ORG_REPO_RE = re.compile(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_-]+$")


def looks_like_path(s: str) -> bool:
    s = s.strip()
    if " " in s:
        return False
    if ORG_REPO_RE.match(s) and not s.startswith((".", "~", "/")):
        return False  # `org/repo`, not a file
    return "/" in s or s.startswith("~") or bool(re.search(r"\.[A-Za-z0-9]{1,6}$", s))


def parse_contract(text: str) -> dict:
    sections = split_sections(text)
    deliverables = find_section(sections, "deliverables")
    items: list[dict] = []
    if deliverables is not None:
        current: dict | None = None
        for line in deliverables.splitlines():
            im = ITEM_RE.match(line)
            if im and not line.startswith("   "):
                current = {"n": int(im.group(1)), "title": im.group(2), "evidence": [], "raw_evidence": None}
                inline = re.search(r"Evidence:\s*(.*)$", im.group(2), re.I)
                if inline:
                    current["title"] = im.group(2)[: inline.start()].strip().rstrip("-—:").strip()
                    current["raw_evidence"] = inline.group(1).strip()
                    current["evidence"] = classify_evidence(current["raw_evidence"])
                items.append(current)
                continue
            em = EVIDENCE_RE.match(line)
            if em and current is not None and current["raw_evidence"] is None:
                current["raw_evidence"] = (em.group(1) or "").strip()
                current["evidence"] = classify_evidence(current["raw_evidence"])
    result = find_section(sections, "result", "delivery gate receipt")
    statuses: dict[int, dict] = {}
    section_status = None
    if result is not None:
        sm = STATUS_RE.search(result)
        section_status = sm.group(1) if sm else None
        for line in result.splitlines():
            rm = RESULT_ITEM_RE.match(line)
            if rm:
                n = int(rm.group(1))
                body = rm.group(2).strip()
                st = STATUS_RE.search(body)
                statuses[n] = {"status": st.group(1) if st else None, "text": body}
    structured = bool(items)
    return {
        "structured": structured,
        "items": items,
        "result_text": result or "",
        "result_status": section_status,
        "item_statuses": statuses,
        "mode": (re.search(r"^Mode:\s*(\w+)", text, re.M) or [None, None])[1],
    }


# ---------------------------------------------------------------- checks

def check_path(value: str, cwd: Path) -> str:
    p = Path(os.path.expanduser(value))
    if not p.is_absolute():
        p = cwd / p
    return "ok" if p.exists() else "path_missing"


def check_url(url: str, no_network: bool) -> str:
    if no_network:
        return "unverifiable"
    try:
        req = urllib.request.Request(url, method="HEAD", headers={"User-Agent": "hookshot-gate"})
        with urllib.request.urlopen(req, timeout=4) as resp:  # noqa: S310
            return "ok" if resp.status < 400 else "url_%d" % resp.status
    except Exception as exc:  # noqa: BLE001
        code = getattr(exc, "code", None)
        if code in (404, 410):
            return "url_%d" % code
        return "unverifiable"


def check_pr(url: str, no_network: bool) -> str:
    if no_network:
        return "unverifiable"
    try:
        proc = subprocess.run(["gh", "pr", "view", url, "--json", "number"], capture_output=True, text=True, timeout=8)
        if proc.returncode == 0:
            return "ok"
        if "Could not resolve" in proc.stderr or "not found" in proc.stderr.lower():
            return "pr_missing"
        return "unverifiable"
    except Exception:  # noqa: BLE001
        return check_url(url, no_network)


def check_receipt(literal: str, last_message: str, result_text: str) -> str:
    hay = (last_message or "") + "\n" + (result_text or "")
    return "ok" if literal in hay else "receipt_absent"


def qualified_hold(status_line: str) -> bool:
    """A BLOCKED / AWAITING OWNER ACTION line counts only when it names something."""
    body = STATUS_RE.sub("", status_line).strip(" -—:.,")
    return len(body) >= 12


def evaluate(contract: dict, last_message: str, cwd: Path, no_network: bool) -> tuple[list[dict], list[dict]]:
    misses: list[dict] = []
    judge: list[dict] = []
    if not STATUS_RE.search(last_message or ""):
        misses.append({"type": "no_status_word", "item": None, "evidence": None, "check": "last_message"})
    if not contract["structured"]:
        judge.append({"type": "format_loose", "item": None, "question": "Diff the prose contract against the final message: short count, substitution, skipped standards, evidence, work still running."})
        return misses, judge
    has_item_statuses = bool(contract["item_statuses"])
    for it in contract["items"]:
        n = it["n"]
        st = contract["item_statuses"].get(n)
        if has_item_statuses and st is None:
            misses.append({"type": "short_count", "item": n, "evidence": it["raw_evidence"], "check": "absent_from_result"})
            continue
        if st and st["status"] in ("BLOCKED", "AWAITING OWNER ACTION"):
            if qualified_hold(st["text"]):
                continue
            misses.append({"type": "bare_status", "item": n, "evidence": st["status"], "check": "hold_without_dependency_or_action"})
            continue
        if not it["evidence"]:
            judge.append({"type": "claim_without_evidence", "item": n, "question": "No evidence named; is the item done?"})
            continue
        for tok in it["evidence"]:
            kind, val = tok["kind"], tok["value"]
            if kind == "path":
                res = check_path(val, cwd)
            elif kind == "url":
                res = check_url(val, no_network)
            elif kind == "pr":
                res = check_pr(val, no_network)
            elif kind == "receipt":
                res = check_receipt(val, last_message, contract["result_text"])
            else:
                judge.append({"type": "claim_without_evidence", "item": n, "question": f"Verify: {val}"})
                continue
            if res not in ("ok", "unverifiable"):
                misses.append({"type": "claim_without_evidence", "item": n, "evidence": val, "check": res})
            elif res == "unverifiable":
                judge.append({"type": "unverifiable", "item": n, "question": f"Could not verify {kind}: {val}"})
    for t in JUDGE_ONLY_TYPES:
        judge.append({"type": t, "item": None, "question": t.replace("_", " ")})
    return misses, judge


# ---------------------------------------------------------------- io

def append_log(state: Path, record: dict) -> None:
    logdir = state / "hookshot"
    logdir.mkdir(parents=True, exist_ok=True)
    with (logdir / "gate-shadow.jsonl").open("a") as fh:
        fh.write(json.dumps(record, ensure_ascii=False) + "\n")


def write_packet(state: Path, sid: str, contract_path: Path, contract_text: str, last_message: str, judge: list[dict], misses: list[dict]) -> None:
    d = state / "hookshot" / "judge"
    d.mkdir(parents=True, exist_ok=True)
    (d / f"{sid}.json").write_text(json.dumps({
        "session_id": sid, "contract_path": str(contract_path), "contract": contract_text,
        "last_assistant_message": last_message, "judge_items": judge, "deterministic_misses": misses,
    }, ensure_ascii=False))


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(add_help=True)
    ap.add_argument("--client", required=True, choices=["claude-code", "codex", "codex-exec"])
    ap.add_argument("--session-id")
    ap.add_argument("--last-message", help="file holding the final assistant message (runner mode)")
    ap.add_argument("--contract", help="contract path; overrides the session pointer")
    ap.add_argument("--cwd")
    args = ap.parse_args(argv)

    mode = os.environ.get("HOOKSHOT_GATE_MODE", "shadow").strip().lower() or "shadow"
    no_network = bool(os.environ.get("HOOKSHOT_NO_NETWORK"))
    payload: dict = {}
    raw = ""
    if not sys.stdin.isatty():
        raw = sys.stdin.read()
    cwd = Path(args.cwd or os.getcwd())
    state = Path(os.environ.get("HOOKSHOT_STATE_DIR") or (cwd / ".state"))
    sid = args.session_id or "unknown"
    base = {"ts": now_iso(), "client": args.client, "mode": mode}
    try:
        if raw.strip():
            payload = json.loads(raw)
            cwd = Path(args.cwd or payload.get("cwd") or cwd)
            state = Path(os.environ.get("HOOKSHOT_STATE_DIR") or (cwd / ".state"))
            sid = args.session_id or payload.get("session_id") or sid
    except Exception as exc:  # noqa: BLE001
        append_log(state, {**base, "kind": "error", "session_id": sid, "error": f"bad stdin: {type(exc).__name__}", "would_block": False})
        return 0
    base.update({"session_id": sid, "cwd": str(cwd)})
    try:
        if payload.get("stop_hook_active"):
            return 0
        if args.last_message:
            last_message = Path(args.last_message).read_text() if Path(args.last_message).exists() else ""
        else:
            last_message = payload.get("last_assistant_message") or ""
        contract_path: Path | None = None
        if args.contract:
            contract_path = Path(args.contract)
        else:
            ptr = state / "contracts" / sid
            if ptr.exists():
                target = ptr.read_text().strip().splitlines()[0].strip() if ptr.read_text().strip() else ""
                if target:
                    contract_path = Path(os.path.expanduser(target))
        if contract_path is not None and not contract_path.is_absolute():
            contract_path = cwd / contract_path
        if contract_path is None or not contract_path.exists():
            append_log(state, {**base, "kind": "no_contract", "contract": str(contract_path) if contract_path else None, "would_block": False})
            return 0
        text = contract_path.read_text()
        contract = parse_contract(text)
        misses, judge = evaluate(contract, last_message, cwd, no_network)
        native = args.client == "claude-code"
        running = [t for t in (payload.get("background_tasks") or []) if t] if isinstance(payload.get("background_tasks"), list) else []
        if running:
            misses.append({"type": "work_still_running", "item": None, "evidence": f"{len(running)} background task(s)", "check": "background_tasks"})
        would_block = bool(misses)
        sm = STATUS_RE.search(last_message or "")
        record = {
            **base, "kind": "gate", "contract": str(contract_path), "format": "structured" if contract["structured"] else "loose",
            "contract_mode": contract["mode"], "status_word": sm.group(1) if sm else None,
            "judge": "native" if native else "none", "judge_items": len(judge),
            "misses": misses, "would_block": would_block,
        }
        append_log(state, record)
        if native and (judge or misses):
            write_packet(state, sid, contract_path, text, last_message, judge, misses)
        if mode == "enforce" and would_block:
            reasons = "; ".join(f"{m['type']}" + (f" item {m['item']}" if m.get("item") else "") + (f" ({m['check']})" if m.get("check") else "") for m in misses)
            print(json.dumps({"decision": "block", "reason": f"Delivery gate: unmet contract items. {reasons}. Deliver them or mark each BLOCKED / AWAITING OWNER ACTION with its dependency or action in the contract's Result section, then stop again."}))
        return 0
    except Exception as exc:  # noqa: BLE001
        try:
            append_log(state, {**base, "kind": "error", "error": f"{type(exc).__name__}: {exc}"[:200], "would_block": False})
        except Exception:  # noqa: BLE001
            pass
        return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
