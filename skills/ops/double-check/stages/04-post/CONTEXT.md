# Stage 04: Post (inline)

Runs inline in the orchestrator — do NOT spawn a Task. The `[pylot] outcome=...` marker MUST be
emitted from here.

## Inputs
- `.procedure-output/double-check/01-setup/handoff.md` — PR metadata, URL, branches, PR body, **labels**
- `.procedure-output/double-check/02-review/handoff.md` — verdict, curated findings, new issues
- `.procedure-output/double-check/03-fix/handoff.md` — fixes applied, tests, push (absent if stage 03 skipped)

## Task
Confirm stage 02's claims-vs-diff verdict against the **live** PR, detect whether this is a
re-check run (PR has `needs-work`), post the curated review comment, apply labels to close the
pipeline loop (re-check path) or signal completion (first-check path), verify the side effects
landed, write the local report file, and emit the outcome marker. NO Quest — the report is a
local file only.

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
CLAIMS=$(grep "^claims_reconciled:" "$REVIEW_HANDOFF" | head -1 | awk '{print $2}')
[ -n "$CLAIMS" ] || CLAIMS=unknown
```

### Claims-vs-diff gate against the LIVE PR (BLOCKING — run before posting)

Stage 02 judged a handoff. This step confirms that judgement against GitHub itself: the handoff's
diff may have been truncated, and the branch may have moved since setup. **Always run it** — it is
the skill's only orchestrator-level verification of its own subject matter.

```bash
gh pr view $PR --repo $REPO --json title,body,additions,deletions,files,headRefOid \
  > /tmp/dc-pr-$PR.json
LIVE_STAT=$(jq -r '"+\(.additions)/-\(.deletions), \(.files|length) files"' /tmp/dc-pr-$PR.json)
LIVE_FILES=$(jq -r '.files[].path' /tmp/dc-pr-$PR.json)
LIVE_HEAD_SHA=$(jq -r '.headRefOid' /tmp/dc-pr-$PR.json)
echo "[stage-04] live diff: $LIVE_STAT"
echo "[stage-04] head reviewed: $LIVE_HEAD_SHA"
printf '%s\n' "$LIVE_FILES"
```

Then:

- **`CLAIMS=unknown`** (stage 02 could not reconcile, e.g. truncated diff) — reconcile now yourself:
  read the live `.body` and `.files` from `/tmp/dc-pr-$PR.json` and apply the stage-02 rules
  (backed / elsewhere / unbacked). Set `CLAIMS=pass` or `CLAIMS=fail` from what you find.
- **`CLAIMS=pass`** — sanity-check that the live changed-file list still matches the manifest
  stage 02 reviewed. If files were added or removed since setup (the branch moved, or stage 03
  pushed), re-reconcile the affected claims before continuing.
- **`CLAIMS=fail`** — force `VERDICT=needs-work` and take **Branch D** below. Do not apply
  `double-checked`, whatever stage 02's verdict said.

```bash
if [ "$CLAIMS" = "fail" ]; then VERDICT=needs-work; fi
```

### Post the curated review comment

Fill `shared/review-comment-template.md` from the stage-02 (curated findings, new issues, verdict)
and stage-03 (tests, fixes) handoffs, then post:

```bash
gh pr comment $PR --repo $REPO --body "$(cat <<'REVIEW_EOF'
## Double-Check Review: PR #$PR — $PR_TITLE

**Reviewer:** Automated double-check
**Branch:** `$PR_BRANCH` → `$BASE_BRANCH`
**Head reviewed:** `$LIVE_HEAD_SHA`

---

### Intent
[1-2 sentences: does the PR deliver what it's supposed to?]

### Claims vs Diff — $CLAIMS
Live diff: $LIVE_STAT

| Claim | Status | Evidence |
|-------|--------|----------|
| [claim from PR title/body] | backed / elsewhere / **unbacked** | [where it is, or that it is absent] |

[On unbacked claims, add: "**This PR's description does not match its diff.** Correct the body to
describe what actually landed, or land the missing code. `double-checked` withheld until then."]

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

<!-- review-state v1
{REVIEW_STATE_JSON}
-->

REVIEW_EOF
)"
```

**Updating `REVIEW_STATE_JSON` (#2210):** take the incoming state from the setup handoff's
`## Review State` (or start a fresh object with `"findings": []` if it was `none`), then:
- set `"stage": "double-check"` and set `"head_sha"` to `LIVE_HEAD_SHA` (never copy the stale
  incoming value; fix commits or rebases may have moved it)
- set `"tier"` to the final tier (respect any escalation from stage 02; never lower)
- update each existing finding's `"status"`: `fixed` (stage 03 addressed it — add
  `"note": "fixed in <sha>"`), `dismissed` (DISCARD verdict — note the reason), or leave `open`
- append stage-02's new issues as findings with their `D{n}` IDs, `"status": "open"` or `"fixed"`
- append this stage's `verified` entries (and stage 03's
  `{"what": "test suite after fixes", "how": "executed", "by": "double-check"}` when tests ran)

Validate with `jq .` before posting — downstream cto-review parses it.

