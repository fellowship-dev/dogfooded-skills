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
  Post the review as a **post-merge note** (Step 1). Apply the verdict label (Step 4). Do NOT
  attempt any merge in Step 5 — skip merge entirely. Write the report (Step 6). Emit success with
  `action=post-merge-note`.

- **`open`**: full path — Steps 1-7 below, then emit success.

## Steps

### Step 1: Post the review comment
Use the exact template in `shared/review-comment-format.md`. Populate from the stage 01 and stage 02
handoffs. The comment MUST include a `## Checked / Found` receipts section (see below) — this is
mandatory for every verdict comment, not optional (#2918).

```bash
gh pr comment $PR --repo $REPO --body "$(cat <<'COMMENT_EOF'
# CTO Review: $REPO PR #$PR — $PR_TITLE
... (see shared/review-comment-format.md — verbatim) ...

## Checked / Found
**Labels seen:** {comma-separated list from stage 02 Receipts, or "none"}
**Comments checked:** {N} (last author: {login})
**Blockers found:**
| Blocker | Type | Status |
|---------|------|--------|
| {description} | {label/comment/CI} | {resolved/unresolved/escalated} |
{... or "_No blockers found_"}

{VISUAL_EVIDENCE_NOTICE — omit this line entirely unless stage 01 recorded `notice: yes`}

<!-- review-state v1
{REVIEW_STATE_JSON}
-->
COMMENT_EOF
)"
```
For `merge_state: merged`, prefix the verdict line to make clear it is a post-merge note.
Capture the returned comment URL for the report.

**Visual evidence notice (advisory, never a blocker).** If the stage 01 handoff's
`## Visual Evidence` block says `notice: yes`, append exactly this block in place of the
`{VISUAL_EVIDENCE_NOTICE}` placeholder. If it says `notice: no` or the block is absent, write
nothing there — no empty heading, no "n/a" line.

```
_Advisory — not a merge blocker._ The diff touches a user-facing surface ({trigger}) and the PR
body carries no embedded screenshot. If it renders something a person looks at, `/evidence-upload`
captures and embeds it (capture needs a worker devbox — the operator image has no browser). If
there is genuinely no visual surface, add a level-2 heading reading `Visual` + `Evidence` followed
within 3 lines by `N/A — no user-facing surface` and this line stops appearing.
```

**Do NOT write a literal `Visual Evidence` markdown heading at column 0 anywhere in the comment.**
The step 5.6 comment scan selects comments matching `^#{1,4}\s.*[Vv]isual\s+[Ee]vidence`; a notice
carrying that heading would be read back as evidence on the next run and the check would grade its
own homework. Keep the token split or in prose, exactly as above.

The notice never applies a label, never changes the verdict, and never affects the merge bar in
Step 3.

**Finalizing `REVIEW_STATE_JSON` (#2210):** take the incoming state from the setup handoff's
`## Review State` (or a fresh `{"v":1,"findings":[]}` if `none`), set `"stage": "cto-review"`,
update finding statuses per stage 02's Ledger Reconciliation (a REWORK verdict leaves its driving
findings `open`; LGTM with dismissals records the dismissal reasons in `note`), and append
`verified` entries for the dimensions this review covered. Validate with `jq .` before posting —
the block is the pipeline's permanent audit trail (close-audit and re-checks read it).

### Step 2: Security / Owner Gate — RUNS BEFORE VERDICT LABEL (#2918, #3009)

This gate runs BEFORE the verdict label (Step 4) is applied. When it fires and exits, `needs-work`
is never written to the PR — preventing phantom `rework-on-needs-work` missions on parked PRs.
(#3009 — was Step 3.0, moved here to correct label ordering.)

This check is **deterministic code, not judgement**. It runs immediately before the merge call,
using a FRESH label read from GitHub (not from the stage 01 handoff cache). If the PR carries
`security` OR `waiting-on-owner`, cto-review MUST NOT merge — full stop.

```bash
# Fresh label read at merge time — must NOT use the cached handoff from stage 01
LIVE_LABELS=$(gh pr view $PR --repo $REPO --json labels --jq '[.labels[].name]' 2>/dev/null || echo '[]')
GATE_FIRED=false

if echo "$LIVE_LABELS" | grep -qE '"security"'; then
  GATE_FIRED=true
  GATE_REASON="security"
elif echo "$LIVE_LABELS" | grep -qE '"waiting-on-owner"'; then
  GATE_FIRED=true
  GATE_REASON="waiting-on-owner"
fi

if [ "$GATE_FIRED" = "true" ]; then
  # Ensure waiting-on-owner is applied (it may only be security right now)
  gh label create "waiting-on-owner" --repo $REPO --color "e99695" --description "Waiting for owner decision before merge" 2>/dev/null || true
  gh pr edit $PR --repo $REPO --add-label "waiting-on-owner"

  # Post the park comment — include receipts so the owner has full context
  RECEIPTS=$(grep -A20 '## Receipts' .procedure-output/cto-review/02-review/handoff.md 2>/dev/null \
    | head -20 || echo "Labels seen: $LIVE_LABELS")

  cat > /tmp/cto-owner-gate.md <<PARK_EOF
## cto-review: Parked — Owner Gate (#2918)

This PR carries label(s) **${GATE_REASON}** that require a human decision before automation may merge.

**Why this gate exists:** the \`security\` and \`waiting-on-owner\` labels are explicit holds set by
the pipeline or by a human reviewer to flag that a decision is beyond the automation's jurisdiction.
An LLM reading context cannot override this — the gate is unconditional.

**To unpark:** remove the \`${GATE_REASON}\` label (and \`waiting-on-owner\` if present) after the
human review is complete, then re-trigger cto-review.

${RECEIPTS}
PARK_EOF
  gh pr comment $PR --repo $REPO --body-file /tmp/cto-owner-gate.md

  echo "[cto-review] owner gate fired: $GATE_REASON — PR parked, NOT merged"
  echo "[pylot] outcome=\"cto-review parked: PR #${PR} carries ${GATE_REASON} — owner review required\" status=blocked"
  exit 0
fi
echo "[cto-review] owner gate: CLEAR — labels=$LIVE_LABELS"
```

**Rules that are absolute:**
- This check fires EVEN IF stage 02 gave LGTM verdict — verdict cannot override the gate.
- This check fires EVEN IF the labels were applied by mistake — label removal is the human's action.
- `security` and `waiting-on-owner` are the ONLY two trigger labels; no other label blocks merge.
- The gate reads labels from GitHub live, NOT from the stage 01 handoff. A label applied AFTER
  stage 01 started (e.g. by a concurrent automation) will still trigger the gate.
- `waiting-on-owner` is applied if not already present, so the PR is always clearly parked for
  humans to find via label filter.
- The park comment MUST include the receipts block from stage 02 so the owner has full context.
- After firing, emit `status=blocked` and STOP — no merge, no further steps.
- **The gate is LANE-INDEPENDENT (#2996).** It fires identically on `lane:fast` and `lane:staging`
  and on a PR with no lane label. The fast lane removes double-check and the staging deploy; it
  removes nothing from this gate. A fast-lane PR carrying `security` parks here exactly as it does
  today — that is the #2918 acceptance criterion, replayed.

### Step 3: Resolve the merge bar for this lane (#2996)

The required-label set is the ONLY thing the lane changes. Read the lane from the SAME fresh
`$LIVE_LABELS` string that Step 2 just fetched — never from the stage 01 handoff, and never from
the lane recorded at review time.

```bash
LANE="staging"                                             # default; also covers "no lane label"
echo "$LIVE_LABELS" | grep -qE '"lane:fast"' && LANE="fast"
echo "[cto-review] merge bar lane: $LANE"

case "$LANE" in
  fast)    REQUIRED_LABELS="reviewed" ;;                   # double-check never ran, by design
  *)       REQUIRED_LABELS="reviewed double-checked" ;;
esac

MISSING=""
for l in $REQUIRED_LABELS; do
  echo "$LIVE_LABELS" | grep -qE "\"$l\"" || MISSING="$MISSING $l"
done
echo "[cto-review] required labels ($LANE lane): $REQUIRED_LABELS | missing:${MISSING:- none}"
```

**Why the fast lane drops `double-checked`:** on `lane:fast` the `review-pr-on-reviewed`
automation is suppressed, so double-check is never dispatched and `double-checked` can never
appear. Leaving it in the required set would make every fast-lane PR unmergeable — the merge bar
would be waiting on a mission that the pipeline deliberately did not run. **A missing
`double-checked` on a `lane:fast` PR is the expected state, not a defect. Do not apply
`needs-work` for it, do not comment asking for a double-check, and do not dispatch one.**

**What still guards a fast-lane merge** — name these in the receipts, they are the compensating
controls the owner traded the staging net for:
1. review-pr's findings and the `review-state v1` ledger (still-open findings are verdict inputs).
2. This stage's own cohesive whole-diff judgement.
3. The #2918 owner hard-stop at Step 2 — lane-independent, above.
4. CI green — unchanged, and never merged red (Hard Rule 9).
5. **The in-deploy full corpus gate.** The fast lane skips the *pre-merge staging deploy*; it does
   not touch the release train. `scripts/ci-release-gate.sh` still runs the unscoped corpus before
   anything reaches production, on every train, for every commit that lands on develop. A fast-lane
   merge is a merge to develop, not a deploy to prod.
6. Post-deploy journeys and evals (#2788) as the behavioural net after the fact.

### Step 4: Apply the verdict label
```bash
gh label create "approved" --repo $REPO --color "0e8a16" --description "CTO approved — ready to merge" 2>/dev/null || true
gh label create "needs-work" --repo $REPO --color "d93f0b" --description "Needs work before merge" 2>/dev/null || true

if [[ "$VERDICT" == "merge" ]]; then
  gh pr edit $PR --repo $REPO --add-label "approved"
elif [[ "$VERDICT" == "hold" || "$VERDICT" == "sendback" ]]; then
  gh pr edit $PR --repo $REPO --add-label "needs-work"
fi
```

### Step 5: Merge or label (OPEN PRs only — skip entirely if merge_state is `merged`)

Only proceed to a merge if ALL hold:
1. Stage 02 `merge_decision` is `merge` (verdict LGTM / "merge immediately").
2. `MISSING` is empty — i.e. the lane's required labels from Step 3 are all present.
3. CI is green.
4. Step 2 (owner gate) did NOT fire.

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

### Step 6: Write the report file (local only — NO Quest)
Use the template in `shared/report-format.md`:
```bash
REPORT_PATH="$PYLOT_DIR/reports/$(date +%Y-%m-%d)-cto-review-$(echo $REPO | tr '/' '-')-pr$PR.md"
```
(If `$PYLOT_DIR` is unset, use `$(git rev-parse --show-toplevel)/reports`.) Write the verdict, full
checklist, action items, and the posted comment URL into the file. There is NO Quest POST — the
report ends at the file write; operators surface it via the mission report.

### Step 7: Emit the outcome marker (orchestrator only)
```
[pylot] outcome="cto-review PR #{N} complete — verdict={verdict}, action={merged|labeled|closed-superseded|held|post-merge-note}" status=success
```
On the closed-no-merge short-circuit, emit the `status=blocked` marker shown above instead.
On the owner gate fire (Step 2), emit the parked marker and STOP:
```
[pylot] outcome="cto-review parked: PR #{N} carries {label} — owner review required" status=blocked
```
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
- lane: {fast | staging} (from the fresh label read at merge time)
- required_labels: {reviewed | reviewed double-checked}
- owner_gate_fired: {true (label: security|waiting-on-owner) | false}
- comment_posted: {url or "skipped (closed-no-merge)" or "park comment (owner gate)"}
- label_applied: {approved | needs-work | ready-to-merge | waiting-on-owner (gate) | none}
- merge_action: {merged | labeled-ready-to-merge | closed-superseded | held (CI-red only) | parked (owner gate) | skipped (already merged) | skipped (closed)}
- report_path: {path}

## Outcome
{the emitted [pylot] outcome marker, verbatim}
```

## Success criteria
- Owner gate (Step 2) ran using a FRESH GitHub label read, not the cached handoff.
- Merge bar (Step 3) resolved from that SAME fresh label read: `reviewed` on `lane:fast`,
  `reviewed` + `double-checked` on `lane:staging` or no lane label.
- On `lane:fast`, a missing `double-checked` was NOT treated as a blocker and did NOT produce
  `needs-work` or a request for a double-check.
- If gate fired: park comment posted (with receipts), `waiting-on-owner` applied, `status=blocked` emitted. STOP.
- If gate clear: comment posted (with `## Checked / Found` receipts section), label applied per verdict, merge/label honoring merge state and CI, report file written (no Quest), outcome marker emitted from the orchestrator.

## Failure
- Comment post or label edit errors → emit the stage-03 failure marker; still write whatever report
  is possible (marker is the primary signal).
