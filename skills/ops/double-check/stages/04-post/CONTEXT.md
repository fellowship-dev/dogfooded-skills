# Stage 04: Post (inline)

Runs inline in the orchestrator — do NOT spawn a Task. The `[pylot] outcome=...` marker MUST be
emitted from here.

## Inputs
- `.procedure-output/double-check/01-setup/handoff.md` — PR metadata, URL, branches, **labels**, and the path of the verbatim `pr-body.md` artifact
- `.procedure-output/double-check/02-review/handoff.md` — verdict, curated findings, new issues
- `.procedure-output/double-check/03-fix/handoff.md` — fixes applied, tests, push (absent if stage 03 skipped)

## Task
Confirm Stage 02's verdict against the **live** PR and promote only when the live 40-hex head
equals the exact head Stage 02 reviewed. Fetch the live head immediately before every mutation.
On the first head transition, return control to the orchestrator for a fresh setup → clean review
cycle. On a second transition, or an unreadable live read, stop blocked. Only a matching head may
post the curated comment, apply labels, verify side effects, write the local report, and emit a
successful outcome. NO Quest.

## Steps

```bash
export PR={PR}
export REPO={REPO}
PR_TITLE={from setup handoff}
PR_BRANCH={from setup handoff}
BASE_BRANCH={from setup handoff}
PR_URL={from setup handoff}
```

### Carry branch (`review_scope: carry` — stages 02 and 03 did not run)

Setup found a `ready` verdict on the same patch-id: the head moved (rebase or merge-from-base) but
the PR's own diff did not. Re-verify that against the live PR, post one line, keep the labels, and
stop. No review runs and no label is touched.

```bash
SETUP_HANDOFF=".procedure-output/double-check/01-setup/handoff.md"
: "${DC_SKILL_DIR:?Pass the absolute loaded skill directory from the orchestrator}"
source "$DC_SKILL_DIR/shared/exact-head-receipt.sh"
REVIEW_SCOPE=$(awk '/^review_scope:/{print $2; exit}' "$SETUP_HANDOFF")
RESTART_COUNT=${RESTART_COUNT:-0}
if [ "$REVIEW_SCOPE" = carry ]; then
  read -r PRIOR_HEAD PRIOR_PATCH_ID PRIOR_VERDICT <<<"$(dc_latest_verdict_receipt $PR $REPO)"
  read -r LIVE_HEAD_SHA LIVE_PATCH_ID <<<"$(dc_live_patch_receipt $PR $REPO)"
  DECISION=$(dc_exact_head_decision "$PRIOR_HEAD" "$LIVE_HEAD_SHA" "$RESTART_COUNT" "$PRIOR_PATCH_ID" "$LIVE_PATCH_ID")
  [ "$PRIOR_VERDICT" = ready ] || DECISION=blocked
  if ! gh pr view $PR --repo $REPO --json labels --jq '.labels[].name' | grep -qx double-checked; then
    if [ "$RESTART_COUNT" = 0 ]; then DECISION=restart; else DECISION=blocked; fi
  fi
  if [ "$DECISION" = carry ]; then
    CARRY_MARKER="pylot:exact-head-promoted pr=$PR head=$LIVE_HEAD_SHA"
    if ! gh pr view $PR --repo $REPO --json comments --jq '.comments[].body' | grep -qF "$CARRY_MARKER"; then
      gh pr comment $PR --repo $REPO --body "<!-- $CARRY_MARKER patch_id=$LIVE_PATCH_ID verdict=ready carried_from=$PRIOR_HEAD -->
Double-check verdict carried: patch-id unchanged (\`${PRIOR_HEAD:0:7}\` → \`${LIVE_HEAD_SHA:0:7}\`, patch-id \`${LIVE_PATCH_ID:0:12}\`)."
    fi
  elif [ "$DECISION" = promote ]; then
    echo "[stage-04] verdict already names the live head — nothing to carry"
  elif [ "$DECISION" = restart ]; then
    echo "[stage-04] restart: the PR's diff changed after setup"; exit 3
  else
    echo "[stage-04] blocked: carry receipt unreadable or superseded"; exit 2
  fi
fi
```

