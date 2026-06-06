# Stage 05: Test Plan

## Inputs
- `stages/01-read-issue/output/handoff.md`
- `stages/02-context-completeness/output/handoff.md`
- `stages/03-assess-clarity/output/handoff.md`

## Principle
Tests must be done on the PR, not deferred. If testing requires prod access, flag it explicitly.

## Task
Produce a test plan with pre-merge verification steps and tooling prerequisites.

## Steps
1. Read prior handoffs (01, 02, 03)
2. Identify what needs testing (API behavior, UI flow, integration, data migration, etc.)
3. Assess current test infrastructure:
   - Does the repo have a test suite? What framework?
   - Are there seeds/fixtures for the relevant data?
   - Is there a dev server or mock server available?
   - Can the feature be tested in isolation or does it need external services?
4. Identify testing prerequisites — things to build BEFORE the PR can be verified:
   - Mock servers (for external APIs, webhooks)
   - Test fixtures/seeds (for DB-dependent features)
   - New test suites (if the area has no existing coverage)
   - Dev environment setup (replicate prod behavior locally)
   - Visual evidence tooling (screenshots for UI changes)
5. Write the pre-merge verification checklist

## Output: handoff.md
```markdown
# Stage 05: Test Plan

## Test Strategy
[What to test and why]

## Prerequisites (build FIRST)
- [ ] ...

## Pre-merge Verification
- [ ] ...

## Post-merge Verification (if any)
- [ ] [flagged explicitly — requires prod access]

## Open questions
- [Testing prerequisite that needs human decision]
```

## Success criteria
- Every requirement from stage 03 has at least one test case
- Prerequisites listed are concrete and actionable
- Post-merge items are explicitly flagged (not hidden in the pre-merge list)
