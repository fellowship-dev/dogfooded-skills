# Feature Specification: issue-to-prd nonce-keyed outcome markers

**Feature Branch**: `3277-issue-to-prd-nonce-marker`
**Created**: 2026-09-05
**Status**: Draft
**Input**: fellowship-dev/pylot#3277 — migrate the two issue-to-prd terminal-path outcome markers to
the nonce-keyed grammar the harness accepts, and add the ask-path dedup guard.

## User Scenarios & Testing

### User Story 1 — Questions-path run records its real outcome (P1)

An `issue-to-prd` run that batches open questions and exits is a legitimate success, not a failure.

**Acceptance** (AC-1, AC-2):
1. **Given** stage 06 takes the questions path, **When** it emits its terminal line, **Then** the
   line uses the harness's accepted nonce-keyed grammar (variable form, never a literal nonce) with
   the outcome phrase `"questions posted"` and the status word unchanged (`success`).
2. **Given** that run completes, **When** the mission is recorded, **Then** it does not increment
   `consecutive_failures` on the dispatching automation row, because the harness now parses a
   verdict from the marker instead of failing closed on an unrecognized line.

---

### User Story 2 — Guard-abort run records its real outcome (P2)

A run that aborts at stage 00 (`no-automation` / `epic` / not-open) is a correct skip, not a failure.

**Acceptance** (AC-4):
1. **Given** stage 00 aborts, **When** it emits its terminal line, **Then** the line uses the same
   nonce-keyed grammar (variable form) with the existing outcome phrase and status word unchanged.

---

### User Story 3 — A parked, unanswered issue is not re-asked (P1)

Re-running `issue-to-prd` on an issue that is already correctly parked on `open-questions` must not
post a second question comment.

**Acceptance** (AC-3):
1. **Given** the `open-questions` label is present, **and** a prior bot-authored question comment
   exists on the issue, **and** no later comment from a non-bot author exists, **When** stage 06
   runs, **Then** it posts no comment, applies no label, and exits success with a phrase naming the
   skip.
2. **Given** any one of those three conditions does not hold (label absent, no prior bot question,
   or a later non-bot comment exists), **When** stage 06 runs, **Then** normal questions/PRD routing
   applies — the dedup guard does not fire.

---

### Edge Cases

- A later comment from the bot itself (not a human/org-member reply) after the question comment
  must not count as an "answer" — the guard checks for a **non-bot** author specifically.
- The dedup guard must not change which questions get asked, their wording, the one-comment rule,
  or `open-questions` label semantics — it only prevents a redundant second pass from writing.

## Requirements

### Functional

- **FR-001**: `stages/00-automation-guard/CONTEXT.md`'s abort exit line MUST use the harness's
  nonce-keyed marker grammar (the `$PYLOT_OUTCOME_NONCE` variable, never a literal value),
  preserving its existing outcome phrase and `status=success`.
- **FR-002**: `stages/06-ask-or-structure/CONTEXT.md`'s questions-path exit line MUST use the same
  nonce-keyed marker grammar, preserving its existing `"questions posted"` phrase and
  `status=success`.
- **FR-003**: `stages/06-ask-or-structure/CONTEXT.md` MUST add a dedup guard, checked before any
  write on the questions path, that reads: `open-questions` label present AND a prior bot-authored
  question comment exists AND no later non-bot comment exists → post nothing, label nothing, exit
  success naming the skip. Detection is a manual read of labels + comment authorship/timestamps via
  the `gh` calls the skill already uses (mirrors the low-tech detection in `05b-prototype-gate`'s
  `P` section and the precondition style in `07-publish`).
- **FR-004**: Neither site's status word changes — both already read `success` and MUST stay that
  way.
- **FR-005**: No literal nonce value is ever written into skill text; the marker always references
  the variable.

### Out of Scope (explicit fence)

- The other 12 skills teaching the same bare marker form (`build-train`, `cto-review`,
  `deps-runner`, `double-check`, `flowchad-runner`, `release-train-runner`, `review-pr`,
  `security-runner`, `speckit-proc`, `speckit-runner`, `vercel-deploy`, `procedure-builder`) — a
  follow-up issue covers them.
- Retry/requeue/dispatch-layer logic — none exists today; none is added or removed here.
- Question content, the one-comment rule, and `open-questions` label semantics — unchanged.
- Any `skills/issue-to-prd/` path inside `fellowship-dev/pylot` — the skill lives only in
  `fellowship-dev/dogfooded-skills`.

### Key Entities

- **Outcome marker**: the terminal line an operator emits to report a mission verdict. Accepted
  grammar (from `fellowship-dev/pylot` `scripts/operator.sh`), reproduced here only inside a fence
  per the issue's own reporting-hazard note:
  ```
  [pylot:$PYLOT_OUTCOME_NONCE] outcome="<one-line summary>" status=<success|partial|...|...>
  ```
  The two skill sites in scope currently emit a bare, non-nonce-keyed form that the harness
  silently rejects, leaving the mission with no parsed verdict.

## Success Criteria

- **SC-001**: `grep -rn '\[pylot\] outcome=' skills/ops/issue-to-prd/` returns zero hits after the
  change.
- **SC-002**: Both marker sites match the harness's nonce-keyed grammar byte-for-byte apart from
  phrase and status word.
- **SC-003**: The diff touches exactly two files (`stages/00-automation-guard/CONTEXT.md`,
  `stages/06-ask-or-structure/CONTEXT.md`); the other 12 affected skills are untouched.
- **SC-004**: The new dedup guard states all three conditions and the no-write exit explicitly, and
  does not alter question wording, the one-comment rule, or label semantics.

## Assumptions

- The fix is inert until the next skills sync (`buildspec-skills-sync.yml` → S3 → operators); no
  in-repo test can exercise the harness's marker parser directly.
- `#3275` (a live, correctly-parked `open-questions` issue with two bot comments and no human
  answer) is the intended post-sync replay case for the dedup guard — not built or touched by this
  spec.
- Implementation (editing the two CONTEXT.md files) is a later phase; this spec captures
  requirements only.
