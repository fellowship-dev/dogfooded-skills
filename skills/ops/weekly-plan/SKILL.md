---
name: weekly-plan
description: Interactive weekly roadmap session for a Pylot team (run in a Claude Code or pylot chat session — NOT headless). Pulls goals + backlog, ranks candidates by metrics + momentum + leverage, asks the owner for their perceived priorities and reconciles, deep-triages to kill ghosts, decomposes epics into hourly-sized testable+deployable slices, writes the reconciled goals, and activates/tunes the hourly auto-pylot. It is the thinking session that shapes what the hourly then executes.
argument-hint: "org/repo [team]"
user-invocable: true
allowed-tools: Read, Write, Bash, Glob, Grep
---

# weekly-plan

The hourly `auto-pylot` is a tight executor: it triages cheaply and dispatches the top 1–3 issues. It can't afford a deep roadmap dive every hour, and it has no human to ask. `weekly-plan` is the **interactive** counterpart you run **with a person in the loop** — in a Claude Code session or a pylot chat session — to set direction for the week. It shapes the backlog and the goals; the hourly executes them.

**This is not a cron.** It asks the owner questions and waits for answers, so it only runs where a human can respond. There is **no Telegram, no push** — every question and the final digest are presented **in-session**.

**Division of labor:** weekly-plan *shapes* (rank, ask, reconcile, triage, decompose, write goals, activate the hourly). The hourly *executes* (dispatch). One clean kill beats five grazing shots.

## When to Use
- The owner opens a CC or pylot-chat session to plan the week / set direction before turning the hourly loose.
- The backlog feels stale, mislabeled, or unfocused and the goals need a reset.
- After a big merge wave, to re-aim the hourly.

## Invocation
```
/weekly-plan org/repo [team]      # e.g. /weekly-plan fellowship-dev/pylot infra  (team defaults to infra)
```

## Environment
In a session these are already set (operator/chat boot); for a local run, source the ops env.
```bash
export REPO="${1:?usage: /weekly-plan org/repo [team]}"; export TEAM="${2:-infra}"
: "${GH_TOKEN:?}"; : "${PYLOT_DISPATCH_TOKEN:?}"; : "${PYLOT_API_URL:?}"
GW(){ curl -sS -H "Authorization: Bearer $PYLOT_DISPATCH_TOKEN" "$@"; }
```

---

## PRIME DIRECTIVE — research before you promote
Before you rank, promote, or decompose ANY issue, research it **and its linked/sibling issues**: read the code, git history, linked PRs, and the thread. Most of a long-lived backlog is stale, partially done, or superseded. **Don't chase ghosts.** The default triage outcome is CLOSE or RE-SCOPE with cited evidence — promotion to the hourly's queue is *earned*.

## Step 1 — Orient (load the ground truth)
Never plan from titles. Load, for `$TEAM`:
```bash
GW "$PYLOT_API_URL/admin/goals/$TEAM"                 # current goals you're validating against
GW "$PYLOT_API_URL/missions?status=running"           # in-flight — never re-rank these as unstarted
GW "$PYLOT_API_URL/crew" | jq '.crews[]|select(.name=="'"$TEAM"'")|{cron,repos}'  # hourly state + scope
```
Read `docs/principles.md` if present — goals serve the invariants.

## Step 2 — Compute the signals (metrics + momentum + leverage)
Pull real numbers; don't hand-wave "leverage".
```bash
SINCE=$(date -u -v-10d +%Y-%m-%d 2>/dev/null || date -u -d '10 days ago' +%Y-%m-%d)
# VELOCITY: how fast is the team closing? (throughput is often NOT the constraint — direction is)
gh issue list --repo "$REPO" --state closed  --limit 200 --json closedAt  --jq "[.[]|select(.closedAt>\"$SINCE\")]|length"
# MOMENTUM: what's actively moving right now?
gh issue list --repo "$REPO" --state open --limit 300 --json number,title,updatedAt,labels \
  --jq "sort_by(.updatedAt)|reverse|.[:25]|.[]|\"\(.number) \(.updatedAt[0:10]) [\(.labels|map(.name)|join(\",\"))] \(.title)\""
# METRICS: age, priority label, ready-to-work vs blocked/open-questions, install/usage where it applies.
```
For each candidate score three axes: **leverage** (does it unblock the owner / a daily-use surface?), **momentum** (recently active, already in-flight?), **metrics** (ready vs blocked, age, impact ÷ effort). Flag **mislabeled priority** — a daily-use blocker sitting at P2 is a P0 in disguise.

