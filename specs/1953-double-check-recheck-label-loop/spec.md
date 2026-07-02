# Feature Specification: double-check re-check closes the rework loop via labels

**Feature Branch**: `1953-double-check-recheck-label-loop`
**Created**: 2026-07-02
**Status**: Draft
**Issue**: fellowship-dev/pylot#1953

## Context

### Problem (from issue)

The double-check re-check path ends in prose, not labels — the rework loop never closes
without a human.

Evidence (overnight 2026-07-02): PR fellowship-dev/pylot#1940 re-check **PASSED** at ~02:4xZ
and ended with the prose instruction "Re-trigger test-in-staging". No automation consumes prose.
The PR sat dead until a human manually removed `needs-work` and re-toggled `double-checked`.

### Pylot-side compatibility (pre-verified — no code change in this repo)

`gateway/modules/automations/event-reactions.mts` already supports the re-toggle pattern:

- **Lines 386–398**: dedup guard is scoped to `envelope.type === "issues"` only; `pull_request`
  events are outside its scope and always reach rule matching.
- **`matchRule` (lines 119–194)**: evaluates each `pull_request.labeled` event purely on
  `trigger.match.label` with no memory of prior evaluations — re-adding `double-checked`
  after removing it matches identically to the first add.
- **SQS ingress** (`gateway/modules/connectors/ingress.mts:55`): `MessageDeduplicationId` uses
  `Date.now()`, so remove and re-add each get a unique ID and both reach the processor.

**Conclusion**: no pylot-side code change is needed. All work is in
`fellowship-dev/dogfooded-skills` at `skills/ops/double-check/`.

### Current stage 04-post behavior

Stage 04-post currently:
1. Posts the curated review comment
2. Applies the `double-checked` label (triggers `cto-review-on-double-checked` event rule)
3. Writes a local report file
4. Emits the `[pylot] outcome=...` marker

Missing: no re-check context detection, no label manipulation on PASS/FAIL re-check paths.

### Re-check context detection

Stage 01-setup already fetches PR labels (via `gh pr view --json labels`) and records them in
the handoff under `## PR / Labels`. Stage 04-post can read these to detect re-check context:
`needs-work` label present at invocation time = re-check run.

---

## User Scenarios & Testing

### User Story 1 — Re-check PASS closes the rework loop (P1)

A developer fixes rework items, re-triggers double-check on a PR that has `needs-work`. The
re-check passes. Without any human touching labels, the next pipeline stage (cto-review)
fires automatically.

**Acceptance**:
1. **Given** a PR with `needs-work` + `double-checked` labels, **When** stage 04-post runs with
   verdict=ready (re-check PASS), **Then** `needs-work` is removed from the PR, `double-checked`
   is removed and immediately re-added, and the `pull_request.labeled` event fires a new
   cto-review dispatch.
2. **Given** the re-toggle fired, **When** the pylot event processor receives the `double-checked`
   labeled event, **Then** `reactRules` matches the `cto-review-on-double-checked` rule with no
   dedup suppression (verified: `matchRule` has no memory of prior evaluations).

---

### User Story 2 — Re-check FAIL posts structured verdict, keeps needs-work (P2)

A developer re-triggers double-check after rework but the re-check fails (issues remain). The
PR keeps `needs-work`. A structured verdict comment is posted (not prose) so the developer
and any downstream automation can distinguish a REWORK verdict from a mission failure.

**Acceptance**:
1. **Given** a PR with `needs-work`, **When** stage 04-post runs with verdict=needs-work
   (re-check FAIL), **Then** `needs-work` remains on the PR (not re-added, just left in place)
   and a structured verdict comment is posted.
2. **Given** the structured verdict comment, **Then** it contains a machine-readable marker
   (`<!-- pylot:recheck-fail -->`) and the specific remaining items from the review handoff —
   a human or future automation can distinguish it from a generic "review failed" message.
3. **Given** re-check FAIL, **Then** stage 04-post does NOT re-toggle `double-checked` (the
   `cto-review-on-double-checked` automation must NOT fire when work still needs doing).

---

### Edge Cases

