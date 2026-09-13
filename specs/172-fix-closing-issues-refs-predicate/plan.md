# Implementation Plan: Fix closingIssuesReferences Repo Predicate

**Branch**: `172-fix-closing-issues-refs-predicate` | **Date**: 2026-09-11 | **Spec**: `./spec.md`
**Input**: `/specs/172-fix-closing-issues-refs-predicate/spec.md`

## Summary

Replace the `.repository.nameWithOwner` jq lookup — a field the real `gh pr view --json
closingIssuesReferences` payload does not contain — with
`.repository.owner.login + "/" + .repository.name`, byte-identical at both consumer sites
(`pr-postcondition.sh`'s Step 8 postcondition and `SKILL.md`'s Step 0 resume/dedup gate). Delete
the test suite's Python `jq` reimplementation stub so real `jq` executes the shipped predicate
string against a real-shaped fixture, closing the blind spot that let this defect ship green.

## Technical Context

- **Language/Version**: POSIX sh (deployed predicate) + jq 1.7
- **Primary Dependencies**: `jq` (already required), `gh` (stubbed in tests, never called live)
- **Storage**: N/A — pure predicate over an in-memory JSON payload
- **Testing**: `bash skills/ops/speckit-runner/tests/pr-postcondition.test.sh`, real `jq`, stubbed `gh`
- **Target Platform**: speckit-runner (bash procedure invoked by the runner skill)
- **Project Type**: operational skill (shell script + shell test harness), no app/service layer
- **Performance Goals**: N/A — one jq call per postcondition/resume check, unchanged from today
- **Constraints**: predicate byte-identical at both sites; fail closed (missing `repository` key or empty refs array → rejection, never a jq error); no new runtime dependency
- **Scale/Scope**: 3 files (scope-fenced by the issue): `shared/pr-postcondition.sh`, `SKILL.md`, `tests/pr-postcondition.test.sh` (+ optional fixture)

## Constitution Check

Project constitution is unfilled boilerplate (no repo-specific gates defined) — falling back to
the issue's own documented bar instead:

- [x] Must-fail-before check: revert only the predicate to `.repository.nameWithOwner`, suite must fail; restore the fix (issue's primary acceptance evidence)
- [x] No stub reimplementation: delete the Python `jq` stub so the real shell predicate string executes, not a hand-mirrored model of it
- [x] Fail closed: missing `repository` key / empty refs array → rejection, not a jq execution error
- [x] Byte-identical predicate at both call sites, diffed before commit

No violations requiring justification; Complexity Tracking table omitted.

## Project Structure

```text
specs/172-fix-closing-issues-refs-predicate/
├── plan.md         # this file
├── research.md     # Phase 0 — real payload shape, jq null-propagation fail-closed proof
└── quickstart.md   # Phase 1 — manual must-fail-before walkthrough
```

No `data-model.md` (no persistent entities beyond the one documented JSON shape, captured in
spec.md's Key Entities) and no `contracts/` (no external API surface — `gh pr view --json
closingIssuesReferences` is an existing GitHub CLI contract already consumed by the helper).

**Structure Decision**: in-place edits to the 3 scope-fenced files only; no new files or
scaffolding beyond the two docs above.

## Complexity Tracking

*No violations — table omitted.*
