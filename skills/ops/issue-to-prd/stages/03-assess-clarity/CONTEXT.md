# Stage 03: Assess Clarity

## Inputs
- `$WORK/01-read-issue.md`
- `$WORK/02-context-completeness.md`
- `stages/03-assess-clarity/references/gap-checklist.md`

## Task
Check the issue against the 8-section gap checklist. Produce a gap list and verdict.

## Steps
1. Read stages 01 and 02 handoffs
2. Read `references/gap-checklist.md` for the 8-section checklist
3. For each of the 5 required sections, assess: covered (even implicitly), partial, or missing
4. For optional sections, note presence or absence
5. Determine verdict:
   - `clear`: all 5 required sections covered (even implicitly)
   - `needs-questions`: any required section missing or ambiguous

## Output: `$WORK/03-assess-clarity.md`
```markdown
# Stage 03: Clarity Assessment

## Verdict
`clear` | `needs-questions`

## Gap Analysis
| Section | Required | Status | Gap description |
|---------|----------|--------|-----------------|
| Problem Statement | Yes | covered/partial/missing | ... |
| User Stories | Yes | ... | ... |
| Success Metrics | Yes | ... | ... |
| Scope (in + out) | Yes | ... | ... |
| Technical Constraints | Yes | ... | ... |
| Mockups/Examples | No | ... | ... |
| Dependencies | No | ... | ... |
| Timeline | No | ... | ... |

## Owner questions (if needs-questions)
- Q: {decision} | Options: A. … / B. … | Recommended: … because …
```

## Success criteria
- Verdict is `clear` or `needs-questions`
- Every required section is explicitly assessed
