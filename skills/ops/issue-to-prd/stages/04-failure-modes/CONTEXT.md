# Stage 04: Failure Mode Analysis

## Inputs
- `$WORK/01-read-issue.md`
- `$WORK/02-context-completeness.md`
- `$WORK/03-assess-clarity.md`

## Reference
`shared/failure-modes.md` — common pitfall catalog

## Task
Predict how an agent can go astray on this issue. Produce guardrails for the PRD.

## Steps
1. Read all prior handoffs (01, 02, 03) and `shared/failure-modes.md`
2. For each requirement/feature in the issue, ask:
   - How can an agent misinterpret this? (wrong scope, wrong approach, over-engineering)
   - Where can it get lost in the weeds? (rabbit holes, tangential work)
   - What wrong assumptions might it make? (about architecture, what exists, permissions)
3. For each failure mode, specify a guardrail:
   - Code examples showing the right pattern
   - Explicit "do NOT" instructions
   - Pointers to existing code that already solves part of the problem
   - Scope fences (which files to touch)

## Output: `$WORK/04-failure-modes.md`
```markdown
# Stage 04: Failure Mode Analysis

## Failure Modes
| Risk | Likelihood | Impact | Guardrail |
|------|------------|--------|-----------|
| ... | high/med/low | high/med/low | ... |

## Recommended PRD additions
### Anti-patterns
- Do NOT ...

### Scope fences
- Only touch files: ...

### Existing code to follow
- See `{file}:{line}` for the pattern to replicate
```

## Success criteria
- At least one failure mode identified per major requirement
- Every failure mode has a concrete guardrail, not just a warning
