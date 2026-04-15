---
name: cold-start-check
description: Sensor — tests whether a repo's docs are good enough for a fresh agent to understand the system. Spawns N isolated sessions, grades responses against a rubric, and reports which concepts are reliably discoverable vs. consistently missed.
user-invocable: true
allowed-tools: Read, Write, Bash, Glob, Grep
---

# Cold-Start Check

Sensor. Spawn. Grade. Report. **Never fix.**

**Install via npx:**
```bash
npx skills add fellowship-dev/dogfooded-skills/skills/ops/cold-start-check
```

## When to Use

- **After a doc update:** Verify that the changes actually make the system understandable to a fresh agent.
- **Before a doc sprint:** Establish a baseline of what's discoverable — then re-run after the sprint to measure improvement.
- **Periodic health check:** Monthly or quarterly, to catch doc rot before it compounds.
- **After onboarding a new repo to the harness:** Confirm that `docs/` gives an agent enough to work independently.

## What It Does

Cold-start-check asks a rubric's questions to N fresh agent sessions that have never seen the repo before. It grades each response against expected concepts, then aggregates across sessions to identify:

- **Reliable gaps** — concepts missed in 2+ sessions = genuine doc hole
- **Noise** — concept missed in only 1 session = probably fine
- **Hallucinations** — agent asserts something confidently that isn't in the docs

The rubric file lives at `docs/cold-start-rubric.yml`. It is **hidden before spawning** — agents that can see the rubric will parrot its answers and produce false positives.

---

## Instructions

### 0. Identify Target Repo

```bash
REPO_ROOT=$(git rev-parse --show-toplevel)
REPO_NAME=$(basename $(git remote get-url origin) .git)
TODAY=$(date +%Y-%m-%d)
```

### 1. Read the Rubric

```bash
RUBRIC="$REPO_ROOT/docs/cold-start-rubric.yml"

if [ ! -f "$RUBRIC" ]; then
  echo "ERROR: No rubric found at $RUBRIC"
  echo "Create docs/cold-start-rubric.yml before running cold-start-check."
  exit 1
fi
```

Read the rubric file now — you need to parse it before hiding it.

Parse each question's `prompt` and `expected_concepts` list. Store them in indexed shell variables (Bash 3.2 compatible — no associative arrays):

```bash
# Parse rubric questions into indexed variables.
# Use yq if available, otherwise fall back to manual parsing.
if command -v yq >/dev/null 2>&1; then
  Q_COUNT=$(yq eval '.questions | length' "$RUBRIC")
  i=0
  while [ "$i" -lt "$Q_COUNT" ]; do
    eval "Q${i}_PROMPT=\$(yq eval \".questions[$i].prompt\" \"$RUBRIC\")"
    eval "Q${i}_CONCEPT_COUNT=\$(yq eval \".questions[$i].expected_concepts | length\" \"$RUBRIC\")"
    j=0
    while [ "$j" -lt "$(eval echo \$Q${i}_CONCEPT_COUNT)" ]; do
      eval "Q${i}_C${j}=\$(yq eval \".questions[$i].expected_concepts[$j]\" \"$RUBRIC\")"
      j=$((j + 1))
    done
    i=$((i + 1))
  done
else
  echo "WARNING: yq not found. Install yq for reliable YAML parsing."
  echo "  brew install yq   or   npm install -g yq"
  echo "Attempting manual parse (may fail on complex YAML)..."
  # Manual parse: extract prompts and concepts line-by-line
  # This is a fallback — prefer yq
fi
```

### 2. Hide the Rubric

The rubric **must not be visible** to fresh sessions. Move it before spawning any agents.

```bash
RUBRIC_BACKUP="/tmp/cold-start-rubric-$(date +%s).yml"

# Trap guarantees restore even on failure, Ctrl-C, or error
trap 'mv "$RUBRIC_BACKUP" "$RUBRIC" 2>/dev/null; echo "Rubric restored."' EXIT INT TERM

mv "$RUBRIC" "$RUBRIC_BACKUP"
echo "Rubric hidden at $RUBRIC_BACKUP"
```

Verify the rubric is gone before continuing:

```bash
if [ -f "$RUBRIC" ]; then
  echo "ERROR: Failed to hide rubric. Aborting."
  exit 1
fi
```

### 3. Spawn Fresh Sessions

Run N sessions (default: 3). Each session gets the full repo context but **no rubric**.

