---
name: weekly-plan
description: Use when running the interactive weekly planning session for a Pylot team (interactive session only — not headless).
argument-hint: "team [org/repo]"
user-invocable: true
allowed-tools: Read, Write, Bash, Glob, Grep
---

# weekly-plan

The hourly `auto-pylot` is a tight executor: it triages cheaply and dispatches the top 1–3 issues. It can't afford a deep roadmap dive every hour, and it has no human to ask. `weekly-plan` is the **interactive** counterpart you run **with a person in the loop** — in a Claude Code session or a pylot chat session — to set direction for the week. It shapes the backlog and the goals; the hourly executes them.

**This is not a cron.** It asks the owner questions and waits for answers, so it only runs where a human can respond. There is **no push channel** — every question and the final digest are presented **in-session**.

**One team per session.** Run it once per team, sequentially. Each session reads and mutates ONLY its own team — no other team's metrics, costs, or config appear anywhere in the session.

**Division of labor:** weekly-plan *shapes* (score, rank, ask, reconcile, triage, decompose, write goals, set budget, activate the hourly). The hourly *executes* (dispatch). One clean kill beats five grazing shots.

## When to Use
- The owner opens a CC or pylot-chat session to plan a team's week before turning the hourly loose.
- The backlog feels stale, mislabeled, or unfocused and the goals need a reset.
- After a big merge wave, to re-aim the hourly.

## Invocation
```
/weekly-plan team [org/repo]      # e.g. /weekly-plan infra — repo arg optionally narrows to one of the team's repos
```

## Environment
```bash
export TEAM="${1:?usage: /weekly-plan team [org/repo]}"; export REPO_FILTER="${2:-}"
PYLOT_API="${PYLOT_API:-${PYLOT_API_URL:-${PYLOT_GATEWAY_URL:?set PYLOT_API or PYLOT_GATEWAY_URL}}}"
```
**GitHub auth — never require a static `GH_TOKEN`.** In an operator or pylot-chat session, auth is already wired via the platform's GitHub App installation tokens (`git-credential-pylot`; `gh` works for every org the App installation covers). In a local Claude Code session, use the identity `gh auth status` already has, routed per target org. If `gh` can't read a team repo, stop and say which org needs access — don't ask for a PAT.

