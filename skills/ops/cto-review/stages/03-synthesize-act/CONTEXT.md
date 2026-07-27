# Stage 03: Synthesize & Act (inline — orchestrator only)

## Inputs
- `.procedure-output/cto-review/01-setup/handoff.md`
- `.procedure-output/cto-review/02-review/handoff.md` (absent only on the short-circuit path)

## Task
Take action on the verdict: post the formatted GH review comment, apply the verdict label, merge or
label honoring merge state and CI, write the local report file, and emit the outcome marker. This
stage runs inline in the orchestrator — do NOT spawn a Task. All GH side effects and the
`[pylot] outcome=...` marker MUST originate here.

## Merge-state branching (decide FIRST, from stage 01 `merge_state`)

- **`closed-no-merge`** (short-circuit; stage 02 was skipped):
  Post nothing, label nothing, merge nothing. Write a one-line report noting the PR was closed
  without merge. Emit:
  ```
  [pylot] outcome="cto-review skipped: PR #{N} closed without merge" status=success
  ```
  STOP. (A closed-without-merge PR is a normal terminal state — not a blocker requiring human
  intervention. `status=blocked` would trigger an unnecessary escalation to the human operator.)

- **`merged`** (already merged):
  Post the review as a **post-merge note** (Step 1). Apply the verdict label (Step 2). Do NOT
  attempt any merge in Step 3 — skip merge entirely. Write the report (Step 4). Emit success with
  `action=post-merge-note`.

- **`open`**: full path — Steps 1-4 below, then emit success.

## Steps

### Step 1: Post the review comment
Use the exact template in `shared/review-comment-format.md`. Populate from the stage 01 and stage 02
handoffs:
```bash
gh pr comment $PR --repo $REPO --body "$(cat <<'COMMENT_EOF'
# CTO Review: $REPO PR #$PR — $PR_TITLE
... (see shared/review-comment-format.md — verbatim) ...

<!-- review-state v1
{REVIEW_STATE_JSON}
-->
COMMENT_EOF
)"
```
For `merge_state: merged`, prefix the verdict line to make clear it is a post-merge note.
Capture the returned comment URL for the report.

**Finalizing `REVIEW_STATE_JSON` (#2210):** take the incoming state from the setup handoff's
`## Review State` (or a fresh `{"v":1,"findings":[]}` if `none`), set `"stage": "cto-review"`,
update finding statuses per stage 02's Ledger Reconciliation (a REWORK verdict leaves its driving
findings `open`; LGTM with dismissals records the dismissal reasons in `note`), and append
`verified` entries for the dimensions this review covered. Validate with `jq .` before posting —
the block is the pipeline's permanent audit trail (close-audit and re-checks read it).

### Step 2: Apply the verdict label
```bash
gh label create "approved" --repo $REPO --color "0e8a16" --description "CTO approved — ready to merge" 2>/dev/null || true
gh label create "needs-work" --repo $REPO --color "d93f0b" --description "Needs work before merge" 2>/dev/null || true

if [[ "$VERDICT" == "merge" ]]; then
  gh pr edit $PR --repo $REPO --add-label "approved"
elif [[ "$VERDICT" == "hold" || "$VERDICT" == "sendback" ]]; then
  gh pr edit $PR --repo $REPO --add-label "needs-work"
fi
```

### Step 3: Merge or label (OPEN PRs only — skip entirely if merge_state is `merged`)
Only proceed to a merge if ALL hold:
1. Stage 02 `merge_decision` is `merge` (verdict LGTM / "merge immediately").
2. Required labels present (`reviewed`, `double-checked`).
3. CI is green.

```bash
# Verify CI is green
gh pr checks $PR --repo $REPO

# Verify required labels
gh pr view $PR --repo $REPO --json labels --jq '.labels[].name'
```
**If the branch is CONFLICTING with base** (`gh pr view $PR --json mergeable`): a
conflict is NOT a hold reason — finish it now, in this order:

1. **Superseded check first.** On agent-driven repos the usual cause is a competing
   PR for the same issue that already merged. Compare base's current version of the
   conflicted files against this PR's changes (`gh pr list --state merged --search
   "<issue#>"`, then read both implementations). If base already contains an
   equivalent implementation → **close the PR** with evidence naming the merged PR
   and what was compared. Action: `closed-superseded`.
2. **Otherwise rebase and resolve semantically.** `gh pr checkout $PR && git fetch
   origin $BASE && git rebase origin/$BASE` — read both sides of each conflict,
   write the resolution that preserves both intents, verify zero leftover conflict
   markers AND the repo's test gate passes, then `git push --force-with-lease`.
   Your LGTM verdict already covers the content; the rebase only replays it onto
   current base. Then merge below.
3. If the two sides genuinely contradict and the issue doesn't say which behavior
   wins: comment the specific one-sentence decision needed, apply `blocked`. This
   is the only legitimate non-merge outcome for a conflict, and it must name a
   human-decidable question.

Use the `merge_strategy` resolved in stage 01:
```bash
if [ "$MERGE_STRATEGY" = "label-only" ]; then
  # Team requires human merge — label instead
  gh label create "ready-to-merge" --repo $REPO --color "0e8a16" --description "Agent-verified, Max merges" 2>/dev/null || true
  gh pr edit $PR --repo $REPO --add-label "ready-to-merge"
  echo "Labeled ready-to-merge (merge_strategy: label-only)"
else
  # Default: auto-merge
  gh pr merge $PR --repo $REPO --merge
fi
```
If CI is failing: do NOT merge — the verdict should already be hold; note the CI failure in the
comment if not already noted. Record the action taken: `merged` | `labeled` | `closed-superseded` | `held` (CI-red only — never for a conflict).

### Step 4: Write the report file (local only — NO Quest)
Use the template in `shared/report-format.md`:
```bash
REPORT_PATH="$PYLOT_DIR/reports/$(date +%Y-%m-%d)-cto-review-$(echo $REPO | tr '/' '-')-pr$PR.md"
```
(If `$PYLOT_DIR` is unset, use `$(git rev-parse --show-toplevel)/reports`.) Write the verdict, full
checklist, action items, and the posted comment URL into the file. There is NO Quest POST — the
report ends at the file write; operators surface it via the mission report.

### Step 5: Emit the outcome marker (orchestrator only)
```
[pylot] outcome="cto-review PR #{N} complete — verdict={verdict}, action={merged|labeled|closed-superseded|held|post-merge-note}" status=success
```
On the closed-no-merge short-circuit, emit the `status=blocked` marker shown above instead.
If a side effect failed hard (comment post errored), emit:
```
[pylot] outcome="cto-review failed at stage 03: {reason}" status=failed
```

## Output: handoff.md

Path: `.procedure-output/cto-review/03-synthesize-act/handoff.md`

```markdown
# Stage 03: Synthesize & Act

## Actions Taken
- merge_state: {open | merged | closed-no-merge}
- comment_posted: {url or "skipped (closed-no-merge)"}
- label_applied: {approved | needs-work | ready-to-merge | none}
- merge_action: {merged | labeled-ready-to-merge | closed-superseded | held (CI-red only) | skipped (already merged) | skipped (closed)}
- report_path: {path}

## Outcome
{the emitted [pylot] outcome marker, verbatim}
```

## Success criteria
- Comment posted (unless closed-no-merge), label applied per verdict, merge/label honoring merge
  state and CI, report file written (no Quest), outcome marker emitted from the orchestrator.

## Failure
- Comment post or label edit errors → emit the stage-03 failure marker; still write whatever report
  is possible (marker is the primary signal).
