# Stage 02: Post (inline)

## Inputs
- `.procedure-output/review-pr/00-context/handoff.md` (PR metadata: title, branches, sizes, URL)
- `.procedure-output/review-pr/01-cohesive-review/handoff.md` (summary, findings, convention
  compliance, Closes-vs-Refs, verdict)
- PR number + `org/repo`

## Task
Post the structured review comment, apply the `security` label if warranted (security-class
findings or new auth surface), apply the deterministic `lane:*` label, apply the `reviewed` label
LAST, and write the local report file.
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
**Head reviewed:** `$HEAD_SHA`
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

REVIEW_EOF
)"
```

**Comment rules:**
- Always include the Summary — even if no findings, the summary helps the double-checker
- The `**Head reviewed:**` line always carries the full 40-hex head — it is the receipt the
  dedup gate and downstream stages compare against the current head
- Empty findings table → write "No issues found above confidence threshold"
- Never write findings below 80 confidence — they are noise
- Location must reference file path and line numbers from the diff
- Verdict is always "proceed to double-check" — this skill never blocks

> **Label ORDER is load-bearing (#2996).** `reviewed` is the TRIGGER label — the automations that
> react to it read the PR's label set as it appears in the `pull_request.labeled` webhook payload,
> which is a snapshot at delivery time. Any label that a rule needs to see must therefore be on the
> PR *before* `reviewed` is applied. So: **Step 2 (`security`) → Step 2.5 (`lane:*`) → Step 3
> (`reviewed`, LAST).** Applying `reviewed` first re-opens the exact race #2996 exists to close: the
> `reviewed` event would carry no lane label, `review-pr-on-reviewed` would not be excluded, and a
> fast-lane PR would silently pay for a double-check + staging deploy anyway.

### Step 2: Apply security Label (deterministic — #2918)

The `security` label is a machine-readable hold signal consumed by cto-review's merge gate.
Apply it NOW, in the same mission as the review, so the gate is set before any merge attempt.

Read from the handoffs:
- `auth_surface` field from stage 00 handoff (`new-auth-surface` or `none`)
- `has_security_findings` from stage 01 handoff (`true` or `false`)

```bash
AUTH_SURFACE=$(grep -m1 'auth_surface:' .procedure-output/review-pr/00-context/handoff.md | awk '{print $3}' || echo "none")
HAS_SEC=$(grep -m1 'has_security_findings:' .procedure-output/review-pr/01-cohesive-review/handoff.md | awk '{print $3}' || echo "false")

APPLY_SECURITY="false"
if [ "$AUTH_SURFACE" = "new-auth-surface" ] || [ "$HAS_SEC" = "true" ]; then
  APPLY_SECURITY="true"
fi

if [ "$APPLY_SECURITY" = "true" ]; then
  gh label create "security" --repo $REPO --color "e11d48" --description "Security-sensitive — requires owner review before merge" 2>/dev/null || true
  gh pr edit $PR --repo $REPO --add-label "security"
  echo "[review-pr] security label applied (auth_surface=$AUTH_SURFACE, has_security_findings=$HAS_SEC)"
else
  echo "[review-pr] security label NOT applied (auth_surface=$AUTH_SURFACE, has_security_findings=$HAS_SEC)"
fi
```

**Rules:**
- Apply `security` if ANY finding is security-class (auth/privilege/IDOR/injection) — even if the
  overall verdict is "clean" after disproof (a surviving IDOR finding is a hard trigger).
- Apply `security` if `auth_surface: new-auth-surface` (PR touches `route-capability.mts` or
  `modules/auth/`) — even with zero findings. New auth surface is owner-gated by default.
- Do NOT apply `security` for non-auth findings (perf, docs, style, etc.).
- The `security` label does NOT change the review-pr outcome — proceed to double-check as normal.
- The cto-review merge gate reads the label at merge time; this step is just the setter.
- `APPLY_SECURITY` is consumed by Step 2.5 — it is an INPUT to the lane classifier, so this step
  must stay ahead of it.

### Step 2.5: Lane labels RETIRED (owner ruling 2026-09-06)

The #2996 lane machinery is retired: per-PR flowchad and test-in-staging no longer run
(automations disabled), every PR follows one pipeline — review-pr → double-check → cto-review —
and staging testing is mandatory per RELEASE TRAIN instead (pylot#3389).

**Do NOT apply, remove, or reason about `lane:*` labels.** Do not run
`classify-pr-surface.mts --lane`. A `lane:*` label already present on an older PR is legacy
context: leave it in place, never wait on it. Set `LANE="n/a"` for the handoff and move on:

```bash
LANE="n/a"
echo "[review-pr] lane labels retired (owner ruling 2026-09-06) — none applied"
```

### Step 3: Apply reviewed Label — LAST

Only AFTER the comment posts successfully **and** after Steps 2 and 2.5 have applied their labels.

```bash
REVIEW_RUN=$(grep -m1 'review_run:' .procedure-output/review-pr/00-context/handoff.md | awk '{print $3}' || echo "fresh")
if [ "$REVIEW_RUN" = "stale-refresh" ]; then
  gh pr edit $PR --repo $REPO --remove-label "reviewed" 2>/dev/null || true
