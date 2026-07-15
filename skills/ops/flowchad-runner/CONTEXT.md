# flowchad-runner — Overview

5-stage ICM procedure for FlowChad flow automation, converted from the monolithic
`flowchad-runner` skill.

## Purpose

The monolithic flowchad-runner ran Phases 0–5 in one session. By the time the report phase
judged pass/fail, the context carried the full history of every step of every flow — diluting
the per-flow judgement. This procedure isolates each phase into a focused subagent: clean
context for the walk, clean context for the report, and a resumable stage boundary between them.

**The ICM win is clean-context isolation + resumability — NOT parallelism.** Flows are walked
one at a time inside a single stage, because they share browser, session, and persona state and
would collide if run concurrently. There is no per-flow fan-out and no parallel Task launches
anywhere in this procedure.

## Architecture

5 stages, all sequential. Stages 01–04 each run as a Task subagent with isolated context.
Stage 05 (report) runs inline in the orchestrator so it can emit the outcome marker.

## Key invariants

- Stage 01: validates the environment contract, resolves run context (TARGET_URL via trigger,
  selective on-demand preview, deploy-wait, browser/Navvi/persona, FLOWS_TO_RUN). First gate —
  invalid identity/target, no browser for interactive work, no URL, or failed deploy → blocked.
- Stage 02: pure read/validate. Flow file missing → blocked (issue created).
- Stage 03: the only stage that drives a browser. **Sequential per-flow loop** — connect,
  walk steps, screenshot each step, judge `expect`, CAPTCHA→Navvi escalation, JSONL transcript.
  Flows never overlap.
- Stage 04: best-effort evidence upload. Failure here never blocks; it degrades to "no URLs".
- Stage 05: inline. Aggregates, posts PR comment, creates failure issues, writes the local
  report file, emits `[pylot] outcome=...` from the orchestrator. NO Quest, no dashboards.
- Interactive runs have four terminal states: PASSED, FAILED, BLOCKED, and N/A. Static/curl
  diagnostics cannot produce PASSED.

## Folder map

```
SKILL.md             — invocation reference and execution logic
CONTEXT.md           — this file
stages/01-05/        — CONTEXT.md per stage
```

## Runtime handoff path

```
.procedure-output/flowchad-runner/{stage}/handoff.md
```

Written at runtime in the repo working directory (not inside the skill directory).
Per-flow evidence (screenshots, video, GIF, results.json) lands under
`.flowchad/snapshots/{date}-{flow-slug}/` as in the original skill.

## Emit on completion

- Success: `[pylot] outcome="flowchad {flow} on {repo}: all flows passed" status=success`
- Failure: `[pylot] outcome="flowchad {flow} on {repo}: {N} flow(s) failed" status=failed`
- Blocked: `[pylot] outcome="flowchad blocked: {reason}" status=blocked`