## SESSION SHAPE — briefing first, then a real interview
This is a **planning conversation, not a form**. Target **15–30 minutes** of engaged owner time — depth is the point; a 1-minute session means the owner decided blind.
- **ALL research happens BEFORE the first question**, and the owner gets the full written **briefing** (Step 3) before being asked anything. Decisions come from context on screen, never from memory.
- **Interview one question at a time, spec-plan style** (credit: Matt Pocock's "grill me"). Each question carries its own inline context — full markdown links to the issues/PRs it concerns, what's known, the trade-off — plus **your recommended answer with reasoning**. Wait for the response. Answers open new branches; follow them. Ten or more turns is a healthy session, not a failure.
- **Never use multiple-choice questionnaire widgets** (e.g. `AskUserQuestion`): option descriptions truncate to a few words, links are stripped, and the owner ends up picking between labels they can't evaluate. Ask in plain conversation, full markdown.
- **Resolve dependencies first** — when one decision blocks others, ask the blocker before the dependents. Never re-ask what the briefing or an earlier answer already settled; if the codebase has the answer, explore instead of asking.
- Confirm individually anything destructive or irreversible: issue closes, budget cuts, cron flips.

---

## PRIME DIRECTIVE — research before you promote
Before you rank, promote, or decompose ANY issue, research it **and its linked/sibling issues**: read the code, git history, linked PRs, and the thread. Most of a long-lived backlog is stale, partially done, or superseded. **Don't chase ghosts.** The default triage outcome is CLOSE or RE-SCOPE with cited evidence — promotion to the hourly's queue is *earned*.

## Step 0 — Score last week (plan-vs-actual)
Open the session with how the previous plan actually went. Pull, don't recall:
```bash
GW "$PYLOT_API/admin/goals/$TEAM"            # previous "This week's focus" = what was planned
GW "$PYLOT_API/costs?team=$TEAM&days=7"      # THIS team only — sum cost_usd client-side; never pull or present other teams' numbers
GW "$PYLOT_API/missions?limit=200"           # filter client-side to agents starting "$TEAM." (no team/date param exists)
gh pr list --repo "$R" --state merged --limit 50 --json number,title,mergedAt,labels   # per team repo
```
Present **exactly four numbers** for `$TEAM`, with a trend arrow vs the prior week, one line:
1. **Planned vs merged** — focus-block items that produced a merged PR.
2. **Rework rate** — merged PRs that needed >2 revision rounds.
3. **Cost per merged PR** — team spend ÷ merged PRs.
4. **Top failure cause** — from mission reports/ledger, one phrase.

Mission `status` lies (delivered PRs sometimes report `failed`) — score delivery from GitHub, not from mission status. Last week's misses are this week's first triage candidates.

## Step 1 — Orient (load the ground truth)
Never plan from titles. Load, for `$TEAM`:
```bash
GW "$PYLOT_API/crew" | jq '.crews[]|select(.name=="'"$TEAM"'")|{repos,cron,budget_daily_usd,operators:(.operators|keys)}'
GW "$PYLOT_API/missions?status=running"      # in-flight — never re-rank these as unstarted
for R in $REPOS; do GW "$PYLOT_API/admin/playbooks/$R"; done   # per-repo guardrails (branch model, deploy hazards, test cmds)
```
Scope = the team's full repo list (narrowed by `$REPO_FILTER` if given). Read `docs/principles.md` if present — goals serve the invariants. Playbook guardrails (e.g. "pushing master deploys production") MUST flow into Step 7's goals.

## Step 2 — Compute the signals (metrics + momentum + leverage)
Pull real numbers per repo in scope; don't hand-wave "leverage".
```bash
SINCE=$(date -u -v-10d +%Y-%m-%d 2>/dev/null || date -u -d '10 days ago' +%Y-%m-%d)
# VELOCITY: how fast is the team closing? (throughput is often NOT the constraint — direction is)
gh issue list --repo "$R" --state closed  --limit 200 --json closedAt  --jq "[.[]|select(.closedAt>\"$SINCE\")]|length"
# MOMENTUM: what's actively moving right now?
gh issue list --repo "$R" --state open --limit 300 --json number,title,updatedAt,labels \
  --jq "sort_by(.updatedAt)|reverse|.[:25]|.[]|\"\(.number) \(.updatedAt[0:10]) [\(.labels|map(.name)|join(\",\"))] \(.title)\""
# METRICS: age, priority label, ready-to-work vs blocked/open-questions, install/usage where it applies.
```
For each candidate score three axes: **leverage** (does it unblock the owner / a daily-use surface?), **momentum** (recently active, already in-flight?), **metrics** (ready vs blocked, age, impact ÷ effort). Flag **mislabeled priority** — a daily-use blocker sitting at P2 is a P0 in disguise.

**Weight by task type.** Verifiable chores, fixes, tests, and docs merge at far higher autonomous rates than features and perf work. Fill most of the hourly's weekly queue with verifiable work; treat features/perf as the scarce items that earn the owner's richest specs in Step 4.

## Step 3 — The briefing (the owner reads BEFORE deciding anything)
Present one written, scannable document — full markdown, **every issue/PR as a real link** (`[org/repo#N](url)`) with a sentence of genuine context, never a bare number. Sections:
1. **Last week** — the Step 0 scorecard, plus what merged and **who did it** (agent missions vs other humans on the team — the owner needs to see colleagues' work, not just the fleet's).
2. **In-flight now** — running missions and open agent PRs, where each stands in the review pipeline.
3. **Half-done epics & long-running threads** — multi-week work that's partially landed; what remains per epic. These rot silently if no one names them.
4. **The ready queue** — ranked shortlist with the three signals cited per item; what's ready vs needs re-triage vs blocked on the owner.
5. **Budget view** — this team ONLY, four numbers: daily spend vs cap, cost per merged PR, waste % (spend on failed missions), trend vs prior week; then a budget-cap proposal. No portfolio or cross-team comparison — this is team planning.
6. **What the data can't see** — an explicit prompt for the inputs only the owner has: news from the CEO/co-founders, marketing, customers, money, hiring, anything that re-prioritizes the week. This is the first interview question, not a footnote.

## Step 4 — The interview (one question at a time, owner wins)
Reconcile your data-ranking with the owner's gut as a **conversation**: one question per turn, each with inline context + your recommended answer, then wait. Let each answer reshape what you ask next — new priorities from Step 3.6 typically reorder everything. Surface where the data disagrees with the owner's read ("you ranked chat #1, but it's not dispatch-ready — devbox is the cleaner first fuel"). Walk every branch that affects the week: focus, epics to advance vs park, blocked-on-owner items, budget, the hourly's posture. **The owner's call wins**; record the why next to each decision.

## Step 5 — Deep-triage the shortlist (anti-ghost)
For each promoted candidate, do the research the PRIME DIRECTIVE demands (shallow-clone, read code + history + linked issues). Close done/dup and re-scope partials with a cited comment on the issue. Never close P0/P1.

## Step 6 — Decompose epics into AGENT-READY, hourly-sized slices
A big epic isn't dispatchable. Break each promoted epic into the smallest slices where every slice is:
1. **independently deliverable** (one PR, no cross-slice barrier),
2. **testable in staging** on its own, and
3. **deployable** through the team's pipeline within roughly **one hourly auto-pylot cycle**.

Every issue you file or relabel `ready-to-work` MUST carry the **agent-ready contract** — autonomous completion rates live or die on issue quality:
- **Done-condition** — binary and machine-checkable ("done when X passes in CI / verified by Y in staging"), written BEFORE dispatch;
- **Context links** — the code paths, sibling issues, and PRs the agent needs (agents can't absorb mid-task scope changes — front-load everything);
- **Out-of-scope line** — what NOT to touch;
- **Task-type label** (chore/fix/test/docs/feature/perf).

Note what was sliced and what's deferred.

## Step 7 — Write the reconciled goals
Goals are the hourly's steering wheel — its triage scores every issue against this exact text, so vague goals make a vague fleet. Write `goals.new.md` in this shape:
```markdown
# {Team} Goals

## North Star
One sentence on what this team is for.

## Guardrails — do NOT
- The non-negotiables (from playbooks + owner), e.g. branch/deploy rules, forbidden areas, PR/day caps.

## Current goals
### [P0] Title — done when <binary, verifiable condition>
### [P1] Title — done when <...>

## This week's focus (expires YYYY-MM-DD)
Dated, ready, highest-ROI first targets for the hourly. Stale plans steer worse than no plan:
past the expiry date the hourly should treat this block as void and fall back to safe
maintenance work (deps, flaky tests) instead of free-styling on old priorities.
```
Show the diff against the current goals; **apply only on confirmation**, then record provenance:
```bash
GW -X PUT "$PYLOT_API/admin/goals/$TEAM" -H "Content-Type: text/plain" --data-binary @goals.new.md
GW -X POST "$PYLOT_API/admin/crew/$TEAM/ledger" -H "Content-Type: application/json" \
  -d '{"type":"event","actor":"weekly-plan","summary":"weekly plan written","metadata":{"action":"weekly-plan-update","expires":"YYYY-MM-DD","focus_items":N}}'
rm -f goals.new.md
```
The ledger entry is what next week's Step 0 scores against.

## Step 8 — Set the budget and tune the hourly
Two mutations, both shown to the owner first, both team-local:
```bash
# 1. Budget (from Step 3's approved allocation):
GW -X PATCH "$PYLOT_API/admin/crew/$TEAM" -H "Content-Type: application/json" -d '{"budget_daily_usd": NN}'

# 2. Cron — read-modify-write; the PATCH replaces the WHOLE array, so never send a partial:
GW "$PYLOT_API/crew" | jq '.crews[]|select(.name=="'"$TEAM"'").cron' > cron.json
# edit cron.json: add/enable the auto-pylot entry or adjust its schedule; keep every other entry intact
GW -X PATCH "$PYLOT_API/admin/crew/$TEAM" -H "Content-Type: application/json" \
  -d "$(jq -c '{cron: .}' cron.json)"
GW "$PYLOT_API/crew" | jq '.crews[]|select(.name=="'"$TEAM"'")|{cron,budget_daily_usd}'   # verify
rm -f cron.json
```

## Step 9 — Session summary (in-session, no push)
Present in the session: the Step 0 scorecard, the ranking + the three signals, what was triaged (closed/re-scoped, with refs), the **hourly-ready queue** (top first), the epic slices created, the decisions captured (with the owner's whys), the goals diff, the budget, and the final auto-pylot state (enabled? schedule? first focus?).

Optionally — with the owner's go — dispatch the single top ready item so the week starts now. The task MUST use an explicit `/skill` prefix or it fails at operator boot:
```bash
GW -X POST "$PYLOT_API/dispatch" -H "Content-Type: application/json" \
  -d '{"agent":"'"$TEAM"'.lead","repo":"org/repo","task":"Run /speckit-runner on org/repo#123 — title"}'
```

---

## Boundaries
- **Interactive only** — needs a human to answer; never run headless/cron.
- **One team per session** — reads and mutates only `$TEAM`'s data (goals, budget, cron, costs); other teams never appear in the session.
- **Shapes, doesn't mass-dispatch** — respects the hourly's concurrency cap; at most dispatches the single top ready item (Step 9, explicit `/skill` task).
- **Never** closes P0/P1, rewrites goals, sets budgets, or flips the cron without explicit owner confirmation.

## Anti-patterns
- Ranking by the `P*` label instead of the three signals — the point is to catch mislabeling.
- Hand-waving "leverage" without pulling velocity/momentum numbers.
- Scoring last week from mission `status` instead of merged PRs — delivered work sometimes reports `failed`.
- Goals without binary done-conditions, or a focus block without an expiry date.
- Filing `ready-to-work` issues missing the agent-ready contract (done-condition, context, out-of-scope, type label).
- Decomposing an epic into slices too big to test+ship in one hourly cycle.
- Multiple-choice questionnaire widgets (`AskUserQuestion` and kin) — truncated options strip the context the decision needs.
- Asking anything before the briefing is on screen, or questions with bare issue numbers instead of links + context.
- Asking without recommending — every question proposes an answer and the reasoning behind it.
- Requiring a static `GH_TOKEN` — auth comes from App installation tokens (sessions) or the runner's own `gh` identity (local).
- One mega-session across teams, or touching another team's config from this one.
- Flipping the cron, setting budgets, or rewriting goals without showing the diff and getting a yes.

## Verification
- The session opened with the four plan-vs-actual numbers, trend-arrowed.
- Every promoted item carries the three signals and a one-line justification.
- Every `ready-to-work` issue satisfies the agent-ready contract; the weekly queue skews toward verifiable task types.
- Goals carry done-conditions, guardrails (playbook hazards included), and a dated, expiring focus block; a weekly-plan ledger entry exists (type `event`, action `weekly-plan-update`).
- Budget and cron state match what the owner approved (verified via `GET /crew`).
- The in-flight set from Step 1 appears nowhere in the hourly-ready queue.
- The owner saw the full briefing (incl. colleagues' work, half-done epics, and the "what the data can't see" prompt) before the first question; every question carried links, context, and a recommendation.
- Session depth: 15–30 minutes of real conversation — one question per turn, branches followed to resolution.
