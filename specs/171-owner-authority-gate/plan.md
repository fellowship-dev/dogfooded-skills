# Implementation Plan: Owner-Authority Gate Narrows `security` Parking

**Branch**: `171-owner-authority-gate` | **Date**: 2026-09-11 | **Spec**: [spec.md](./spec.md)
**Input**: `/specs/171-owner-authority-gate/spec.md`

## Summary

Narrow `cto-review`'s owner gate to fire only on a human-applied `waiting-on-owner` label or a new
closed five-class owner-authority classifier match; `security` becomes classification metadata
everywhere it is described. The classifier lives in `02-review` (holds the full diff) and writes
four handoff fields that `03-synthesize-act`'s deterministic gate consumes without re-judging.
Every automated park posts one closed decision line and a named answerer.

## Technical Context

- **Language/Version**: N/A for the edit (agent-instruction Markdown); Python 3 for the new test,
  matching the repo's stdlib-only test style
- **Primary Dependencies**: none — stdlib only (`json`, `pathlib`, `re`), mirroring
  `trash-truck/evals/test_retirement_contract.py`
- **Storage**: N/A
- **Testing**: static contract test over fixed JSON fixtures, no live `gh` calls; registered in
  `.github/workflows/tests.yml`'s explicit `tests=` list; `markdownlint` clean
- **Target Platform**: GitHub Actions `ubuntu-latest` (CI) + the agent runtime reading these
  skills during a live `cto-review`/`review-pr` mission
- **Project Type**: agent-instruction skill content (no running service)
- **Constraints**: scope fence is exactly 9 files (below); `security`'s detector condition stays
  byte-identical (AC1); the five-class taxonomy text is verbatim, not paraphrased (TR3)
- **Scale/Scope**: 7 edited, 2 new test files, 1 CI registry edit

## Constitution Check

`.specify/memory/constitution.md` is the unfilled generic template — no repo-specific gate exists
there. The operative doctrine is the issue's own **Repo doctrine** clause (protocol-only wording,
no org names) and `cto-review/SKILL.md` Hard Rules 2 & 5 (02 judges, 03 stays deterministic
shell) — both satisfied by design: classifier in 02-review, no org-specific path added.
Re-checked post-design: still satisfied — the four fields extend the existing handoff.md contract
already shared between these two stages; no new interface introduced.

## Project Structure

Skill-content edit, no `src/`/`tests/` split. Scope fence (verified against current files):

```text
skills/ops/cto-review/stages/03-synthesize-act/CONTEXT.md   # drop security branch/rules/park template/handoff field
skills/ops/cto-review/stages/02-review/CONTEXT.md           # :64,83 wording + new classifier step + 4 handoff fields
skills/ops/cto-review/SKILL.md                               # :38,146,163,193 prose only, not the numbering drift
skills/ops/review-pr/stages/02-post/CONTEXT.md              # :77,94,105 wording only, detector untouched
skills/ops/review-pr/stages/00-context/CONTEXT.md           # :91,107 wording only, detector untouched
skills/ops/review-pr/SKILL.md                                # :155-156
skills/ops/cto-review/tests/test_owner_gate_contract.py     # new — Python, trash-truck shape
skills/ops/cto-review/tests/owner-gate-fixtures.json         # new — #3372/#3408 + 1/class + human-label fixture
.github/workflows/tests.yml                                  # register the new test path
```

**Structure Decision**: no `contracts/` dir — the classifier's output is an internal handoff
between two stages of the same skill, already the `handoff.md` contract; `data-model.md` documents
its new `## Owner Authority (#3240)` block instead of a separate schema file.

## Complexity Tracking
No constitution violations requiring justification — table omitted.
