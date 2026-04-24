---
name: trash-truck
description: Code slop cleanup agent — scans for duplicate patterns, dead code, misplaced files, accidentally committed files, and pattern drift; opens targeted, reviewable refactoring PRs
allowed-tools: Read, Write, Bash, Glob, Grep
user-invocable: true
argument-hint: "[org/repo] (focus: dead-code|duplicates|drift|misplaced|committed-by-error|unused-functions)"
---

# trash-truck

Finds and removes code slop without changing behavior. Opens small, reviewable PRs. Inspired by the real cost of AI-generated entropy: teams that skip cleanup spend 20% of their week on slop.

## Invocation

```
/trash-truck [org/repo]
/trash-truck [org/repo] focus:dead-code
/trash-truck [org/repo] focus:duplicates
/trash-truck [org/repo] focus:drift
/trash-truck [org/repo] focus:misplaced
/trash-truck [org/repo] focus:committed-by-error
/trash-truck [org/repo] focus:unused-functions
```

## Targets

| Category | What to look for |
|----------|-----------------|
| **dead-code** | Unused exports, orphaned imports, debug `console.log`/`print`, commented-out code blocks |
| **duplicates** | Same concept implemented multiple ways across the codebase |
| **inconsistent** | Same operation done differently in different modules (error handling, fetch patterns, config access) |
| **drift** | Deviations from golden principles documented in `CLAUDE.md`, `docs/`, or established skill files |
| **misplaced** | Files in wrong directories — test files outside test dirs, configs buried in source trees |
| **committed-by-error** | Files that shouldn't be in version control — `.env`, `.DS_Store`, swap files, compiled bytecode, IDE configs, database files |
| **unused-functions** | Functions/methods defined but never called or referenced anywhere in the codebase (Python via `ast`, JS/TS via export/import analysis). **Costs more tokens** — use as a targeted focus, not in `all` |

## How It Works

1. Clone or enter the target repo
2. **Run pre-scan** for cheap static analysis before spending tokens on LLM review
3. Review pre-scan results — filter false positives, group into cleanup units
4. Open each PR with a focused, reviewable diff

### Pre-scan (Step 2)

The `pre-scan.sh` script in this skill's directory uses `rg` + Python `ast` to find candidates cheaply before Claude reviews them. This cuts token cost by 5-10x compared to having Claude grep the entire codebase.

```bash
# Run from the repo root — outputs structured JSON
SKILL_DIR="$(dirname "$(readlink -f "$0")")"  # or wherever the skill was synced
bash "$SKILL_DIR/pre-scan.sh" [focus] [repo-root]

# Examples:
bash pre-scan.sh all /path/to/repo          # everything except unused-functions
bash pre-scan.sh dead-code /path/to/repo     # just debug stmts + commented code
bash pre-scan.sh unused-functions /path/to/repo  # deeper analysis, slower
```

The script outputs JSON with findings grouped by category. Each finding has `file`, `kind`, and usually `line` and `detail`. Use this output to guide which files to read and what to clean up — don't re-scan what the script already found.

**What pre-scan does NOT do:** It finds candidates, not confirmed slop. Claude still needs to verify each finding (is the "unused" function actually called via reflection? is the "debug" print actually a user-facing log?). The script is intentionally aggressive — false positives are filtered by Claude, not suppressed at scan time.

## PR Rules

- **One PR per logical cleanup** — keep diffs small and reviewable
- **Title format:** `chore: [what was cleaned] in [file/module]`
- **No behavior changes** — if a change could alter runtime behavior, skip it and open an issue instead
- **CTO reviews process** (was the right pattern followed?), not the code itself

## What NOT to Do

- Do not refactor logic — only remove or consolidate dead/duplicate patterns
- Do not open a single giant PR — small diffs or nothing
- Do not touch tests unless the test itself is dead or duplicated
- Do not include `unused-functions` in an `all` scan — it's too expensive for routine sweeps
