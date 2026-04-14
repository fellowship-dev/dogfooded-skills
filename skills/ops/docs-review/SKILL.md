---
name: docs-review
description: Detect drift between docs/ and source code — scans docs/ files, cross-references claims against actual source, reports discrepancies with file:line evidence.
allowed-tools: Read, Bash, Glob, Grep
---

# docs-review

A generic docs auditor: reads each markdown file in `docs/`, identifies what source code it documents (by scanning file paths, flag names, command syntax, state names, config examples), then cross-references those claims against actual source files. Reports drift (doc says X, code does Y) with file:line evidence.

## When to Use

- **Periodically** (weekly cron) to catch docs that fall behind code changes
- **Before a release** to ensure docs are accurate against the current codebase
- **After refactoring** commands, config schemas, or state machines
- Skip if `docs/` does not exist — exit cleanly with a note

## When NOT to Use

- Pure narrative sections with no verifiable source claims (history, philosophy, rationale)
- Docs for external APIs you don't own — you can't grep their source
- Formatting or style reviews — only semantic drift matters

## Invocation

```bash
/docs-review
/docs-review --since 2026-04-01
/docs-review --output reports/docs-drift.md
```

| Flag | Effect |
|------|--------|
| *(none)* | Review all `docs/*.md` files |
| `--since <date>` | Narrow to docs files modified since `<date>` (`git log --since`) |
| `--output <path>` | Write findings to file in addition to stdout |

---

## Workflow

### Step 1: Discover docs

```bash
ls docs/*.md 2>/dev/null || echo "No docs/ directory found"
```

If no `docs/` directory exists, exit cleanly:

```
No docs/ directory found — nothing to review.
Exit 0.
```

If `--since <date>` was provided, narrow the file list:

```bash
git log --since="<date>" --name-only --pretty=format: -- docs/*.md | sort -u | grep '\.md$'
```

If this returns nothing, exit cleanly:

```
No docs files modified since <date> — nothing to review.
Exit 0.
```

### Step 2: For each doc file, extract verifiable claims

Read each doc and extract claims that can be cross-referenced against source code:

| Claim type | What to look for | Example |
|---|---|---|
| **Command flags** | `--flag-name` patterns | `--group-id`, `--not-before` |
| **State names/transitions** | `state/ → state/` or quoted state strings | `pending/ → running/ → done/` |
| **Config keys** | backtick-quoted key names in config context | `` `max_concurrent` ``, `` `not_before` `` |
| **File paths** | paths mentioned as "located at X" or "see X" | `dispatch.sh`, `executor.sh` |
| **Exit codes** | "exits with N" or "returns N" | `exit 0`, `exit 1` |
| **Example invocations** | command examples in code blocks | `./dispatch.sh --agent lexgo` |

Skip sections that are clearly non-verifiable: intro prose, motivation, design rationale, future plans.

### Step 3: Cross-reference each claim against source

**Command flags** — search shell scripts and code files:

```bash
grep -rn "\-\-flag-name" --include="*.sh" --include="*.mjs" --include="*.js" --include="*.py" --include="*.ts" .
```

If no match: DRIFT candidate. Confirm the flag truly doesn't exist before reporting.

**State names** — search executor/dispatcher scripts for the state strings:

```bash
grep -rn "pending\|running\|done\|failed" --include="*.sh" --include="*.js" --include="*.py" .
```

Cross-check the exact transition order documented against what the code enforces.

**Config keys** — grep the relevant config files and any code that reads them:

```bash
grep -rn "max_concurrent\|not_before" --include="*.sh" --include="*.yml" --include="*.json" --include="*.js" .
```

**File paths** — check they exist:

```bash
[ -f "path/to/file" ] && echo "EXISTS" || echo "MISSING"
```

Or for directories:

```bash
[ -d "path/to/dir" ] && echo "EXISTS" || echo "MISSING"
```

**Exit codes** — grep the relevant scripts for the actual exit calls:

```bash
grep -n "exit [0-9]" script.sh
```

**Example invocations** — verify the binary/script exists and the flags used in the example are real:

```bash
[ -x "./dispatch.sh" ] && echo "executable exists" || echo "MISSING"
grep -n "\-\-agent" dispatch.sh
```

### Step 4: Format findings

For each **drift item** found:

```
DRIFT: docs/dispatch.md:42 claims "--context" flag exists
  Source check: grep "--context" *.sh → not found
  Evidence: no match in dispatch.sh, executor.sh, or any .sh file
```

For each **verified claim**:

```
OK: docs/dispatch.md:15 "--group-id" → dispatch.sh:47 (confirmed)
```

For each **skipped claim** (non-verifiable):

```
SKIP: docs/overview.md:1-10 — intro prose, no verifiable source claims
```

### Step 5: Summary

After processing all files, emit:

```
=== docs-review summary ===
Docs reviewed: N files
Claims checked: M
  OK:    X verified
  DRIFT: Y items
  SKIP:  Z non-verifiable

Drift items:
  - docs/dispatch.md:42 — "--context" flag not found in source
  - docs/executor.md:18 — state "queued" not found; code uses "pending"

Exit 0 if no drift found, exit 1 if any drift items exist.
```

If `--output <path>` was provided, write the full findings (all OK/DRIFT/SKIP lines + summary) to that file.

---

## Checks to Perform

The six canonical checks — apply all of them:

| Check | What to grep | Where to look |
|---|---|---|
| **Flag parity** | `--flag-name` patterns from docs | `*.sh`, `*.js`, `*.py`, `*.ts` |
| **State parity** | state strings and transition order | executor, dispatcher scripts |
| **Config key parity** | config key names | config files, scripts that read them |
| **Link validity** | `[text](./path)` or `[text](path.md)` internal links | resolve against filesystem |
| **Path existence** | paths mentioned as real locations | `[ -f path ]` or `[ -d path ]` |
| **Exit code accuracy** | "exits N" or "returns N" | `grep -n "exit [0-9]" script` |

**Link validity** check — extract and verify all internal markdown links:

```bash
# Extract internal links (not http/https)
grep -oP '\[.*?\]\(\K[^)]+(?=\))' docs/file.md | grep -v '^https\?://' | while read link; do
  [ -f "$link" ] || [ -d "$link" ] && echo "OK: $link" || echo "DRIFT: broken link → $link"
done
```

---

## Anti-Patterns

Do NOT do these:

- **Fabricate drift** — only report what you actually verified with grep/read. If grep returns results but you can't find the exact claim, mark SKIP not DRIFT.
- **Skip docs that look correct** — every doc gets checked; intuition is not evidence.
- **Fail on formatting** — wrong indentation, different phrasing of correct content: not drift.
- **Report style issues** — "this example could be clearer" is not drift.
- **Check external API docs** — if the doc describes a third-party API, skip it.
- **Over-grep** — match the exact flag name, not a substring. `--group` should not match `--group-id`.

---

## Adding to a Team Cron

To run docs-review automatically on a schedule:

```yaml
# In crew.yml, under the team's cron section:
cron:
  - schedule: "0 6 * * 1"  # Weekly Monday 6am UTC
    task: "Run docs-review: check docs/ for drift against code"
```

For repos with active doc changes, use a daily schedule:

```yaml
cron:
  - schedule: "0 7 * * *"  # Daily 7am UTC
    task: "Run docs-review --since yesterday: check docs/ for overnight drift"
```

---

## Exit Codes

| Exit code | Meaning |
|---|---|
| `0` | No drift found (or no docs to review) |
| `1` | One or more drift items found |
