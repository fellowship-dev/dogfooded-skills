# Stage 02: Context Completeness

## Inputs
- `stages/01-read-issue/output/handoff.md`
- Repo codebase (README, CLAUDE.md, files referenced in the issue)

## Task
Audit whether a fresh agent with only this repo + issue would understand what to do.

## Steps
1. Read stage 01 handoff
2. Read repo README, CLAUDE.md, and any source files referenced in the issue
3. For each potential gap, ask: would a fresh agent be confused by this?
4. Identify implicit context gaps:
   - Undefined terms or jargon
   - Vague references ("the thing we discussed", "the old way")
   - Assumed architectural knowledge not visible in the repo
   - Unstated constraints or preferences
   - Missing use cases or intent
5. For each gap, classify the type of context that would fill it

## Output: handoff.md
```markdown
# Stage 02: Context Completeness

## Verdict
`self-contained` | `needs-context`

## Implicit Context Gaps
| Gap | Description | Context type needed |
|-----|-------------|---------------------|
| ... | ... | code example / intent / use case / constraint |

## Recommended additions
- ...
```

## Success criteria
- Verdict is `self-contained` or `needs-context`
- Every gap has a type classification
- No gaps invented — only what's genuinely ambiguous
