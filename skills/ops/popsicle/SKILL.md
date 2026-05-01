---
name: popsicle
description: Autonomous doc-quality sensor — discovers what matters in a repo, generates docs, validates with fresh agent sessions that can only read the docs. Runs in a loop until docs pass. No rubric needed.
user-invocable: true
allowed-tools: Read, Write, Bash, Glob, Grep
---

# Popsicle

Autonomous doc-quality sensor. Discover. Generate. Validate. Loop.

**No rubric needed.** Popsicle reads the code, figures out what matters, writes/updates docs, then spawns fresh agent sessions that can ONLY see the docs to verify they're actually useful.

**Install via npx:**
```bash
npx skills add fellowship-dev/dogfooded-skills/skills/ops/popsicle
```

## When to Use

- **After major refactors:** Verify docs still match reality.
- **New repo onboarding:** Bootstrap docs from scratch and validate them.
- **Periodic health check:** Catch doc rot before it compounds.
- **Before handing a repo to agents:** Confirm docs give a fresh agent enough to work independently.

## Anti-Cheat Constraint

Whatever you discover during research is the **answer key**. The repo docs are the **test**. The fresh validation session is the **student**.

Discovery artifacts (knowledge map) MUST live in `/tmp`, never in the repo. The validation sessions must have zero access to discovery artifacts. If they can see what you found, the test is worthless.

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

Scan the repo systematically. Build a knowledge map of what someone SHOULD be able to learn from good docs.

**What to scan:**
- Entry points (`main`, `index`, `app`, CLI entrypoints)
- Public functions and their signatures
- API routes and endpoints
- Config files (env vars, feature flags, deploy config)
- Important abstractions (key classes, modules, patterns)
- Architecture (service boundaries, data flow, external deps)
- Dev workflow (how to run, test, deploy)

**Pick 5-10 concepts per iteration.** Rotate across iterations so you eventually cover the whole repo. Don't repeat concepts that already PASSed.

Write the knowledge map to a temp file:

```bash
KNOWLEDGE_MAP="/tmp/popsicle-knowledge-$(date +%s).json"
```

Use `python3` to write structured JSON:

```bash
python3 -c "
import json, sys
concepts = [
    {
        'id': 'concept-1',
        'category': 'architecture',
        'name': 'Short name',
        'description': 'What a dev should know about this',
        'evidence': 'Where you found it in the code (file:line)',
        'question': 'Question to ask the validation session'
    },
    # ... 5-10 concepts
]
with open('$KNOWLEDGE_MAP', 'w') as f:
    json.dump({'repo': '$REPO_NAME', 'iteration': $ITERATION, 'concepts': concepts}, f, indent=2)
"
```

**This file is the answer key. It stays in `/tmp`. Never commit it.**

---

### Phase 2: Generate (Improve the Docs)

Read existing docs:
- `CLAUDE.md`
- `README.md`
- `docs/` directory
- `ARCHITECTURE.md`
- Any other markdown in the repo root

Compare against the knowledge map. For each concept:
1. Is it documented anywhere? Search the docs.
2. If missing or vague, update the most appropriate doc file.
3. If no appropriate file exists, add to `CLAUDE.md` (preferred) or create a focused doc in `docs/`.

**Rules for doc changes:**
- Be concise. One paragraph per concept is usually enough.
- Don't restructure existing docs — add to them.
- Don't duplicate info that's already clear.
- Focus on the gaps: undocumented entry points, missing env vars, unexplained architecture decisions.

Commit the doc changes:

```bash
git add -A
git commit -m "docs: popsicle iteration $ITERATION — fill doc gaps

Concepts targeted: [list the concept names]"
```

---

### Phase 3: Validate (Test with Fresh Sessions)

**Critical: the knowledge map must be invisible to validation sessions.** It's already in `/tmp` (not in the repo), so fresh sessions can't see it.

