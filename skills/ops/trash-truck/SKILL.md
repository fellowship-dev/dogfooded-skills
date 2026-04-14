---
name: trash-truck
description: Code slop cleanup agent — scans for duplicate patterns, dead code, inconsistent implementations, and pattern drift; opens targeted, reviewable refactoring PRs
allowed-tools: Read, Write, Bash, Glob, Grep
user-invocable: true
argument-hint: "[org/repo] (focus: dead-code|duplicates|drift)"
---

# trash-truck

Finds and removes code slop without changing behavior. Opens small, reviewable PRs. Inspired by the real cost of AI-generated entropy: teams that skip cleanup spend 20% of their week on slop.

## Invocation

```
/trash-truck [org/repo]
/trash-truck [org/repo] focus:dead-code
/trash-truck [org/repo] focus:duplicates
/trash-truck [org/repo] focus:drift
```

## Targets

| Category | What to look for |
|----------|-----------------|
| **dead-code** | Unused exports, orphaned imports, debug `console.log`/`print`, commented-out code blocks |
| **duplicates** | Same concept implemented multiple ways across the codebase |
| **inconsistent** | Same operation done differently in different modules (error handling, fetch patterns, config access) |
| **drift** | Deviations from golden principles documented in `CLAUDE.md`, `docs/`, or established skill files |

## How It Works

1. Clone or enter the target repo
2. Scan for slop in the selected category (or all if no focus given)
3. Group findings into logical cleanup units — one PR per unit
4. Open each PR with a focused, reviewable diff

## PR Rules

- **One PR per logical cleanup** — keep diffs small and reviewable
- **Title format:** `chore: [what was cleaned] in [file/module]`
- **No behavior changes** — if a change could alter runtime behavior, skip it and open an issue instead
- **CTO reviews process** (was the right pattern followed?), not the code itself

## What NOT to Do

- Do not refactor logic — only remove or consolidate dead/duplicate patterns
- Do not open a single giant PR — small diffs or nothing
- Do not touch tests unless the test itself is dead or duplicated
