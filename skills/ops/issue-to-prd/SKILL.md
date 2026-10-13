---
name: issue-to-prd
description: Use when turning a GitHub issue into a spec before implementation. Writes specs/<issue>-<slug>/spec.md with a PRD and a mandatory "Questions for the owner" section (options plus a recommended answer for every open decision). Works unattended in a devbox or attended in a session; makes no GitHub writes.
user-invocable: true
allowed-tools: Read, Write, Bash, Glob, Grep, Task
metadata:
  version: 2.0.0
---

# issue-to-prd

ICM procedure: turn an issue into a committed spec, then hand its open decisions to the owner.
This is the spec step of the devbox workflow. The owner decision round that follows is
mandatory, and implementation (`/ce-plan` → `/ce-work` → `/code-review`) starts only once the
spec's status is `decided`.

## Invocation
```
/issue-to-prd {repo} {issue_number}
/issue-to-prd {issue_number}        # issue title, body and comments supplied in the prompt
```
Example: `/issue-to-prd Lexgo-cl/rails-backend 1230`

Run it from the target repository's root, at the commit the work will start from.

## Output contract
- **`specs/{issue_number}-{slug}/spec.md`** in the target repository: the PRD from
  `shared/prd-template.md`, ending with `## Questions for the owner`. Every open decision is a
  question with at least two options, one recommended answer with its reason, and whether it
  blocks implementation.
- A status line: `awaiting-owner-decisions` until every question has an owner answer, then
  `decided`.
- Inside a devbox the spec is committed with the work (or on its own when the run only writes
  the spec), following the caller's branch and delivery instructions.
- No GitHub writes: no comments, labels or issue-body edits. Posting the questions is the
  caller's job.
- `scripts/check_spec.py specs/{issue_number}-{slug}/spec.md` must exit 0.

## Why the owner round is mandatory
In the 2026-10-13 bake-off this procedure produced the best specs on vague asks, yet every agent
arm contradicted at least one real owner decision: agents ask the right questions, then
recommend the conservative engineering answer. So the spec records recommendations, never
decisions, for anything the issue and codebase do not settle.

## Stages
1. **01-read-issue** — read the issue (via `gh`, read-only, or from the prompt) and any prior
   spec with owner answers
2. **01b-triage-challenge** — look for an existing mechanism serving the same need and test the
   ask against its smallest version → `delete-retire` / `close` / `re-scope` / `prd`; a non-`prd`
   verdict skips stages 02-05 and stage 06 writes a short triage spec with one owner question
3. **02-context-completeness** — implicit context gaps a fresh agent would miss
4. **03-assess-clarity** — 8-section gap checklist → `clear` or `needs-questions`
5. **04-failure-modes** — how an implementer could go astray → guardrails
6. **05-test-plan** — test strategy and prerequisites, pre-merge and post-merge
7. **06-ask-or-structure** — write the spec: structure what the evidence settles, ask about
   everything else, set the status

## Modes
- **Unattended** (devbox, scheduled run, or "nobody will answer"): never prompt. Write the spec
  with its questions and stop.
- **Attended** (a person is in the session): write the spec, then put all questions to them once,
  with recommendations. Record their answers in the spec, update the status, and stop.

## Execution
Set a scratch directory for stage handoffs outside the repository, so nothing but the spec
lands in the working tree:

```bash
WORK="${TMPDIR:-/tmp}/issue-to-prd-{issue_number}"; mkdir -p "$WORK"
```

Run the stages in order and read each stage's `CONTEXT.md` before executing it. Each stage
writes `$WORK/{stage}.md` and later stages read earlier handoffs. Stage 01b is a gate: on any
verdict but `prd`, skip to stage 06.

## Reference files
- `shared/prd-template.md` — spec structure (stage 06)
- `shared/failure-modes.md` — agent pitfall catalog (stage 04)
- `stages/03-assess-clarity/references/gap-checklist.md` — 8-section checklist
- `scripts/check_spec.py` — structural check of a written spec
- `evals/` — contract test and the triage scenario
