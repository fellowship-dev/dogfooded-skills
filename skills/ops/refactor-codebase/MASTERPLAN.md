# The Masterplan

The masterplan is the **single source of truth** for the refactoring loop. It outlives any session. Keep it where the team already looks — a tracking issue (GitHub/Linear), or a `docs/refactor-masterplan.md` file checked into the repo. One masterplan per loop.

> **On a repo you don't own (or a blind/dogfood run), don't commit the masterplan into the repo.** Adding an unsolicited planning doc pollutes a codebase whose conventions you haven't been invited to change. Keep the masterplan, gate-harness, and handoff in a **scratch dir outside the tree** (e.g. `/tmp/<repo>-refactor/`), and reference it from the PR rather than committing it. Commit *into* the repo only the durable artifact the project actually wants — a tracking issue, or a doc the maintainers asked for. (Fixing a *stale* doc your refactor touches is different — that's an in-PR change the repo wants; see [PREREQUISITES.md](PREREQUISITES.md#docs-are-part-of-the-refactor).)

It answers four questions a fresh agent must be able to read off in 60 seconds:
1. **Why** — the goal and the doctrine (the rules that don't change between cycles).
2. **What's left** — the worklist, worst-first.
3. **What's done** — the scoreboard, with evidence.
4. **How** — the loop protocol and the gates (link to [CYCLE.md](CYCLE.md) / [GATES.md](GATES.md)).

## Template

```markdown
# Masterplan: <goal in one line>

## Goal & doctrine (settled — do not re-litigate per cycle)
- **Trigger:** what makes something a target. Default to the evidence-based model in
  [SELECTION.md](SELECTION.md): **churn × complexity hotspots**, cross-boundary
  coupling (connascence / temporal coupling), and the high-signal smells (God Class,
  Long Method). **Line count is a pre-filter only, never the trigger.**
- **Axis:** how you split (e.g. "by domain/cohesion; background machinery becomes its
  own sub-module, separate from interactive handlers"). Diagnose direction
  (split vs consolidate) from the smell — see SELECTION.
- **Ordering:** worst-first by **churn × complexity**, re-ranked each cycle.
- **Risk posture:** prefer T1–T3 moves ([CATALOG.md](CATALOG.md)); treat god-file
  splits (T5) as characterization-first, staged, reviewed work — not the default.
- **Scope:** which dirs are in/out of scope.
- **Quality bar (the acceptance test):** every change must make the design measurably
  better — interface narrowed, cross-boundary connascence reduced, or predicted
  change-amplification lowered. Reject any "split" whose halves still import each
  other's internals (that is *shallower* and worse). Depth, not line count, is the goal.

## Verification gates (the contract every cycle must pass)
<link to GATES.md, and state the headline gate for THIS codebase —
 e.g. "byte-identical esbuild bundle + full suite green">

## Worklist (worst-first; re-ranked each cycle)
- [ ] <target> (<size/metric>) — <candidate technique> — <one-line domain seam note>
- [ ] ...

## Scoreboard
| Cycle | Target | Technique | Result | Evidence |
|------|--------|-----------|--------|----------|
|      |        |           |        |          |

## Loop protocol
<link to CYCLE.md; note any project-specific deploy/review steps>

## Open questions / blockers
- ...
```

## Notes on keeping it honest

- **The metric is "fat files / debt remaining," not "lines moved."** Track the thing you actually want gone.
- **Re-rank, don't pre-plan everything.** Earlier cycles change the terrain (a split can reveal or dissolve a later target). Re-run an `Explore` pass at the top of each cycle and update the worklist. Only the *doctrine* is fixed up front.
- **Record refuted candidates.** If a target turns out to be a bad split (would widen interfaces, order is load-bearing, etc.), note it in the worklist as struck-through with the reason, or promote it to an ADR — so future re-ranks don't re-suggest it.
- **One masterplan supersedes another cleanly.** When the goal changes, close the old plan with a pointer to the new one; carry forward the doctrine and scoreboard. Don't fork state.