fi
gh label create "reviewed" --repo $REPO --color "bfd4f2" --description "First-pass review complete" 2>/dev/null || true
gh pr edit $PR --repo $REPO --add-label "reviewed"
```

This label is the pipeline TRIGGER. Which rule it fires now depends on the lane label already on
the PR:

| labels at this moment | rule that fires | pipeline |
|---|---|---|
| `lane:fast` + `reviewed` | `cto-review-on-reviewed-fast` | review → cto-review (merge authority) |
| `lane:staging` + `reviewed` | `review-pr-on-reviewed` | double-check → flowchad → test-in-staging → cto-review |
| no lane label + `reviewed` | `review-pr-on-reviewed` | pre-#2996 behaviour (fail-closed default) |

Never apply `double-checked` — that's a different skill entirely.

On `stale-refresh`, removing then re-adding `reviewed` is intentional: the new receipt now binds
the review to current HEAD, and the re-add emits the downstream event. Do not remove the label
earlier; a failed comment or prerequisite-label step must leave the previous pipeline state intact.

### Step 4: Write Report (local file only — NO Quest)

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

## Lane

`lane:{fast|staging|n/a}` — {the classifier's first stderr reason, verbatim}

## Verdict

[Clean / N findings — handed off to {double-check (lane:staging) | cto-review (lane:fast)}]
```

Write the report file and stop. Do NOT POST anywhere — operators surface the report via the mission
report. (There is no Quest step.)

### Step 5: Emit outcome marker (orchestrator, inline)

```bash
echo "[pylot] outcome=\"review-pr complete — reviewed label applied, lane:$LANE\" status=success"
```

## Output: handoff.md

Path: `.procedure-output/review-pr/02-post/handoff.md`

```markdown
# Stage 02: Post

## Status
Posted

## Actions taken
- Review comment posted to $PR_URL
- `security` label applied: {yes — reason: auth_surface|security_findings | no}
- `lane` label applied: {lane:fast | lane:staging | none — repo not lane-enabled}
- lane reason: {classifier's first stderr reason, verbatim | "repo not lane-enabled"}
- `reviewed` label applied (LAST, after security + lane)
- Report written to {REPORT_FILE}

## Outcome
[pylot:$PYLOT_OUTCOME_NONCE] outcome="review-pr complete — reviewed label applied, lane:{fast|staging|n/a}" status=success
```

## Success criteria
- Review comment posted (Summary always present)
- `security` label applied if auth-surface or security-class findings detected
- Exactly one `lane:*` label applied on a lane-enabled repo, or none at all on a repo that is not
  lane-enabled — never both, never a lane other than `fast`/`staging`
- `reviewed` label applied AFTER the comment posted **and after the security + lane labels**
  (the ordering is what makes the lane gate work — see the note above Step 2)
- `double-checked` label NOT applied
- Local report file written; NO Quest POST performed
- `[pylot] outcome=...` marker emitted from the orchestrator

## Failure
- Comment post fails → do NOT apply the label; emit
  `[pylot:$PYLOT_OUTCOME_NONCE] outcome="review-pr failed at stage 02: comment post failed" status=failed`
- Lane classification fails (classifier missing, crash, empty output) → this is NOT a stage
  failure. Apply `lane:staging` and continue; the PR takes the pre-#2996 pipeline, which is
  correct-but-slow. Record the reason in the handoff.