- **`needs-work` absent but `double-checked` already present** (first-check re-run, not a rework
  cycle): treat as normal first-check; apply `double-checked` label; no removal of needs-work
  (there is none to remove).
- **Re-check PASS, `double-checked` not on PR** (race — label was manually removed): just add
  `double-checked`; no prior label to remove in the re-toggle.
- **Label API errors on remove/re-add**: log and emit `status=failed`; do not silently skip.

---

## Requirements

### Functional

- **FR-001**: Stage 04-post MUST detect re-check context by reading the `Labels` field from
  the stage-01 handoff and checking for `needs-work`. (Stage 01-setup already captures labels —
  no change to stage 01 needed.)
- **FR-002**: On re-check PASS (verdict=ready AND needs-work in labels):
  - Remove `needs-work` from PR (`gh pr edit --remove-label "needs-work"`)
  - Remove `double-checked` if present (`gh pr edit --remove-label "double-checked"`)
  - Re-add `double-checked` (`gh pr edit --add-label "double-checked"`)
  - Emit: `[pylot] outcome="double-checked re-check PASS {repo}#{pr} — loop closed, cto-review re-fired" status=success`
- **FR-003**: On re-check FAIL (verdict=needs-work AND needs-work in labels):
  - Leave `needs-work` in place (do not remove or re-add)
  - Post a structured verdict comment with `<!-- pylot:recheck-fail -->` marker, the specific
    remaining items from the stage-02 handoff's Fix List / Verdict section, and the re-check
    verdict (`needs more work — items: [...]`).
  - Do NOT re-toggle `double-checked` (cto-review must not fire).
  - Emit: `[pylot] outcome="double-checked re-check FAIL {repo}#{pr} — needs-work retained" status=success`
- **FR-004**: On first-check (needs-work NOT in labels), behavior is unchanged from current:
  - Apply `double-checked` label regardless of verdict (cto-review handles the verdict).
- **FR-005**: The pylot automation layer re-fires cto-review on the re-add of `double-checked`
  with no additional code change (verified against `event-reactions.mts`).

### Structured verdict comment format (re-check FAIL)

```
<!-- pylot:recheck-fail pr={PR} repo={REPO} -->
## Re-check Result: Still Needs Work

**PR:** {REPO}#{PR} — {PR_TITLE}
**Re-check verdict:** needs more work

### Remaining items
{ordered list from stage-02 handoff Fix List / Verdict — specific, not prose}

### What to do
1. Address the items above.
2. Push your fixes.
3. Remove and re-add the `double-checked` label to re-trigger this re-check.
```

### Key Files

**All changes are in `fellowship-dev/dogfooded-skills`:**
- `skills/ops/double-check/stages/04-post/CONTEXT.md` — add re-check detection + label
  manipulation logic (PASS: remove needs-work + re-toggle double-checked; FAIL: structured
  comment, no re-toggle)
- `skills/ops/double-check/SKILL.md` — update exit path docs to reflect re-check outcomes
- `skills/ops/double-check/shared/review-comment-template.md` — optionally add re-check FAIL
  template section

**No changes in `fellowship-dev/pylot`** (automation compatibility pre-verified).

---

## Success Criteria

- **SC-001**: A full rework cycle — double-check FAIL → rework → re-check PASS → next pipeline
  stage fires — completes with **zero human label pokes** on a real PR.
- **SC-002**: Re-check PASS observably removes `needs-work` and re-adds `double-checked` on
  a real PR (cite mission log as evidence; contrast with pylot#1940 manual intervention).
- **SC-003**: Re-check FAIL leaves `needs-work` in place and posts a structured verdict comment
  containing `<!-- pylot:recheck-fail -->` and the remaining item list.
- **SC-004**: The dogfooded-skills PR passes the double-check skill's own review (if it applies).

## Assumptions

- Stage 01-setup already captures PR labels in the handoff — no change to stage 01 is needed.
- The `needs-work` label exists in the target org's label set (it's already in use).
- The dev worker has push access to `fellowship-dev/dogfooded-skills` (same GitHub App token).
- Re-check context = `needs-work` in PR labels at the time stage 04-post runs. This is the
  signal that a previous cycle left the PR in the "rework needed" state.