On `carry` or `promote`, verify the comment landed (`gh pr view --json comments`) and that
`double-checked` is still present, write the report file with verdict `carried`, and emit
(final full assistant line, not from Bash and not inside a fence):

[pylot:$PYLOT_OUTCOME_NONCE] outcome="double-check {repo}#{pr} — verdict carried: patch-id unchanged, no re-review" status=success

Exit `3` returns to the orchestrator for one full cycle (stage 01 then picks the delta scope);
exit `2` emits the blocked marker below. Skip every step after this section on the carry branch.

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
MUST_FIX_OPEN=$(grep "^must_fix_open:" "$REVIEW_HANDOFF" | head -1 | awk '{print $2}')
BODY_NOTE=$(sed -n 's/^body_note: //p' "$REVIEW_HANDOFF" | head -1)
# Zero MUST-FIX code items is a pass, on a first check and a re-check alike. Only code-level
# MUST-FIX items hold a PR at needs-work; body staleness and non-code asks never do.
if [ "$VERDICT" = "needs-work" ] && [ "$MUST_FIX_OPEN" = "0" ]; then
  echo "[stage-04] verdict needs-work with must_fix_open=0 — normalizing to ready"
  VERDICT=ready
fi

# Stage 02 records the exact remote checkout it reviewed. Missing/malformed is unsafe.
REVIEWED_HEAD_SHA=$(awk '/^reviewed_head_sha:/{print $2; exit}' "$REVIEW_HANDOFF")
RESTART_COUNT=${RESTART_COUNT:-0}
if ! printf '%s' "$REVIEWED_HEAD_SHA" | grep -Eq '^[0-9a-f]{40}$'; then
  echo "[stage-04] blocked: stage 02 did not record an exact reviewed HEAD SHA"
  exit 2
fi
```

If the missing/malformed-SHA branch exits, emit this as your final full assistant line (not from
Bash and not inside a fence), then stop:

[pylot:$PYLOT_OUTCOME_NONCE] outcome="double-check blocked: no exact reviewed HEAD SHA recorded" status=blocked

### Exact-head gate against the LIVE PR (BLOCKING — run before posting)

Stage 02 judged a handoff. This step confirms that the branch has not moved since setup.
**Always run it** before any comment or label mutation.

```bash
# Do not use local checkout state, abbreviated SHAs, filenames, or diff stats as an identity.
# This is the final live read before any possible comment/label mutation.
if ! gh pr view $PR --repo $REPO --json title,body,additions,deletions,files,headRefOid \
  > /tmp/dc-pr-$PR.json
then
  LIVE_READ_FAILED=true
fi
# exact-head-receipt.sh was sourced at the top of this stage (carry branch section).
LIVE_HEAD_SHA=$(dc_pr_json_read "/tmp/dc-pr-$PR.json" head 2>/dev/null || true)
# The reviewed diff's patch-id comes from setup (stage 02 reviewed exactly the setup head).
SETUP_PATCH_ID=$(sed -n 's/^- Setup patch-id: //p' "$SETUP_HANDOFF" | head -1)
LIVE_PATCH_ID=$SETUP_PATCH_ID
if [ "$LIVE_HEAD_SHA" != "$REVIEWED_HEAD_SHA" ]; then
  read -r PID_HEAD LIVE_PATCH_ID <<<"$(dc_live_patch_receipt $PR $REPO)"
  [ "$PID_HEAD" = "$LIVE_HEAD_SHA" ] || LIVE_PATCH_ID=""
fi
DECISION=$(dc_exact_head_decision "$REVIEWED_HEAD_SHA" "$LIVE_HEAD_SHA" "$RESTART_COUNT" \
  "$SETUP_PATCH_ID" "$LIVE_PATCH_ID")