**Rules:**
- If no CI findings exist: write "No CI review comments found — reviewed diff directly"
- If tests weren't run: explain why (e.g., "deps-only change, no test suite applicable")
- Verdict must be specific: either "ready for CTO review" or list what still needs work
- If stage 03 was skipped (`fixes_needed: false`): mark all "Fixed?" cells "No (no fix needed)"
- The `review-state v1` block is ALWAYS present and valid JSON
- The Claims vs Diff table is ALWAYS present (write "no checkable claims in the body" if the body
  makes none). Never soften an unbacked claim into an observation.

Also append to the `verified` manifest:
`{"what": "PR title/body claims reconciled against live changed files", "how": "gh pr view", "by": "double-check"}`

### Apply labels (re-check vs first-check)

Only after the review comment posts successfully.

**Four branches — check Branch D FIRST, then match on IS_RECHECK and VERDICT:**

---

#### Branch D — Claims mismatch (CLAIMS=fail AND IS_RECHECK=false) — takes precedence over C

When `CLAIMS=fail` on a **re-check** (IS_RECHECK=true), Branch B already does the right thing:
`needs-work` stays, `double-checked` is not re-toggled. Branch D covers the first-check case,
which otherwise applies `double-checked` and promotes the PR.

The PR describes work its diff does not contain. Withhold `double-checked`: that label is what
fires `cto-review-on-double-checked`, `flowchad-on-double-checked`, and
`test-in-staging-on-double-checked`, so withholding it stops the promotion chain at this gate
instead of handing a phantom delivery to the CTO stage.

Do NOT apply `needs-work` here — `rework-on-needs-work` dispatches `/double-check`, so applying it
from inside double-check loops the skill onto itself. The withheld label plus the comment is the
signal.

```bash
if [ "$IS_RECHECK" = "false" ]; then
  # Branch D: claims not backed by the diff (first-check only)
  echo "[stage-04] CLAIMS=fail — withholding double-checked, PR description does not match its diff"

  MARKER_SEEN=$(gh pr view $PR --repo $REPO --json comments \
    --jq '.comments[].body | select(contains("pylot:claims-mismatch"))' 2>/dev/null | head -1)

  if [ -z "$MARKER_SEEN" ]; then
    gh pr comment $PR --repo $REPO --body "$(cat <<CLAIMS_EOF
<!-- pylot:claims-mismatch pr=$PR repo=$REPO -->
## Blocked: PR description does not match the diff

Live diff: $LIVE_STAT

The following claims in the PR title/body have no corresponding change in this PR:

{one bullet per unbacked claim, from the Claims vs Diff table}

\`double-checked\` is withheld, so cto-review / staging / FlowChad will not run.

### To unblock
1. Land the missing code, **or** rewrite the PR body to describe what this diff actually does
   (including any \`Closes\`/\`Implements\` refs and staging evidence that no longer apply).
2. Remove and re-add the \`reviewed\` label to re-run the review chain.
CLAIMS_EOF
)"
  else
    echo "[stage-04] claims-mismatch marker already present — skipping duplicate comment"
  fi
  # Do NOT add double-checked. Do NOT add needs-work. Skip branches A/B/C.
fi
# (CLAIMS=fail AND IS_RECHECK=true: falls through to Branch B, which retains needs-work correctly)
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

#### Branch C — First-check (IS_RECHECK=false, CLAIMS != fail, any verdict)

Existing behavior unchanged: apply `double-checked` label. cto-review handles verdict routing.

```bash
# Branch C: first-check
echo "[stage-04] first-check — applying double-checked label"
gh label create "double-checked" --repo $REPO --color "0075ca" \
  --description "Double-checked by agent" 2>/dev/null || true
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
| C (first-check) | `double-checked` present |
| D (claims mismatch) | `double-checked` **absent**, claims-mismatch comment present |

Mismatch → log `[stage-04] verification FAIL — {what was expected vs seen}` and emit
`status=failed` with that reason. Label propagation can lag a second; retry the read once before
declaring failure.

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

**Claims mismatch** (Branch D):
```
[pylot] outcome="double-check BLOCKED {repo}#{pr} — {N} PR-body claims unbacked by the diff, double-checked withheld" status=success
```

**First-check** (IS_RECHECK=false, any verdict):
```
[pylot] outcome="double-checked {repo}#{pr} — verdict {ready|needs-work}, {N} findings curated, {N} fixes pushed" status=success
```

If any step failed, emit `status=failed` with the reason instead.

## Success criteria
- Live claims-vs-diff gate run (`gh pr view`) before posting, and its result reflected in `CLAIMS`
- Curated review comment posted, including the Claims vs Diff table
- Labels applied per the branch above (claims mismatch: double-checked withheld + mismatch comment;
  re-check PASS: needs-work removed + double-checked re-toggled; re-check FAIL: no label change +
  structured verdict comment posted; first-check: double-checked applied)
- Post-action `gh pr view` confirms the expected labels/comments for the branch taken
- Report file written to `reports/`
- NO Quest POST anywhere
- `[pylot] outcome=...` marker emitted from the orchestrator

## Failure
- Comment post fails → emit `status=failed`, do NOT apply labels
- Label apply fails → log it, report file still written, emit `status=failed` with reason
- Post-action verification disagrees with the branch taken → emit `status=failed` with the diff
- Re-check FAIL comment post fails → emit `status=failed` (idempotency guard means next retry is safe)
