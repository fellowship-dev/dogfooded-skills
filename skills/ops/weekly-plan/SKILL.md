---
name: weekly-plan
description: Weekly roadmap deep-dive for a Pylot team. Deep-triages the full backlog (closes ghosts, re-scopes partials with cited evidence), re-ranks by OWNER LEVERAGE, surfaces open-questions as one batched decision digest, and proposes goal edits. Shapes the queue and the goals that the hourly auto-pylot then executes — it is the thinking counterpart to the hourly's execution.
argument-hint: "org/repo [team]"
user-invocable: true
allowed-tools: Read, Write, Bash, Glob, Grep
---

# weekly-plan

The hourly `auto-pylot` is a tight executor: it triages cheaply and dispatches the top 1–3 issues by impact. It cannot afford a deep roadmap dive every hour. `weekly-plan` is the slow, deliberate counterpart that runs once a week: it reads the *whole* backlog and the code behind it, kills stale work, re-ranks the roadmap by what actually unblocks the owner, batches every open question into one decision digest, and proposes goal edits. The hourly then executes the shaped backlog.

**Division of labor:** weekly-plan *shapes* (close, re-scope, re-rank, ask, propose goals). The hourly *executes* (dispatch). weekly-plan does **not** mass-dispatch missions — at most it dispatches the single top item if the queue is empty. One clean kill beats five grazing shots.

## When to Use

- A weekly cron fires it (operator `infra.cto`, `task: /weekly-plan fellowship-dev/pylot infra`).
- The owner runs `/weekly-plan` to think through roadmap priorities before a sprint.
- The backlog feels stale, mislabeled, or full of half-done work and needs a reset.

## Invocation

```
/weekly-plan org/repo [team]
```

**Examples:**
```
/weekly-plan fellowship-dev/pylot infra
/weekly-plan fellowship-dev/pylot            # team defaults to infra
```

## Token & Environment

In an operator container these are already in the environment (provided at boot). For a local run, source the ops env first.

```bash
export REPO="${1:?usage: /weekly-plan org/repo [team]}"
export TEAM="${2:-infra}"
# Local runs only — in the operator these are already set:
# set -a; source "$HOME/Projects/fellowship-dev/claude-buddy/.env"; set +a
: "${GH_TOKEN:?missing}"; : "${PYLOT_DISPATCH_TOKEN:?missing}"; : "${PYLOT_API_URL:?missing}"
GH(){ gh "$@"; }
GW(){ curl -sS -H "Authorization: Bearer $PYLOT_DISPATCH_TOKEN" "$@"; }
```

---

## PRIME DIRECTIVE — research before you promote

Before you close, re-scope, rank, or propose dispatching ANY issue, research it **and its
linked/sibling issues**: read the code, the git history, the linked PRs, and the issue thread.
Most of a long-lived backlog is stale, partially done, or superseded. **Do not chase ghosts.**
The default outcome of triage is to CLOSE or RE-SCOPE with cited evidence — promotion to the
dispatch queue is *earned* only when the work is real, unstarted, and goal-aligned. This is the
same directive the team GOALS carry; weekly-plan applies it at roadmap scale.

---

## Step 1: Orient

Load the ground truth you will plan against. Never plan from issue titles alone.

```bash
# Current goals (the leverage order you are validating against)
GW "$PYLOT_API_URL/admin/goals/$TEAM" | tee /tmp/wp-goals.md
# Work already in flight — never re-dispatch or re-rank these as if unstarted
GH issue list --repo "$REPO" --state open --label in-progress --label dispatched \
   --json number,title,labels --jq '.[] | "\(.number)\t\(.title)"'
```

Also read `docs/principles.md` in the target repo if present — goals must serve the invariants.

## Step 2: Pull the full backlog

```bash
GH issue list --repo "$REPO" --state open --limit 500 \
  --json number,title,labels,createdAt,updatedAt,comments \
  --jq 'sort_by(.updatedAt) | reverse | .[]
        | "\(.number)\t\(.updatedAt[0:10])\t[\(.labels|map(.name)|join(","))]\t\(.title)"'
```

Group into themes (cluster by label + title): the owner-facing surfaces (chat, devbox, UI),
platform health (reliability, secrets, migrations), epics, and pure polish.

## Step 3: Deep-triage (anti-ghost) — close or re-scope with evidence

For each candidate, do the research the PRIME DIRECTIVE demands. Shallow-clone the repo once and
read the actual code + history rather than guessing from the thread.

```bash
git clone --depth 50 "https://x-access-token:${GH_TOKEN}@github.com/${REPO}.git" /tmp/wp-src 2>/dev/null
cd /tmp/wp-src   # use absolute paths; never cd before dispatching workers
git log --oneline -30 -- <paths the issue touches>
GH issue view <n> --repo "$REPO" --json body,comments  # read the thread + linked refs
```

Decide, with a one-line cited reason on the issue:

| Finding | Action |
|---|---|
| Already implemented / merged | **Close** — cite the commit/PR. Never close P0/P1 (leave for human); `premature-close-checker` is the backstop. |
| Superseded by a newer issue/PR | **Close as duplicate** — link the survivor. |
| Partially done / scope crept | **Re-scope** — edit the body to the remaining vertical slice; relabel. |
| Mislabeled priority | **Re-triage** — fix the `P*` label (see Step 4). |
| Real, unstarted, goal-aligned | **Keep** — promote to the ranked queue (Step 4). |

## Step 4: Re-rank by OWNER LEVERAGE

This is the heart of the skill. Rank not by raw priority label but by **what unblocks the owner**.

1. **Daily-use surfaces the owner cannot use come first.** A bug that blocks the owner from using
   chat or a devbox outranks any backend nicety — even if it is labeled P2. Hunt for this
   mislabeling explicitly: a `chat-ux`/`devbox` "can't use it" bug tagged P2 is a P0 in disguise.
   Fix the label and cite why.
2. **Then platform-health by impact ÷ effort** (reliability, observability, secrets, migrations).
3. **Decompose epics into vertical slices.** A big epic (multi-tenant, GitHub-App) is not
   dispatchable as one mission — break out the smallest independently-deliverable slice and rank
   *that*. (Mirror the `to-issues` / `issue-to-prd` skills.)
4. Produce a ranked **dispatch-ready queue** (issues that survived Step 3 and are fully specified).

## Step 5: Surface open-questions as ONE decision digest

For every `open-questions` (or otherwise under-specified) issue, do the research, then post a
recommendation comment on the issue so the thread carries your reasoning:

```bash
GH issue comment <n> --repo "$REPO" --body "weekly-plan: recommend <option> because <evidence>. Open decision: <the question for the owner>."
```

Then compile **a single batched digest** of every decision the owner must make this week — do not
ping per-issue. Never dispatch an under-specified issue blind: prep it (recommendation + the one
question), then ask. Send the digest to the owner via Telegram (the executor resolves
`TELEGRAM_CHAT_ID`/`TELEGRAM_BOT_TOKEN`):

```bash
GW -X POST "$PYLOT_API_URL/admin/notify" -H "Content-Type: application/json" \
   -d "$(jq -nc --arg t "$DIGEST" '{text:$t}')" || echo "(notify endpoint optional; digest also in the report)"
```

## Step 6: Propose goal edits — never silently overwrite

Diff the current goals against the re-ranked reality. If the leverage order has shifted (e.g. a
surface the owner now needs has risen, or a finished goal should retire), draft the new GOALS.md
and present the diff for approval. Apply only on explicit owner approval or when invoked with an
`--apply` argument — autonomous goal rewrites are how an operator starts chasing the wrong work.

```bash
# Draft only — write the proposal, show the diff, DO NOT PUT without approval:
diff <(cat /tmp/wp-goals.md) /tmp/wp-goals.proposed.md || true
# On approval:
# GW -X PUT "$PYLOT_API_URL/admin/goals/$TEAM" -H "Content-Type: text/plain" --data-binary @/tmp/wp-goals.proposed.md
```

## Step 7: Produce the weekly plan report

Write a mission report (and post the digest to the owner). Sections:

1. **Leverage summary** — the top 3 themes this week, in owner-leverage order, one line each.
2. **Triaged** — counts: closed-as-done, closed-as-dup, re-scoped, re-triaged (with issue refs).
3. **Dispatch-ready queue** — the ranked, fully-specified issues the hourly should execute, top first.
4. **Decisions needed** — the batched open-questions digest (issue ref + recommendation + the question).
5. **Proposed goal changes** — the GOALS diff, or "no change".

---

## Boundaries — hand off to the hourly

- **Do NOT mass-dispatch.** Respect max-3-concurrent and the in-flight set from Step 1. At most,
  dispatch the single top queue item if nothing is running and it is fully specified.
- **Do NOT close P0/P1** — surface them for a human.
- **Do NOT rewrite goals** without owner approval / `--apply`.
- The deliverable is a *shaped backlog + a decision digest + a goals proposal*, not a pile of branches.

## Anti-patterns

- Ranking by the `P*` label instead of by owner leverage — the whole point is to catch mislabeling.
- Triaging from issue titles without reading code/history — that is exactly the ghost-chasing the
  PRIME DIRECTIVE forbids.
- Per-issue owner pings — batch every decision into one digest; the owner's time is sacred.
- Dispatching an under-specified issue "to make progress" — prep it and ask instead.
- Auto-applying goal edits — propose, show the diff, wait.

## Verification

- Every closed issue has a comment citing the commit/PR/duplicate that justifies it.
- Every item in the dispatch-ready queue is fully specified (a worker could start with no questions).
- The decision digest contains every `open-questions` issue, each with a recommendation.
- If goals changed, the report shows the diff and an approval reference; otherwise it says "no change".
- The in-flight set from Step 1 appears nowhere in the dispatch-ready queue.
