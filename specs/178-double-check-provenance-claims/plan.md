# Implementation Plan: Reconcile Diff-Provenance Claims in double-check

**Branch**: `178-double-check-provenance-claims` | **Date**: 2026-09-12 | **Spec**: [spec.md](./spec.md)
**Input**: `/specs/178-double-check-provenance-claims/spec.md`

## Summary

Stage 02's claim-reconciliation gate has no taxonomy entry for diff-provenance/range claims, so
they're certified by silence. Add a bounded provenance/range category to the existing extraction
and disposition lists in `skills/ops/double-check/stages/02-review/CONTEXT.md` step 2, naming the
evidence source (range diff, cited SHA → stage 01's recorded setup head SHA) and pinning the
disposition to `unbacked` (never `unknown`) when the range contradicts the claim or is undiffable.

## Technical Context

- **Language/Version**: N/A — prose edit to an agent-facing Markdown context file
- **Primary Dependencies**: none; reuses stage 01's existing `## Local Checkout` / `Setup head SHA`
  handoff fields and `git diff --stat`
- **Storage**: N/A
- **Testing**: manual replay against the recorded live-instance sentence (see spec SC-001..SC-003);
  no automated test entry point — issue scope explicitly forbids adding one
- **Target Platform**: `double-check` stage 02 review step (agent-executed protocol prose)
- **Project Type**: single-file documentation/prose edit (internal tooling)
- **Performance Goals**: N/A
- **Constraints**: exactly one file touched; additive hunks only; text stays PROTOCOL (no org,
  repo, issue-number, or environment references per repo placement doctrine)
- **Scale/Scope**: ~5-8 line addition split across one extraction sentence + one disposition bullet

## Constitution Check

No project-specific constitution is authored in this repo (template is unfilled; `.specify/` is
bootstrap-only tooling, never committed — see prior review finding removing vendored scaffolding
from a sibling PR). No gates apply beyond the issue's own scope fence, which this plan follows:
one file, additive, no new mechanism, no test entry point.

## Project Structure

```text
specs/178-double-check-provenance-claims/
├── plan.md         # this file
├── research.md     # Phase 0
├── data-model.md   # Phase 1
├── quickstart.md   # Phase 1 — manual replay steps
└── tasks.md         # Phase 2
```

**Structure Decision**: No `src/`/`tests/` layout — the only production artifact is
`skills/ops/double-check/stages/02-review/CONTEXT.md`. `contracts/` skipped: no external interface,
API, or CLI schema is introduced (internal-only prose edit per plan rules).

## Complexity Tracking

*No Constitution Check violations — table intentionally empty.*
