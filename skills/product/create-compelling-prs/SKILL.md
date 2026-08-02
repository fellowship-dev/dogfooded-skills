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
[paste — proves no regressions]

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
[paste — full suite green]
```

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

**Where images are hosted is repo policy.** Check the playbook for an asset-hosting section: if it names an upload path — a skill (e.g. `skills/ops/evidence-upload`), an endpoint, a bucket — follow it exactly, including any visibility step needed to make the URL public.

> **No asset-hosting section?** Attach the images to the PR directly (GitHub hosts images uploaded through the PR editor or the comment API) or link a CI artifact, and say which you used. Never link an image from a host the reviewer cannot reach.

**Skip** if: backend-only, CLI-only, config/infra, test-only, or capture exceeds 120s. Visual evidence is a recommendation, never a gate — unless the repo playbook makes it one.

---

## Self-Audit Checklist

Run this before opening or marking a PR ready for review:

- [ ] **Complete?** Does this finish every deliverable in the original task?
- [ ] **Shippable?** If merged as-is, would the task be done — no follow-up tickets created?
- [ ] **No manual caveats?** Zero "you'll need to X manually" instructions in the PR body.
- [ ] **Tests pass?** Ran them yourself right now — not trusting earlier cached output.
- [ ] **Evidence present?** Screenshots or test output embedded for every meaningful change.
- [ ] **Policy honored?** The playbook's deployment-evidence block is present, verbatim, in the location it names — or the "no policy in playbook" note is in the body.
- [ ] **Issue linked?** `Closes #N` when this PR delivers the issue — that is the default. `Refs #N` ONLY when the PR is one phase of deliberately multi-PR work; the final phase carries the `Closes`. Do not default to `Refs` out of caution: issues whose work merged but never closed are tracker drift, and premature-close is the close-audit's job to catch, not this checkbox's.

**If the "No manual caveats?" check fails: close the PR and report the blocker instead** — in whatever form the repo playbook names (blocker report, issue, mission report); an issue on the repo if it names none. A PR that punts work back is worse than no PR. Reroute around obstacles — if the UI is the only path, use the API; if the API is missing, script it.

---

## Lead Self-Assessment Loop

After a worker reports done, do not immediately accept. Press harder.

**Iteration protocol:**

1. Ask: **"What would you improve? How can you go the extra mile?"**
2. Require **actions, not claims** — "I'd add tests" → demand they write them now. "I'd verify it renders" → demand a screenshot.
3. When improvement is done, ask again.
4. Stop after ~3 iterations if returns are marginal. After 10 with persistent gaps → respawn with stricter instructions.

**Rules:**

- **Never accept rhetoric.** "I'm confident this is solid" is not evidence — demand it.
- **Verify independently.** Run the tests yourself. Open the PR URL. Load the live site.
- **Track the diff between iterations.** No file changes = worker is stalling → push harder.

**Rotation questions** (vary to avoid formulaic answers):

- "What would a senior engineer reject in code review?"
- "Run the full test suite now and paste the output."
- "Screenshot the affected page. Does it match the design system?"
- "What did you punt on? Re-read the task and list every deliverable."
- "If this gets rejected, what's the most likely reason? Fix it preemptively."
