# Implementation Plan: issue-to-prd nonce-keyed outcome markers

**Branch**: `3277-issue-to-prd-nonce-marker` | **Date**: 2026-09-05 | **Spec**: `spec.md`
**Input**: `/specs/3277-issue-to-prd-nonce-marker/spec.md`

## Summary

Migrate the two `issue-to-prd` terminal-path outcome markers to the harness's accepted
variable-nonce grammar and add an AC-3 dedup guard, both as prose edits to two `CONTEXT.md`
files. No code, no tests, no new dependencies — this is a documentation-only skill-prose change.

## Technical Context

- **Language/Version**: N/A — Markdown prose (skill instructions read by an operator LLM)
- **Primary Dependencies**: None
- **Storage**: N/A
- **Testing**: None (no automated suite in this repo). Verification is grep-based; see
  `quickstart.md`. Real behavioral verification requires a post-merge skills sync (out of scope).
- **Target Platform**: N/A
- **Project Type**: skill-prose (not library/cli/web-service)
- **Performance Goals**: N/A
- **Constraints**: Functional diff = exactly two files (see below). No literal nonce. Status word
  unchanged. No retry logic added or removed.
- **Scale/Scope**: 2 files, ~2 lines changed + one new guard section (~15–20 lines) in one of them.

## Constitution Check

No `.specify/memory/constitution.md` exists in this repo (Spec-Kit was bootstrapped for this
feature only, per the scaffolding-removal decision below) — no project constitution to gate
against. No violations to track.

## Project Structure

```text
specs/3277-issue-to-prd-nonce-marker/
├── plan.md         # this file — working artifact, does not ship
├── research.md     # Phase 0 — working artifact, does not ship
├── quickstart.md   # Phase 1 — grep verification steps, working artifact, does not ship
└── tasks.md        # Phase 2 — working artifact, does not ship
```

`data-model.md` and `contracts/` are skipped: no data entities, no external interface — this is an
internal-only prose edit (per Rule: "Skip contracts/ for internal-only projects").

**Structure Decision**: Functional changes land only in
`skills/ops/issue-to-prd/stages/00-automation-guard/CONTEXT.md` and
`skills/ops/issue-to-prd/stages/06-ask-or-structure/CONTEXT.md`. Every other file created while
planning (`.specify/`, `.claude/commands/speckit.*.md`, this `specs/3277-*/` directory) is
scaffolding for doing the work, not the deliverable, and is deleted in the final task before the
PR — its content is pasted into the PR body instead. This keeps the shipped diff at exactly the
two files the issue's pre-merge checklist requires.

## Complexity Tracking

*No Constitution Check violations — table intentionally omitted.*
