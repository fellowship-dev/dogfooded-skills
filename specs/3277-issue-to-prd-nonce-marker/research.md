# Research: issue-to-prd nonce-keyed outcome markers

No `[NEEDS CLARIFICATION]` markers in spec.md — the source issue (pylot#3277) is itself a
re-scoped PRD with cited evidence for every decision below, so no open research questions remain.

## Decision: accepted marker grammar

- **Decision**: The variable form `[pylot:$PYLOT_OUTCOME_NONCE] outcome="<phrase>" status=success`
  (never a literal nonce value).
- **Rationale**: Confirmed directly against `fellowship-dev/pylot` `scripts/operator.sh` — the
  nonce-authenticated marker is the only form `extract_outcome_marker()` accepts; a bare
  (non-nonce) form is silently rejected. Verified by reading the emit sites and the extractor in
  that file during pre-flight, not taken on the issue's word alone.
- **Alternatives considered**: Hardcoding a sample nonce (rejected — explicitly forbidden in the
  issue; a constant can never match a live per-mission nonce and would teach operators a value that
  always fails). Leaving the status word alone entirely and only changing wording (rejected — the
  regression is the marker format, not the status word, which the issue confirms is already
  correct at both sites).

## Decision: AC-3 dedup guard is prose, not code

- **Decision**: Add a documented three-condition check to `06-ask-or-structure/CONTEXT.md`,
  written in that file's existing imperative/table voice, not a script.
- **Rationale**: Every other guard in this skill (`00-automation-guard`, `07-publish`'s
  precondition, `05b-prototype-gate`'s § P) is a manual `gh`-call procedure described in prose, not
  executable code — the skill has no code, only CONTEXT.md instructions an operator follows.
  Matching that keeps the skill internally consistent.
- **Alternatives considered**: A shell script under a new `scripts/` directory (rejected — no such
  precedent in this skill, and out of scope per the two-file fence).

## Decision: Spec-Kit scaffolding does not ship

- **Decision**: `.specify/`, `.claude/commands/speckit.*.md`, and `specs/3277-*/` are working
  artifacts only. The final implementation task deletes them from the branch; their substance
  (plan/spec/tasks essentials) is pasted into the PR body instead of shipped as files.
- **Rationale**: This repo has no existing Spec-Kit adoption on `main`, and adopting it is not this
  issue's deliverable (one issue = one deliverable). Shipping it would make the "exactly two files"
  pre-merge check fail.
- **Alternatives considered**: Leave the scaffolding in a separate commit for a follow-up PR
  (rejected — no such follow-up was requested, and unshipped tooling sitting on a merged branch is
  clutter with no owner).

## Non-decisions (explicitly out of scope, from spec.md)

- The other 12 skills teaching the same bare marker form.
- Retry/requeue/dispatch-layer logic.
- Question content, one-comment rule, `open-questions` label semantics.
