# Tasks: Rollcall P0/P1 Verification

## Task 1: Update Section 0 header in daily-report skill

In `skills/ops/daily-report/SKILL.md`:
- Update the section header to: `### Section 0: Production Health (MANDATORY — P0/P1 verification required)`
- This signals that verification is not optional

## Task 2: Add P0/P1 Verification Protocol subsection

After the Section 0 format examples, add a new `#### P0/P1 Verification Protocol`
subsection with:
- Trigger conditions (P0/P1 labels OR keywords: 500, down, broken, production)
- Decision tree (liveness check → evidence check → ask filer)
- Curl command template
- Output format table (verified 🔴, unverified ⚠️, needs-review 🟡)
- Ask-filer comment template

## Task 3: Update Quality Rules section

Add a rule:
- "P0/P1 production claims MUST be verified with curl before promoting to briefing — see P0/P1 Verification Protocol above"

## Task 4: Commit and push
