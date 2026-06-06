# GH Review Comment Format (verbatim from cto-review)

Post the CTO review as a PR comment in the exact format below. Lifted verbatim from the original
`cto-review` skill — do not alter the structure.

```bash
gh pr comment $PR --repo $REPO --body "$(cat <<'COMMENT_EOF'
# CTO Review: $REPO PR #$PR — $PR_TITLE

**Date:** $(date +%Y-%m-%d)
**Repo:** $REPO
**PR:** [$REPO#$PR]($PR_URL) — $PR_TITLE
**Branch:** `$HEAD_BRANCH` → `$BASE_BRANCH`
**Labels:** $CURRENT_LABELS

---

## Verdict

**[VERDICT_EMOJI] [VERDICT_TEXT]**

---

## CTO Checklist

### Documentation
| Check | Status |
|-------|--------|
| [check_name] | [✅ description / ❌ what's missing] |

### External Dependencies
- [dep_finding_1]
- [dep_finding_2]
- _None_ (if no external deps)

### Downstream Impact
- **[repo_1], [repo_2]** — [impact description]
- All changes are **opt-in** / **breaking** — [details]

### Merge Strategy
- [VERDICT_EMOJI] [Merge immediately / Hold — pending N items / Send back — reason]

### Process Verification
| Check | Status |
|-------|--------|
| Related code searched | [✅ evidence found / ❌ no evidence / N/A] |
| Docs updated | [✅ / ❌ what is missing] |
| Merge strategy | [Direct merge / Release train — reason] |
| FlowChad flows affected | [✅ none / ⚠️ re-run flowchad-runner post-merge / N/A] |
| Production impact assessed | [✅ low risk / ⚠️ requires careful deploy / N/A] |

---

## Action Items Before Merge

[1. **`path/to/file`** — specific change needed]
[2. **`path/to/file`** — specific change needed]

_None — ready to merge_ (if no items)

COMMENT_EOF
)"
```

**Format rules (match the reference report exactly):**
- Header: `# CTO Review: {REPO} PR #{N} — {TITLE}`
- Verdict section: bold emoji + text
- Documentation: table with Check | Status columns
- Status values: `✅ description` or `❌ what's missing`
- Action items: numbered, `**path**` bold, then dash + description
- No trailing whitespace in table cells

## Verdict Reference

| Verdict | Emoji | Label | Merge? |
|---------|-------|-------|--------|
| LGTM | ✅ | `approved` | Yes |
| REWORK | 🔄 | `needs-work` | No |
| BLOCKED | ⏸️ | `needs-work` | No |
| NEW_ISSUE | 📋 | — | Approve PR on its own merits, create separate issue |
