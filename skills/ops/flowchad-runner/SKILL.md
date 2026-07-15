---
name: flowchad-runner
description: Use when verifying local, preview, production, or recurring critical user flows with browser evidence and selective on-demand deployments.
allowed-tools: Read, Bash, Glob, Grep, Task
---

# flowchad-runner

Verify named FlowChad flows with Playwright/Navvi, capture per-step screenshot + video
evidence, auto-switch to Navvi on CAPTCHA, upload evidence (best-effort), then post results
to GitHub and write a local report. Each stage runs as a focused subagent with isolated
context. The ICM win here is **clean stage contracts + resumability**, NOT parallelism:
flows CANNOT run concurrently because they share browser, session, and persona state and
would collide. Stage 03 walks flows **one at a time in a sequential loop**.

## When to Use

- Explicit pre-merge verification for a PR that affects declared flows
- Production verification after deployment
- Weekly or scheduled critical production smoke runs
- Manual local diagnosis when local CAPTCHA behavior is explicitly configured

## When Not to Use

- Docs-only, Dependabot, or unaffected PRs: return `N/A` without creating a preview
- Static-only analysis presented as interactive certification
- Global provider auto-preview enablement; previews are explicit and on-demand

## Arguments

| Param | Required | Default | Notes |
| ------- | ---------- | --------- | ------- |
| `flow-name` | yes | — | Flow name, or `all` (`smoke.critical` for cron; `smoke.flows` otherwise) |
| `repo` | yes | — | Target `org/repo` |
| `pr-number` | no | (none) | If set, post results comment to this PR |
| `trigger` | no | `manual` | `pr` \| `merge` \| `cron` \| `manual` — drives URL resolution + deploy-wait |

Parse positionally from `$ARGUMENTS`: `$1=flow-name $2=repo $3=pr-number $4=trigger`.
Use the literal `none` when a cron/manual invocation has no PR number.

## Result Contract

| State | Meaning |
| --- | --- |
| `PASSED` | Required steps passed with real browser evidence |
| `FAILED` | Browser evidence demonstrated a product or flow defect |
| `BLOCKED` | A required target, deploy, browser, persona, or credential was unavailable |
| `N/A` | PR is docs-only, Dependabot, or does not affect a declared flow |

Interactive flows can never pass from curl, static HTML, or bundle inspection. Read
[references/interactive-contract.md](references/interactive-contract.md) when creating or
upgrading `.flowchad/config.yml` and flow definitions.

## What it does

5-stage ICM procedure (all sequential — no parallel stages):

| Stage | Mode | Description |
| ------- | ------ | ------------- |
| 01-preflight | subagent | Validate contract, select affected flow, resolve target/selective preview, deploy-wait, browser/persona check |
| 02-load-flows | subagent | Read `.flowchad/config.yml`, validate each flow file exists, load flow YAML |
| 03-walk-flows | subagent | **Sequential loop**: for each flow one-at-a-time — connect browser, run steps, per-step screenshot, expect-judgement, CAPTCHA→Navvi, transcript |
| 04-upload-evidence | subagent | Best-effort: push screenshots/GIFs to evidence backend, collect URLs |
| 05-report | inline | Aggregate results, post PR comment, create issues on failure, write local report, emit outcome marker |

## Handoff locations

All handoffs live in the repo working directory:

```text
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

```text
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

Before stage 01, verify the checked-in contract deterministically:

```bash
MODE="$TRIGGER"
[ "$MODE" = merge ] && MODE=production
[ "$MODE" = pr ] && MODE=preview
[ "$MODE" = manual ] && MODE=local
python3 .claude/skills/flowchad-runner/scripts/validate_contract.py \
  --mode "$MODE" --repo "$REPO" --format json \
  > .procedure-output/flowchad-runner/contract.json
```

Any validator error blocks production, preview, and cron certification. Do not silently fall
back to legacy `.url`, template identity, or localhost for those modes.

### Stage 05 (inline)

Run stage 05 yourself in the orchestrator. Read CONTEXT.md:

```text
.claude/skills/flowchad-runner/stages/05-report/CONTEXT.md
```

Aggregate the prior handoffs, post the PR comment / create failure issues, write the local
report file, and emit the `[pylot] outcome=...` marker from the orchestrator (never a subagent).

## Stage handoff chain

```text
01-preflight ─► 02-load-flows ─► 03-walk-flows ─► 04-upload-evidence ─► 05-report (inline)
   (URL,            (validated        (sequential        (evidence URLs,        (PR comment,
   persona,          flow YAML)        per-flow walk,     best-effort)           issues, local
   FLOWS_TO_RUN)                       results+transcript)                       report, marker)
```

## Exit paths

- **Success**: stage 05 emits `[pylot] outcome="flowchad {flow} on {repo}: all flows passed" status=success`
- **Failure**: stage 05 emits `[pylot] outcome="flowchad {flow} on {repo}: {N} flow(s) failed" status=failed`
  (failure issues already created in stage 05)
- **Blocked**: stage 01 (invalid contract / no URL / deploy failed / no browser) or stage 02
  (flow missing) emits
  `[pylot] outcome="flowchad blocked: {reason}" status=blocked` and the chain stops.
- **N/A**: stage 01 detects an unaffected/docs-only/Dependabot PR and emits
  `[pylot] outcome="flowchad N/A: no affected interactive flow" status=success` without a deploy.

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
9. **Interactive PASS requires browser evidence.** Static/curl diagnostics can support a
   `FAILED` or `BLOCKED` result, never `PASSED`.
10. **Production-critical controls are never optional or skipped.** Missing CAPTCHA/Navvi
    capability is `BLOCKED`, not a pass and not a production skip.
11. **Preview creation is selective.** Never enable provider auto-previews; create at most one
    on-demand preview for an explicitly dispatched relevant PR when no staging target exists.
12. **Cron uses `smoke.critical`.** Failures create or update a deduplicated issue with browser
    evidence; the public skill does not own the scheduler.

## Reference files

- `CONTEXT.md` — architecture overview
- `stages/NN-name/CONTEXT.md` — per-stage inputs, task, output contract
- `references/interactive-contract.md` — target configuration and CAPTCHA/i18n examples
- `scripts/validate_contract.py` — deterministic environment/flow contract validator
