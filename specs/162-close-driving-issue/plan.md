# Implementation Plan: Close Driving Issues and Decompose Remainders

**Branch**: `162-close-driving-issue` | **Date**: 2026-09-07 | **Spec**: `specs/162-close-driving-issue/spec.md`

## Summary

Use one close-and-decompose contract: `review-pr` enforces finish-or-follow-up, while
`create-compelling-prs` closes one driving issue and shares the same remainder template.

## Technical Context

| Field | Decision |
| --- | --- |
| Language | Markdown agent instructions; shell-backed corpus checks |
| Dependencies | GitHub closing-keyword semantics, `gh` CLI, `rg`, repository test entry points |
| Testing | Targeted `rg` contract checks, markdown lint, `.github/workflows/tests.yml` suite |
| Platform | Agent runtimes installing this skill repository |
| Constraints | Preserve calibrated review confidence; allow `Refs` only for clearly related issues |
| Scope | Two skill surfaces, one shared template, regression checks, one live review receipt |

## Constitution Check

- Pre-design: PASS. The constitution contains placeholders, not enforceable project gates.
- Post-design: PASS. The design follows existing `shared/` conventions, adds deterministic checks,
  and introduces no security, persistence, or architecture exception.

## Design

1. Add `skills/shared/follow-up-issue-template.md` with canonical fields, copy, and label rules.
2. Make `review-pr` retain `Closes`, require finish-or-follow-up, and flag driving-issue `Refs`.
3. Make `create-compelling-prs` close one driving issue and reserve `Refs` for related-only issues.
4. Register a corpus regression script so obsolete guidance and contract drift fail CI.

## Project Structure

```text
skills/shared/follow-up-issue-template.md
skills/ops/review-pr/stages/01-cohesive-review/CONTEXT.md
skills/product/create-compelling-prs/SKILL.md
skills/ops/review-pr/tests/driving-issue-contract.test.sh
.github/workflows/tests.yml
specs/162-close-driving-issue/{plan,research,data-model,quickstart,tasks}.md
```

**Contracts**: no `specs/.../contracts/` artifact; the externally consumed interface is the
canonical runtime contract at `skills/shared/follow-up-issue-template.md`.

## Verification and Delivery Boundaries

- Local: focused contract test, markdown lint, and all repository test entry points.
- Live: review one real partial-delivery PR and link the resulting finish-or-follow-up finding.
- Post-merge: record the synced gateway catalog version in the closing PR; implementation prepares
  the evidence slot but cannot produce a post-merge receipt before merge.

## Complexity Tracking

None.
