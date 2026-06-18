# Stage 06: Ask or Structure

## Inputs
- All prior handoffs: 02, 03, 04, 05

## Task
Decision point: synthesize all findings into either a question list (exit) or a PRD draft.

## Decision logic
ANY of the following triggers questions:
- Stage 02 verdict = `needs-context`
- Stage 03 verdict = `needs-questions`
- Stage 04 has failure modes requiring human clarification to guardrail
- Stage 05 has open questions blocking the test plan

**If questions → exit early:**
1. Batch ALL gaps into a single numbered list Q1-Qn (one comment only — never two)
2. Post comment: `gh issue comment {number} --repo {repo} --body "..."`
3. Add label: `gh issue edit {number} --repo {repo} --add-label "open-questions"`
5. STOP — do not proceed to stage 07

**If all clear → PRD draft:**
1. Use `shared/prd-template.md` as the skeleton
2. Fill in all sections from prior handoffs
3. Weave in stage 02 context additions to relevant sections
4. Add stage 04 guardrails as "Implementation Constraints" section
5. Add stage 05 test plan as "Testing Strategy" section
6. Write draft to `stages/06-ask-or-structure/output/handoff.md`

## Output (questions path): handoff.md
```
Verdict: needs-questions
Questions posted: Q1 ... Qn
```

## Output (PRD path): handoff.md
Full PRD draft (see `shared/prd-template.md` for structure).

## Success criteria
- Questions: single comment, `open-questions` label applied, exit emitted, stage stops
- PRD: all sections populated, no unresolved TBD/TODO
