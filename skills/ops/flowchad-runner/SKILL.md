---
name: flowchad-runner
description: Use when verifying local, preview, production, or recurring critical user flows with browser evidence and selective on-demand deployments.
allowed-tools: Read, Bash, Glob, Grep, Task
---

# flowchad-runner

Verify named FlowChad flows with Playwright/Navvi, capture per-step screenshot + video
evidence, auto-switch to Navvi on CAPTCHA, upload evidence (best-effort), then post results
to GitHub and write a local report. Each stage runs as a focused subagent with isolated
context. The ICM win here is **clean stage contracts + resumability**, NOT parallelism:
flows CANNOT run concurrently because they share browser, session, and persona state and
would collide. Stage 03 walks flows **one at a time in a sequential loop**.

## When to Use

- Explicit pre-merge verification for a PR that affects declared flows
- Production verification after deployment
- Weekly or scheduled critical production smoke runs
- Manual local diagnosis when local CAPTCHA behavior is explicitly configured

## When Not to Use

- Docs-only, Dependabot, or unaffected PRs: return `N/A` without creating a preview
- Static-only analysis presented as interactive certification
- Global provider auto-preview enablement; previews are explicit and on-demand

## Arguments

| Param | Required | Default | Notes |
| ------- | ---------- | --------- | ------- |
| `flow-name` | yes | — | A flow name, or one of the **selectors** `affected` / `all` |
| `repo` | yes | — | Target `org/repo` |
| `pr-number` | no | (none) | If set, post results comment to this PR |
| `trigger` | no | `manual` | `pr` \| `merge` \| `cron` \| `manual` — drives URL resolution + deploy-wait |

Parse positionally from `$ARGUMENTS`: `$1=flow-name $2=repo $3=pr-number $4=trigger`.
Use the literal `none` when a cron/manual invocation has no PR number.

**Selectors are not flow names.** `$1` is a flow name only when it is neither `affected` nor
`all`:

| `flow-name` | Resolves to |
| --- | --- |
| `affected` | the flows whose `affects` globs match the PR's changed files — **the production form**, used by every `flowchad-on-double-checked` dispatch |
| `all` | `smoke.flows`, falling back to `smoke.critical`, falling back to the files in `.flowchad/flows/` |
| *(a name)* | that flow, intersected with the affected set |
| *(any, `trigger=cron`)* | `smoke.critical` |

Never resolve `affected` or `all` to `.flowchad/flows/<selector>.yml`. Intersecting the literal
string `affected` against real flow names yields the empty set and returns a false `N/A` on a PR
that genuinely touches a flow.

## Result Contract

| State | Meaning |
| --- | --- |
| `PASSED` | Required steps passed with real browser evidence |
| `FAILED` | Browser evidence demonstrated a product or flow defect |
| `BLOCKED` | A required target, deploy, browser, persona, or credential was unavailable |
| `N/A` | PR is docs-only, Dependabot, or does not affect a declared flow |

Interactive flows can never pass from curl, static HTML, or bundle inspection. Read
[references/interactive-contract.md](references/interactive-contract.md) when creating or
upgrading `.flowchad/config.yml` and flow definitions.

## What it does

5-stage ICM procedure (all sequential — no parallel stages):

| Stage | Mode | Description |
| ------- | ------ | ------------- |
| 01-preflight | subagent | Validate contract, resolve the flow selector, resolve target/selective preview, deploy-wait, capture-host/persona check |
| 02-load-flows | subagent | Read `.flowchad/config.yml`, validate each flow file exists, load flow YAML, resolve the evidence backend |
| 03-walk-flows | subagent | **Spawn a worker devbox** (the operator has no browser), then a **sequential loop**: for each flow one-at-a-time — connect browser, run steps, per-step screenshot, expect-judgement, CAPTCHA→Navvi, transcript |
| 04-upload-evidence | subagent | Upload screenshots/GIFs with `evidence_class: visual` (permanent URLs), record per-file success/failure, attach an unclassed copy to the requesting conversation when there is one, stop the worker |
| 05-report | inline | Aggregate results, **embed the screenshot URLs per step**, post PR comment, post the verdict to the requesting Slack thread when there is one, create issues on failure, write local report, emit outcome marker |

### Where the browser actually runs

`Dockerfile.operator` installs no browser system libraries; `.devcontainer/Dockerfile` (the repo
devbox/worker image) installs exactly the ones Chromium needs. So **Playwright capture runs on a
worker devbox that stage 03 spawns**, and Navvi — an MCP tool bound to the operator session —
runs in the operator turn. Attempting `chromium.launch()` in the operator turn fails with
*"missing system shared libraries … no sudo/apt-get available"*, which yields a `BLOCKED` verdict
carrying no screenshots. The dispatching automation's context already says *"Use qa worker."*

