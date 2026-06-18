---
name: release-train-runner
description: Use when merging multiple reviewed PRs into one release branch on remote compute.
user-invocable: true
allowed-tools: Read, Bash, Glob, Grep, Task
---

## Purpose

Merge N reviewed PRs into a single release branch on remote compute (Ona or Codespaces),
one PR at a time, in order. Run the full test suite after each merge. Produce one release PR
with conflicts documented and a unified manual test plan, plus a local report.

**This skill runs in the OPERATOR session** and owns its worker lifecycle. It spawns a repo
through the worker. Stage 00 (claim compute) and stage 07 (report + outcome marker) run
inline in the operator.

**This procedure is FULLY SEQUENTIAL.** There is no parallelism anywhere. Each PR generates
new conflicts for every other PR, so PRs MUST be validated and integrated ONE AT A TIME, in the
provided order, inside a single loop in stage 03. Do NOT fan out per-PR subagents.

## Worker Setup

Spawn a worker at stage 00 (after claiming compute) for stages 01-06:

```bash
REPO="${0:-$PYLOT_REPO}"
SPAWN_RESP=$(curl -s --max-time 90 -X POST \
WID=$(echo "$SPAWN_RESP" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("worker_id",""))' 2>/dev/null)
```

idle between stages. Stop the worker after stage 06 completes, before the inline stage 07
writes the report and emits the outcome marker:

```bash
curl -s --max-time 30 -X POST \
```

## Arguments

| Param | Required | Default | Notes |
|-------|----------|---------|-------|
| `repo` | yes | — | `org/repo`, e.g. `Lexgo-cl/rails-backend` (parsed as `$0`) |
| `pr_numbers` | yes | — | Space-separated PR numbers in merge order, e.g. `1372 1375 1430` (`$1 $2 $3 ...`) |
| `instructions` | no | — | Complementary guidance in trailing parentheses; narrows scope |

Parse from `$ARGUMENTS`: first token is the repo, remaining bare integers are PR numbers in
order, trailing `(...)` is optional complementary instructions. Merge order = the order provided.

## What it does

8-stage FULLY SEQUENTIAL ICM procedure:

| Stage | Mode | Description |
|-------|------|-------------|
| 00-claim-compute | inline | Claim remote env (Ona or Codespaces); set `REMOTE_EXEC` + `REPO_DIR` |
| 01-preflight | subagent | Default branch, PR manifest, validate PRs, clean the env |
| 02-release-branch | subagent | Cut `release/YYYY-MM-DD` from default branch |
| 03-validate-integrate | subagent | **Sequential in-order loop**: per PR → validate → merge → resolve conflicts → test → log; next PR |
| 04-lockfiles | subagent | Regenerate lockfiles if any merged PR touched deps; re-test |
| 05-push-release-pr | subagent | Push release branch; open one release PR with unified test plan |
| 06-release-env | subagent | Write async trigger notification; release/stop remote compute |
| 07-report | inline | Write local report file; emit outcome marker |

Stage 03 is the isolated critical-judgement stage: PR validation, conflict resolution, and
merge verdicts all happen there in one clean context, looping over PRs sequentially.

## Handoff locations

All handoffs live in the repo working directory:
```
.procedure-output/release-train-runner/{stage}/handoff.md
```

Stage 00 writes the compute-claim context. Each subagent stage receives only the handoffs its
CONTEXT.md lists as inputs — never the full orchestrator context.

## Execution

### Stage 00 (inline)

Run stage 00 yourself (orchestrator context). Read CONTEXT.md:
```
.claude/skills/release-train-runner/stages/00-claim-compute/CONTEXT.md
```
Claim the remote environment, resolve `REMOTE_EXEC` and `REPO_DIR`, and write handoff to
`.procedure-output/release-train-runner/00-claim-compute/handoff.md`.

### Stages 01 → 06 (sequential subagents — one at a time)

For each stage in order, spawn exactly ONE Task. Wait for it to finish before launching the
next. **Never launch two stages in the same response. There are no parallel stages.**

Each Task prompt must be self-contained:
- Include only the input handoff paths the stage's CONTEXT.md lists
- Include the path to the stage's CONTEXT.md
- Do NOT pass orchestrator history or prior reasoning

Task prompt template:
```
You are running stage {NN}-{name} of the release-train-runner procedure.

Read your stage instructions:
  .claude/skills/release-train-runner/stages/{NN}-{name}/CONTEXT.md

Your inputs:
  .procedure-output/release-train-runner/{prior-stage}/handoff.md
  (...any other handoffs the CONTEXT.md lists)

Write your output to:
  .procedure-output/release-train-runner/{NN}-{name}/handoff.md

Execute all steps in CONTEXT.md. Write handoff.md before exiting.
```

If any stage emits a hard blocker (e.g. no compute in 00, zero valid PRs in 01), emit the
matching outcome marker and stop. A single skipped PR in stage 03 does NOT stop the chain.

### Stage 07 (inline)

Run stage 07 yourself (orchestrator context). Read CONTEXT.md:
```
.claude/skills/release-train-runner/stages/07-report/CONTEXT.md
```
(never from a subagent).

## Stage handoff chain

```
00 ─► 01 ─► 02 ─► 03 ─► 04 ─► 05 ─► 06 ─► 07 (inline, reads all)
              (per-PR loop:
               validate → merge → resolve → test,
               one PR at a time, in order)
```

## Exit paths

- **Success**: stage 07 emits
- **Failure**: failing stage emits
- **Blocked**: no compute claimable (00) or no valid PRs to merge (01) →

The outcome marker is always emitted by the orchestrator (inline), never by a subagent.

## Hard Rules

1. **FULLY SEQUENTIAL — no parallelism.** Never launch two Task calls in one response. There
   are no parallel stages.
2. **Per-PR validate+integrate is sequential and in-order.** Stage 03 loops over PRs one at a
   time in the provided order. NEVER fan out per-PR subagents — each merge changes the conflict
   surface for every later PR.
3. **A PR is reviewed in cohesion** — the whole diff, all dimensions together. Never split a PR
   review across files or dimensions.
4. **Stage 00 runs inline** — compute is claimed in orchestrator context so `REMOTE_EXEC` /
   `REPO_DIR` are stable for downstream stages.
6. **Never pass full orchestrator context** into subagent Task prompts — inputs only.
7. **Each stage writes handoff.md before the next stage reads it.**
8. **Do not skip stages** — every stage executes even if its action is "nothing to do"
   (e.g. stage 04 with no dependency changes still runs and records "no lockfile changes").
9. **Skip rather than break.** A PR that fails validation, conflicts irreconcilably, or breaks
   tests is skipped/reverted and logged — it does NOT abort the train.
10. **Never merge the release PR, never force-push, always `--no-ff`, always test after each
    merge.** Max reviews and merges the release PR manually.
11. **NO QUEST.** Reporting is the local report file only (stage 07) plus the async trigger
    notification (stage 06). No Quest POST, no Quest token, no Quest URL anywhere.

## Reference files

- `CONTEXT.md` — architecture overview
- `shared/release-pr-template.md` — release PR body template (used by stage 05)
- `shared/report-template.md` — local report template (used by stage 07)
- `shared/test-commands.md` — per-project test command lookup (used by stages 03 and 04)
- `stages/NN-name/CONTEXT.md` — per-stage inputs, task, output contract
