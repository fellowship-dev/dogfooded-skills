---
name: create-compelling-prs
description: Use when preparing a PR for review — applies body templates, attaches the deployment and visual evidence the repo playbook requires, and runs the self-audit checklist.
user-invocable: true
trigger-hint: "When creating a PR or preparing to push a branch for review"
allowed-tools: Read, Write, Bash, Glob, Grep
---

# create-compelling-prs

Your PR competes for attention. The reviewer is looking at many PRs — if yours isn't immediately convincing, it gets skipped or rejected. Evidence beats rhetoric. A single well-implemented PR that convinces in 2 minutes is worth more than five that require follow-up.

## PR Body Templates

Pick the template matching your change type.

### Bugfix

```markdown
## What broke
[One sentence: what failed and where]

## Root cause
[The underlying cause — missing guard, race condition, wrong assumption]

## Fix
[What changed and why this approach over alternatives]

## Before / After
| Before | After |
|--------|-------|
| ![before](URL) | ![after](URL) |

## Test output
[paste test run]

## How to verify
1. [Step to reproduce original bug — should now pass]
2. [Regression check]

Closes #ISSUE
```

### Feature

```markdown
## What this adds
[One sentence: the user-visible capability]

## Why
[Business or product motivation]

## Implementation
[2-3 sentences: what was added/changed, key design decisions]

## Demo
![demo](URL_OR_GIF)

## Test output
[paste test run]

## How to verify
1. [Golden path step]
2. [Edge case]

Closes #ISSUE
```

### Refactor

```markdown
## What changed
[What was moved, renamed, or restructured]

## Why
[The underlying problem that made this necessary]

## What stays the same
[Public API, behavior, outputs — nothing visible changed]

## Test output
[paste exact commands, revisions, scope and results; state limits and remaining required gates]

Closes #ISSUE
```

### Deps

```markdown
## Update
[Package] vX.Y.Z → vA.B.C

## Why now
[Security advisory / feature needed / routine bump]

## Risk
[Low/Medium/High — breaking changes? Coverage of affected areas?]

## Test output
[paste — owning repo dependency verification passed; name the commands and scope]
```

---

## Independent Review Record

When the implementation pipeline provides an independent advisory review, add a
short section that distinguishes suggestions corrected, declined with rationale,
unavailable due to review runtime failure, and still residual. Objective repo
policy may gate readiness or merge. Independent LLM suggestions themselves never
block PR creation, fail the mission, or strand its pushed checkpoint.

---

## Deployment Evidence

Whether a PR must prove it ran somewhere before review — and in what form — is **repo policy, not protocol**. Some companies gate infra/backend PRs on a verified staging deploy; some have no staging environment at all.

**Read the repo playbook first** (`GET /admin/playbooks/<org>/<repo>`, falling back to `CONTRIBUTING.md` / `.github/PULL_REQUEST_TEMPLATE.md`) and resolve:

| Question | Why it matters |
| --- | --- |
| What deployment evidence does the review gate require, and for which paths? | A gate can reject the PR unreviewed |
| What is the exact evidence-block format? | Gates parse it — **reproduce the playbook's block verbatim**, do not paraphrase |
| Body or comment? | Body-scanning gates do not see comments, and vice versa |
| What waives it? | Docs/test-only PRs are usually exempt; the playbook says how to record the waiver |

> **No deployment-evidence policy in the playbook?** Do not invent one and do not assume a staging environment exists. State what you verified locally and how — the exact commands and their output — and note in the PR body that the playbook defines no deployment-evidence requirement.

---

## Visual Evidence

For any UI-impacting change, capture before/after screenshots (Playwright preferred, manual fallback) and embed them in the PR body.

**Where images are hosted is repo policy.** Check the playbook for an asset-hosting section and follow it. When the policy uses Pylot assets, read `pylot-cli` and use its Assets workflow; that skill is the single source for supported lifecycle commands and upload transport.

> **No asset-hosting section?** Attach the images to the PR directly (GitHub hosts images uploaded through the PR editor or the comment API) or link a CI artifact, and say which you used. Never link an image from a host the reviewer cannot reach.