`pylot.qa` and `booster-pack.qa` — the operators that carry `flowchad-runner` — carry
`pylot-cli` (the injected baseline, so it is on every operator) and `evidence-upload`, which is
everything the operator side needs. They do
**not** need `playwright` or `visual-evidence` installed: the browser requirement belongs to the
worker image, not the operator.

## Handoff locations

All handoffs live in the resolved repo workspace (`$WORKDIR`, see Workspace resolution):

```text
$WORKDIR/.procedure-output/flowchad-runner/{stage}/handoff.md
```

Stage 01 writes the resolved run context (URL, persona, flow list). Each subagent stage
receives ONLY the handoff paths its CONTEXT.md lists as inputs — never orchestrator history.

## Execution

Run stages **strictly sequentially, one after another**. There are NO parallel Task launches
in this procedure. Spawn exactly one Task per subagent stage and await it before the next.

### Workspace resolution (ALWAYS run this first)

The contract, flows, handoffs, and reports all live inside a checkout of the target repo.
Missions run in a workspace that does NOT contain that checkout — never assume the current
directory is the repo. Resolve it deterministically before anything else:

```bash
SKILL_DIR="$HOME/.claude/skills/flowchad-runner"
[ -d "$SKILL_DIR" ] || SKILL_DIR="$(pwd)/.claude/skills/flowchad-runner"

if [ -f .flowchad/config.yml ]; then
  # Already inside a checkout (local/manual runs)
  WORKDIR="$(pwd)"
else
  REPO_NAME="${REPO##*/}"
  REPO_DIR="/tmp/flowchad-${REPO_NAME}"
  if [ ! -d "$REPO_DIR/.git" ]; then
    # Plain https URL — inline credentials would bypass git-credential-pylot
    git clone "https://github.com/${REPO}.git" "$REPO_DIR" 2>/dev/null \
      || gh repo clone "$REPO" "$REPO_DIR"
  fi
  cd "$REPO_DIR"
  git fetch origin --prune
  if [ "$TRIGGER" = pr ] && [ -n "$PR_NUMBER" ] && [ "$PR_NUMBER" != none ]; then
    # Validate the PR's OWN contract — flows/config may change in the PR itself
    git fetch origin "pull/${PR_NUMBER}/head:flowchad-pr-${PR_NUMBER}" --force
    git checkout -f "flowchad-pr-${PR_NUMBER}"
  else
    DEFAULT_BRANCH=$(gh repo view "$REPO" --json defaultBranchRef -q .defaultBranchRef.name)
    git checkout -f "$DEFAULT_BRANCH"
    git reset --hard "origin/${DEFAULT_BRANCH}"
  fi
  WORKDIR="$REPO_DIR"
fi
[ -f "$WORKDIR/.flowchad/config.yml" ] || {
  echo "[pylot] outcome=\"flowchad blocked: $REPO has no .flowchad/config.yml at the resolved ref\" status=blocked"
  exit 0
}
```

Every subsequent command (validator, stage handoffs, reports) runs with `cd "$WORKDIR"`.
Because subagent Tasks do NOT inherit the orchestrator's `cd`, stage prompts must carry
ABSOLUTE paths: substitute the literal values of `$WORKDIR` and `$SKILL_DIR` into the
template below — never pass `.claude/...` or `.procedure-output/...` relative forms.

### Stages 01 → 04 (sequential subagents)

For each stage, spawn one Task. The Task prompt must be self-contained:

- Include only the stage's input handoff paths
- Include the path to the stage's CONTEXT.md
- Do NOT pass orchestrator history or prior reasoning

Task prompt template:

```text
You are running stage {NN}-{name} of the flowchad-runner procedure.

Workspace: cd {WORKDIR} before any step (absolute path — all relative paths resolve there).

Read your stage instructions:
  {SKILL_DIR}/stages/{NN}-{name}/CONTEXT.md

Your inputs:
  {list each input handoff path this stage needs — absolute, under {WORKDIR}}

Write your output to:
  {WORKDIR}/.procedure-output/flowchad-runner/{NN}-{name}/handoff.md

Execute all steps in CONTEXT.md. Write handoff.md before exiting.
```

`{WORKDIR}` and `{SKILL_DIR}` are the absolute values resolved in Workspace resolution.

Do not start the next stage until the current one completes. If stage 01 cannot resolve a
TARGET_URL, or stage 01's deploy-wait fails, or stage 02 finds the flow file missing, emit
the matching outcome marker and stop (those stages also create GitHub issues themselves).

Before stage 01, verify the checked-in contract deterministically (from `$WORKDIR`):

```bash
cd "$WORKDIR"
mkdir -p .procedure-output/flowchad-runner
MODE="$TRIGGER"
[ "$MODE" = merge ] && MODE=production
[ "$MODE" = pr ] && MODE=preview
[ "$MODE" = manual ] && MODE=local
python3 "$SKILL_DIR/scripts/validate_contract.py" \
  --mode "$MODE" --repo "$REPO" --format json \
  > .procedure-output/flowchad-runner/contract.json
```