if [ "${LIVE_READ_FAILED:-false}" = true ]; then DECISION=blocked; fi
CARRIED_FROM=""
if [ "$DECISION" = carry ]; then
  # Head moved (rebase/merge-from-base) but the PR's own diff is the one reviewed: promote at the
  # live head. Every later mutation guard pins to this head.
  echo "[stage-04] verdict carried: patch-id unchanged ($REVIEWED_HEAD_SHA -> $LIVE_HEAD_SHA)"
  CARRIED_FROM=$REVIEWED_HEAD_SHA
  REVIEWED_HEAD_SHA=$LIVE_HEAD_SHA
  DECISION=promote
fi

if [ "$DECISION" = restart ]; then
  echo "[stage-04] restart: PR HEAD moved after review ($REVIEWED_HEAD_SHA -> $LIVE_HEAD_SHA)"
  exit 3
fi
if [ "$DECISION" = blocked ]; then
  REASON="exact head unavailable or superseded"
  [ "${LIVE_READ_FAILED:-false}" = true ] && REASON="live PR read failed"
  echo "[stage-04] blocked: $REASON (reviewed=$REVIEWED_HEAD_SHA live=${LIVE_HEAD_SHA:-unavailable})"
  exit 2
fi

if ! LIVE_STAT=$(dc_pr_json_read "/tmp/dc-pr-$PR.json" stat 2>/dev/null) ||
   ! LIVE_FILES=$(dc_pr_json_read "/tmp/dc-pr-$PR.json" files 2>/dev/null); then
  REASON="live PR diff metadata unavailable or malformed"
  echo "[stage-04] blocked: $REASON"
  exit 2
fi
echo "[stage-04] live diff: $LIVE_STAT"
echo "[stage-04] stage-02 head reviewed: $REVIEWED_HEAD_SHA"
echo "[stage-04] live head: $LIVE_HEAD_SHA"
printf '%s\n' "$LIVE_FILES"

# `promote` is possible only after the helper's full-SHA equality check above.
```

If either terminal branch exits, emit its resolved marker as your final full assistant line (not
from Bash and not inside a fence), then stop:

- `restart`: [pylot:$PYLOT_OUTCOME_NONCE] outcome="double-check restart required: PR HEAD moved after review" status=blocked
- `blocked`: [pylot:$PYLOT_OUTCOME_NONCE] outcome="double-check blocked: ${REASON}" status=blocked

### Executable mutation guard

Use this guard immediately before every approving comment or label mutation. It reads GitHub
again, so neither a cached JSON document nor the local checkout can authorize a promotion. If it
does not print `promote`, do **not** run the mutation: log the decision, emit the matching
restart/blocked outcome marker, then exit `3`/`2` respectively.

```bash
dc_require_promotable_head() {
  local decision
  decision=$(dc_live_promotion_decision "$PR" "$REPO" "$REVIEWED_HEAD_SHA" \
    "$RESTART_COUNT" "/tmp/dc-final-pr-$PR.json")
  [ "$decision" = promote ] && return 0
  echo "[stage-04] promotion mutation blocked: exact-head decision=$decision"
  if [ "$decision" = restart ]; then
    exit 3
  fi
  exit 2
}
```

If this guard exits, emit the matching marker as your final full assistant line (not from Bash and
not inside a fence), then stop:

- `restart`: [pylot:$PYLOT_OUTCOME_NONCE] outcome="double-check restart required: PR HEAD moved after review" status=blocked
- `blocked`: [pylot:$PYLOT_OUTCOME_NONCE] outcome="double-check blocked: exact head unavailable or superseded" status=blocked

Then sanity-check that the live changed-file list still matches the manifest stage 02 reviewed.
SHA equality above is mandatory even when the file list is unchanged; a stage-03 fix or any other
push requires a fresh stage-02 review before posting. The PR body is not re-checked here: body
staleness never changes the verdict.

### Post the curated review comment

Fill `$DC_SKILL_DIR/shared/review-comment-template.md` from the stage-02 (curated findings, new issues, verdict)
and stage-03 (tests, fixes) handoffs, then post:

```bash
PROMOTION_MARKER="pylot:exact-head-promoted pr=$PR head=$LIVE_HEAD_SHA"
# The receipt binds the verdict to the head AND the PR's patch-id; consumers carry it across a
# head change only while the patch-id is unchanged. `-` when unknown (then only the head binds).
PROMOTION_ALREADY_POSTED=$(gh pr view $PR --repo $REPO --json comments \
  --jq '.comments[].body' | grep -F "$PROMOTION_MARKER" || true)