For each session and each question, spawn a fresh `claude -p` invocation:

```bash
N=3
TMPDIR_RESULTS=$(mktemp -d)

i=1
while [ "$i" -le "$N" ]; do
  echo "=== Session $i of $N ==="

  q=0
  while [ "$q" -lt "$Q_COUNT" ]; do
    PROMPT=$(eval echo "\$Q${q}_PROMPT")
    SESSION_TAG="cold-start-s${i}-q${q}-$(date +%s)"
    RESULT_FILE="$TMPDIR_RESULTS/s${i}_q${q}.txt"

    echo "  Q$((q+1)): $PROMPT"

    # Spawn fresh session — no --continue, no shared context
    claude -p "You are reviewing the repository at $REPO_ROOT. Answer this question based only on what you can find in the repo's docs and code — do not guess or invent. Question: $PROMPT" \
      --output-format text \
      2>/dev/null > "$RESULT_FILE" || echo "" > "$RESULT_FILE"

    echo "  Response saved to $RESULT_FILE"
    q=$((q + 1))
  done

  i=$((i + 1))
done
```

If `claude` is not in PATH, check `~/.claude/local/claude` or `npx claude`.

### 4. Restore the Rubric

The trap will fire automatically on EXIT, but call it explicitly for clarity:

```bash
mv "$RUBRIC_BACKUP" "$RUBRIC"
echo "Rubric restored at $RUBRIC"
# Disarm the trap (already restored)
trap - EXIT INT TERM
```

### 5. Grade Responses

For each question, each concept, each session: check if the concept keywords appear in the response.

Grading is mechanical (keyword matching). Use the full concept string as a multi-word search — split into words and require all words to appear.

```bash
# Grade: returns 1 if concept found in response file, 0 if not
grade_concept() {
  RESPONSE_FILE="$1"
  CONCEPT="$2"

  if [ ! -s "$RESPONSE_FILE" ]; then
    echo "0"
    return
  fi

  # Check if all significant words from the concept appear in the response
  # (case-insensitive, order-independent)
  FOUND=1
  for WORD in $CONCEPT; do
    # Skip short stop words
    case "$WORD" in
      a|an|the|is|in|of|to|and|or|for|not|no|be) continue ;;
    esac
    if ! grep -qi "$WORD" "$RESPONSE_FILE" 2>/dev/null; then
      FOUND=0
      break
    fi
  done
  echo "$FOUND"
}
```

Grade every cell and store results:

```bash
q=0
while [ "$q" -lt "$Q_COUNT" ]; do
  CONCEPT_COUNT=$(eval echo "\$Q${q}_CONCEPT_COUNT")
  c=0
  while [ "$c" -lt "$CONCEPT_COUNT" ]; do
    s=1
    while [ "$s" -le "$N" ]; do
      RESULT=$(grade_concept "$TMPDIR_RESULTS/s${s}_q${q}.txt" "$(eval echo "\$Q${q}_C${c}")")
      echo "$RESULT" > "$TMPDIR_RESULTS/grade_q${q}_c${c}_s${s}.txt"
      s=$((s + 1))
    done
    c=$((c + 1))
  done
  q=$((q + 1))
done
```

### 6. Apply AI Judgment (Optional)

For any concept graded 0 by keyword matching, re-read the response and judge whether the concept was described in different words. This catches semantic matches that keyword search misses.

Use your own judgment here — you are the grading agent. Override a 0 to 1 only when the response clearly conveys the concept even without the exact keywords.

### 7. Compute Verdicts

For each concept, count how many sessions found it:

- **3/3 found** → `PASS`
- **2/3 found** → `PASS (2/3)` — weak signal, worth documenting
- **1/3 found** → `FLAKY` — not reliable
- **0/3 found** → `FAIL — doc gap`

Track overall totals:
```bash
TOTAL_CONCEPTS=0
TOTAL_FOUND=0

q=0
while [ "$q" -lt "$Q_COUNT" ]; do
  CONCEPT_COUNT=$(eval echo "\$Q${q}_CONCEPT_COUNT")
  c=0
  while [ "$c" -lt "$CONCEPT_COUNT" ]; do
    TOTAL_CONCEPTS=$((TOTAL_CONCEPTS + 1))
    FOUND_COUNT=0
    s=1
    while [ "$s" -le "$N" ]; do
      VAL=$(cat "$TMPDIR_RESULTS/grade_q${q}_c${c}_s${s}.txt" 2>/dev/null || echo "0")
      FOUND_COUNT=$((FOUND_COUNT + VAL))
      s=$((s + 1))
    done
    # Concept "found" if 2+ sessions found it
    if [ "$FOUND_COUNT" -ge 2 ]; then
      TOTAL_FOUND=$((TOTAL_FOUND + 1))
    fi
    c=$((c + 1))
  done
  q=$((q + 1))
done
```

