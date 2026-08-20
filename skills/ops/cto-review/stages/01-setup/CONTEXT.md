# Stage 01: Setup — Gather Context, Diff, and Merge State (subagent)

## Inputs
- Arguments only: `PR_NUMBER` and `REPO` (org/repo). No upstream handoff.

## Task
Build everything the review stage needs in one place: repo architectural context, PR metadata, the
FULL diff, and the authoritative merge state. Detect the CLOSED-not-merged case and short-circuit so
the review stage is skipped. Also gate on staging evidence for infra/backend PRs.

## Steps

1. Set up environment:
```bash
export PR=$PR_NUMBER
export REPO=$REPO
```
(No token export. GitHub auth is ambient — the pod's `git-credential-pylot` helper and the `gh`
shim mint short-lived App installation tokens per operation.)

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
gh pr view $PR --repo $REPO --json number,title,body,headRefName,headRefOid,baseRefName,url,files,labels,author,additions,deletions,commits
CURRENT_HEAD_SHA=$(gh pr view $PR --repo $REPO --json headRefOid --jq '.headRefOid')
BASE_BRANCH=$(gh pr view $PR --repo $REPO --json baseRefName --jq '.baseRefName')

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

5.2. **Fetch all PR comments and label snapshot for receipts (#2918)** — run immediately after
step 5.1. The receipts data feeds stage 02's judgement layer and stage 03's verdict comment.

```bash
# Fetch all comments — capture count, last author, and each body for blocker analysis.
# This is a snapshot at stage 01 time; stage 03 does a fresh label read at merge time.
ALL_COMMENTS=$(gh pr view $PR --repo $REPO --json comments 2>/dev/null || echo '{"comments":[]}')
COMMENT_COUNT=$(echo "$ALL_COMMENTS" | jq '.comments | length')
LAST_COMMENT_AUTHOR=$(echo "$ALL_COMMENTS" | jq -r '.comments | last | .author.login // "none"')
ALL_COMMENT_BODIES=$(echo "$ALL_COMMENTS" | jq -r '.comments[].body' 2>/dev/null || echo "")

# Current label snapshot
CURRENT_LABELS=$(gh pr view $PR --repo $REPO --json labels --jq '[.labels[].name] | join(", ")' 2>/dev/null || echo "")
echo "[cto-review] labels at setup: $CURRENT_LABELS"
echo "[cto-review] comment count: $COMMENT_COUNT, last author: $LAST_COMMENT_AUTHOR"
```

Record in the handoff:
- `comment_count: {N}`
- `last_comment_author: {login | none}`
- Full list of all comment bodies (stage 02 reads them to identify unresolved blockers)

5.3. **Resolve the pipeline lane (#2996)** — one variable, read straight off the label snapshot
from 5.2. It changes the staging-evidence gate (5.5) and the merge bar (stage 03), and nothing
else. It never changes the review's depth or standards.

```bash
LANE="none"
case ",$(echo "$CURRENT_LABELS" | tr -d ' ')," in
  *,lane:fast,*)    LANE="fast" ;;
  *,lane:staging,*) LANE="staging" ;;
esac
echo "[cto-review] lane: $LANE"
```

Record `lane: {fast | staging | none}` in the handoff.

`none` means the PR predates #2996 or its lane label never landed — treat it exactly as
`staging`. Fast is opt-in and requires the explicit `lane:fast` label; there is no inference.

5.5. **Staging evidence gate** — check BEFORE proceeding to the expensive diff/full-review path.
Only fires for open PRs; merged/closed PRs skip this gate entirely.

Run this bash block immediately after step 5 (requires `MERGE_STATE` set in step 3 and `LANE` set
in step 5.3):

```bash
# Gate only fires for open PRs — merged/closed PRs skip evidence check
if [ "${MERGE_STATE:-open}" = "open" ]; then
  # Collect changed filenames
  CHANGED_FILES=$(gh pr diff $PR --repo $REPO --name-only 2>/dev/null || echo "")

  # Detect if this PR touches infra/backend paths that require staging evidence.
  # *.d.mts files are TypeScript type-declaration outputs — they never affect deployed runtime
  # and are excluded from the necessity trigger (pylot#1861 fix 3).
  NEEDS_EVIDENCE=false
  while IFS= read -r f; do
    case "$f" in
      *.d.mts) ;;  # type-declaration files: exclude from necessity trigger
      infra/*|gateway/*|crew.mjs) NEEDS_EVIDENCE=true; break ;;
      */migrations/*.sql) NEEDS_EVIDENCE=true; break ;;
    esac
  done <<< "$CHANGED_FILES"

  # ── FAST-LANE WAIVER (#2996) ────────────────────────────────────────────────
  # WHY THIS IS NOT A HOLE: this gate's `gateway/*` trigger is a whole-directory
  # approximation of "deployable surface". The #2996 lane classifier answers the same
  # question with a precise path list (infra, CI, migrations, gateway/modules/auth/**,
  # gateway/shared/route-capability.mts, secrets, Dockerfile*, harness-versions.json) —
  # anything it puts on lane:fast provably touches none of them. Without this waiver the
  # fast lane is dead on arrival: nearly every pylot PR touches gateway/*, so every fast-lane
  # PR would arrive here, find no staging evidence (test-in-staging never ran, by design),
  # and get bounced to needs-work — a rework loop that can never terminate.
  # It is a WAIVER OF THE EVIDENCE REQUIREMENT ONLY. The #2918 owner gate, the visual-evidence
  # gate, CI, the review findings and the in-deploy full corpus gate are all untouched.
  if [ "$NEEDS_EVIDENCE" = "true" ] && [ "${LANE:-none}" = "fast" ]; then
    NEEDS_EVIDENCE=false
    echo "[cto-review] staging evidence gate: WAIVED — lane:fast (#2996); the lane classifier already proved the diff touches no infra/CI/migration/auth/secrets/Dockerfile/harness path, and test-in-staging is not expected to have run"
  fi

  # Record waiver rationale when the gate is not triggered (pylot#1861 fix 3).
  if [ "$NEEDS_EVIDENCE" = "false" ] && [ -n "$CHANGED_FILES" ]; then
    echo "[cto-review] staging evidence gate: WAIVED — no infra/gateway/migration paths in diff — staging not required"
  fi

  if [ "$NEEDS_EVIDENCE" = "true" ]; then
    # Fetch PR body to check for evidence section
    PR_BODY=$(gh pr view $PR --repo $REPO --json body --jq '.body' 2>/dev/null || echo "")
    # Heading match is format-tolerant (#1754 follow-up): case-insensitive and
    # decoration-tolerant so "## Staging evidence", "## ✅ Staging Evidence — PR cycle",
    # "### Staging Evidence" all count. Substance (the verified build below) is NOT loosened.
    EVIDENCE_HEADING='^#{1,4}[[:space:]].*[Ss]taging[[:space:]]+[Ee]vidence'
    if echo "$PR_BODY" | grep -qiE "$EVIDENCE_HEADING"; then
      # Section exists — now validate it is real, current evidence (not pending/stale)
      # Check for pending placeholder — always block
      if echo "$PR_BODY" | grep -iA2 -E "$EVIDENCE_HEADING" | grep -qE '>\s*pending'; then
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
      if echo "$PR_BODY" | grep -iA3 -E "$EVIDENCE_HEADING" | grep -qiF 'N/A'; then
        echo "[cto-review] staging evidence gate: PASSED (N/A — docs-only PR)"
      else

      # Verify staging evidence against the real build record (fellowship-dev/pylot#1713).
      # The worker emits staging_build_id: `<BUILD_ID>` only when its deploy SUCCEEDED
      # and /health confirmed sha == HEAD. The gate calls /admin/build-worker/<id> and
      # requires SUCCEEDED + sha == HEAD. A pasted deployed_sha string cannot pass this gate.
      PR_HEAD_SHA=$(gh pr view $PR --repo $REPO --json headRefOid --jq '.headRefOid' 2>/dev/null || echo "")
      # PR_HEAD_SHA must be an env-var PREFIX on the python3 command (VAR=x cmd form).
      # Trailing VAR=x after `python3 -c "script"` is argv, not environment — the script
      # would see an empty head_sha and the freshness check silently passes (pylot#1861).
      GATE_RESULT=$(echo "$PR_BODY" | PR_HEAD_SHA="$PR_HEAD_SHA" python3 -c "
import sys, re, os, urllib.request, json

body = sys.stdin.read()
STAGING_URL = os.environ.get('PYLOT_STAGING_URL', '').rstrip('/')
STAGING_TOKEN = os.environ.get('PYLOT_STAGING_DISPATCH_TOKEN', '')
head_sha = os.environ.get('PR_HEAD_SHA', '')
if not head_sha:
    # Fail CLOSED: an unresolved PR HEAD means freshness is unverifiable — an empty
    # head_sha trivially matching any build sha is the exact bug class this guards.
    print('BLOCK:PR head sha unresolved — freshness unverifiable')
    sys.exit(0)

# Format-tolerant build-id extraction (#1754 follow-up + pylot#2097): accept
# staging_build_id / 'staging build id' (':' or '=' or none, backticks optional) AND the
# prose form '**Build:** \`pylot-builder-staging:<id>\`' that real evidence blocks use
# (pylot#2084 false-block). The VALUE is still verified against the live build record
# below — loosening the format never loosens the check.
BUILD_ID_RE = re.compile(r'(?:staging[_ ]build[_ ]id|\*\*build:?\*\*)\s*[:=]?\s*\`?([A-Za-z0-9][A-Za-z0-9:/_-]+)\`?', re.I)
m = BUILD_ID_RE.search(body)
if not m:
    print('BLOCK:no verified build for HEAD')
    sys.exit(0)
build_id = m.group(1)
try:
    req = urllib.request.Request(
        f'{STAGING_URL}/admin/build-worker/{build_id}',
        headers={'Authorization': f'Bearer {STAGING_TOKEN}'},
    )
    with urllib.request.urlopen(req, timeout=10) as resp:
        record = json.loads(resp.read())
except Exception as e:
    print(f'BLOCK:build-record lookup failed: {e}')
    sys.exit(0)
status = record.get('status', '')
if status != 'SUCCEEDED':
    print('BLOCK:build did not succeed')
    sys.exit(0)
build_sha = record.get('sha', '')
short = min(len(head_sha), len(build_sha), 7)
if head_sha[:short] != build_sha[:short]:
    print('BLOCK:build sha mismatch')
    sys.exit(0)
print('PASS:verified build for HEAD')
" 2>/dev/null || echo "BLOCK:build-record check failed (python error)")

      GATE_DECISION=$(echo "$GATE_RESULT" | cut -d: -f1)
      GATE_REASON=$(echo "$GATE_RESULT" | cut -d: -f2-)

      if [ "$GATE_DECISION" = "PASS" ]; then
        echo "[cto-review] staging evidence gate: PASSED ($GATE_REASON)"
      else
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
      # Body had no evidence heading — scan PR comments newest-first (pylot#1861 fix 2).
      # /test-in-staging posts its evidence block as a comment by default; body-only scan
      # was causing false-negative blocks even when evidence existed in a comment.
      # Use jq --arg to select the full body of the first (newest) matching comment in one
      # shot — avoids the line-by-line read trap that would capture only the heading line.
      COMMENT_BODY=$(gh pr view $PR --repo $REPO --json comments 2>/dev/null \
        | jq -r --arg pat "$EVIDENCE_HEADING" \
          '[.comments[]] | reverse | map(select(.body | test($pat;"i"))) | .[0].body // ""' \
        2>/dev/null || true)

      if [ -n "$COMMENT_BODY" ]; then
        echo "[cto-review] staging evidence gate: evidence found in PR comment — evaluating"
        PR_BODY="$COMMENT_BODY"
        # Fall through: $PR_BODY now holds the comment body — reuse the heading/pending/NA/build checks.
        if echo "$PR_BODY" | grep -iA2 -E "$EVIDENCE_HEADING" | grep -qE '>\s*pending'; then
          echo "[cto-review] staging evidence gate: BLOCKED — evidence in comment is pending"
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

        if echo "$PR_BODY" | grep -iA3 -E "$EVIDENCE_HEADING" | grep -qiF 'N/A'; then
          echo "[cto-review] staging evidence gate: PASSED (N/A in comment — docs-only PR)"
        else
          PR_HEAD_SHA=$(gh pr view $PR --repo $REPO --json headRefOid --jq '.headRefOid' 2>/dev/null || echo "")
          GATE_RESULT=$(echo "$PR_BODY" | PR_HEAD_SHA="$PR_HEAD_SHA" python3 -c "
import sys, re, os, urllib.request, json

body = sys.stdin.read()
STAGING_URL = os.environ.get('PYLOT_STAGING_URL', '').rstrip('/')
STAGING_TOKEN = os.environ.get('PYLOT_STAGING_DISPATCH_TOKEN', '')
head_sha = os.environ.get('PR_HEAD_SHA', '')
if not head_sha:
    print('BLOCK:PR head sha unresolved — freshness unverifiable')
    sys.exit(0)

BUILD_ID_RE = re.compile(r'(?:staging[_ ]build[_ ]id|\*\*build:?\*\*)\s*[:=]?\s*\`?([A-Za-z0-9][A-Za-z0-9:/_-]+)\`?', re.I)
m = BUILD_ID_RE.search(body)
if not m:
    print('BLOCK:no verified build for HEAD')
    sys.exit(0)
build_id = m.group(1)
try:
    req = urllib.request.Request(
        f'{STAGING_URL}/admin/build-worker/{build_id}',
        headers={'Authorization': f'Bearer {STAGING_TOKEN}'},
    )
    with urllib.request.urlopen(req, timeout=10) as resp:
        record = json.loads(resp.read())
except Exception as e:
    print(f'BLOCK:build-record lookup failed: {e}')
    sys.exit(0)
status = record.get('status', '')
if status != 'SUCCEEDED':
    print('BLOCK:build did not succeed')
    sys.exit(0)
build_sha = record.get('sha', '')
short = min(len(head_sha), len(build_sha), 7)
if head_sha[:short] != build_sha[:short]:
    print('BLOCK:build sha mismatch')
    sys.exit(0)
print('PASS:verified build for HEAD')
" 2>/dev/null || echo "BLOCK:build-record check failed (python error)")

          GATE_DECISION=$(echo "$GATE_RESULT" | cut -d: -f1)
          GATE_REASON=$(echo "$GATE_RESULT" | cut -d: -f2-)

          if [ "$GATE_DECISION" = "PASS" ]; then
            echo "[cto-review] staging evidence gate: PASSED via comment ($GATE_REASON)"
          else
            echo "[cto-review] staging evidence gate: BLOCKED — $GATE_REASON (evidence in comment)"
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
      else
        echo "[cto-review] staging evidence gate: BLOCKED — no staging evidence in body or comments"
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
fi
```

If `short_circuit: missing-staging-evidence` is set, the orchestrator will post the rejection
comment, apply `needs-work`, and emit the blocked outcome without running stage 02 or 03.

5.6. **Visual evidence gate** — the same shape as 5.5, for user-facing surfaces. Runs only if
5.5 did not short-circuit (one blocker at a time). Only fires for open PRs.

The rule this encodes: *a PR that changes what a user sees must show what a user sees.* Before
this gate the requirement existed only as repo prose, so it was enforced by an LLM reading
CLAUDE.md — which is what produced 29 consecutive "human action required" comments on one PR
(fellowship-dev/pylot#2802, #2829). The waiver is deliberately generous: on the last 45 PRs in
that repo, 39 were waived without the gate reading a single body.

```bash
if [ "${MERGE_STATE:-open}" = "open" ]; then
  CHANGED_FILES=$(gh pr diff $PR --repo $REPO --name-only 2>/dev/null || echo "")
  PR_HEAD_SHA=$(gh pr view $PR --repo $REPO --json headRefOid --jq '.headRefOid' 2>/dev/null || echo "")

  # Per-repo opt-in override: .pylot/ui-paths — one glob per line, '#' comments, leading '!'
  # excludes. Read at the PR HEAD so a PR that edits the list is judged by its own list; fall
  # back to the default branch, then to absent. A fetch failure degrades to "absent", which can
  # only ever NARROW the gate — an API hiccup must never manufacture a block.
  UI_PATHS=$(gh api "repos/$REPO/contents/.pylot/ui-paths?ref=$PR_HEAD_SHA" --jq '.content' 2>/dev/null | base64 -d 2>/dev/null \
          || gh api "repos/$REPO/contents/.pylot/ui-paths" --jq '.content' 2>/dev/null | base64 -d 2>/dev/null \
          || true)

  # Trigger: is there a user-facing surface in the diff? Prints "ext:<file>", "glob:<file>",
  # or "none". Exclusions always win; an explicit .pylot/ui-paths glob overrides the built-in
  # NOT_UI carve-out (which mirrors the *.d.mts exclusion the staging gate already has).
  #
  # STRICT INCLUDES: if .pylot/ui-paths carries at least one INCLUDE line, that list is the
  # repo's complete declaration of its UI surface and the built-in extension default is not
  # consulted at all. A repo that knows where its UI lives should not also be judged by a
  # file-extension guess — that guess is what fired on a skills library shipping an HTML
  # report template (dogfooded-skills#125). A file with only `!` exclusion lines does NOT
  # enable strict mode: it narrows the extension default, which stays in force.
  UI_TRIGGER=$(printf '%s\n' "$CHANGED_FILES" | UI_PATHS="$UI_PATHS" python3 -c "
import sys, os, re
UI_EXT = re.compile(r'\.(tsx|jsx|vue|svelte|css|scss|sass|less|html|erb)\$', re.I)
NOT_UI = re.compile(r'(\.d\.m?ts|\.(test|spec|stories|example|config)\.[^/]+)\$', re.I)
def globre(g):
    out, i = '', 0
    while i < len(g):
        if g[i] == '*':
            if g[i:i+2] == '**':
                out += '.*'; i += 2; continue
            out += '[^/]*'
        elif g[i] == '?':
            out += '[^/]'
        else:
            out += re.escape(g[i])
        i += 1
    return re.compile('^' + out + '\$')
inc, exc = [], []
for ln in os.environ.get('UI_PATHS', '').splitlines():
    ln = ln.strip()
    if not ln or ln.startswith('#'):
        continue
    (exc if ln.startswith('!') else inc).append(globre(ln.lstrip('!')))
for f in sys.stdin.read().splitlines():
    f = f.strip()
    if not f or any(g.match(f) for g in exc):
        continue
    if any(g.match(f) for g in inc):
        print('glob:' + f); break
    if not inc and UI_EXT.search(f) and not NOT_UI.search(f):
        print('ext:' + f); break
else:
    print('none')
" 2>/dev/null || echo "none")

  if [ "$UI_TRIGGER" = "none" ]; then
    # Record the waiver rationale, exactly as the staging gate does when it does not fire.
    echo "[cto-review] visual evidence gate: WAIVED — no user-facing surface in diff"
  else
    # Parse the body. VIS_RESULT is PASS:<reason> or BLOCK:<reason>.
    VIS_PARSE="
import sys, re
body = sys.stdin.read()
# Format-tolerant heading, mirroring the staging gate's: case-insensitive, decoration-tolerant,
# so '## Visual Evidence', '### 📸 Visual Evidence — after rework', '#### visual evidence' count.
HEADING = re.compile(r'^#{1,4}\s.*visual\s+evidence', re.I | re.M)
IMG = re.compile(r'!\[[^\]]*\]\(\s*(https?://[^)\s]+)|<img\b[^>]*\bsrc\s*=\s*[\"\'](https?://[^\"\']+)', re.I)
m = HEADING.search(body)
if not m:
    print('BLOCK:no Visual Evidence section'); sys.exit(0)
lines = body.splitlines()
h = next(i for i, ln in enumerate(lines) if HEADING.search(ln))
# '> pending' within 2 lines is a placeholder, not evidence — same as the staging gate.
if re.search(r'>\s*pending', '\n'.join(lines[h:h+3]), re.I):
    print('BLOCK:evidence is pending'); sys.exit(0)
# Waiver: literal 'N/A' within 3 lines of the heading. Byte-equivalent to the staging gate's
# 'grep -iA3 \$HEADING | grep -qiF N/A'. The canonical spelling is
# 'N/A — no user-facing surface'; only the N/A token is parsed, the rationale is for humans.
if 'n/a' in '\n'.join(lines[h:h+4]).lower():
    print('PASS:waived — N/A within 3 lines of the heading'); sys.exit(0)
# Evidence must live INSIDE the section: heading line -> next heading of any level, or EOF.
end = len(lines)
for j in range(h + 1, len(lines)):
    if re.match(r'^#{1,4}\s', lines[j]):
        end = j; break
n = len(IMG.findall('\n'.join(lines[h:end])))
if n:
    print('PASS:%d embedded image(s) in the section' % n)
else:
    print('BLOCK:section present but carries no embedded image and no N/A waiver')
"
    PR_BODY=$(gh pr view $PR --repo $REPO --json body --jq '.body' 2>/dev/null || echo "")
    VIS_RESULT=$(printf '%s' "$PR_BODY" | python3 -c "$VIS_PARSE" 2>/dev/null || echo "BLOCK:visual parse failed (python error)")

    if [ "${VIS_RESULT%%:*}" = "BLOCK" ]; then
      # Body missed — scan PR comments newest-first, and ONLY comments that themselves carry
      # the heading (the same containment rule the staging gate uses). This is what lets a
      # FlowChad verdict or a capture-mission comment satisfy the gate; a stray image in an
      # unrelated comment cannot.
      VIS_COMMENT=$(gh pr view $PR --repo $REPO --json comments 2>/dev/null \
        | jq -r '[.comments[]] | reverse
                 | map(select(.body | test("^#{1,4}\\s.*[Vv]isual\\s+[Ee]vidence";"im")))
                 | .[0].body // ""' 2>/dev/null || true)
      if [ -n "$VIS_COMMENT" ]; then
        VIS_FROM_COMMENT=$(printf '%s' "$VIS_COMMENT" | python3 -c "$VIS_PARSE" 2>/dev/null || echo "BLOCK:visual parse failed")
        [ "${VIS_FROM_COMMENT%%:*}" = "PASS" ] && VIS_RESULT="$VIS_FROM_COMMENT (in comment)"
      fi
    fi

    if [ "${VIS_RESULT%%:*}" = "PASS" ]; then
      echo "[cto-review] visual evidence gate: PASSED (${VIS_RESULT#*:})"
    else
      # NOT a blocker. Missing visual evidence is recorded as a NOTICE and the review runs to
      # completion — see "Why this is a notice, not a gate" below. VIS_NOTICE is carried into
      # the handoff and surfaced by stage 03 as an advisory line; it sets no short_circuit,
      # applies no label, and never suppresses stages 02/03.
      echo "[cto-review] visual evidence: NOTICE — ${VIS_RESULT#*:} (trigger: $UI_TRIGGER)"
      VIS_NOTICE="yes"
    fi
  fi
fi
```

### Why this is a notice, not a gate

This check used to set `short_circuit: missing-visual-evidence`, which skipped stages 02 and 03
entirely and applied `needs-work`. That was wrong in both directions:

- **It withheld the review that was already earned.** On dogfooded-skills#125 a 12,208-line PR had
  already surfaced two real test-infrastructure bugs; the missing screenshot threw the deeper
  review away and returned a needs-work label instead of the findings. A missing picture is not a
  reason to stop reading the code.
- **The remedy is not always cheap.** The self-serve path assumes a capturable running surface. For
  a skill whose "UI" is an HTML report rendered from its own pipeline, producing the screenshot
  means running the entire pipeline against real data on a browser-capable devbox — far more
  expensive than the evidence is worth, and the auto-dispatch loop cannot do it unattended.

So: the review always runs, and missing visual evidence is reported as an advisory line in the
review comment. It never blocks a merge and never applies a label on its own. The anti-nag property
that motivated the machine-parsed gate is preserved — the verdict is still deterministic and stated
once, rather than an LLM re-litigating it every run — but it is now advice, not a wall.

The notice text MUST still name the self-serve path, and MUST NOT contain a literal `Visual
Evidence` markdown heading at column 0 (the comment scan would otherwise read the notice back as
evidence on the next run and grade its own homework).

6. Extract the LAST `review-state v1` block from the PR comments (#2210) — the machine ledger the
   earlier pipeline stages accumulated (findings with statuses + verification manifest + risk tier):
```bash
REVIEW_STATE=$(gh pr view $PR --repo $REPO --json comments --jq '.comments[].body' \
  | awk '/^<!-- review-state v1$/{buf="";f=1;next} f&&/^-->$/{f=0;last=buf;next} f{buf=buf $0 "\n"} END{printf "%s", last}')
echo "$REVIEW_STATE" | jq . >/dev/null 2>&1 || REVIEW_STATE="none"
```
   Record it verbatim in the handoff's `## Review State` section (`none` if absent/unparseable —
   pre-#2210 PRs).

7. Fetch the FULL diff (the review reads this whole, in cohesion):
```bash
gh pr diff $PR --repo $REPO
```
Also pull dependency-manifest changes explicitly so they are easy to spot:
```bash
gh pr diff $PR --repo $REPO -- "**/package.json" "**/Gemfile" "**/requirements.txt" "**/go.mod" "**/pyproject.toml"
```

8. Classify CI once at the reviewed head (the review and act stages consume this authoritative
   result; never substitute `gh pr checks` exit status). The classifier is fail-closed: an API,
   authorization, JSON, workflow-parsing, or required-context lookup failure is `block`, not an
   empty check set. Collect all three expected-check sources at `CURRENT_HEAD_SHA`:

```bash
CI_DIR="skills/cto-review/stages/01-setup"
test -f "$CI_DIR/ci_gate.py" || CI_DIR="skills/ops/cto-review/stages/01-setup"

# Check-runs response for the exact reviewed SHA. Preserve API failure separately from zero runs.
CHECK_RUNS=$(gh api "repos/$REPO/commits/$CURRENT_HEAD_SHA/check-runs?per_page=100" 2>/dev/null) || CHECK_RUNS_OK=false
: "${CHECK_RUNS_OK:=true}"

# Legacy commit-status contexts are distinct from check-runs. Required contexts may be supplied by
# either API, so omitting this response would falsely block a green external status or waive it.
COMMIT_STATUSES=$(gh api "repos/$REPO/commits/$CURRENT_HEAD_SHA/status" 2>/dev/null) || COMMIT_STATUSES_OK=false
: "${COMMIT_STATUSES_OK:=true}"

# A 404 means no branch protection is configured; every other failure remains a block.
REQUIRED=$(gh api "repos/$REPO/branches/$BASE_BRANCH/protection/required_status_checks" 2>/tmp/cto-required.err) || REQUIRED_STATUS=$?
if grep -q '404' /tmp/cto-required.err; then
  REQUIRED='{"contexts":[]}'
  REQUIRED_OK=true
elif [ "${REQUIRED_STATUS:-0}" = "0" ]; then
  REQUIRED_OK=true
else
  REQUIRED_OK=false
fi

# Rulesets can add required checks independently of legacy branch protection. A 404 means no
# matching ruleset; any other error is evidence we cannot safely classify as N/A.
RULESETS=$(gh api "repos/$REPO/rules/branches/$BASE_BRANCH" 2>/tmp/cto-rulesets.err) || RULESETS_STATUS=$?
if grep -q '404' /tmp/cto-rulesets.err; then
  RULESETS='[]'
elif [ "${RULESETS_STATUS:-0}" != "0" ]; then
  REQUIRED_OK=false
fi

# Enumerate workflow files at the PR head. Parse every declaration; a lookup or parsing failure
# blocks rather than incorrectly waiving CI. `pr_workflows` holds PR-triggered workflows only.
WORKFLOW_TREE=$(gh api "repos/$REPO/git/trees/$CURRENT_HEAD_SHA?recursive=1" 2>/dev/null) || WORKFLOW_TREE_OK=false
: "${WORKFLOW_TREE_OK:=true}"
PR_WORKFLOWS='[]'
if [ "$WORKFLOW_TREE_OK" = true ]; then
  WORKFLOW_PATHS=$(echo "$WORKFLOW_TREE" | python3 -c '
import json, sys
payload = json.load(sys.stdin)
if payload.get("truncated") is True or not isinstance(payload.get("tree"), list):
    sys.exit(1)
for item in payload["tree"]:
    if not isinstance(item, dict):
        sys.exit(1)
    path = item.get("path", "")
    if path.startswith(".github/workflows/") and path.endswith((".yml", ".yaml")):
        print(path)
') || WORKFLOW_TREE_OK=false
fi
if [ "$WORKFLOW_TREE_OK" = true ]; then
  PR_WORKFLOWS=$(printf '%s\n' "$WORKFLOW_PATHS" | while IFS= read -r path; do
    content=$(gh api "repos/$REPO/contents/$path?ref=$CURRENT_HEAD_SHA" --jq .content 2>/dev/null | base64 -d) || exit 1
    if printf '%s\n' "$content" | python3 -c '
import re, sys
text = sys.stdin.read()
trigger = re.compile(r"^[ \\t]*(pull_request|pull_request_target|[\\\"\\x27](pull_request|pull_request_target)[\\\"\\x27])[ \\t]*:", re.M)
inline = re.compile(r"^[ \\t]*on[ \\t]*:[^#\\n]*(pull_request|pull_request_target)", re.M)
sys.exit(0 if trigger.search(text) or inline.search(text) else 1)
'; then printf '%s\n' "$path"; fi
  done | jq -Rsc 'split("\n") | map(select(length > 0))') || WORKFLOW_TREE_OK=false
fi

CI_EVIDENCE=$(jq -n \
  --argjson runs "${CHECK_RUNS:-null}" \
  --argjson statuses "${COMMIT_STATUSES:-null}" \
  --argjson required "${REQUIRED:-null}" \
  --argjson rulesets "${RULESETS:-null}" --argjson workflows "${PR_WORKFLOWS:-null}" \
  --arg check_ok "$CHECK_RUNS_OK" --arg status_ok "$COMMIT_STATUSES_OK" --arg required_ok "$REQUIRED_OK" --arg workflow_ok "$WORKFLOW_TREE_OK" \
  '{check_runs_ok: ($check_ok == "true"), commit_statuses_ok: ($status_ok == "true"), expected_checks_ok: ($required_ok == "true"), pr_workflows_ok: ($workflow_ok == "true"), check_runs: ($runs.check_runs // null), commit_statuses: ($statuses.statuses // null), expected_checks: (($required.contexts // []) + ($required.checks // [] | map(.context // .)) + [$rulesets[]?.rules[]? | select(.type == "required_status_checks") | .parameters.required_status_checks[]?]), pr_workflows: $workflows}')
CI_RESULT=$(printf '%s' "$CI_EVIDENCE" | python3 "$CI_DIR/ci_gate.py")
CI_CLASSIFICATION=$(echo "$CI_RESULT" | jq -r .classification)
CI_REASON=$(echo "$CI_RESULT" | jq -r .reason)
echo "[cto-review] CI classification: $CI_CLASSIFICATION — $CI_REASON"
```

`pass` requires every observed check to be completed with conclusion `success`. `block` covers a
pending, failing, cancelled, skipped, neutral, unknown, or missing expected check. Only a successful
zero-check response with no required context and no pull-request workflow is
`na-no-configured-checks`; render its receipt exactly as `CI: N/A — no configured checks`.

9. Resolve the team merge strategy from Pylot's DB-authoritative live team
   configuration. Automated merge authority is explicit: only
   `deploy.release_mode=ship` maps to `auto`; `propose`, missing, malformed,
   ambiguous, or unavailable configuration maps to `label-only`:
```bash
MERGE_RESOLVER="skills/cto-review/resolve-merge-strategy.sh"
test -f "$MERGE_RESOLVER" || MERGE_RESOLVER="skills/ops/cto-review/resolve-merge-strategy.sh"
MERGE_STRATEGY=$(bash "$MERGE_RESOLVER" "$REPO")
echo "merge_strategy=$MERGE_STRATEGY"
```
Do not read `crew.yml`: live Pylot team configuration is stored in the database.
Do not infer merge authority from a missing file or from the model's judgement.

10. Write handoff (capture the full diff verbatim — stage 02 reviews it from here).

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
- Current HEAD SHA: {CURRENT_HEAD_SHA}
- Labels: {comma-separated current labels}
- Additions/Deletions: +{N} / -{N}

## Label Snapshot
Labels present at stage-01 time: {comma-separated list, or "none"}
(Note: stage 03 re-reads labels fresh from GitHub at merge time — this snapshot is for stage 02 judgement only.)

## Lane (#2996)
- lane: {fast | staging | none}
- staging_evidence_waived_by_lane: {true | false}
(`none` is treated as `staging` everywhere. Stage 03 re-reads the lane fresh at merge time.)

## Comment Thread Summary
- comment_count: {N}
- last_comment_author: {login | none}

## All PR Comments (for stage 02 blocker analysis)
{each comment body verbatim, separated by --- dividers, or "(no comments)"}

## Merge State
- merge_state: {open | merged | closed-no-merge}
- mergedAt: {timestamp or null}
- mergeCommit: {oid or null}
- short_circuit: {none | closed-no-merge | missing-staging-evidence}
- ci_classification: {pass | block | na-no-configured-checks}
- ci_receipt: {"CI: N/A — no configured checks" for N/A, otherwise the classifier reason}
- ci_observed_checks: {check-run names/status/conclusion from the reviewed head}
- ci_expected_checks: {required contexts/ruleset checks and PR workflow paths, or "none"}
- merge_strategy: {auto | label-only}

## Visual Evidence
- trigger: {ext:<file> | glob:<file> | none}
- result: {PASS:<reason> | BLOCK:<reason> | waived}
- notice: {yes | no}
(Advisory only — never a short_circuit. `notice: yes` means stage 03 appends the advisory line.)

## Repo Context
- CLAUDE.md direction: {summary or "(no CLAUDE.md)"}
- Recent commits: {bullet list}
- Open issues: {bullet list}

## PR Description / Linked Issue
{PR body; linked issue number+title if extractable from body or branch}

## Review State
{the LAST review-state v1 JSON verbatim — or "none" (pre-#2210 PR or unparseable block)}

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
- Label snapshot and all comment bodies captured (step 5.2) — feeds stage 02 judgement layer.
- Lane resolved from the label snapshot (step 5.3) and recorded; absent label recorded as `none`.
- Staging evidence gate evaluated before the expensive full-diff fetch, with the `lane:fast`
  waiver applied and its rationale echoed when it fires.
- Visual evidence evaluated after it, and only if it did not short-circuit. Its verdict is recorded
  as `notice`; it never sets a short_circuit and never suppresses stages 02/03.
- For `open`/`merged`: full diff, metadata, repo context, CI classification/evidence, and merge
  strategy all captured.
- For `closed-no-merge` or `missing-staging-evidence`: short_circuit set; remaining gathering skipped.

## Failure
- PR does not exist or `gh auth` fails → write handoff with `status: error` and the reason; the
  orchestrator emits the failure marker.