if [ -z "$PROMOTION_ALREADY_POSTED" ]; then
# A promotion race is never repaired by posting the stale comment.
dc_require_promotable_head
gh pr comment $PR --repo $REPO --body "$(cat <<REVIEW_EOF
<!-- $PROMOTION_MARKER patch_id=${LIVE_PATCH_ID:--} verdict=$VERDICT${CARRIED_FROM:+ carried_from=$CARRIED_FROM} -->
## Double-Check Review: PR #$PR — $PR_TITLE

**Reviewer:** Automated double-check
**Branch:** \`$PR_BRANCH\` → \`$BASE_BRANCH\`
**Head reviewed:** \`$LIVE_HEAD_SHA\`
**Patch-id:** \`${LIVE_PATCH_ID:-unknown}\`${CARRIED_FROM:+ (verdict carried: patch-id unchanged since \`$CARRIED_FROM\`)}

---

### Intent
[1-2 sentences: does the PR deliver what it's supposed to?]

[Only when stage 02 recorded a body_note other than "none", add one line:
"Note: the PR body is stale against the diff — <body_note>. Not a blocker."]

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
else
  echo "[stage-04] exact-head promotion marker already posted — skipping duplicate verdict"
fi
```

**Rules:**
- If no CI findings exist: write "No CI review comments found — reviewed diff directly"
- If tests were not run: name the owning contract, scope and matching reused receipts or precise execution gap. Dependencies/lockfiles are not automatically exempt; non-runtime classifications need their required static/policy checks.
- Verdict must be specific: either "ready for CTO review" or list what still needs work
- If stage 03 was skipped (`fixes_needed: false`): mark all "Fixed?" cells "No (no fix needed)"
- The `**Head reviewed:**` line is ALWAYS present with the full 40-hex live head — it is the
  receipt downstream consumers and the dedup gate compare against the current head
- The verdict follows `must_fix_open`: zero open MUST-FIX code items is "Ready for CTO review".
  A stale body gets at most the one-line note above; never list it as a remaining item.

The `dc_require_promotable_head` invocation directly above `gh pr comment` is mandatory. If it
fails, it emits the restart/blocked outcome and exits — never an approving comment.
This prevents the tiny race between the first gate and `gh pr comment`.

### Apply labels (re-check vs first-check)

Only after the review comment posts successfully and the final exact-head equality has passed.
Immediately before every `gh pr edit` / `gh label` mutation, call
`dc_require_promotable_head`; it exits with the restart/blocked outcome if the head moved.
If the matching `PROMOTION_MARKER` already exists and `double-checked` is already present, leave
the label untouched; never remove/re-add it merely to replay a promotion.

**Four branches — check Branch D FIRST, then match on IS_RECHECK and VERDICT:**

---

#### Branch D — First-check non-promotion (`IS_RECHECK=false` and `VERDICT != ready`) — takes precedence over C

This is an explicit `needs-work` verdict with at least one open MUST-FIX code item, or a
missing/malformed verdict. On a **re-check** (IS_RECHECK=true), Branch B already retains `needs-work`
and does not re-toggle the positive label.

Fail closed: `double-checked` fires CTO, FlowChad, and staging, so remove it if present and do
not add it. Add or retain `needs-work`. Do this only after the negative curated comment posts
successfully, and call `dc_require_promotable_head` immediately before every label mutation. No
positive follow-on may be created from a negative or conflicting review verdict.