For each concept in the knowledge map, spawn a fresh `claude -p` session. Each session gets ONLY the repo context — no discovery artifacts, no hints. Use `--model sonnet` for validators — they only need to read docs and answer questions.

```bash
RESULTS_DIR="/tmp/popsicle-results-$(date +%s)"
mkdir -p "$RESULTS_DIR"
```

For each concept, run a fresh session:

```bash
# For concept N:
claude -p "You are examining the repository at $REPO_ROOT. \
Using ONLY the documentation and docs in this repo (CLAUDE.md, README, docs/, etc.), \
answer this question. Do not read source code — only docs. \
If the docs don't cover this, say 'NOT DOCUMENTED'. \
\
Question: [concept.question from knowledge map]" \
  --model sonnet --output-format text \
  2>/dev/null > "$RESULTS_DIR/concept-N.txt"
```

**Each invocation must be truly fresh — no `--continue`, no shared context.** Run up to 3 concepts in parallel to save time (background the `claude -p` calls and `wait`). Do not exceed 3 concurrent sessions — small machines will OOM.

---

### Phase 4: Grade

Read each validation response. For each concept, score it:

- **PASS**: The session found and explained the concept correctly from docs alone.
- **PARTIAL**: The session found something relevant but the answer is incomplete or vague.
- **FAIL**: The session couldn't answer from docs, or said "NOT DOCUMENTED".

Use your own judgment — semantic understanding matters more than keyword matching. A response that explains the concept in different words is still a PASS.

Compute the pass rate:

```bash
PASS_RATE=$((PASS_COUNT * 100 / TOTAL_CONCEPTS))
```

---

### Phase 5: Report

Write the report:

```bash
REPORT="$REPO_ROOT/docs/popsicle-report-${TODAY}.md"
```

Report format:

```markdown
# Popsicle Report — {REPO_NAME}

**Date**: {TODAY}
**Iteration**: {N}
**Concepts tested**: {count}
**Pass rate**: {PASS_COUNT}/{TOTAL} ({PCT}%)

## Results

| # | Concept | Category | Verdict |
|---|---------|----------|---------|
| 1 | {name}  | arch     | PASS    |
| 2 | {name}  | config   | PARTIAL |
| 3 | {name}  | api      | FAIL    |

## Gaps Remaining

- **{concept}**: {why it failed — what's missing from docs}
- ...

## Doc Changes This Iteration

- Updated `CLAUDE.md`: added {what}
- Updated `docs/architecture.md`: added {what}
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
  echo "Pass rate ${PASS_RATE}% >= ${PASS_THRESHOLD}%. Docs are good enough. Stopping."
  exit 0
fi

if [ "$ITERATION" -ge "$MAX_ITERATIONS" ]; then
  echo "Hit max iterations ($MAX_ITERATIONS). Pass rate: ${PASS_RATE}%. Review remaining gaps manually."
  exit 0
fi

ITERATION=$((ITERATION + 1))
```

If pass rate is below threshold and iterations remain:
1. Read the FAILed concepts from the report.
2. Go back to **Phase 2** — target the FAILed concepts as priority.
3. Re-discover only if you need fresh concepts to rotate in.

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
# As a slash command
/popsicle

# Via claude -p
claude -p "Run the popsicle skill on this repo. One iteration only."
```

**Loop** (iterate until pass rate >= 80% or max 5 iterations):
```bash
# As a slash command
/popsicle --loop

# Via claude -p
claude -p "Run the popsicle skill on this repo. Loop until pass rate >= 80%."
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

1. **No rubric.** The skill discovers what matters by reading the code. No upfront configuration needed.
2. **Anti-cheat by architecture.** Discovery artifacts live in `/tmp`. Validation sessions are fresh. The test is honest.
3. **Docs get better every iteration.** This isn't just measurement — it actively fills gaps.
4. **Fresh sessions are the oracle.** If a fresh agent can't learn it from docs, the docs are broken.
5. **Loop-first.** One iteration is useful. Five iterations with targeted fixes is transformative.