## Step 3 — Propose a ranking (in-session)
Present, in the session, a short ranked shortlist with the three signals cited per item, plus: what's **ready** vs **needs re-triage**, and what's already **in-flight**. This is a proposal, not a verdict — it sets up Step 4.

## Step 4 — Ask the owner for their perceived priorities
Interactively reconcile your data-ranking with the owner's gut. In Claude Code use `AskUserQuestion`; in pylot chat, ask directly and wait. Surface where the data disagrees with the owner's read ("you ranked chat #1, but it's not dispatch-ready — devbox is the cleaner first fuel"). **The owner's call wins**; record the why.

## Step 5 — Deep-triage the shortlist (anti-ghost)
For each promoted candidate, do the research the PRIME DIRECTIVE demands (shallow-clone, read code + history + linked issues). Close done/dup and re-scope partials with a cited comment on the issue. Never close P0/P1.

## Step 6 — Decompose epics into HOURLY-sized slices
A big epic isn't dispatchable. Break each promoted epic into the smallest slices where every slice is:
1. **independently deliverable** (one PR, no cross-slice barrier),
2. **testable in staging** on its own, and
3. **deployable** through develop→staging→prod within roughly **one hourly auto-pylot cycle**.
File/relabel these `ready-to-work` so the hourly can pick one up, test it, and ship it each hour. Note what was sliced and what's deferred.

## Step 7 — Write the reconciled goals
Update `/goals` to match the decision, including a dated **"This week's focus"** block pointing the hourly at the ready, highest-ROI first targets. Show the diff; apply on confirmation.
```bash
# after confirmation:
GW -X PUT "$PYLOT_API_URL/admin/goals/$TEAM" -H "Content-Type: text/plain" --data-binary @goals.new.md
```

## Step 8 — Activate / tune the hourly
Bring the auto-pylot cron in line with the plan and, **with the owner's go**, enable it.
```bash
# enable (or adjust schedule) — send the FULL cron array back with auto-pylot enabled:true
GW -X PATCH "$PYLOT_API_URL/admin/crew/$TEAM" -H "Content-Type: application/json" -d "$(jq -c ...)"
GW "$PYLOT_API_URL/crew" | jq '.crews[]|select(.name=="'"$TEAM"'").cron'   # verify
```

## Step 9 — Session summary (in-session, no push)
Present in the session: the ranking + the three signals, what was triaged (closed/re-scoped, with refs), the **hourly-ready queue** (top first), the epic slices created, the decisions captured, the goals diff, and the final auto-pylot state (enabled? schedule? first focus?).

---

## Boundaries
- **Interactive only** — needs a human to answer; never run headless/cron.
- **Shapes, doesn't mass-dispatch** — respects max-3-concurrent; at most dispatches the single top ready item.
- **Never** closes P0/P1, rewrites goals, or flips the cron without explicit owner confirmation.

## Anti-patterns
- Ranking by the `P*` label instead of the three signals — the point is to catch mislabeling.
- Hand-waving "leverage" without pulling velocity/momentum numbers.
- Decomposing an epic into slices too big to test+ship in one hourly cycle.
- Pushing questions to Telegram/email — this skill is in-session; ask the person in front of you.
- Flipping the cron or rewriting goals without showing the diff and getting a yes.

## Verification
- Every promoted item carries the three signals and a one-line justification.
- Every epic slice is independently deliverable, staging-testable, and deployable in ~one hourly cycle.
- Goals reflect the reconciled decision; the "This week's focus" names ready first targets.
- The auto-pylot cron state matches what the owner approved (verified via `GET /crew`).
- The in-flight set from Step 1 appears nowhere in the hourly-ready queue.
