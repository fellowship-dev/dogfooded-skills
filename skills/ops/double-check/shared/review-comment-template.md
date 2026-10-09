# Curated PR Review Comment Template

Used by stage 04 to post the double-check review as a PR comment. Lifted verbatim from the
original `double-check` skill (Step 7).

```bash
gh pr comment $PR --repo $REPO --body "$(cat <<'REVIEW_EOF'
## Double-Check Review: PR #$PR — $PR_TITLE

**Reviewer:** Automated double-check
**Branch:** `$PR_BRANCH` → `$BASE_BRANCH`
**Head reviewed:** `$LIVE_HEAD_SHA` (exact 40-character SHA)
**Patch-id:** `$LIVE_PATCH_ID` (`git diff base...head | git patch-id --verbatim`; the stage-04 marker
records it as `patch_id=` so a rebase carries the verdict)

---

### Intent
[1-2 sentences: does the PR deliver what it's supposed to?]

[Only if stage 02 recorded a body_note: "Note: the PR body is stale against the diff — <note>.
Not a blocker."]

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
- Zero open MUST-FIX code items means "Ready for CTO review". A stale PR body is at most the
  one-line note above and never a remaining item.
- If no CI findings exist: write "No CI review comments found — reviewed diff directly"
- If tests were not run: name the owning contract, scope and matching reused receipts or precise execution gap. Dependencies/lockfiles are not automatically exempt; non-runtime classifications need their required static/policy checks.
- Verdict must be specific: either "ready for CTO review" or list what still needs work
