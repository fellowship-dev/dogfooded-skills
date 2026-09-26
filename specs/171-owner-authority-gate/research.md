# Phase 0 Research: Owner-Authority Gate Narrows `security` Parking

No `[NEEDS CLARIFICATION]` markers exist in spec.md — the issue's own Open Questions section
already closed both judgement calls. The research below records the design decisions the issue's
Technical Requirements already made, so plan/tasks don't re-derive them.

## Decision: mirror the five-class taxonomy verbatim from `fellowship-dev/pylot` PR #3454

- **Rationale**: TR3 requires the taxonomy be reproduced word-for-word so the two copies (this
  repo's cto-review, and pylot's `rework-on-needs-work` automation) cannot drift. The exact text
  is quoted in the issue body itself — no need to fetch the pylot PR to get it right.
- **Alternatives considered**: a taxonomy tailored to this repo's own concerns — rejected; the
  issue is explicit that this is a cross-repo protocol invariant, not a per-repo customization.

## Decision: classifier lives in `02-review`, gate logic stays in `03-synthesize-act`

- **Rationale**: `02-review` already holds the full diff in isolated context and is the skill's
  judgement stage (`cto-review/SKILL.md` Hard Rules 2 & 5); `03-synthesize-act` runs inline with no
  diff in hand. TR2 states this split explicitly.
- **Alternatives considered**: classifying directly in `03-synthesize-act` against the label
  snapshot — rejected; that stage never re-fetches the diff, so it cannot produce quotable runtime
  evidence (TR4), only re-read a label.

## Decision: the gate is an OR of two independent, non-interacting triggers

- **Rationale**: TR1 requires preserving a human-applied `waiting-on-owner` as an unconditional
  hard-block (AC6) while removing `security` from the trigger set entirely. Two independent OR
  branches keep the human trigger un-couplable from the classifier's verdict.
- **Alternatives considered**: making the label trigger conditional on the classifier agreeing —
  explicitly forbidden by the issue's Do-NOT list as "the one real safety regression available in
  this change."

## Decision: contract test is Python, static-fixture, `trash-truck`-shaped

- **Rationale**: the issue's scope fence names `test_owner_gate_contract.py` (not `.test.sh`); the
  `trash-truck` test already demonstrates this repo's pattern for asserting markdown-content
  invariants (regex/text checks against `SKILL.md`/`CONTEXT.md`) plus fixture-driven logic replay
  in plain Python — exactly what's needed to assert both "no site describes `security` as a hold"
  and "replaying PR #3372/#3408 never applies `waiting-on-owner`."
- **Alternatives considered**: the `double-check` bash-variant shape — rejected; it drives real
  shell helpers under test, but the gate's actual logic here is two boolean conditions best
  expressed and asserted directly in Python against the fixtures, not re-implemented in bash for
  the test to shell out to.
