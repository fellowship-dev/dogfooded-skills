# Stage 02: Post (inline)

## Inputs
- `.procedure-output/review-pr/00-context/handoff.md` (PR metadata: title, branches, sizes, URL)
- `.procedure-output/review-pr/01-cohesive-review/handoff.md` (summary, findings, convention
  compliance, Closes-vs-Refs, verdict)
- PR number + `org/repo`

## Task
Post the structured review comment, apply the `reviewed` label, and write the local report file.
This stage runs inline in the orchestrator — do NOT spawn a Task. It is the only side-effecting
stage. The `[pylot] outcome=...` marker MUST come from the orchestrator here, never from a
subagent. NO Quest — write the local report file only.

## Steps

### Step 1: Post Review Comment

Fill the body from the stage 00 + stage 01 handoffs (Summary, Findings table, Convention
Compliance, Closes vs Refs, Verdict).

```bash
gh pr comment $PR --repo $REPO --body "$(cat <<'REVIEW_EOF'
## PR Review: $REPO#$PR — $PR_TITLE

**Branch:** `$PR_BRANCH` → `$BASE_BRANCH`
**Size:** +$ADDITIONS / -$DELETIONS across $FILE_COUNT files

### Summary
[2-3 sentences: what this PR does, what problem it solves, and whether the approach is sound]

### Findings

| # | Severity | Location | Finding | Confidence |
|---|----------|----------|---------|------------|
| 1 | 🔴 Bug | `path/file.ts#L67-72` | [description] | 95 |
| 2 | 🟡 Warning | `path/other.ts#L23` | [description] | 85 |
| 3 | ℹ️ Info | `path/util.ts#L45` | [description] | 80 |

[If no findings ≥ 80 confidence: "No issues found above confidence threshold."]

### Convention Compliance
[Findings from CLAUDE.md — or "No CLAUDE.md found" / "All conventions followed"]

### Closes vs Refs
[Result of mandatory check — or "No Closes keywords found"]

### Verdict
[Clean — proceed to double-check / {N} findings to address — proceed to double-check]

<!-- review-state v1
{REVIEW_STATE_JSON}
-->

REVIEW_EOF
)"
```

**Building `REVIEW_STATE_JSON` (#2210):** one minified-ish JSON object assembled from the two
handoffs — this is the machine ledger double-check and cto-review extend instead of re-deriving
everything cold. Shape:

```json
{
  "v": 1,
  "stage": "review-pr",
  "head_sha": "{from stage 00 Risk Tier section}",
  "tier": "{HIGH|MEDIUM|LOW — the FINAL tier (post-escalation if stage 01 escalated)}",
  "tier_reasons": ["{reason}", "..."],
  "findings": [
    {"id": "R1", "severity": "bug", "loc": "path/file.ts#L67-72", "desc": "{short}", "confidence": 95, "status": "open"}
  ],
  "verified": [
    {"what": "whole diff, cross-file cohesion", "how": "read", "by": "review-pr"},
    {"what": "runtime-shape checklist 1-5", "how": "read", "by": "review-pr"}
  ]
}
```

All findings start `"status": "open"`. Keep `desc` to one sentence — the human table above carries
the detail. Valid JSON is a hard requirement (downstream stages parse it); if in doubt, validate
with `jq . <<< "$REVIEW_STATE_JSON"` before posting.

**Comment rules:**
- Always include the Summary — even if no findings, the summary helps the double-checker
- Empty findings table → write "No issues found above confidence threshold" (and `"findings": []`
  in the state block — the block itself is ALWAYS present)
- Never write findings below 80 confidence — they are noise
- Location must reference file path and line numbers from the diff
- Verdict is always "proceed to double-check" — this skill never blocks

### Step 2: Apply reviewed Label

Only AFTER the comment posts successfully.

```bash
gh label create "reviewed" --repo $REPO --color "bfd4f2" --description "First-pass review complete" 2>/dev/null || true
gh pr edit $PR --repo $REPO --add-label "reviewed"
```

This label triggers the `review-pr-on-reviewed` event rule, which dispatches double-check. Never
apply `double-checked` — that's a different skill entirely.

### Step 3: Write Report (local file only — NO Quest)

```bash
REPORT_FILE="reports/$(date +%Y-%m-%d)-review-$(echo $REPO | tr '/' '-')-pr$PR.md"
```

Report format:
```markdown
# Review: $REPO PR #$PR — $PR_TITLE

**Date:** YYYY-MM-DD
**Repo:** $REPO
**PR:** [$REPO#$PR]($PR_URL)
**Branch:** `$PR_BRANCH` → `$BASE_BRANCH`
**Size:** +$ADDITIONS / -$DELETIONS across $FILE_COUNT files

## Summary

[What this PR does and why]

## Findings

[Findings table or "No issues found"]

## Convention Compliance

[CLAUDE.md check results]

## Verdict

[Clean / N findings — handed off to double-check]
```

Write the report file and stop. Do NOT POST anywhere — operators surface the report via the mission
report. (There is no Quest step.)

### Step 4: Emit outcome marker (orchestrator, inline)

```bash
echo "[pylot] outcome=\"review-pr complete — reviewed label applied\" status=success"
```

## Output: handoff.md

Path: `.procedure-output/review-pr/02-post/handoff.md`

```markdown
# Stage 02: Post

## Status
Posted

## Actions taken
- Review comment posted to $PR_URL
- `reviewed` label applied
- Report written to {REPORT_FILE}

## Outcome
[pylot] outcome="review-pr complete — reviewed label applied" status=success
```

## Success criteria
- Review comment posted (Summary always present)
- `reviewed` label applied AFTER the comment posted
- `double-checked` label NOT applied
- Local report file written; NO Quest POST performed
- `[pylot] outcome=...` marker emitted from the orchestrator

## Failure
- Comment post fails → do NOT apply the label; emit
  `[pylot] outcome="review-pr failed at stage 02: comment post failed" status=failed`
