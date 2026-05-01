---
name: popsicle
description: Agent onboarding doc generator — discovers what matters in a repo, writes structured docs an agent can navigate, validates with fresh sessions. Enforces size budgets and doc-type separation.
user-invocable: true
allowed-tools: Read, Write, Bash, Glob, Grep
---

# Popsicle

Agent onboarding doc generator. Discover. Structure. Validate. Loop.

**Purpose:** Make any repo agent-ready. A fresh AI agent with zero context should be able to read the docs and start working — without reading source code first.

**Install via npx:**
```bash
npx skills add fellowship-dev/dogfooded-skills/skills/ops/popsicle
```

## When to Use

- **New repo onboarding:** Bootstrap agent-readable docs from scratch.
- **After major refactors:** Verify docs still match reality.
- **Periodic health check:** Catch doc rot before it compounds.
- **Before handing a repo to agents:** Confirm docs give a fresh agent enough to work independently.

## Anti-Cheat Constraint

Whatever you discover during research is the **answer key**. The repo docs are the **test**. The fresh validation session is the **student**.

Discovery artifacts (knowledge map) MUST live in `/tmp`, never in the repo. The validation sessions must have zero access to discovery artifacts. If they can see what you found, the test is worthless.

---

## Doc Types — What Goes Where

Agents need three kinds of documentation. Popsicle enforces separation:

### 1. `CLAUDE.md` — Agent Instructions (≤80 lines)

The entry point. An agent reads this first. It answers: "What is this repo, how do I work in it, and what rules must I follow?"

**What belongs here:**
- Project identity (one sentence: what this is, what stack)
- How to install, run, test, deploy (commands only, no explanation)
- Key rules and constraints (things that break if violated)
- Pointers to `docs/` for deeper reference

**What does NOT belong here:**
- Architecture explanations (→ `docs/architecture.md`)
- API reference (→ `docs/api.md`)
- Config/env var tables longer than 5 rows (→ `docs/configuration.md`)
- Runbooks or troubleshooting (→ `docs/runbook.md`)
- History, context, or "why we built this" (→ README.md or nowhere)

**Budget: ≤80 lines.** If CLAUDE.md exceeds 80 lines after your changes, refactor: move detail into `docs/` and replace with a one-line pointer. Count lines with `wc -l CLAUDE.md`.

### 2. `docs/*.md` — Reference Documentation

Deep knowledge an agent navigates to when working on specific areas. Each file covers one topic. An agent should be able to find the right file by name alone.

**Standard files** (create only the ones the repo needs):
- `docs/architecture.md` — system boundaries, data flow, key abstractions, service map
- `docs/api.md` — routes, endpoints, request/response shapes
- `docs/configuration.md` — env vars, feature flags, config files with all options documented
- `docs/workflows.md` — dev workflow, CI/CD, deploy process, release steps
- `docs/data-model.md` — database schema, key tables, relationships
- `docs/glossary.md` — domain terms that aren't obvious from code (only if needed)
- `docs/runbook.md` — how to debug common issues, operational procedures

**Rules:**
- One topic per file. If a file exceeds 200 lines, split it.
- File names must be self-descriptive — an agent picks which file to read based on the name.
- No `docs/misc.md` or `docs/notes.md` — if it doesn't have a clear topic, it doesn't belong.
- Link between doc files when concepts cross boundaries.

### 3. `README.md` — Human Documentation (don't touch)

README.md is for humans: badges, screenshots, marketing copy, contribution guides. **Popsicle does not modify README.md.** If critical info exists only in README.md and belongs in agent docs, copy the relevant facts into the appropriate `docs/` file or CLAUDE.md — don't restructure the README.

---

## Instructions

### 0. Setup

```bash
REPO_ROOT=$(git rev-parse --show-toplevel)
REPO_NAME=$(basename $(git remote get-url origin) .git)
TODAY=$(date +%Y-%m-%d)
ITERATION=1
MAX_ITERATIONS=5
PASS_THRESHOLD=80
```

Check for `--loop` flag: if present (or if dispatched as a crew mission), run the full loop. Otherwise run one iteration and report.

**You MUST complete ALL phases (1-6) in every iteration.** Do not stop after validation — always grade, report, and decide whether to loop. If context is tight, keep grading terse (one line per concept).

---

### Phase 1: Discover (Build the Answer Key)

Scan the repo systematically. Build a knowledge map of what an agent SHOULD be able to learn from good docs.

**What to scan:**
- Entry points (`main`, `index`, `app`, CLI entrypoints)
- How to install, run, test (the commands, not just that they exist)
- API routes and endpoints
- Config files (env vars, feature flags, deploy config)
- Important abstractions (key classes, modules, patterns)
- Architecture (service boundaries, data flow, external deps)
- Dev workflow (CI, deploy, release process)
- Domain-specific terms that aren't obvious from code

**Classify each concept by doc type** — where should an agent find this?

