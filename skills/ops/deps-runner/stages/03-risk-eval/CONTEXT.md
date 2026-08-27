# Stage 03: Risk Evaluation (subagent — THE isolated critical-judgement stage)

## Inputs
- `.procedure-output/deps-runner/01-scan-context/handoff.md`
- `.procedure-output/deps-runner/02-preflight-baseline/handoff.md`
- `../../shared/risk-matrix.md` (risk classification matrix)

## Task
Classify EVERY candidate dependency PR: what changed, dep type, direct usage, and risk level.
This is the critical-judgement step — it gets a clean context so the verdict is not polluted by
preflight logs or build output.

**SINGLE COHESIVE PASS.** Evaluate all dependency groups in this one stage, one after another,
in this single subagent. Do NOT fan out one subagent per group/PR/dimension. A dependency is
reasoned about as a whole (bump type × direct usage × dep type), and groups are compared
against each other for companion-package issues — that cross-cutting view only exists when one
agent sees them all.

This stage is **pure analysis — no checkouts, no merges, no side effects.** Read diffs only.

## Steps

Read `worker_id` from the stage 02 handoff (it forwards stage 01's, or a respawned
replacement). For each PR (process all groups sequentially):

### a) Check the diff — what changed?
```bash
WID="<worker_id from stage 02 handoff>"

pylot workers prompt "$WID" --mission "$PYLOT_JOB_ID" --wait --timeout 60 \
  "Run: git fetch origin <pr-branch>:refs/remotes/origin/<pr-branch> && git diff main..origin/<pr-branch> --name-only. Report the file list."
pylot workers prompt "$WID" --mission "$PYLOT_JOB_ID" --wait --timeout 60 \
  "Run: git diff main..origin/<pr-branch> -- package.json Gemfile requirements.txt pyproject.toml. Report the diff verbatim."
pylot workers output "$WID" --mission "$PYLOT_JOB_ID"
```
Look at package.json / Gemfile / requirements.txt — what package, what version bump (patch/minor/major)?

### b) Compile-time or runtime dependency?
```bash
# Node: dependencies vs devDependencies
pylot workers prompt "$WID" --mission "$PYLOT_JOB_ID" --wait --timeout 60 \
  "Run: cat package.json | python3 -c \"
import sys,json; p=json.load(sys.stdin)
pkg='<PACKAGE_NAME>'
if pkg in p.get('dependencies',{}): print('RUNTIME')
elif pkg in p.get('devDependencies',{}): print('DEV/BUILD')
else: print('TRANSITIVE')
\". Report the single word printed."

# Rails: Gemfile group
pylot workers prompt "$WID" --mission "$PYLOT_JOB_ID" --wait --timeout 60 \
  "Run: grep -A2 '<gem_name>' Gemfile. Report the matched lines."
pylot workers output "$WID" --mission "$PYLOT_JOB_ID"
```

### c) Used directly in the codebase?
```bash
pylot workers prompt "$WID" --mission "$PYLOT_JOB_ID" --wait --timeout 60 \
  "Run: grep -r '<package-name>' --include='*.{js,ts,jsx,tsx,rb,py}' -l | grep -v node_modules | grep -v vendor. Report the file list, or 'none' if empty."
pylot workers output "$WID" --mission "$PYLOT_JOB_ID"
```

### d) Classify risk
Apply the matrix in `shared/risk-matrix.md`. Note companion-package gaps: Dependabot does NOT
bump companion packages (react without react-dom, @strapi/strapi without @strapi/plugin-*) —
these cause version mismatches that fail builds → classify HIGH and flag.

### e) Write handoff (all PRs).

## Output: handoff.md

Path: `.procedure-output/deps-runner/03-risk-eval/handoff.md`

```markdown
# Stage 03: Risk Evaluation

## Worker
worker_id: {forwarded from stage 02}

## Per-PR Classification
| PR | Package | Old → New | Bump | Dep type | Direct usage | Risk | Notes |
|----|---------|-----------|------|----------|--------------|------|-------|
| #N | name | x.y.z → a.b.c | patch/minor/major | runtime/dev/transitive | yes (N files)/no | low/med/high | companion-gap? lockfile-only? |

## Companion-Package Flags
{any PRs missing a companion bump → HIGH, or "none"}

## Build/Test Order (lowest-risk-first)
{ordered list of PR numbers for stage 04}
```

## Success criteria
- Every candidate PR classified with bump / dep type / direct usage / risk
- All groups evaluated in this single stage (no fan-out)
- `worker_id` forwarded unchanged
- Build/test order produced for stage 04

## Failure
- Cannot read a PR diff → record the PR as "unclassified — flag for Max" rather than guessing;
  continue with the rest. Do not block the stage on one unreadable PR.
