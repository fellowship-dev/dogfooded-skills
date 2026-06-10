---
name: weekly-plan
description: Interactive weekly planning session for ONE Pylot team (run in a Claude Code or pylot chat session — NOT headless). Opens with a plan-vs-actual scorecard, ranks candidates by metrics + momentum + leverage, asks the owner everything as one batched recommendation-first questionnaire, deep-triages to kill ghosts, decomposes epics into agent-ready hourly-sized slices, writes goals with binary done-conditions and a dated focus block, sets the team's budget, and activates/tunes the hourly auto-pylot. Run once per team, sequentially. It is the thinking session that shapes what the hourly then executes.
argument-hint: "team [org/repo]"
user-invocable: true
allowed-tools: Read, Write, Bash, Glob, Grep
---

# weekly-plan

The hourly `auto-pylot` is a tight executor: it triages cheaply and dispatches the top 1–3 issues. It can't afford a deep roadmap dive every hour, and it has no human to ask. `weekly-plan` is the **interactive** counterpart you run **with a person in the loop** — in a Claude Code session or a pylot chat session — to set direction for the week. It shapes the backlog and the goals; the hourly executes them.

**This is not a cron.** It asks the owner questions and waits for answers, so it only runs where a human can respond. There is **no push channel** — every question and the final digest are presented **in-session**.

**One team per session.** Run it once per team, sequentially (product teams first, the platform team last, so the platform plan can absorb what the product sessions surfaced). Each session mutates ONLY its own team; cross-team data is read-only context.

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
: "${PYLOT_DISPATCH_TOKEN:?}"
PYLOT_API="${PYLOT_API:-${PYLOT_API_URL:-${PYLOT_GATEWAY_URL:?set PYLOT_API or PYLOT_GATEWAY_URL}}}"
GW(){ curl -sS -H "Authorization: Bearer $PYLOT_DISPATCH_TOKEN" "$@"; }
```
**GitHub auth — never require a static `GH_TOKEN`.** In an operator or pylot-chat session, auth is already wired via the platform's GitHub App installation tokens (`git-credential-pylot`; `gh` works for every org the App installation covers). In a local Claude Code session, use the identity `gh auth status` already has, routed per target org. If `gh` can't read a team repo, stop and say which org needs access — don't ask for a PAT.

## SESSION BUDGET — the owner's time is the scarcest resource
- Target **≤30 minutes of owner attention**. ALL research happens BEFORE the first question.
- Ask everything as **ONE batched questionnaire, ≤10 decisions, recommendation-first**: each item is "Recommendation: X, because Y. Alternatives: Z. Pick 1/2/3." The owner taps numbers; they may bulk-accept ("go with your picks").
- Any topic needing more than 2 exchanges → tag it `[NEEDS CLARIFICATION]` on the issue, park it, and ship the plan without it.
- Individually confirm only destructive or irreversible calls: issue closes, budget cuts, cron flips.

---

## PRIME DIRECTIVE — research before you promote
Before you rank, promote, or decompose ANY issue, research it **and its linked/sibling issues**: read the code, git history, linked PRs, and the thread. Most of a long-lived backlog is stale, partially done, or superseded. **Don't chase ghosts.** The default triage outcome is CLOSE or RE-SCOPE with cited evidence — promotion to the hourly's queue is *earned*.

## Step 0 — Score last week (plan-vs-actual)
Open the session with how the previous plan actually went. Pull, don't recall:
```bash
GW "$PYLOT_API/admin/goals/$TEAM"            # previous "This week's focus" = what was planned
GW "$PYLOT_API/costs/summary?days=7"         # ALL teams, read-only — portfolio view for budget context
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

## Step 3 — Propose the plan (in-session)
Present a short ranked shortlist with the three signals cited per item, plus: what's **ready** vs **needs re-triage**, what's already **in-flight**, and a **budget proposal** for the week (Step 0's portfolio view: concentrate spend on what's converting — a team whose cost-per-merged-PR doubled loses budget to one that's converting; don't peanut-butter). This is a proposal, not a verdict — it sets up Step 4.

## Step 4 — The questionnaire (one batch, owner wins)
Reconcile your data-ranking with the owner's gut in **one batched, recommendation-first questionnaire** (SESSION BUDGET rules). In Claude Code use `AskUserQuestion`; in pylot chat, ask directly and wait. Surface where the data disagrees with the owner's read ("you ranked chat #1, but it's not dispatch-ready — devbox is the cleaner first fuel"). **The owner's call wins**; record the why next to each decision.

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
  -d '{"type":"weekly-plan-update","actor":"weekly-plan","summary":"weekly plan written","metadata":{"expires":"YYYY-MM-DD","focus_items":N}}'
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
- **One team per session** — mutates only `$TEAM`'s goals/budget/cron; other teams' data is read-only context.
- **Shapes, doesn't mass-dispatch** — respects the hourly's concurrency cap; at most dispatches the single top ready item (Step 9, explicit `/skill` task).
- **Never** closes P0/P1, rewrites goals, sets budgets, or flips the cron without explicit owner confirmation.

## Anti-patterns
- Ranking by the `P*` label instead of the three signals — the point is to catch mislabeling.
- Hand-waving "leverage" without pulling velocity/momentum numbers.
- Scoring last week from mission `status` instead of merged PRs — delivered work sometimes reports `failed`.
- Goals without binary done-conditions, or a focus block without an expiry date.
- Filing `ready-to-work` issues missing the agent-ready contract (done-condition, context, out-of-scope, type label).
- Decomposing an epic into slices too big to test+ship in one hourly cycle.
- Open-ended question dribble — batch once, recommend first, park `[NEEDS CLARIFICATION]` topics.
- Requiring a static `GH_TOKEN` — auth comes from App installation tokens (sessions) or the runner's own `gh` identity (local).
- One mega-session across teams, or touching another team's config from this one.
- Flipping the cron, setting budgets, or rewriting goals without showing the diff and getting a yes.

## Verification
- The session opened with the four plan-vs-actual numbers, trend-arrowed.
- Every promoted item carries the three signals and a one-line justification.
- Every `ready-to-work` issue satisfies the agent-ready contract; the weekly queue skews toward verifiable task types.
- Goals carry done-conditions, guardrails (playbook hazards included), and a dated, expiring focus block; a `weekly-plan-update` ledger entry exists.
- Budget and cron state match what the owner approved (verified via `GET /crew`).
- The in-flight set from Step 1 appears nowhere in the hourly-ready queue.
- Total owner attention spent: ≤30 minutes, ≤10 decisions, one batch.
