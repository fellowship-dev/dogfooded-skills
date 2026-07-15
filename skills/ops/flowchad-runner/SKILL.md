---
name: flowchad-runner
description: Use when running FlowChad flow automation — all flows run sequentially to avoid browser/session collisions.
user-invocable: true
argument-hint: "[flow-name|all] [org/repo] (pr-number) (trigger)"
allowed-tools: Read, Bash, Glob, Grep, Task
---

## Purpose

Walk named FlowChad flows with Playwright/Navvi, capture per-step screenshot + video
evidence, auto-switch to Navvi on CAPTCHA, upload evidence (best-effort), then post results
to GitHub and write a local report. Each stage runs as a focused subagent with isolated
context. The ICM win here is **clean stage contracts + resumability**, NOT parallelism:
flows CANNOT run concurrently because they share browser, session, and persona state and
would collide. Stage 03 walks flows **one at a time in a sequential loop**.

## Arguments

| Param | Required | Default | Notes |
|-------|----------|---------|-------|
| `flow-name` | yes | — | Flow name, or `all` for the smoke set |
| `repo` | yes | — | Target `org/repo` |
| `pr-number` | no | (none) | If set, post results comment to this PR |
| `trigger` | no | `manual` | `pr` \| `merge` \| `cron` \| `manual` — drives URL resolution + deploy-wait |

Parse positionally from `$ARGUMENTS`: `$1=flow-name $2=repo $3=pr-number $4=trigger`.

## What it does

5-stage ICM procedure (all sequential — no parallel stages):

| Stage | Mode | Description |
|-------|------|-------------|
| 01-preflight | subagent | Parse args, resolve TARGET_URL (trigger-driven), deploy-wait, Navvi/persona check, build FLOWS_TO_RUN |
| 02-load-flows | subagent | Read `.flowchad/config.yml`, validate each flow file exists, load flow YAML |
| 03-walk-flows | subagent | **Sequential loop**: for each flow one-at-a-time — connect browser, run steps, per-step screenshot, expect-judgement, CAPTCHA→Navvi, transcript |
| 04-upload-evidence | subagent | Best-effort: push screenshots/GIFs to evidence backend, collect URLs |
| 05-report | inline | Aggregate results, post PR comment, create issues on failure, write local report, emit outcome marker |

## Handoff locations

All handoffs live in the repo working directory:
```
.procedure-output/flowchad-runner/{stage}/handoff.md
```
Stage 01 writes the resolved run context (URL, persona, flow list). Each subagent stage
receives ONLY the handoff paths its CONTEXT.md lists as inputs — never orchestrator history.

## Execution

Run stages **strictly sequentially, one after another**. There are NO parallel Task launches
in this procedure. Spawn exactly one Task per subagent stage and await it before the next.

### Stages 01 → 04 (sequential subagents)

For each stage, spawn one Task. The Task prompt must be self-contained:
- Include only the stage's input handoff paths
- Include the path to the stage's CONTEXT.md
- Do NOT pass orchestrator history or prior reasoning

Task prompt template:
```
You are running stage {NN}-{name} of the flowchad-runner procedure.

Read your stage instructions:
  .claude/skills/flowchad-runner/stages/{NN}-{name}/CONTEXT.md

Your inputs:
  {list each input handoff path this stage needs}

Write your output to:
  .procedure-output/flowchad-runner/{NN}-{name}/handoff.md

Execute all steps in CONTEXT.md. Write handoff.md before exiting.
```

Do not start the next stage until the current one completes. If stage 01 cannot resolve a
TARGET_URL, or stage 01's deploy-wait fails, or stage 02 finds the flow file missing, emit
the matching outcome marker and stop (those stages also create GitHub issues themselves).

### Stage 05 (inline)

Run stage 05 yourself in the orchestrator. Read CONTEXT.md:
```
.claude/skills/flowchad-runner/stages/05-report/CONTEXT.md
```
Aggregate the prior handoffs, post the PR comment / create failure issues, write the local
report file, and emit the `[pylot] outcome=...` marker from the orchestrator (never a subagent).

## Stage handoff chain

```
01-preflight ─► 02-load-flows ─► 03-walk-flows ─► 04-upload-evidence ─► 05-report (inline)
   (URL,            (validated        (sequential        (evidence URLs,        (PR comment,
   persona,          flow YAML)        per-flow walk,     best-effort)           issues, local
   FLOWS_TO_RUN)                       results+transcript)                       report, marker)
```

## Exit paths

- **Success**: stage 05 emits `[pylot] outcome="flowchad {flow} on {repo}: all flows passed" status=success`
- **Failure**: stage 05 emits `[pylot] outcome="flowchad {flow} on {repo}: {N} flow(s) failed" status=failed`
  (failure issues already created in stage 05)
- **Blocked**: stage 01 (no URL / deploy failed) or stage 02 (flow missing) emits
  `[pylot] outcome="flowchad blocked: {reason}" status=blocked` and the chain stops.

## Cron Mode

Run a weekly production smoke against the critical flow set.

**Trigger**: pass `trigger=cron` as the 4th argument.

**What it walks**: Only flows marked `critical: true` under `smoke.flows` in `.flowchad/config.yml`.
Flows without that flag are skipped. Example config:

```yaml
smoke:
  flows:
    - name: contact-form
      critical: true
    - name: language-switch
      critical: true
    - name: page-load
      critical: true
    - name: author-page    # no critical: true — excluded from cron
```

**Config requirements for cron**: Stage 01 validates two things before running:
1. `name` must not be `booster-pack` (stale template identity).
2. `environments.production.url` must be present (non-empty).

A stale or missing config blocks immediately with a clear `block_reason` — no flows are walked.

**CAPTCHA-gated flows in cron**: If a critical flow has a non-optional `captcha: true` step
and Navvi is available, the flow is walked using Navvi. If Navvi is unavailable, the flow is
marked `blocked` (not `pass`) and a capability issue is created.

**Failure issue deduplication**: Stage 05 checks for existing open issues with matching title
before creating. If an open issue already exists for that flow, no duplicate is created. This
means repeated cron runs on a broken site produce exactly one open issue per failing flow.

**Scheduling**: Pylot handles the weekly dispatch via its own cron system. This skill only
needs `trigger=cron` passed in — it does not self-schedule. To configure weekly execution,
set a Pylot cron job to call:
```
/flowchad-runner all <org/repo> "" cron
```

**Exit**: `[pylot] outcome="flowchad all on {repo}: all flows passed" status=success`
or `status=failed` / `status=blocked` depending on results.

## Hard Rules

1. **All stages run SEQUENTIALLY** — exactly one Task at a time, awaited before the next.
   There is NO parallel fan-out anywhere in this procedure.
2. **Flows are walked ONE AT A TIME inside stage 03** — never one subagent per flow. Flows
   share browser/session/persona state and would collide if run concurrently.
3. **Stage 05 runs inline** — the `[pylot] outcome=...` marker MUST come from the orchestrator,
   never a subagent.
4. **Never pass full orchestrator context** into subagent Task prompts — inputs only.
5. **Each stage writes handoff.md before the next stage reads it.**
6. **Do not skip stages** — every stage executes even if its action is "nothing to do"
   (e.g. evidence upload with backend `none` still writes a handoff).
7. **A broken step is a finding, not a crash** — stage 03 continues collecting evidence after
   a step error; only flow-level pass/fail is judged.
8. **NO Quest, no external dashboards.** Reporting = the local report file + GitHub only.

## Reference files

- `CONTEXT.md` — architecture overview
- `stages/NN-name/CONTEXT.md` — per-stage inputs, task, output contract