Any validator error blocks production, preview, and cron certification. Do not silently fall
back to legacy `.url`, template identity, or localhost for those modes.

### Stage 05 (inline)

Run stage 05 yourself in the orchestrator. Read CONTEXT.md:

```text
.claude/skills/flowchad-runner/stages/05-report/CONTEXT.md
```

Aggregate the prior handoffs, post the PR comment / create failure issues, write the local
report file, and emit the `[pylot] outcome=...` marker from the orchestrator (never a subagent).

## Stage handoff chain

```text
01-preflight ─► 02-load-flows ─► 03-walk-flows ─► 04-upload-evidence ─► 05-report (inline)
   (URL,            (validated        (SPAWN WORKER,     (permanent URLs        (PR comment
   persona,          flow YAML,        sequential         per step, upload        WITH the
   capture_host,     evidence          per-flow walk,     accounting,             screenshots,
   FLOWS_TO_RUN)     backend)          results+transcript) STOP WORKER)           issues, marker)
```

The worker devbox spans stages 03→04: stage 03 spawns it and leaves it running so stage 04 can
upload the evidence sitting on its filesystem; stage 04 stops it. Stage 05 stops it as a
backstop if stage 04 did not.

## Exit paths

- **Success**: stage 05 emits `[pylot] outcome="flowchad {flow} on {repo}: all flows passed" status=success`
- **Failure**: stage 05 emits `[pylot] outcome="flowchad {flow} on {repo}: {N} flow(s) failed" status=failed`
  (failure issues already created in stage 05)
- **Blocked**: stage 01 (invalid contract / no URL / deploy failed / no browser) or stage 02
  (flow missing) emits
  `[pylot] outcome="flowchad blocked: {reason}" status=blocked` and the chain stops.
- **N/A**: stage 01 detects an unaffected/docs-only/Dependabot PR and emits
  `[pylot] outcome="flowchad N/A: no affected interactive flow" status=success` without a deploy.

## Hard Rules

1. **All stages run SEQUENTIALLY** — exactly one Task at a time, awaited before the next.
   There is NO parallel fan-out anywhere in this procedure.
2. **Flows are walked ONE AT A TIME inside stage 03** — never one subagent per flow. Flows
   share browser/session/persona state and would collide if run concurrently.
3. **Stage 05 runs inline** — the `[pylot] outcome=...` marker MUST come from the orchestrator,
   never a subagent.
4. **Never pass full orchestrator context** into subagent Task prompts — inputs only.
5. **Each stage writes handoff.md before the next stage reads it.**
6. **Do not skip stages** — every stage executes even if its action is "nothing to do"
   (e.g. evidence upload with backend `none` still writes a handoff).
7. **A broken step is a finding, not a crash** — stage 03 continues collecting evidence after
   a step error; only flow-level pass/fail is judged.
8. **NO Quest, no external dashboards.** Reporting = the local report file + GitHub — plus, *only*
   when the mission's `dispatched_by_conv` is set, one `slack-post` back to the thread that asked
   for the walk. An automation-dispatched run posts nowhere but GitHub.
9. **Interactive PASS requires browser evidence.** Static/curl diagnostics can support a
   `FAILED` or `BLOCKED` result, never `PASSED`.
10. **Production-critical controls are never optional or skipped.** Missing CAPTCHA/Navvi
    capability is `BLOCKED`, not a pass and not a production skip.
11. **Preview creation is selective.** Never enable provider auto-previews; create at most one
    on-demand preview for an explicitly dispatched relevant PR when no staging target exists.
12. **Cron uses `smoke.critical`.** Failures create or update a deduplicated issue with browser
    evidence; the public skill does not own the scheduler.
13. **Never launch a browser in the operator turn.** The operator image has no browser
    libraries. Playwright capture goes to a worker devbox; Navvi stays operator-side. A missing
    capture host is `BLOCKED`, never a static-probe pass.
14. **Every uploaded asset carries `evidence_class: visual`.** Unclassed capability URLs 410
    after 30 days, so an unclassed receipt is a receipt with an expiry date. Publishing a
    classed asset additionally requires `override_policy: true`.
15. **The verdict carries the receipts.** Screenshot URLs are embedded per step in the PR
    comment. A flow-walk verdict with no images is testimony, not evidence.
16. **An upload failure is best-effort to deliver and mandatory to disclose.** It never blocks
    the run and it never disappears — stage 04 counts it, stage 05 prints it. Silence is
    indistinguishable from "no screenshots were needed".

## Reference files

- `CONTEXT.md` — architecture overview
- `stages/NN-name/CONTEXT.md` — per-stage inputs, task, output contract
- `references/interactive-contract.md` — target configuration and CAPTCHA/i18n examples
- `scripts/validate_contract.py` — deterministic environment/flow contract validator
