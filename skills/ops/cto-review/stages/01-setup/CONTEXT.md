# Stage 01: Setup — Gather Context, Diff, and Merge State (subagent)

## Inputs
- Arguments only: `PR_NUMBER` and `REPO` (org/repo). No upstream handoff.

## Task
Build everything the review stage needs in one place: repo architectural context, PR metadata, the
FULL diff, and the authoritative merge state. Detect the CLOSED-not-merged case and short-circuit so
the review stage is skipped. Also gate on staging evidence for infra/backend PRs.

## Steps

1. Set up environment and token:
```bash
export PR=$PR_NUMBER
export REPO=$REPO
export GH_TOKEN=$(grep 'GH_PAT_FELLOWSHIP' $HOME/projects/fellowship-dev/claude-buddy/.env | cut -d= -f2)
```
(For a specific team, use the team's `token_var` from crew config instead.)

2. Verify prerequisites:
```bash
gh auth status
gh pr view $PR --repo $REPO   # verify PR exists
```

3. Fetch merge state FIRST — it gates everything downstream:
```bash
gh pr view $PR --repo $REPO --json state,mergedAt,mergeCommit,isDraft \
  --jq '{state:.state, mergedAt:.mergedAt, mergeCommit:.mergeCommit.oid, draft:.isDraft}'
```
- If `state == "CLOSED"` and `mergedAt == null` → **short-circuit**: this PR was closed without
  merging. Set `merge_state: closed-no-merge` and `short_circuit: closed-no-merge` in the handoff,
  skip the remaining gathering steps, and write the handoff. The orchestrator will skip stage 02.
- If `mergedAt != null` → the PR is **already merged**. Set `merge_state: merged`. Continue
  gathering so stage 02 can produce a post-merge review note; stage 03 will NOT attempt a merge.
- Otherwise (`state == "OPEN"`) → set `merge_state: open`. Continue normally.

After resolving merge state, export `MERGE_STATE` for use in later steps (e.g., the evidence gate):
```bash
# Set MERGE_STATE based on the above logic
# e.g.: MERGE_STATE=open | MERGE_STATE=merged | MERGE_STATE=closed-no-merge
export MERGE_STATE
```

4. Gather repo architectural context:
```bash
# Read repo CLAUDE.md for architectural direction
gh api repos/$REPO/contents/CLAUDE.md --jq '.content' | base64 -d 2>/dev/null || echo "(no CLAUDE.md)"

# Recent commit history
gh api "repos/$REPO/commits?per_page=10" --jq '.[].commit.message'

# Open issues — see what the team is working on
gh api "repos/$REPO/issues?state=open&per_page=10" --jq '.[].title'
```

5. Fetch PR metadata:
```bash
gh pr view $PR --repo $REPO --json number,title,body,headRefName,baseRefName,url,files,labels,author,additions,deletions,commits

# Existing labels
gh pr view $PR --repo $REPO --json labels --jq '.labels[].name'

# Changed file list
gh pr diff $PR --repo $REPO --name-only
```

5.1. **Resolve linked spec** — fetch the originating issue or PRD body so stage 02 can check
spec conformance. Run immediately after step 5 (PR metadata is already in hand).

```bash
# Extract PR body and branch name (already fetched in step 5)
PR_BODY=$(gh pr view $PR --repo $REPO --json body --jq '.body' 2>/dev/null || echo "")
BRANCH_REF=$(gh pr view $PR --repo $REPO --json headRefName --jq '.headRefName' 2>/dev/null || echo "")

# Try repo-qualified ref first: org/repo#NNN
SPEC_QUALIFIED=$(echo "$PR_BODY" | grep -oE '[a-zA-Z0-9_.-]+/[a-zA-Z0-9_.-]+#[0-9]+' | head -1 || echo "")

if [ -n "$SPEC_QUALIFIED" ]; then
  SPEC_REPO=$(echo "$SPEC_QUALIFIED" | cut -d'#' -f1)
  SPEC_NUM=$(echo "$SPEC_QUALIFIED" | cut -d'#' -f2)
  SPEC_REF="$SPEC_QUALIFIED"
  SPEC_BODY=$(gh issue view $SPEC_NUM --repo $SPEC_REPO --json body --jq '.body' 2>/dev/null || echo "")
  SPEC_SOURCE="issue"
else
  # Fall back to bare #NNN ref in PR body or branch name
  SPEC_NUM=$(echo "$PR_BODY $BRANCH_REF" | grep -oE '#[0-9]+' | head -1 | tr -d '#' || echo "")
  if [ -n "$SPEC_NUM" ]; then
    SPEC_REF="#$SPEC_NUM"
    SPEC_BODY=$(gh issue view $SPEC_NUM --repo $REPO --json body --jq '.body' 2>/dev/null || echo "")
    SPEC_SOURCE="issue"
  else
    SPEC_REF="none"
    SPEC_BODY="No spec available — skipping conformance check"
    SPEC_SOURCE="none"
  fi
fi

# Guard: treat fetch failures as no-spec
[ -z "$SPEC_BODY" ] && { SPEC_BODY="No spec available — skipping conformance check"; SPEC_SOURCE="none"; SPEC_REF="none"; }
```

5.5. **Staging evidence gate** — check BEFORE proceeding to the expensive diff/full-review path.
Only fires for open PRs; merged/closed PRs skip this gate entirely.

Run this bash block immediately after step 5 (requires `MERGE_STATE` set in step 3):

```bash
# Gate only fires for open PRs — merged/closed PRs skip evidence check
if [ "${MERGE_STATE:-open}" = "open" ]; then
  # Collect changed filenames
  CHANGED_FILES=$(gh pr diff $PR --repo $REPO --name-only 2>/dev/null || echo "")

  # Detect if this PR touches infra/backend paths that require staging evidence
  NEEDS_EVIDENCE=false
  while IFS= read -r f; do
    case "$f" in
      infra/*|gateway/*|crew.mjs) NEEDS_EVIDENCE=true; break ;;
      */migrations/*.sql) NEEDS_EVIDENCE=true; break ;;
    esac
  done <<< "$CHANGED_FILES"

  if [ "$NEEDS_EVIDENCE" = "true" ]; then
    # Fetch PR body to check for evidence section
    PR_BODY=$(gh pr view $PR --repo $REPO --json body --jq '.body' 2>/dev/null || echo "")
    if echo "$PR_BODY" | grep -qF '## Staging Evidence'; then
      # Section exists — now validate it is real, current evidence (not pending/stale)
      # Check for pending placeholder — always block
      if echo "$PR_BODY" | grep -A2 '## Staging Evidence' | grep -qE '>\s*pending'; then
        echo "[cto-review] staging evidence gate: BLOCKED — evidence is pending"
        mkdir -p .procedure-output/cto-review/01-setup
        cat > .procedure-output/cto-review/01-setup/handoff.md << EOF
# Stage 01: Setup

## PR Identity
- PR: #${PR}
- Repo: ${REPO}

## Merge State
- merge_state: open
- short_circuit: missing-staging-evidence

## Changed Files
${CHANGED_FILES}
EOF
        exit 0
      fi

      # N/A bypass — docs-only PRs emit no deployed_sha; pass them through
      if echo "$PR_BODY" | grep -A3 '## Staging Evidence' | grep -qF 'N/A'; then
        echo "[cto-review] staging evidence gate: PASSED (N/A — docs-only PR)"
      else

      # Extract deployed_sha from evidence block and compare to current PR HEAD.
      # Tolerate BOTH the canonical /test-in-staging emitter line ('**Deployed SHA:** `sha`')
      # AND hand-written 'deployed_sha: `sha`' — space-or-underscore, case-insensitive.
      # Pick the sha from a SUCCESSFUL evidence section: skip any match whose section
      # contains BUILD FAILED / (build did not succeed), and otherwise prefer the LAST
      # match (a re-run's good section appears below a prior failed one — see #1667).
      EVIDENCE_SHA=$(echo "$PR_BODY" | python3 -c "
import sys, re
body = sys.stdin.read()
ms = list(re.finditer(r'deployed[ _]sha[^\`\n]*\`([0-9a-f]{7,40})\`', body, re.I))
def failed(i):
    s = ms[i].start()
    h = body.rfind('\n##', 0, s)
    p = ms[i-1].end() if i > 0 else -1
    seg = body[max(h, p, 0):s]
    return bool(re.search(r'BUILD FAILED|build did not succeed', seg, re.I))
good = [m for i, m in enumerate(ms) if not failed(i)]
pick = good[-1] if good else (ms[-1] if ms else None)
print(pick.group(1) if pick else '')
" 2>/dev/null || echo "")
      PR_HEAD_SHA=$(gh pr view $PR --repo $REPO --json headRefOid --jq '.headRefOid' | cut -c1-8)

      SHA_VALID=false
      if [ -n "$EVIDENCE_SHA" ] && [ -n "$PR_HEAD_SHA" ]; then
        EVIDENCE_SHORT=$(printf '%s' "$EVIDENCE_SHA" | cut -c1-8)
        [ "$EVIDENCE_SHORT" = "$PR_HEAD_SHA" ] && SHA_VALID=true
      fi

      if [ "$SHA_VALID" = "true" ]; then
        echo "[cto-review] staging evidence gate: PASSED (deployed_sha=${EVIDENCE_SHORT} matches PR HEAD)"
      else
        if [ -z "$EVIDENCE_SHA" ]; then
          GATE_REASON="deployed_sha not found in evidence block"
        else
          GATE_REASON="deployed_sha ${EVIDENCE_SHORT:-$EVIDENCE_SHA} does not match PR HEAD ${PR_HEAD_SHA} (stale evidence)"
        fi
        echo "[cto-review] staging evidence gate: BLOCKED — $GATE_REASON"
        mkdir -p .procedure-output/cto-review/01-setup
        cat > .procedure-output/cto-review/01-setup/handoff.md << EOF
# Stage 01: Setup

## PR Identity
- PR: #${PR}
- Repo: ${REPO}

## Merge State
- merge_state: open
- short_circuit: missing-staging-evidence

## Changed Files
${CHANGED_FILES}
EOF
        exit 0
      fi
      fi  # end N/A bypass else branch
    else
      echo "[cto-review] staging evidence gate: BLOCKED — ## Staging Evidence missing"
      # Write a minimal handoff for the orchestrator to act on
      mkdir -p .procedure-output/cto-review/01-setup
      cat > .procedure-output/cto-review/01-setup/handoff.md << EOF
# Stage 01: Setup

## PR Identity
- PR: #${PR}
- Repo: ${REPO}

## Merge State
- merge_state: open
- short_circuit: missing-staging-evidence

## Changed Files
${CHANGED_FILES}
EOF
      exit 0
    fi
  fi
fi
```

If `short_circuit: missing-staging-evidence` is set, the orchestrator will post the rejection
comment, apply `needs-work`, and emit the blocked outcome without running stage 02 or 03.

6. Fetch the FULL diff (the review reads this whole, in cohesion):
```bash
gh pr diff $PR --repo $REPO
```
Also pull dependency-manifest changes explicitly so they are easy to spot:
```bash
gh pr diff $PR --repo $REPO -- "**/package.json" "**/Gemfile" "**/requirements.txt" "**/go.mod" "**/pyproject.toml"
```

7. Fetch CI status (the review and act stages must honor it):
```bash
gh pr checks $PR --repo $REPO || echo "CHECKS_UNAVAILABLE"
```

8. Resolve the team merge strategy (default `auto`):
```bash
MERGE_STRATEGY=$(python3 -c "
import yaml
with open('$PYLOT_DIR/crew.yml') as f:
    data = yaml.safe_load(f)
for team, cfg in data.get('crew', {}).items():
    if not isinstance(cfg, dict): continue
    for r in cfg.get('repos', []):
        if r.lower() == '$REPO'.lower():
            print(cfg.get('merge_strategy', 'auto'))
            exit()
print('auto')
" 2>/dev/null || echo "auto")
echo "merge_strategy=$MERGE_STRATEGY"
```
(Crew config may live in the DB rather than a YAML file; if `crew.yml` is absent, default `auto`.)

9. Write handoff (capture the full diff verbatim — stage 02 reviews it from here).

## Output: handoff.md

Path: `.procedure-output/cto-review/01-setup/handoff.md`

```markdown
# Stage 01: Setup

## PR Identity
- PR: #{N}
- Repo: {org/repo}
- Title: {title}
- URL: {url}
- Author: {author}
- Branch: `{headRefName}` -> `{baseRefName}`
- Labels: {comma-separated current labels}
- Additions/Deletions: +{N} / -{N}

## Merge State
- merge_state: {open | merged | closed-no-merge}
- mergedAt: {timestamp or null}
- mergeCommit: {oid or null}
- short_circuit: {none | closed-no-merge | missing-staging-evidence}
- ci_status: {passing | failing | pending | unavailable}
- merge_strategy: {auto | label-only}

## Repo Context
- CLAUDE.md direction: {summary or "(no CLAUDE.md)"}
- Recent commits: {bullet list}
- Open issues: {bullet list}

## PR Description / Linked Issue
{PR body; linked issue number+title if extractable from body or branch}

## Spec
- spec_ref: {SPEC_REF — e.g. #42 | fellowship-dev/pylot#42 | none}
- spec_source: {issue | none}

{SPEC_BODY verbatim — the full issue/PRD text, or "No spec available — skipping conformance check"}

## Changed Files
{file list}

## Full Diff
```diff
{the complete `gh pr diff` output}
```

## Dependency-Manifest Changes
{manifest diff, or "none"}
```

## Success criteria
- Merge state resolved and recorded BEFORE gathering (gates the short-circuit).
- Staging evidence gate evaluated before the expensive full-diff fetch.
- For `open`/`merged`: full diff, metadata, repo context, CI status, and merge strategy all captured.
- For `closed-no-merge` or `missing-staging-evidence`: short_circuit set; remaining gathering skipped.

## Failure
- PR does not exist or `gh auth` fails → write handoff with `status: error` and the reason; the
  orchestrator emits the failure marker.