```bash
if [ "$IS_RECHECK" = "false" ] && [ "$VERDICT" != "ready" ]; then
  # Branch D: negative/conflicting first-check verdict — fail closed.
  echo "[stage-04] verdict=$VERDICT must_fix_open=${MUST_FIX_OPEN:-unknown} — withholding double-checked and retaining needs-work"

  MARKER_SEEN=$(gh pr view $PR --repo $REPO --json comments \
    --jq '.comments[].body | select(contains("pylot:first-check-fail-closed"))' 2>/dev/null | head -1)

  if [ -z "$MARKER_SEEN" ]; then
    dc_require_promotable_head
    gh pr comment $PR --repo $REPO --body "$(cat <<FAIL_CLOSED_EOF
<!-- pylot:first-check-fail-closed pr=$PR repo=$REPO verdict=$VERDICT -->
## Double-check blocked: negative or conflicting review verdict

**Verdict:** \`$VERDICT\`
**Open MUST-FIX items:** \`${MUST_FIX_OPEN:-unknown}\`
**Head reviewed:** \`$LIVE_HEAD_SHA\`

The review did not produce an explicitly positive verdict for this exact head. The
\`double-checked\` label is withheld or removed, and \`needs-work\` is retained.

### To unblock
1. Resolve every remaining item from the review comment above.
2. Remove and re-add the \`reviewed\` label to re-run the review chain.
FAIL_CLOSED_EOF
)"
  else
    echo "[stage-04] first-check fail-closed marker already present — skipping duplicate comment"
  fi

  dc_require_promotable_head
  gh pr edit $PR --repo $REPO --remove-label "double-checked" 2>/dev/null || true
  gh label create "needs-work" --repo $REPO --color "d93f0b" \
    --description "Needs work before merge" 2>/dev/null || true
  dc_require_promotable_head
  gh pr edit $PR --repo $REPO --add-label "needs-work"
  # Do NOT add double-checked. Skip branches A/B/C.
fi
# (Negative first-check signals take D; re-check failure falls through to B.)
```

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
dc_require_promotable_head
gh pr edit $PR --repo $REPO --remove-label "needs-work" 2>/dev/null || true

# Step 2: remove double-checked so re-add fires a fresh pull_request.labeled event
dc_require_promotable_head
gh pr edit $PR --repo $REPO --remove-label "double-checked" 2>/dev/null || true

# Step 3: re-add double-checked → fires pull_request.labeled → cto-review-on-double-checked
gh label create "double-checked" --repo $REPO --color "0075ca" \
  --description "Double-checked by agent" 2>/dev/null || true
dc_require_promotable_head
gh pr edit $PR --repo $REPO --add-label "double-checked"

echo "[stage-04] loop closed — cto-review will re-fire via pull_request.labeled"
```

---

#### Branch B — Re-check FAIL (IS_RECHECK=true AND verdict=needs-work)

Only reachable with at least one open MUST-FIX code item. A re-check whose review lists zero
MUST-FIX items was normalized to `ready` above and takes Branch A, even if its prose says
"needs-work".

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

#### Branch C — First-check PASS (`IS_RECHECK=false`, `VERDICT=ready`)

Apply `double-checked` only after an explicit `ready` verdict at the exact live head. This is the
only first-check path that may create positive follow-ons.

```bash
# Branch C: explicitly positive first-check verdict at the exact head
echo "[stage-04] first-check PASS — applying double-checked label"
gh label create "double-checked" --repo $REPO --color "0075ca" \
  --description "Double-checked by agent" 2>/dev/null || true
dc_require_promotable_head
gh pr edit $PR --repo $REPO --add-label "double-checked"
```

---

### Verify the side effects landed

Run after the branch above completes. The label call can 404 or silently no-op; without this the
skill reports success on side effects that never happened.

```bash
gh pr view $PR --repo $REPO --json labels,comments \
  --jq '{labels: [.labels[].name], comments: (.comments|length)}'
