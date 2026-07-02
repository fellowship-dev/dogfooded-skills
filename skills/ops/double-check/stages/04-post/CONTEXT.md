# Stage 04: Post (inline)

Runs inline in the orchestrator — do NOT spawn a Task. The `[pylot] outcome=...` marker MUST be
emitted from here.

## Inputs
- `.procedure-output/double-check/01-setup/handoff.md` — PR metadata, URL, branches, PR body, **labels**
- `.procedure-output/double-check/02-review/handoff.md` — verdict, curated findings, new issues
- `.procedure-output/double-check/03-fix/handoff.md` — fixes applied, tests, push (absent if stage 03 skipped)

## Task
Detect whether this is a re-check run (PR has `needs-work`), post the curated review comment,
apply labels to close the pipeline loop (re-check path) or signal completion (first-check path),
write the local report file, and emit the outcome marker. NO Quest — the report is a local file only.

## Steps

```bash
export PR={PR}
export REPO={REPO}
PR_TITLE={from setup handoff}
PR_BRANCH={from setup handoff}
BASE_BRANCH={from setup handoff}
PR_URL={from setup handoff}
```

### Detect re-check context

Read the `## PR / Labels` field from `.procedure-output/double-check/01-setup/handoff.md`.
If the labels list contains `needs-work`, this is a re-check run.

```bash
SETUP_HANDOFF=".procedure-output/double-check/01-setup/handoff.md"
REVIEW_HANDOFF=".procedure-output/double-check/02-review/handoff.md"

# Extract labels line from setup handoff (format: "- Labels: label1, label2" or "- Labels: none")
LABELS_LINE=$(grep "^- Labels:" "$SETUP_HANDOFF" | head -1)

IS_RECHECK=false
if echo "$LABELS_LINE" | grep -q "needs-work"; then
  IS_RECHECK=true
fi

# Extract verdict from review handoff (format: "verdict: ready" or "verdict: needs-work")
VERDICT=$(grep "^verdict:" "$REVIEW_HANDOFF" | head -1 | awk '{print $2}')
```

### Post the curated review comment

Fill `shared/review-comment-template.md` from the stage-02 (curated findings, new issues, verdict)
and stage-03 (tests, fixes) handoffs, then post:

```bash
gh pr comment $PR --repo $REPO --body "$(cat <<'REVIEW_EOF'
## Double-Check Review: PR #$PR — $PR_TITLE

**Reviewer:** Automated double-check
**Branch:** `$PR_BRANCH` → `$BASE_BRANCH`

---

### Intent
[1-2 sentences: does the PR deliver what it's supposed to?]

### Implementation
[2-4 bullets: key approach, files changed grouped by area]

### Curated CI Findings

| # | Finding | Verdict | Fixed? | Reason |
|---|---------|---------|--------|--------|
| 1 | [description] | MUST FIX | Yes/No | [why, what was done] |
| 2 | [description] | NICE TO HAVE | Yes/No | [why] |
| 3 | [description] | DISCARD | — | [why it's irrelevant] |

### New Issues (not caught by CI)
| # | Issue | Fixed? | Details |
|---|-------|--------|---------|
| 1 | [description] | Yes/No | [what was done] |

### Tests After Fixes
- **Suite:** [pass (N/N) / fail — details / not run — reason]
- **Regressions:** [none / list any]

### Verdict
[Ready for CTO review / Needs more work — list remaining items]

REVIEW_EOF
)"
```

**Rules:**
- If no CI findings exist: write "No CI review comments found — reviewed diff directly"
- If tests weren't run: explain why (e.g., "deps-only change, no test suite applicable")
- Verdict must be specific: either "ready for CTO review" or list what still needs work
- If stage 03 was skipped (`fixes_needed: false`): mark all "Fixed?" cells "No (no fix needed)"

### Apply labels (re-check vs first-check)

Only after the review comment posts successfully.

**Three branches — run the matching one based on IS_RECHECK and VERDICT:**

---

#### Branch A — Re-check PASS (IS_RECHECK=true AND verdict=ready)

Remove `needs-work` and re-toggle `double-checked` so `pull_request.labeled` fires and
`cto-review-on-double-checked` re-dispatches automatically.

**Loop-break guarantee**: `needs-work` is removed in Step 1, BEFORE `double-checked` is
re-added in Step 3. cto-review therefore runs on a PR with no `needs-work` label and does
NOT re-trigger double-check directly. If cto-review subsequently fails, it re-adds `needs-work`
— starting a new rework cycle that requires fresh developer action.

