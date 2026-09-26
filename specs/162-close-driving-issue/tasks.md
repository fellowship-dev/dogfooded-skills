# Tasks: Close Driving Issues and Decompose Remainders

**Input**: `/workspace/specs/162-close-driving-issue/` design artifacts

## Phase 1: Setup

- [X] T001 Record the current prohibited-guidance and shared-contract baseline in `/workspace/specs/162-close-driving-issue/quickstart.md`
- [X] T002 [P] Create the focused executable test scaffold at `/workspace/skills/ops/review-pr/tests/driving-issue-contract.test.sh`

## Phase 2: Foundational Contract

- [X] T003 Define the canonical title, opening line, Origin, Remaining acceptance criteria, Out of scope, verbatim-copy, linkage, `ready-to-work`, and inherited-priority rules in `/workspace/skills/shared/follow-up-issue-template.md`
- [X] T004 Register `/workspace/skills/ops/review-pr/tests/driving-issue-contract.test.sh` in the explicit test manifest at `/workspace/.github/workflows/tests.yml`
- [X] T005 Implement assertions for the canonical template fields and both consumer references in `/workspace/skills/ops/review-pr/tests/driving-issue-contract.test.sh`

## Phase 3: User Story 1 — Review Partial Delivery (P1) — MVP

**Independent test**: Feed the review rubric a `Refs`-only driving issue and a `Closes` issue with one unmet named criterion; each produces a calibrated Bug, and the latter retains `Closes` while requiring completion or a conforming linked follow-up.

- [X] T006 [US1] Replace the recommendation to downgrade partial delivery to `Refs` with finish-or-follow-up behavior in `/workspace/skills/ops/review-pr/stages/01-cohesive-review/CONTEXT.md`
- [X] T007 [US1] Add the `Refs`-only driving-issue Bug rule, related-only `Refs` exception, named-criterion wording, and shared-template reference in `/workspace/skills/ops/review-pr/stages/01-cohesive-review/CONTEXT.md`
- [X] T008 [US1] Add reviewer-behavior and obsolete-guidance regression assertions in `/workspace/skills/ops/review-pr/tests/driving-issue-contract.test.sh`

## Phase 4: User Story 2 — Author Decomposed Work (P2)

**Independent test**: Self-audit a deliberately multi-PR change; the current PR closes exactly one driving issue and links a conforming follow-up for its bounded remainder.

- [X] T009 [US2] Rewrite the completion, shippability, and issue-link self-audit rules around one closing driving issue and linked decomposition in `/workspace/skills/product/create-compelling-prs/SKILL.md`
- [X] T010 [US2] Explicitly reserve `Refs` for clearly identified related-only issues and reference the canonical follow-up template in `/workspace/skills/product/create-compelling-prs/SKILL.md`
- [X] T011 [US2] Add author-guidance and exactly-one-driving-issue regression assertions in `/workspace/skills/ops/review-pr/tests/driving-issue-contract.test.sh`

## Phase 5: User Story 3 — File Consistent Follow-ups (P3)

**Independent test**: Create a follow-up from either consumer; its title and body begin `Follow-up of #N`, criteria are verbatim, required sections exist, and labels are `ready-to-work` plus N's priority.

- [X] T012 [US3] Add a copy-ready issue-body example and label application instructions to `/workspace/skills/shared/follow-up-issue-template.md`
- [X] T013 [US3] Verify both consumer paths resolve the same template and all required fields with fixture cases in `/workspace/skills/ops/review-pr/tests/driving-issue-contract.test.sh`

## Phase 6: Polish and Evidence

- [X] T014 Run `/workspace/skills/ops/review-pr/tests/driving-issue-contract.test.sh` and fix every failure in `/workspace/skills/ops/review-pr/tests/driving-issue-contract.test.sh`
- [X] T015 [P] Run `/workspace/.claude/check-md-lint.sh` and correct affected Markdown in `/workspace/skills/shared/follow-up-issue-template.md`, `/workspace/skills/ops/review-pr/stages/01-cohesive-review/CONTEXT.md`, and `/workspace/skills/product/create-compelling-prs/SKILL.md`
- [X] T016 Run every repository test entry point declared in `/workspace/.github/workflows/tests.yml` and fix regressions in the files changed by this feature
- [ ] T017 Exercise a real partial-delivery PR review and record the finish-or-follow-up finding URL in `/workspace/specs/162-close-driving-issue/quickstart.md`
- [ ] T018 After merge and gateway synchronization, record the gateway catalog version in the closing PR referenced by `/workspace/specs/162-close-driving-issue/quickstart.md`
- [X] T019 [US1] Make Stage 00 extract closing and `Refs` links with complete source-line context in
  `/workspace/skills/ops/review-pr/scripts/extract-issue-links.sh` and document the handoff contract
  in `/workspace/skills/ops/review-pr/stages/00-context/CONTEXT.md`
- [X] T020 [US1] Exercise the Stage 00 producer contract with a `Refs`-only driving issue and an
  explicitly related `Refs` link using
  `/workspace/skills/ops/review-pr/tests/fixtures/refs-driving-pr-body.md`
- [X] T021 Remove unrelated Speckit bootstrap commands, scripts, and templates from this branch
- [X] T022 Verify whitespace over the merge-base range rather than the worktree-only diff

## Dependencies

- T001 and T002 can start together; T003 → T005; T004 depends on T002.
- T003 → T006 → T007 → T008 (US1/MVP).
- T003 → T009 → T010 → T011 (US2); US1 and US2 edit different files until their test tasks.
- T003 → T012 → T013 (US3); T012 waits for T003 because both edit the shared template.
- T008, T011, and T013 are sequential because they edit the same test file.
- T005, T008, T011, T013 → T014 → T016; T006, T009, T012 → T015.
- T014–T016 → T017; T018 is post-merge and depends on the synchronized catalog receipt.

## Parallel Execution Examples

- After T005, implement T006–T007 (US1) and T009–T010 (US2) in parallel because they touch separate consumer files.
- After T003, T004 can proceed independently while consumer guidance is updated.
- T015 can run alongside focused test refinement before the final full-suite T016.

## Implementation Strategy

- MVP: T001–T008 delivers reviewer enforcement for US1.
- Increment 2: T009–T011 makes author decomposition consistent.
- Increment 3: T012–T013 proves both paths share the same follow-up contract.
- Delivery: T014–T018 supplies local, live-review, and post-merge catalog evidence.