```

Confirm against the branch you ran:

| Branch | Expect |
|--------|--------|
| A (re-check PASS) | `double-checked` present, `needs-work` absent |
| B (re-check FAIL) | `needs-work` present, `double-checked` unchanged, recheck-fail comment present |
| C (first-check PASS) | `double-checked` present, `needs-work` absent |
| D (first-check fail closed) | `double-checked` **absent**, `needs-work` present, fail-closed comment present |

Mismatch → log `[stage-04] verification FAIL — {what was expected vs seen}` and emit
`status=failed` with that reason. Label propagation can lag a second; retry the read once before
declaring failure.

---

### Write the report file

```bash
REPORT_FILE="reports/$(date +%Y-%m-%d)-review-$(echo $REPO | tr '/' '-')-pr$PR.md"
```

Fill `$DC_SKILL_DIR/shared/report-template.md` and write it to `REPORT_FILE`. For Pylot/crew runs the report
goes to `$(git rev-parse --show-toplevel)/reports/`. Operators surface this file via the mission
report.

**NO Quest.** Do NOT POST to any Quest endpoint, `127.0.0.1:4242`, or `quest.fellowship.dev`, and
do NOT read `QUEST_TOKEN`. The local report file is the only report sink.

### Emit outcome marker

Emit from the orchestrator (never a subagent). Branch on re-check context:

**Re-check PASS** (IS_RECHECK=true, verdict=ready):
```
[pylot:$PYLOT_OUTCOME_NONCE] outcome="double-checked re-check PASS {repo}#{pr} — loop closed, cto-review re-fired" status=success
```

**Re-check FAIL** (IS_RECHECK=true, verdict=needs-work):
```
[pylot:$PYLOT_OUTCOME_NONCE] outcome="double-checked re-check FAIL {repo}#{pr} — needs-work retained" status=success
```

**First-check fail closed** (Branch D):
```
[pylot:$PYLOT_OUTCOME_NONCE] outcome="double-check {repo}#{pr} — verdict {VERDICT}, double-checked withheld, needs-work retained" status=success
```

**Verdict carried** (carry branch, `review_scope: carry`):
```
[pylot:$PYLOT_OUTCOME_NONCE] outcome="double-check {repo}#{pr} — verdict carried: patch-id unchanged, no re-review" status=success
```

**First-check PASS** (IS_RECHECK=false, VERDICT=ready):
```
[pylot:$PYLOT_OUTCOME_NONCE] outcome="double-checked {repo}#{pr} — verdict ready, {N} findings curated, {N} fixes pushed" status=success
```

If any step failed, emit `status=failed` with the reason instead. Head-transition restarts and
unreadable live state emit `status=blocked` (a deliberate stop, not a failure) via the gates above.

## Success criteria
- Live exact-head gate run (`gh pr view`) before posting
- `VERDICT=ready` whenever `must_fix_open` is 0, on first checks and re-checks alike
- Curated review comment posted, including the full 40-hex
  `**Head reviewed:**` line
- Labels applied per the branch above (first-check fail-closed: double-checked removed/withheld +
  needs-work retained + fail-closed comment; re-check PASS: needs-work removed + double-checked
  re-toggled; re-check FAIL: no label change + structured verdict comment posted; first-check PASS:
  double-checked applied)
- Post-action `gh pr view` confirms the expected labels/comments for the branch taken
- Report file written to `reports/`
- NO Quest POST anywhere
- `[pylot] outcome=...` marker emitted from the orchestrator

## Failure
- Comment post fails → emit `status=failed`, do NOT apply labels
- Label apply fails → log it, report file still written, emit `status=failed` with reason
- Post-action verification disagrees with the branch taken → emit `status=failed` with the diff
- Re-check FAIL comment post fails → emit `status=failed` (idempotency guard means next retry is safe)
