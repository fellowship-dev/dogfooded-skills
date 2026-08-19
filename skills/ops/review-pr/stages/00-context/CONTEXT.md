# Stage 00: Context (inline)

## Inputs
- PR number + `org/repo` (from invocation: `PR=$1`, `REPO=$2`)
- GitHub auth is ambient — the pod's `git-credential-pylot` helper and the `gh` shim mint
  short-lived App installation tokens per operation. No token env var is needed or set.

## Task
Run the dedup gate, then gather all PR context and the full diff that the review subagent will
need. This stage runs inline in the orchestrator — do NOT spawn a Task. Read-only: no checkout, no
fixes, no pushes.

If the dedup gate proves that the latest valid review receipt matches current HEAD, the
orchestrator emits the already-complete outcome marker and STOPS. A label without a matching
receipt is stale evidence and continues through the pipeline.

## Steps

### Step 0: Dedup Gate

```bash
export PR=$1
export REPO=$2

PR_SNAPSHOT=$(gh pr view $PR --repo $REPO --json headRefOid,labels,comments)
HEAD_SHA=$(printf '%s' "$PR_SNAPSHOT" | jq -r '.headRefOid')
HAS_REVIEWED=$(printf '%s' "$PR_SNAPSHOT" | jq '[.labels[].name] | contains(["reviewed"])')
REVIEW_STATE=$(printf '%s' "$PR_SNAPSHOT" | jq -r '.comments[].body' \
  | awk '/^<!-- review-state v1$/{buf="";f=1;next} f&&/^-->$/{f=0;last=buf;next} f{buf=buf $0 "\n"} END{printf "%s", last}')
printf '%s' "$REVIEW_STATE" | jq . >/dev/null 2>&1 || REVIEW_STATE=""
REVIEWED_SHA=$(printf '%s' "$REVIEW_STATE" | jq -r '.head_sha // empty' 2>/dev/null || true)

if [ "$HAS_REVIEWED" = "true" ] && [ -n "$REVIEWED_SHA" ] && [ "$REVIEWED_SHA" = "$HEAD_SHA" ]; then
  echo "[pylot] outcome=\"already complete — reviewed receipt matches current HEAD $HEAD_SHA\" status=success"
  exit 0
fi

REVIEW_RUN="fresh"
if [ "$HAS_REVIEWED" = "true" ]; then
  REVIEW_RUN="stale-refresh"
  echo "[review-pr] stale reviewed evidence: receipt=${REVIEWED_SHA:-missing} current=$HEAD_SHA — continuing"
fi
```

If this exits, STOP the whole procedure. Do not spawn stage 01.

### Step 1: Gather Context

```bash
# PR metadata
gh pr view $PR --repo $REPO --json number,title,body,headRefName,baseRefName,url,files,labels,author,additions,deletions,commits

PR_TITLE=$(gh pr view $PR --repo $REPO --json title --jq '.title')
PR_BRANCH=$(gh pr view $PR --repo $REPO --json headRefName --jq '.headRefName')
BASE_BRANCH=$(gh pr view $PR --repo $REPO --json baseRefName --jq '.baseRefName')
PR_URL=$(gh pr view $PR --repo $REPO --json url --jq '.url')
ADDITIONS=$(gh pr view $PR --repo $REPO --json additions --jq '.additions')
DELETIONS=$(gh pr view $PR --repo $REPO --json deletions --jq '.deletions')
FILE_COUNT=$(gh pr view $PR --repo $REPO --json files --jq '.files | length')

# Repo conventions (best-effort)
DECODE_FLAG="-d"; uname 2>/dev/null | grep -qi darwin && DECODE_FLAG="-D"
gh api repos/$REPO/contents/CLAUDE.md --jq '.content' 2>/dev/null | base64 $DECODE_FLAG 2>/dev/null || echo "(no CLAUDE.md)"

# Existing PR comments (avoid duplicating observations)
gh pr view $PR --repo $REPO --json comments --jq '.comments[].body'
gh pr view $PR --repo $REPO --json reviews --jq '.reviews[].body'

# CI status (best-effort)
gh pr checks $PR --repo $REPO 2>/dev/null || echo "CI checks not accessible"
```

### Step 2: Read the Diff

```bash
# Full diff
gh pr diff $PR --repo $REPO

# Changed file names (for quick overview)
gh pr diff $PR --repo $REPO --name-only

# HEAD_SHA was fetched atomically with labels/comments in the dedup snapshot above.
```

Capture the FULL diff into the handoff — the entire diff is reviewed together in stage 01, so the
subagent needs all of it.

### Step 2.5: New Auth Surface Detection (#2918)

Check whether this PR introduces a new auth surface. The rule is deterministic — no judgement.
A new auth surface triggers the `security` label in stage 02 regardless of whether any finding is raised.