**Skip** if: backend-only, CLI-only, config/infra, test-only, or capture exceeds 120s. Visual evidence is a recommendation, never a gate — unless the repo playbook makes it one.

---

## Verification Scope

Resolve the owning repository's active instructions and verification contract before selecting
commands. Map the complete change to affected behavior and direct consumers, including shared
code, dependency/lockfile changes, migrations, transformations, and integration boundaries.
Run meaningful focused checks when that contract permits them; preserve every required broad,
full-suite, build, staging, and release gate. Dependency changes are not test-exempt. Unmapped
impact or missing meaningful coverage requires broader verification or an explicit unresolved
coverage gap. Never infer that CI owns a full gate without checking the repository policy and
its actual configured workflow.

Record commands, scope, results, test counts, exact revision and remaining gates. Failed,
unavailable, or zero-test runs are not a pass. Reuse a current receipt only when its revision,
scope, environment and policy still apply; rerun after changes, failures or unresolved concerns.
Independent acceptance remains required: inspect the diff and reproduce the relevant behavior
or gate where useful, without automatically repeating the same full suite on unchanged code.

## Self-Audit Checklist

Run this before opening or marking a PR ready for review:

- [ ] **Complete?** Does this complete the bounded work represented by this PR's one driving issue?
- [ ] **Shippable?** If merged as-is, will the PR close its driving issue, with every deliberately
      deferred named criterion captured verbatim in a linked follow-up using the shared
      [follow-up issue contract](../../shared/follow-up-issue-template.md)?
- [ ] **No manual caveats?** Zero "you'll need to X manually" instructions in the PR body.
- [ ] **Verification passes?** Current evidence covers the affected behavior and every required repo gate; exact commands, scope and revision are recorded.
- [ ] **Evidence present?** Screenshots or test output embedded for every meaningful change.
- [ ] **Policy honored?** The playbook's deployment-evidence block is present, verbatim, in the location it names — or the "no policy in playbook" note is in the body.
- [ ] **Issue linked?** The PR has exactly one driving issue and uses `Closes #N`, `Fixes #N`, or
      `Resolves #N` for it. Every later PR in deliberate multi-PR work gets its own driving issue;
      file and link a follow-up using the shared
      [follow-up issue contract](../../shared/follow-up-issue-template.md), then close that follow-up
      from the later PR. Use `Refs #N` only for an issue clearly identified as related context,
      never for the issue that drove the current PR.

**If the "No manual caveats?" check fails: close the PR and report the blocker instead** — in whatever form the repo playbook names (blocker report, issue, mission report); an issue on the repo if it names none. A PR that punts work back is worse than no PR. Reroute around obstacles — if the UI is the only path, use the API; if the API is missing, script it.

---

## Lead Self-Assessment Loop

After a worker reports done, do not immediately accept. Press harder.

**Iteration protocol:**

1. Inspect the agreed outcome, diff, affected behavior and current verification receipts.
2. Identify concrete acceptance gaps. Require **actions, not claims**: a missing behavioral
   check needs evidence; a rendering gap needs inspection or a screenshot when relevant.
3. After a correction, verify the affected scope on the resulting revision and resolve any
   remaining material gaps. Preserve independently required repository gates.
4. Stop when acceptance is supported. Do not add iterations, tests or code changes merely to
   demonstrate effort. If a gap cannot be resolved, state the specific blocker and evidence.

**Rules:**

- **Never accept rhetoric.** "I'm confident this is solid" is not evidence — demand it.
- **Verify independently.** Inspect current evidence and reproduce relevant behavior or checks under the owning repo contract. Open the PR URL; load the affected live site when applicable. Resolve material gaps before acceptance.
- **Track corrections and evidence.** A valid verification receipt can close a gap without a code change; require a concrete result for each identified gap.

**Rotation questions** (vary to avoid formulaic answers):

- "What would a senior engineer reject in code review?"
- "Which affected behavior and repository gates does this evidence cover? Run the missing meaningful checks and paste the output."
- "Screenshot the affected page. Does it match the design system?"
- "What did you punt on? Re-read the task and list every deliverable."
- "If this gets rejected, what's the most likely reason? Fix it preemptively."