### 8. Generate Report

Write the report as markdown. Output to stdout and optionally write to `docs/cold-start-report-{TODAY}.md`.

```
## Cold-Start Report — {REPO_NAME}

**Date**: {TODAY}
**Sessions**: {N}
**Questions**: {Q_COUNT}
**Overall**: {TOTAL_FOUND}/{TOTAL_CONCEPTS} concepts found ({PCT}%)

### Q1: "{prompt}"
| Concept | Session 1 | Session 2 | Session 3 | Verdict |
|---------|-----------|-----------|-----------|---------|
| {concept} | ✅ | ✅ | ❌ | PASS (2/3) |
| {concept} | ❌ | ❌ | ❌ | FAIL — doc gap |

### Q2: "{prompt}"
...

### Doc Improvement Targets
- {concept} not discoverable from docs ({found}/3 sessions found it)
- ...

### Hallucinations Detected
- Session {N}, Q{M}: agent stated "{claim}" — not found in docs
  (Note: flag these for human review)
```

For **FAIL** and **FLAKY** concepts, add them to the Doc Improvement Targets section. These are the gaps that doc work should address next.

For any response where the agent asserted a specific fact that you cannot verify in the repo docs, log it as a potential hallucination.

### 9. Cleanup

```bash
rm -rf "$TMPDIR_RESULTS"
```

The rubric was already restored in step 4. Confirm it exists before finishing:

```bash
if [ ! -f "$RUBRIC" ]; then
  echo "WARNING: Rubric not restored. Check $RUBRIC_BACKUP"
else
  echo "Rubric confirmed at $RUBRIC"
fi
```

---

## Rubric Format

```yaml
# docs/cold-start-rubric.yml
questions:
  - prompt: "How do you manage code reviews and tech debt?"
    expected_concepts:
      - "CTO verifies process, not output"
      - "double-checked label triggers CTO review"
      - "entropy grades identify doc staleness"

  - prompt: "What is the deployment architecture?"
    expected_concepts:
      - "Next.js on Vercel"
      - "Strapi on Fly.io"
      - "Cloudflare Worker for email"
```

**Writing good rubric questions:**
- Ask what a new contributor would actually need to know
- Expected concepts should be specific enough to be falsifiable
- Include concepts that are easy to miss (non-obvious from code alone)
- 3-5 concepts per question is the sweet spot — too many dilutes the signal

**What makes a concept gradeable:**
- Must be discoverable from `docs/` or `ARCHITECTURE.md` — not deep in source
- Must have a keyword fingerprint (even a paraphrase will have at least one distinctive word)
- Must represent genuine knowledge, not trivia

---

## Rubric Placement and Security

The rubric **must** live at `docs/cold-start-rubric.yml`. This path is:
- In `.gitignore` for repos where the rubric is team-internal (optional)
- Hidden before every test run (step 2 above)
- Restored after every run, even on failure (trap handler)

Never pass the rubric file path as a `--context` flag or mention its location in the agent prompt. Fresh sessions must have no knowledge that a rubric exists.

---

## Output Example

```
## Cold-Start Report — booster-pack

**Date**: 2026-04-14
**Sessions**: 3
**Questions**: 3
**Overall**: 9/12 concepts found (75%)

### Q1: "What is the architecture of booster-pack?"
| Concept | Session 1 | Session 2 | Session 3 | Verdict |
|---------|-----------|-----------|-----------|---------|
| Next.js + Strapi + Worker stack | ✅ | ✅ | ✅ | PASS |
| SectionRenderer style switch | ✅ | ✅ | ❌ | PASS (2/3) |
| child sites fork via git merge | ✅ | ❌ | ✅ | PASS (2/3) |
| ISR 15-second revalidation | ❌ | ❌ | ❌ | FAIL — doc gap |

### Doc Improvement Targets
- ISR revalidation interval not discoverable from architecture docs (0/3)
- no test coverage threshold or CI gate documented (0/3)
- human contributor process not defined in docs (0/3)
```