```bash
CHANGED_FILES=$(gh pr diff $PR --repo $REPO --name-only 2>/dev/null || echo "")
AUTH_SURFACE="none"
while IFS= read -r f; do
  case "$f" in
    *route-capability.mts) AUTH_SURFACE="new-auth-surface"; break ;;
    modules/auth/*) AUTH_SURFACE="new-auth-surface"; break ;;
    */modules/auth/*) AUTH_SURFACE="new-auth-surface"; break ;;
  esac
done <<< "$CHANGED_FILES"
echo "[review-pr] auth surface: $AUTH_SURFACE"
```

Record `auth_surface: {none|new-auth-surface}` in the handoff. A `new-auth-surface` value means
stage 02 MUST apply the `security` label, even if stage 01 raises zero findings.

### Step 3: Compute the Risk Tier (mechanical — #2210)

Evaluate this rubric against the diff/file list you just fetched. It is deterministic — no
judgement calls beyond what the checks state. Record the tier AND every reason that fired.

**HIGH** if ANY of:
- touches a DB migration (`*/migrations/*` or files creating/altering tables)
- touches auth/credential surface (path or symbol matches `auth|token|jwt|secret|cred|session`)
- ADDED lines call an external service/driver the repo talks to over a boundary (new SDK/client
  imports, new HTTP/queue/DB driver calls) — boundary-shape bugs are the top escape class
- adds or rewires HTTP routes / webhook / event processing
- creates new non-test source files that do NOT mirror an existing module's structure
- > 400 changed lines outside tests/docs

**LOW** if NO HIGH trigger fired AND any of:
- docs/comments-only diff
- ≤ 150 changed lines, tests included, and the change follows an existing pattern in the repo
  (same shape as a sibling module/handler)

**MEDIUM** otherwise.

Later stages may ESCALATE the tier (never lower it) if they find something the rubric missed.

## Output: handoff.md

Append to the handoff, after the PR metadata section:

```markdown
## Risk Tier
- tier: {HIGH|MEDIUM|LOW}
- head_sha: {HEAD_SHA}
- reasons:
  - {each rubric line that fired, or "no HIGH triggers; small template-following diff" for LOW}
```

### Step 3: Closes vs Refs raw data (for the mandatory check in stage 01)

```bash
gh pr view $PR --repo $REPO --json body --jq '.body' | grep -oE '(Closes|Fixes|Resolves) #[0-9]+' | grep -oE '[0-9]+'
```

For each linked issue number found with a `Closes`/`Fixes`/`Resolves` keyword, capture the
TEXT of its acceptance-criteria items — both `- [ ]` and `- [x]`; checkbox state is
auto-generated and meaningless (pylot#2583) — so stage 01 can assess them against the diff
without re-fetching:

```bash
gh issue view ISSUE_N --repo $REPO --json body --jq '.body' | grep -E '^\s*- \[[ x]\]' || echo "NO_AC_ITEMS"
```

### Step 4: Write handoff

## Output: handoff.md

Path: `.procedure-output/review-pr/00-context/handoff.md`

```markdown
# Stage 00: Context — $REPO PR #$PR

## PR Metadata
- Title: {PR_TITLE}
- URL: {PR_URL}
- Branch: {PR_BRANCH} → {BASE_BRANCH}
- Author: {author}
- Size: +{ADDITIONS} / -{DELETIONS} across {FILE_COUNT} files
- Labels: {labels}
- auth_surface: {none|new-auth-surface}
- review_run: {fresh|stale-refresh}
- prior_review_head_sha: {REVIEWED_SHA or none}

## PR Body
{full PR body}

## Repo Conventions (CLAUDE.md)
{full CLAUDE.md content, or "(no CLAUDE.md)"}

## Existing Comments / Reviews
{existing comment + review bodies, or "(none)"}

## CI Status
{gh pr checks output, or "CI checks not accessible"}

## Changed Files
{name-only list}

## Full Diff
```diff
{the complete gh pr diff output}
```

## Closes vs Refs — Raw Data
{for each linked issue: ISSUE_N → its acceptance-criteria item lines verbatim, or NO_AC_ITEMS}
{or "No Closes/Fixes/Resolves keywords found"}
```

## Success criteria
- Head-aware dedup gate ran first; procedure stopped only for a valid current-head receipt
- PR metadata, body, conventions, existing comments, CI status all captured
- The FULL diff captured in the handoff (not truncated)
- Auth surface detection ran; `auth_surface` recorded in handoff
- Closes-vs-Refs raw data captured
- handoff.md written before the stage 01 Task is spawned

## Failure
- PR not found / `gh` auth failure → emit `[pylot] outcome="review-pr failed at stage 00: {reason}" status=failed` and stop
