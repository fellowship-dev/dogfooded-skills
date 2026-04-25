---
name: create-compelling-prs
description: PR quality framework — body templates (bugfix/feature/refactor/deps), S3 visual evidence upload, self-audit checklist, and lead self-assessment loop. Run before pushing a PR for review.
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

## Visual Evidence with S3

For any UI-impacting change, capture before/after screenshots and embed them.

**If `AWS_BUCKET` + `AWS_ACCESS_KEY_ID` are in env** (preferred):

```bash
# Capture screenshots (Playwright preferred, manual fallback)
# Then upload:
aws s3 cp before.png "s3://$AWS_BUCKET/evidence/${REPO}/${PR}/before.png" --acl public-read
aws s3 cp after.png  "s3://$AWS_BUCKET/evidence/${REPO}/${PR}/after.png"  --acl public-read

# Embed in PR body:
# Before: https://${AWS_BUCKET}.s3.amazonaws.com/evidence/${REPO}/${PR}/before.png
# After:  https://${AWS_BUCKET}.s3.amazonaws.com/evidence/${REPO}/${PR}/after.png
```

**Fallback — git evidence branch:**

```bash
git checkout -b "evidence/${BRANCH}-screenshots"
cp *.png specs/${ISSUE}/
git add specs/ && git commit -m "evidence: before/after screenshots"
git push origin "evidence/${BRANCH}-screenshots"
# Embed as raw GitHub URLs in the PR body, then:
git checkout -
```

**Skip** if: backend-only, CLI-only, config/infra, test-only, or capture exceeds 120s. Visual evidence is a bonus, never a gate.

---

## Self-Audit Checklist

Run this before opening or marking a PR ready for review:

- [ ] **Complete?** Does this finish every deliverable in the original task?
- [ ] **Shippable?** If merged as-is, would the task be done — no follow-up tickets created?
- [ ] **No manual caveats?** Zero "you'll need to X manually" instructions in the PR body.
- [ ] **Tests pass?** Ran them yourself right now — not trusting earlier cached output.
- [ ] **Evidence present?** Screenshots or test output embedded for every meaningful change.
- [ ] **Issue linked?** `Closes #N` in the body — or `Refs #N` if the issue has unchecked acceptance criteria (prevents premature auto-close on multi-phase work).

**If the "No manual caveats?" check fails: close the PR. File a blocker report instead.** A PR that punts work back is worse than no PR. Reroute around obstacles — if the UI is the only path, use the API; if the API is missing, script it.

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
