# Stage 04: Post (inline)

emitted from here.

## Inputs
- `.procedure-output/double-check/01-setup/handoff.md` — PR metadata, URL, branches, PR body
- `.procedure-output/double-check/02-review/handoff.md` — verdict, curated findings, new issues
- `.procedure-output/double-check/03-fix/handoff.md` — fixes applied, tests, push (absent if stage 03 skipped)

## Task
Post the curated review comment, apply the `double-checked` label, write the local report file,
and emit the outcome marker. NO Quest — the report is a local file only.

## Steps

```bash
export PR={PR}
export REPO={REPO}
PR_TITLE={from setup handoff}
PR_BRANCH={from setup handoff}
BASE_BRANCH={from setup handoff}
PR_URL={from setup handoff}
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

### Apply the double-checked label

Only after the comment posts successfully:

```bash
# Create label if it doesn't exist
gh label create "double-checked" --repo $REPO --color "0075ca" --description "Double-checked by agent" 2>/dev/null || true

# Apply the label — signals the review is complete and visible
gh pr edit $PR --repo $REPO --add-label "double-checked"
```

This label triggers the `cto-review-on-double-checked` event rule in event-rules.yml.

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

Emit from the orchestrator (never a subagent):

```
```

If the comment or label step failed, emit `status=failed` with the reason instead.

## Success criteria
- Curated review comment posted
- `double-checked` label applied (after the comment)
- Report file written to `reports/`
- NO Quest POST anywhere

## Failure
- Comment post fails → emit `status=failed`, do NOT apply the label
- Label apply fails → log it, report file still written, emit `status=failed` with reason
