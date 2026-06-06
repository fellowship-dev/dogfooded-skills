# issue-to-prd — Overview

ICM procedure that converts a GitHub issue into a structured PRD or posts clarifying questions.

## Purpose
Issues arrive underspecified. This procedure catches context gaps, clarity gaps, and failure modes
before an agent starts work — preventing wasted tokens and off-target PRs.

## Replaces
- `external-rule` (greet) event rule: replaced by `challenge-new-issue`
- Manual `build-prd` skill for the autonomous pipeline case (manual stays for interactive use)

## Architecture
7 sequential stages. Each stage is atomic: defined inputs, defined outputs, explicit side effects.
Stages 01-05 are pure analysis (no GH side effects). Stages 06-07 write to GitHub.

## Key invariants
- Stages 01-05: read-only. No GH comments, no label changes.
- Stage 06: the ONLY decision point. All questions batched into ONE comment.
- Stage 07: runs ONLY when stage 06 produced a PRD (not a questions list).
- Labels added, never removed. `challenged` prevents re-processing.

## Folder map
```
SKILL.md           — invocation reference
CONTEXT.md         — this file
shared/            — prd-template.md, failure-modes.md
stages/01-07/      — CONTEXT.md + output/ per stage
stages/03/references/  — gap-checklist.md
```

## Emit on completion
- Questions path: `[pylot] outcome="questions posted" status=success`
- PRD path: `[pylot] outcome="PRD published" status=success`