| Category | Target file |
|----------|-------------|
| identity, stack, run/test commands, key rules | `CLAUDE.md` |
| system design, data flow, service boundaries | `docs/architecture.md` |
| routes, endpoints, request/response | `docs/api.md` |
| env vars, config files, feature flags | `docs/configuration.md` |
| dev workflow, CI/CD, deploy, release | `docs/workflows.md` |
| database schema, key tables | `docs/data-model.md` |
| domain terms | `docs/glossary.md` |

**Pick 5-10 concepts per iteration.** Rotate across iterations so you eventually cover the whole repo. Don't repeat concepts that already PASSed.

Write the knowledge map to a temp file:

```bash
KNOWLEDGE_MAP="/tmp/popsicle-knowledge-$(date +%s).json"
```

```bash
python3 -c "
import json, sys
concepts = [
    {
        'id': 'concept-1',
        'category': 'architecture',
        'target_file': 'docs/architecture.md',
        'name': 'Short name',
        'description': 'What an agent should know about this',
        'evidence': 'Where you found it in the code (file:line)',
        'question': 'Question to ask the validation session',
        'nav_question': 'Which doc file would you read to learn about this?'
    },
    # ... 5-10 concepts
]
with open('$KNOWLEDGE_MAP', 'w') as f:
    json.dump({'repo': '$REPO_NAME', 'iteration': $ITERATION, 'concepts': concepts}, f, indent=2)
"
```

**This file is the answer key. It stays in `/tmp`. Never commit it.**

---

### Phase 2: Generate (Write Structured Docs)

Read existing docs: `CLAUDE.md`, `docs/` directory, `README.md` (read-only reference).

For each concept in the knowledge map:
1. Does the target file exist? If not, create it with a `# Title` header.
2. Is the concept already documented in the right place? If yes, skip.
3. If documented in the wrong place (e.g., architecture details in CLAUDE.md), move it.
4. If missing, write it in the target file.

**After all concepts are placed, enforce budgets:**

```bash
CLAUDE_LINES=$(wc -l < CLAUDE.md 2>/dev/null || echo 0)
if [ "$CLAUDE_LINES" -gt 80 ]; then
  echo "CLAUDE.md is $CLAUDE_LINES lines — over 80-line budget. Refactor."
fi
```

If CLAUDE.md exceeds 80 lines:
1. Identify sections that are reference material (tables >5 rows, detailed explanations, examples).
2. Move them to the appropriate `docs/` file.
3. Replace with a one-line pointer: `See [docs/configuration.md](docs/configuration.md) for full env var reference.`
4. Re-check the line count.

**CLAUDE.md structure template** (adapt to repo, don't force sections that don't apply):

```markdown
# {Repo Name}

{One sentence: what this is and what stack.}

## Quick Start

{install, run, test commands — no prose, just the commands}

## Key Rules

{Things that break if violated — max 5 bullets}

## Project Structure

{Only if non-obvious — 5-10 lines max showing key directories}

## Reference

- [Architecture](docs/architecture.md) — {one-line summary}
- [Configuration](docs/configuration.md) — {one-line summary}
- [API](docs/api.md) — {one-line summary}
```

Commit the doc changes:

```bash
git add CLAUDE.md docs/
git commit -m "docs: popsicle iteration $ITERATION — structured agent docs

Concepts targeted: [list the concept names]"
```

---

### Phase 3: Validate (Test with Fresh Sessions)

**Critical: the knowledge map must be invisible to validation sessions.** It's already in `/tmp` (not in the repo), so fresh sessions can't see it.

Two types of validation per concept:

```bash
RESULTS_DIR="/tmp/popsicle-results-$(date +%s)"
mkdir -p "$RESULTS_DIR"
```

**Test A — Content validation** (can the agent answer from docs?):

```bash
claude -p "You are examining the repository at $REPO_ROOT. \
Using ONLY the documentation in this repo (CLAUDE.md, docs/*.md), \
answer this question. Do not read source code — only docs. \
If the docs don't cover this, say 'NOT DOCUMENTED'. \
\
Question: [concept.question]" \
  --model sonnet --output-format text \
  2>/dev/null > "$RESULTS_DIR/concept-N-content-1.txt"
```

Run 2 independent content sessions per concept.

**Test B — Navigation validation** (can the agent find WHERE to look?):

```bash
claude -p "You are examining the repository at $REPO_ROOT. \
Look at the documentation files available (CLAUDE.md, docs/*.md). \
Do NOT read the full contents — only look at file names and headers. \
\
Question: Which specific doc file would you open to learn about: [concept.nav_question]? \
Answer with just the file path." \
  --model sonnet --output-format text \
  2>/dev/null > "$RESULTS_DIR/concept-N-nav.txt"
```

Run 1 navigation session per concept.

**Run up to 3 sessions in parallel** (background and `wait`). Do not exceed 3 concurrent — small machines will OOM.

