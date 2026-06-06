# Local Report-File Format (verbatim from cto-review)

Write the report to the commander reports directory. Lifted verbatim from the original `cto-review`
skill. This is the ONLY reporting step — there is no Quest POST.

```bash
REPORT_PATH="$PYLOT_DIR/reports/$(date +%Y-%m-%d)-cto-review-$(echo $REPO | tr '/' '-')-pr$PR.md"
```

(If `$PYLOT_DIR` is unset, use `$(git rev-parse --show-toplevel)` as the repo root.)

Report format:

```markdown
# CTO Review: $REPO PR #$PR — $PR_TITLE

**Date:** YYYY-MM-DD
**Repo:** $REPO
**PR:** [$REPO#$PR]($PR_URL) — $PR_TITLE
**Branch:** `$HEAD` -> `$BASE`
**Labels:** $LABELS

---

## Verdict

[verdict text]

---

## CTO Checklist

[full checklist output]

---

## Action Items Before Merge

[action items or "None"]

---

## Review Comment

Posted at: [comment URL]
```

Reporting ends here. Operators surface this file via the mission report. Do NOT POST it anywhere.
