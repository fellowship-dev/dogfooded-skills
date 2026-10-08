# Stage 01: Setup (subagent)

## Inputs
- `pr` and `repo` (passed in the Task prompt)
- GitHub auth is ambient — the pod's `git-credential-pylot` helper and the `gh` shim mint
  short-lived App installation tokens per operation. No token env var is needed or set.

No upstream handoffs — this is the first stage.

## Task
Gather everything the review stage needs and prepare a clean local working tree:
PR metadata, CI status, the existing (first) review comments, the full diff, and a checked-out
PR branch checked out at its head, with a local, never-pushed check that the base branch merges
cleanly (merge, never rebase; see dogfooded-skills#161). Stage 01 never pushes.

## Steps

```bash
export PR={pr}      # PR number
export REPO={repo}  # org/repo
# Set by the orchestrator only on a stage-04 restart: the head the previous cycle reviewed.
DELTA_BASE_HEAD={delta_base_head or empty}
# Patch-id helpers. Resolved now, because later steps cd into REPO_DIR.
: "${DC_SKILL_DIR:?Pass the absolute loaded skill directory from the orchestrator}"
source "$DC_SKILL_DIR/shared/exact-head-receipt.sh"
```

### Fetch PR metadata

```bash
gh pr view $PR --repo $REPO --json number,title,body,headRefName,baseRefName,url,files,labels,author,additions,deletions,commits,headRefOid,comments

# Extract key info
PR_TITLE=$(gh pr view $PR --repo $REPO --json title --jq '.title')
PR_BRANCH=$(gh pr view $PR --repo $REPO --json headRefName --jq '.headRefName')
BASE_BRANCH=$(gh pr view $PR --repo $REPO --json baseRefName --jq '.baseRefName')
PR_URL=$(gh pr view $PR --repo $REPO --json url --jq '.url')
INITIAL_HEAD_SHA=$(gh pr view $PR --repo $REPO --json headRefOid --jq '.headRefOid')
printf '%s' "$INITIAL_HEAD_SHA" | grep -Eq '^[0-9a-f]{40}$' || {
  echo "live head unavailable or malformed; write setup_ok: false blocked handoff"; exit 1;
}
```

### Check CI status (best-effort — may fail with PAT)

```bash
gh pr checks $PR --repo $REPO 2>/dev/null || echo "CI checks not accessible via token"
```

### Write the verbatim artifacts to files (shell, never retyped)

The PR body, the first review, the changed-file manifest and the full diff go to files **by
shell redirection**, next to the handoff. Never copy them into `handoff.md` through the Write
tool: retyping a large diff token by token was the single biggest setup cost (median 97 s,
up to 5+ min per cycle, measured on 40 pylot missions), and a retyped diff can drift from the
real one. A redirected file is byte-exact and costs nothing.

```bash
# Same directory as handoff.md. Absolute, because later steps cd into REPO_DIR.
OUT="$(pwd)/.procedure-output/double-check/01-setup"
mkdir -p "$OUT"
gh pr view $PR --repo $REPO --json body --jq '.body' > "$OUT/pr-body.md"
```

### Read existing review comments + the first review's head receipt

Capture ALL existing review comments verbatim, and extract the head SHA the latest first review
(review-pr) was bound to — its comment carries a `**Head reviewed:** \`<40-hex>\`` line:

```bash
gh pr view $PR --repo $REPO --json comments --jq '.comments[] | "### comment by \(.author.login) at \(.createdAt)\n\(.body)\n"' > "$OUT/first-review.md" \
  || echo "FIRST REVIEW FETCH FAILED (comments) — treat as unknown, not absent" >> "$OUT/first-review.md"
gh pr view $PR --repo $REPO --json reviews --jq '.reviews[] | "### review by \(.author.login) (\(.state))\n\(.body)\n"' >> "$OUT/first-review.md" \
  || echo "FIRST REVIEW FETCH FAILED (reviews) — treat as unknown, not absent" >> "$OUT/first-review.md"
REVIEW_HEAD_SHA=$(gh pr view $PR --repo $REPO --json comments --jq '.comments[].body' \
  | sed -n 's/^\*\*Head reviewed:\*\* `\([0-9a-f]\{40\}\)`.*/\1/p' | tail -1)
```

Every finding from automated CI / the Claude GitHub App / bots is in `first-review.md` verbatim —
the review stage curates these in a clean context, so they must be carried over faithfully (never
pre-curated here). Read it yourself only as far as you need to fill the receipt fields.

### Read the full diff

```bash
# Full diff, whole and untruncated, straight to a file.
# GitHub refuses very large diffs (HTTP 406): then DIFF_FALLBACK=1, and the checkout step
# below regenerates diff.patch from git before the merge.
gh pr diff $PR --repo $REPO > "$OUT/diff.patch" || DIFF_FALLBACK=1

# Authoritative changed-file manifest with per-file line counts — stage 02 reconciles the
# PR body's claims against THIS list, so it must be complete and unedited.
gh pr view $PR --repo $REPO --json additions,deletions,files \
  --jq '"TOTAL +\(.additions)/-\(.deletions), \(.files|length) files", (.files[] | "\(.path)  +\(.additions)/-\(.deletions)")' \
  > "$OUT/changed-files.txt"
wc -l -c "$OUT"/pr-body.md "$OUT"/first-review.md "$OUT"/diff.patch "$OUT"/changed-files.txt
```

The review stage works only from this handoff and these four files. A failed or empty
`diff.patch` while `changed-files.txt` lists files is a setup failure (`setup_ok: false`), never a
silent gap: stage 02 treats what it is given as ground truth.

### Checkout PR branch + check the base merge locally (never pushed)

```bash
REPO_NAME=$(echo $REPO | cut -d/ -f2)
REPO_DIR="/tmp/double-check-$REPO_NAME"

if [ ! -d "$REPO_DIR" ]; then
  # Plain https URL — inline credentials would bypass git-credential-pylot
  git clone "https://github.com/$REPO.git" "$REPO_DIR"
fi

cd "$REPO_DIR"
git fetch origin $PR_BRANCH
git checkout $PR_BRANCH
git pull origin $PR_BRANCH

# Check that base merges cleanly into the PR, LOCALLY ONLY — never push the merge
# (Max, 2026-10-06, pylot#3738). Every head change restarts this PR's double-check and
# invalidates head-bound receipts, and GitHub does not require a branch to be up to
# date to merge, so a PR that is merely behind is reviewed (and later merged) as it is.
# Nothing downstream runs tests on the merged tree: stage 02 reviews the PR's own diff and
# stage 03 tests its fix delta on top of the PR head. So the check is a --no-commit merge
# that is always undone, leaving REPO_DIR on the PR head; a stage 03 fix push then carries
# only fix commits. Merge, never rebase (dogfooded-skills#161): its conflict semantics
# match the squash merge the factory performs. A real conflict (GitHub: mergeable_state
# "dirty") is not fixed here: it blocks, and auto-pylot stage 03 owns the conflict fix.
dc_check_base_merge() { # <base ref>; prints the conflicted files on conflict; never pushes
  local head rc files; head=$(git rev-parse HEAD) || return 2
  if git merge --no-commit --no-ff "$1" >/dev/null 2>&1; then
    git merge --abort 2>/dev/null || true   # no MERGE_HEAD when already up to date
    rc=0
  else
    files=$(git diff --name-only --diff-filter=U 2>/dev/null | tr '\n' ' ')
    git merge --abort 2>/dev/null || git reset -q --hard "$head"
    if [ -n "$files" ]; then printf '%s' "$files"; rc=1; else rc=2; fi  # no files: not a conflict
  fi
  [ "$(git rev-parse HEAD)" = "$head" ] || { git reset -q --hard "$head"; return 2; }
  return $rc
}

git fetch origin $BASE_BRANCH
if [ -n "$DIFF_FALLBACK" ]; then
  # Same range as `gh pr diff`: merge-base of base and the PR head, to the PR head (pre-merge).
  git diff "$(git merge-base origin/$BASE_BRANCH "$INITIAL_HEAD_SHA")" "$INITIAL_HEAD_SHA" > "$OUT/diff.patch" \
    || { echo "diff unavailable — setup_ok: false (reason: diff, not merge)"; MERGE_FAILED=true; }
fi
if [ -z "$MERGE_FAILED" ]; then
  CONFLICT_FILES=$(dc_check_base_merge "origin/$BASE_BRANCH"); MERGE_RC=$?
  case $MERGE_RC in
    0) echo "origin/$BASE_BRANCH merges cleanly into $PR_BRANCH (checked locally, not pushed)" ;;
    1) echo "Merge conflict in: ${CONFLICT_FILES:-unknown files} — blocked; auto-pylot stage 03 fixes conflicts"
       MERGE_FAILED=true ;;
    *) echo "local base-merge check failed — setup_ok: false"; MERGE_FAILED=true ;;
  esac
fi

CURRENT_HEAD_SHA=$(gh pr view $PR --repo $REPO --json headRefOid --jq '.headRefOid')
printf '%s' "$CURRENT_HEAD_SHA" | grep -Eq '^[0-9a-f]{40}$' || MERGE_FAILED=true
if [ -z "$REVIEW_HEAD_SHA" ]; then
  REVIEW_RECEIPT_STATUS="absent"
elif [ "$REVIEW_HEAD_SHA" = "$CURRENT_HEAD_SHA" ]; then
  REVIEW_RECEIPT_STATUS="current"
else
  REVIEW_RECEIPT_STATUS="stale"
fi
```

If the base merge conflicts or the local check fails (or the PR can't be fetched/checked out), write the
handoff with `setup_ok: false` and the reason — the orchestrator will treat this as a blocked exit.

### Patch-id and review scope (pylot#3738)

A verdict is bound to the PR's own diff as well as its head. The patch-id is
`git diff base...head | git patch-id --verbatim`; `gh pr diff` is the same three-dot diff. A
rebase or a clean merge-from-base (including the one above) keeps it, so it never costs a review.
Compare it with the last verdict receipt to pick one of three scopes:

- `carry` — the last verdict is `ready`, `double-checked` is on and `needs-work` is off, and its
  patch-id equals the current one. Nothing in the PR's own diff is unreviewed: stages 02 and 03
  are skipped and stage 04 carries the verdict to the current head.
- `delta` — the diff changed since the last verdict (rework, fix commits), and the files whose
  hunks changed are at most 30% of the PR's files. Stage 02 reviews only those files plus the
  findings the change is meant to fix.
- `full` — no usable prior verdict, an unreachable prior head, or a wider change.

```bash
read -r LIVE_PID_HEAD SETUP_PATCH_ID <<<"$(dc_live_patch_receipt $PR $REPO)"
if [ "$LIVE_PID_HEAD" != "$CURRENT_HEAD_SHA" ]; then SETUP_PATCH_ID=""; fi
# Too large for `gh pr diff`: the local three-dot diff gives the same id.
if [ -z "$SETUP_PATCH_ID" ] && [ -n "$DIFF_FALLBACK" ]; then
  SETUP_PATCH_ID=$(git -C "$REPO_DIR" diff "origin/$BASE_BRANCH...$CURRENT_HEAD_SHA" | dc_patch_id_of_diff)
fi

read -r PRIOR_HEAD PRIOR_PATCH_ID PRIOR_VERDICT <<<"$(dc_latest_verdict_receipt $PR $REPO)"
LIVE_LABELS=$(gh pr view $PR --repo $REPO --json labels --jq '[.labels[].name] | join(",")')
REVIEW_SCOPE=full
if [ -z "$DELTA_BASE_HEAD" ] && [ "$PRIOR_VERDICT" = ready ] \
  && dc_is_full_sha "$SETUP_PATCH_ID" && [ "$PRIOR_PATCH_ID" = "$SETUP_PATCH_ID" ] \
  && printf ',%s,' "$LIVE_LABELS" | grep -q ',double-checked,' \
  && ! printf ',%s,' "$LIVE_LABELS" | grep -q ',needs-work,'; then
  REVIEW_SCOPE=carry
else
  # A restart compares against the head its previous cycle reviewed; otherwise the last verdict.
  DELTA_FROM=${DELTA_BASE_HEAD:-$PRIOR_HEAD}
  if dc_is_full_sha "$DELTA_FROM" && [ "$DELTA_FROM" != "$CURRENT_HEAD_SHA" ]; then
    git -C "$REPO_DIR" fetch -q origin "$DELTA_FROM" 2>/dev/null || true
    if dc_delta_files "$REPO_DIR" "origin/$BASE_BRANCH" "$DELTA_FROM" "$CURRENT_HEAD_SHA" > "$OUT/delta-files.txt"; then
      DELTA_COUNT=$(grep -c . "$OUT/delta-files.txt" || true)
      TOTAL_COUNT=$(git -C "$REPO_DIR" diff --name-only "origin/$BASE_BRANCH...$CURRENT_HEAD_SHA" | grep -c . || true)
      REVIEW_SCOPE=$(dc_review_scope "$DELTA_COUNT" "$TOTAL_COUNT")
    fi
  fi
fi
if [ "$REVIEW_SCOPE" = delta ] && [ "$DELTA_COUNT" -gt 0 ]; then
  # The PR's current hunks for the delta files, and what changed in them since the last verdict.
  tr '\n' '\0' < "$OUT/delta-files.txt" | xargs -0 git -C "$REPO_DIR" diff "origin/$BASE_BRANCH...$CURRENT_HEAD_SHA" -- > "$OUT/delta.patch"
  tr '\n' '\0' < "$OUT/delta-files.txt" | xargs -0 git -C "$REPO_DIR" diff "$DELTA_FROM" "$CURRENT_HEAD_SHA" -- > "$OUT/delta-range.patch"
  # On a restart, the orchestrator saved the previous cycle's stage-02 handoff: its findings are
  # what the new commits are meant to fix.
fi
if [ "$REVIEW_SCOPE" = delta ]; then
  [ "$DELTA_COUNT" -gt 0 ] || : > "$OUT/delta.patch"   # no hunk changed: only the findings re-check
  [ -f "$(dirname "$OUT")/prior-review.md" ] && cp "$(dirname "$OUT")/prior-review.md" "$OUT/prior-review.md"
fi
echo "[setup] patch-id=${SETUP_PATCH_ID:-unknown} prior=${PRIOR_HEAD:-none}/${PRIOR_PATCH_ID:--}/${PRIOR_VERDICT:--} scope=$REVIEW_SCOPE"
```

## Output: handoff.md

Path: `.procedure-output/double-check/01-setup/handoff.md`

```markdown
# Stage 01: Setup

setup_ok: {true|false}

## PR
- Number: {PR}
- Title: {PR_TITLE}
- URL: {PR_URL}
- Branch: `{PR_BRANCH}` → `{BASE_BRANCH}`
- Author: {author}
- Size: +{additions} / -{deletions}, {N} files, {N} commits
- Labels: {labels or none}
- Initial HEAD SHA: {INITIAL_HEAD_SHA}
- Current HEAD SHA: {CURRENT_HEAD_SHA, live; stage 01 never moves it}
- Setup head SHA: {CURRENT_HEAD_SHA, exactly 40 lowercase hex characters}
- Setup patch-id: {SETUP_PATCH_ID, 40 hex, or "unknown"}

## Review Scope
review_scope: {full | delta | carry}
- Last verdict receipt: {PRIOR_HEAD} patch-id {PRIOR_PATCH_ID} verdict {PRIOR_VERDICT} (or "none")
- Delta from: {DELTA_FROM or "n/a"}; delta files: {DELTA_COUNT} of {TOTAL_COUNT}
- Delta artifacts (delta only): `{OUT}/delta-files.txt`, `{OUT}/delta.patch`,
  `{OUT}/delta-range.patch`, `{OUT}/prior-review.md` (restart only)

## Local Checkout
- REPO_DIR: {REPO_DIR}
- Checked out: `{PR_BRANCH}` at the PR head (base merge checked locally, not applied)
- Base merge: {clean (local check, not pushed) | conflict: files | failed: details}

## CI Status
{gh pr checks output, or "not accessible via token"}

## Artifacts (verbatim files, written by shell — not retyped here)
Absolute paths (`$OUT/...`):
- PR body: `{OUT}/pr-body.md` ({bytes} bytes) — the claims source stage 02 reconciles against
  the diff
- First review: `{OUT}/first-review.md` ({bytes} bytes)
- Changed files: `{OUT}/changed-files.txt` (TOTAL line: {copy the one TOTAL line here})
- Full diff: `{OUT}/diff.patch` ({lines} lines, untruncated)

## First-Review Receipt
- Receipt status: {current | stale | absent}
- Receipt head SHA: {REVIEW_HEAD_SHA or none}

`stale` is not a setup failure and does not restart the pipeline. It tells stage 02 not to treat
the old verification manifest as coverage of current HEAD.

```

Keep `handoff.md` short: metadata, receipt and the artifact pointers. Do not paste the body,
comments, manifest or diff into it.

## Success criteria
- `setup_ok: true`
- PR metadata and CI status in the handoff; PR body, first review, changed files and full diff
  written to their artifact files by shell redirection (never retyped)
- Full remote setup head recorded; a failed live read is blocked
- Setup patch-id and `review_scope` recorded; `carry` only for a `ready` verdict on the same
  patch-id, never on a missing or unknown one
- Changed-file manifest carries per-file line counts; the diff file is complete
- PR branch checked out in REPO_DIR at the PR head, base merge checked locally and never pushed;
  REPO_DIR recorded for downstream stages

## Failure
- PR not found / `gh` error → write handoff with `setup_ok: false` + reason (orchestrator emits a blocked outcome)
- Base merge conflicts → write handoff with `setup_ok: false` + conflict file list
  (orchestrator emits a blocked outcome; auto-pylot stage 03 owns the conflict fix)