```bash
# Branch A: re-check PASS
echo "[stage-04] re-check PASS — removing needs-work, re-toggling double-checked"

# Step 1: remove needs-work (clears the rework signal — MUST happen before step 3)
gh pr edit $PR --repo $REPO --remove-label "needs-work" 2>/dev/null || true

# Step 2: remove double-checked so re-add fires a fresh pull_request.labeled event
gh pr edit $PR --repo $REPO --remove-label "double-checked" 2>/dev/null || true

# Step 3: re-add double-checked → fires pull_request.labeled → cto-review-on-double-checked
gh label create "double-checked" --repo $REPO --color "0075ca" \
  --description "Double-checked by agent" 2>/dev/null || true
gh pr edit $PR --repo $REPO --add-label "double-checked"

echo "[stage-04] loop closed — cto-review will re-fire via pull_request.labeled"
```

---

#### Branch B — Re-check FAIL (IS_RECHECK=true AND verdict=needs-work)

Leave `needs-work` in place. Do NOT re-toggle `double-checked` (cto-review must NOT fire while
work remains). Post a structured verdict comment guarded by a stable HTML marker so retries
never duplicate the comment.

```bash
# Branch B: re-check FAIL
echo "[stage-04] re-check FAIL — retaining needs-work, posting structured verdict"

# Idempotency guard: skip post if a recheck-fail comment already exists on this PR
EXISTING_MARKER=$(gh pr view $PR --repo $REPO --json comments \
  --jq '.comments[].body | select(contains("pylot:recheck-fail"))' 2>/dev/null | head -1)

if [ -z "$EXISTING_MARKER" ]; then
  # Extract remaining items from stage-02 handoff Fix List / Verdict section
  REMAINING=$(awk '/^## Fix List/,/^## Verdict/' "$REVIEW_HANDOFF" | grep "^[0-9]\." | head -10)
  if [ -z "$REMAINING" ]; then
    REMAINING=$(grep -A5 "^## Verdict" "$REVIEW_HANDOFF" | tail -n +2 | head -5)
  fi

  gh pr comment $PR --repo $REPO --body "$(cat <<FAIL_EOF
<!-- pylot:recheck-fail pr=$PR repo=$REPO -->
## Re-check Result: Still Needs Work

**PR:** $REPO#$PR — $PR_TITLE
**Re-check verdict:** needs more work

### Remaining items
$REMAINING

### What to do
1. Address the items above.
2. Push your fixes.
3. Remove and re-add the \`double-checked\` label to re-trigger this re-check.
FAIL_EOF
)"
  echo "[stage-04] structured verdict comment posted"
else
  echo "[stage-04] recheck-fail marker already present — skipping duplicate comment"
fi
# IMPORTANT: do NOT touch double-checked — cto-review must not fire on re-check FAIL
```

---

#### Branch C — First-check (IS_RECHECK=false, any verdict)

Existing behavior unchanged: apply `double-checked` label. cto-review handles verdict routing.

```bash
# Branch C: first-check
echo "[stage-04] first-check — applying double-checked label"
gh label create "double-checked" --repo $REPO --color "0075ca" \
  --description "Double-checked by agent" 2>/dev/null || true
gh pr edit $PR --repo $REPO --add-label "double-checked"
```

---

### Write the report file

```bash
REPORT_FILE="reports/$(date +%Y-%m-%d)-review-$(echo $REPO | tr '/' '-')-pr$PR.md"
```

Fill `shared/report-template.md` and write it to `REPORT_FILE`. For Pylot/crew runs the report
goes to `$(git rev-parse --show-toplevel)/reports/`. Operators surface this file via the mission
report.

**NO Quest.** Do NOT POST to any Quest endpoint, `127.0.0.1:4242`, or `quest.fellowship.dev`, and
do NOT read `QUEST_TOKEN`. The local report file is the only report sink.

### Emit outcome marker

Emit from the orchestrator (never a subagent). Branch on re-check context:

**Re-check PASS** (IS_RECHECK=true, verdict=ready):
```
[pylot] outcome="double-checked re-check PASS {repo}#{pr} — loop closed, cto-review re-fired" status=success
```

**Re-check FAIL** (IS_RECHECK=true, verdict=needs-work):
```
[pylot] outcome="double-checked re-check FAIL {repo}#{pr} — needs-work retained" status=success
```

**First-check** (IS_RECHECK=false, any verdict):
```
[pylot] outcome="double-checked {repo}#{pr} — verdict {ready|needs-work}, {N} findings curated, {N} fixes pushed" status=success
```

If any step failed, emit `status=failed` with the reason instead.

## Success criteria
- Curated review comment posted
- Labels applied per the branch above (re-check PASS: needs-work removed + double-checked re-toggled;
  re-check FAIL: no label change + structured verdict comment posted; first-check: double-checked applied)
- Report file written to `reports/`
- NO Quest POST anywhere
- `[pylot] outcome=...` marker emitted from the orchestrator

## Failure
- Comment post fails → emit `status=failed`, do NOT apply labels
- Label apply fails → log it, report file still written, emit `status=failed` with reason
- Re-check FAIL comment post fails → emit `status=failed` (idempotency guard means next retry is safe)