---

### Phase 4: Grade

For each concept, score on two axes:

**Content score** (from Test A):
- **PASS** (2/2): Both sessions answered correctly from docs.
- **WEAK** (1/2): One got it, one didn't.
- **FAIL** (0/2): Neither could answer.

**Navigation score** (from Test B):
- **HIT**: Agent pointed to the correct file (matches `target_file` from knowledge map).
- **MISS**: Agent pointed to wrong file or couldn't find it.

**Combined verdict:**
- **PASS**: Content PASS + Nav HIT
- **PARTIAL**: Content PASS + Nav MISS (info exists but hard to find), or Content WEAK + Nav HIT
- **FAIL**: Content FAIL (regardless of nav), or Content WEAK + Nav MISS

Compute the pass rate (PASS only, PARTIAL counts as half):

```bash
SCORE=$((PASS_COUNT * 100 + PARTIAL_COUNT * 50))
PASS_RATE=$((SCORE / TOTAL_CONCEPTS))
```

---

### Phase 5: Report

```bash
REPORT="$REPO_ROOT/docs/popsicle-report-${TODAY}.md"
```

```markdown
# Popsicle Report — {REPO_NAME}

**Date**: {TODAY}
**Iteration**: {N}
**Concepts tested**: {count}
**Pass rate**: {PCT}%

## Doc Structure

| File | Lines | Status |
|------|-------|--------|
| CLAUDE.md | {n} | {ok / over budget} |
| docs/architecture.md | {n} | {exists / created / n/a} |
| docs/configuration.md | {n} | {exists / created / n/a} |
| ... | | |

## Results

| # | Concept | Target File | Content | Nav | Verdict |
|---|---------|-------------|---------|-----|---------|
| 1 | {name}  | docs/arch.. | PASS    | HIT | PASS    |
| 2 | {name}  | CLAUDE.md   | WEAK    | HIT | PARTIAL |
| 3 | {name}  | docs/api..  | FAIL    | MISS| FAIL    |

## Gaps Remaining

- **{concept}**: {why it failed — what's missing or misplaced}
- ...

## Doc Changes This Iteration

- Created `docs/architecture.md`: {what}
- Refactored `CLAUDE.md`: moved {what} to `docs/configuration.md`
- ...
```

Commit the report:

```bash
git add "docs/popsicle-report-${TODAY}.md"
git commit -m "docs: popsicle report — iteration $ITERATION, ${PASS_RATE}% pass rate"
```

---

### Phase 6: Loop or Stop

```bash
if [ "$PASS_RATE" -ge "$PASS_THRESHOLD" ]; then
  echo "Pass rate ${PASS_RATE}% >= ${PASS_THRESHOLD}%. Docs are agent-ready. Stopping."
  exit 0
fi

if [ "$ITERATION" -ge "$MAX_ITERATIONS" ]; then
  echo "Hit max iterations ($MAX_ITERATIONS). Pass rate: ${PASS_RATE}%. Review remaining gaps manually."
  exit 0
fi

ITERATION=$((ITERATION + 1))
```

If pass rate is below threshold and iterations remain:
1. Read the FAILed and PARTIAL concepts from the report.
2. For nav MISSes: restructure — move content to a more discoverable location or rename the file.
3. For content FAILs: improve the docs in the target file.
4. Go back to **Phase 2**.

---

### Cleanup

After all iterations complete:

```bash
rm -f /tmp/popsicle-knowledge-*.json
rm -rf /tmp/popsicle-results-*
```

Discovery artifacts are ephemeral. Reports and doc changes are committed.

---

## Usage Modes

**One-shot** (single iteration, report only):
```bash
/popsicle
```

**Loop** (iterate until pass rate >= 80% or max 5 iterations):
```bash
/popsicle --loop
```

**Crew mission** (dispatched via Pylot):
```bash
curl -X POST "$PYLOT_DISPATCH_URL" \
  -H "Authorization: Bearer $PYLOT_DISPATCH_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"agent":"crew.lead","task":"Run popsicle in loop mode on this repo. Commit doc improvements and reports.","repo":"org/repo"}'
```

---

## Design Principles

1. **Agent-first.** Docs are for AI agents, not humans. README.md is for humans — popsicle doesn't touch it.
2. **Structure over volume.** 80 lines of well-placed docs beats 300 lines in one file. If an agent can't find it by filename, the docs are broken.
3. **Anti-cheat by architecture.** Discovery artifacts live in `/tmp`. Validation sessions are fresh. The test is honest.
4. **Navigate then read.** Validation tests both: can the agent find the right file (nav), AND can it answer from that file (content).
5. **Budget-enforced.** CLAUDE.md ≤80 lines. Individual doc files ≤200 lines. Overflow triggers refactoring, not bloat.
6. **Loop-first.** One iteration is useful. Five iterations with structural fixes is transformative.
