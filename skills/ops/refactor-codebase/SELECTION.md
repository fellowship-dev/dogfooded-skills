# Target Selection & Prioritization

**This file decides WHAT to refactor and IN WHAT ORDER.** It is the engine that replaces gut-feel doctrine ("split anything over N lines") with evidence-based targeting. Pair it with [CATALOG.md](CATALOG.md) (which decides *how* — the move and its risk tier).

> The single most important finding from the research behind this skill: **the popular "this file is long, split it" reflex is the least evidence-backed trigger and the most likely to do harm.** Length correlates with complexity but most long files are never touched, so refactoring them is pure cost. Target by *change pressure × complexity*, not by size.

## The trigger function (use this, not line count)

Trigger a refactor on a file/module only if it meets **at least one** of:

1. **It is a hotspot** — high **churn × complexity**. Churn comes from `git log` (revision count, recent-window change frequency, distinct author count); complexity from cognitive complexity (preferred) or a cheap proxy. This is the primary signal.
2. **It exhibits strong, distant, high-degree coupling** — connascence that crosses module boundaries (see ranking below), or **temporal/logical coupling** (files that repeatedly change together in the same commits → shotgun surgery).
3. **It carries a high-signal smell** — chiefly **God Class / Large Class** or **Long Method**, the two smells most consistently linked to defects in the empirical literature. Other smells are weaker signals, often just proxies for length — treat them as conversation-starters, not mandates.

**Line count is not the trigger** — but it is a first-class *secondary* objective for a different reason (agent-navigability), covered in its own section below. A 3,000-line file untouched in two years is a low *defect-ROI* target, yet may still be worth splitting so an agent can read it whole. An 800-line churning file is a top trigger target. Never split a file *because* it is long; split it because it's a churning hotspot, or because its size stops an agent from working safely — and only ever in a way the deep-module acceptance test approves.

### How to compute the hotspot ranking (concrete)

```
# Churn: commits touching each file in a recent window (e.g. last 6-12 months)
git log --since="12 months ago" --name-only --pretty=format: \
  | grep -E '\.(js|mjs|ts|py|go|rb|java|rs)$' | sort | uniq -c | sort -rn

# Cross with a complexity/size proxy per file; rank by (churn × complexity), worst first.
# Distinct authors per file is an additional defect predictor (Nagappan et al.).
```

Where a real tool exists (CodeScene, `scc --by-file`, lizard for cognitive/cyclomatic complexity, `git-of-theseus`), prefer it. The principle is fixed; the tool is whatever the environment offers.

> **Compute churn and size against `origin/<default-branch>` in a fresh worktree — never the local checkout.** On a shared workstation the local working copy is often parked on a stale or unrelated branch, where the very file you're ranking can be wildly different (seen in practice: a local `gateway.mjs` at 15,293 lines while `origin/develop`'s was 2,210 — a 7× phantom). Ranking or reading "the resume state off the repo tree" (SKILL.md step 0) against that stale tree mis-targets the whole cycle. `git fetch` first; run SELECTION, the size check, and the seam scan in a worktree cut from `origin/<default>`.

### Temporal coupling (the shotgun-surgery detector)

```
# Files that change together reveal hidden coupling the source doesn't show.
# For each commit, take the set of changed files; count co-occurring pairs;
# the highest-frequency pairs that AREN'T obviously related are refactor targets.
```

This is the highest-signal smell you can mine from history rather than source.

## AI-navigability: file size as a first-class *secondary* objective (the LLM-specific reason)

The human refactoring literature demotes line count — and for *defect/maintainability ROI* that's correct (most long files are inert; churn × complexity is the real trigger). But an autonomous agent has a constraint a human reviewer does not: **it must hold a file in its context window to change it safely.** A file too large to read whole gets read in fragments, and fragmented editing is precisely what produces function duplication, silent drift, dropped references, and "lost in the middle" confusion — the exact failure classes the gates exist to catch. So for an *agent-maintained* codebase, file size is a real, first-class concern — just on a **different axis** than the trigger.

Treat size on three distinct roles, and never confuse them with "long ⇒ split":

1. **A constraint on process (always).** Read the **entire** target file before editing it. If it doesn't fit in one read, that is itself a risk signal — proceed only with extra care (chunk deliberately, map the whole symbol table first), and record it. An agent editing a file it has only seen in pieces is the highest-probability source of duplication/drift.
2. **A secondary objective.** Bring files under a **context-friendly soft ceiling (~1,000 lines; aim lower where a clean seam exists)** so this agent and the next can operate whole-file. This matters *most* on fresh repos with no docs and no tests and many smells — where the agent is navigating blind and comprehension is the only safety margin it has. AI-navigability is an explicit, legitimate goal of this skill ("make a codebase more testable/AI-navigable").
3. **A tiebreaker.** Among similarly-ranked hotspots, prefer the one too big to read whole.

**The hard rule that keeps this honest:** size makes a file *operationally risky for an agent* and a *valid secondary target*, but it **never by itself justifies a split, and never dictates how to split.** The deep-module acceptance test below still governs: a context-friendly split that leaves the halves importing each other's internals is *classitis* — worse, not better. And the split's **output** must also respect the ceiling: don't carve a 4,000-line file into a tidy barrel plus a 2,000-line sub-file that the next agent still can't read whole.

So the three signals compose: **churn × complexity** says a file is *worth* the effort; **size** says it's *operationally risky for agents and where unaided comprehension breaks down*; the **deep-module acceptance test** says a given split is *correct*. Use all three — don't let any one masquerade as the others.

## Diagnose before you act: which DIRECTION?

A trigger tells you *where*; the smell tells you *which way to move*. The two most common are opposites — get this wrong and you make it worse:

| Diagnosis | Smell | Root cause | Correct direction |
|---|---|---|---|
| One module changes for **many unrelated reasons** | **Divergent Change** | low cohesion | **SPLIT** — extract by reason-to-change |
| One change forces edits across **many modules** | **Shotgun Surgery** | excessive coupling | **CONSOLIDATE** — move/inline together |
| A method uses another type's data more than its own | **Feature Envy** | misplaced behavior | **MOVE** behavior to the data |
| Domain concept encoded as raw primitives everywhere | **Primitive Obsession** | weak types | **INTRODUCE** type / parameter object |

At small scale the usual failure is *over-decomposition* (the right move is often to **merge** shallow files and deepen, not split). At large scale the failure is *misallocated effort* (let churn × complexity pick the ~3% that matters).

## Ranking coupling rigorously: connascence

"Coupling is bad" is too blunt to drive decisions. Connascence ranks it. Two elements are connascent if changing one forces a change in the other. Evaluate on three axes — **strength**, **degree** (how many entities), **locality** (how close).

Strength, weakest → strongest: **Name → Type → Meaning → Position → Algorithm** (static) → **Execution → Timing → Value → Identity** (dynamic). Static is always weaker than dynamic (you can find it by reading source).

Action rules:
- **Attack strong + distant + high-degree connascence first** — that is exactly what produces shotgun surgery.
- Strong connascence is acceptable **when local** (same function/class). Don't refactor local strong coupling; refactor it when it crosses a boundary.
- **Convert** strong→weak where it crosses boundaries (Position→Name via named params / a parameter object; dynamic→static where possible).

## The acceptance test: did the refactor actually improve the design?

Passing tests proves you didn't *break* it; it does not prove you *improved* it. A "split" that turns one 800-line file into ten 80-line files importing each other's internals is **shallower** and worse (Ousterhout's *classitis*). Before accepting any structural change, require **at least one** to be demonstrably true:

1. **The interface narrowed** — fewer exported symbols / parameters relative to implementation (a *deeper* module). Compare public-surface size before/after.
2. **Cross-boundary connascence dropped** — strong/distant/high-degree coupling reduced or localized. The new boundary **hides** information; it does not leak internals.
3. **Predicted change-amplification fell** — the next likely change now touches fewer places (use historical co-change as the predictor).

If none hold, you moved code, you didn't refactor. **Reject the split.** Specifically reject any split where the two halves still import each other's privates — that manufactures a wide, leaky boundary.

## Metric choices (so the agent doesn't guess)

- **Prefer cognitive complexity over cyclomatic.** Cyclomatic measures testability (paths) and is nearly redundant with LOC; it ignores nesting and over-counts flat `switch`es. Cognitive complexity (SonarSource) tracks understandability better — but it too is only modestly validated, so use it as a signal, not gospel.
- **Use LOC only as a pre-filter / tiebreaker**, never standalone.
- **Churn × complexity is the primary prioritizer.** Distinct-author count is a useful secondary defect predictor.

## Scale guidance for selection

| Scale | Dominant failure mode | What to target | What to de-prioritize |
|---|---|---|---|
| **Small (<10k LOC)** | over-decomposition / classitis | deep-module audit; consolidate shallow files; method-level smells (Long Method, Feature Envy) | churn analysis (too little history); aggressive splitting |
| **Medium (10k–100k)** | emerging god-classes, growing coupling | cognitive complexity + cohesion within hotspots; begin churn×complexity ranking | global LOC thresholds |
| **Large (100k+/monorepo)** | misallocated effort on the inert long tail | churn×complexity hotspots + temporal coupling, worst-first; chunk big changes into independently-tested diffs | auditing every large file — most are inert |

## Once a file is picked: rank the intra-file seams

Churn × complexity tells you *which file* to attack; it does **not** tell you *which seam inside it to extract first* — and on a god-file split that order is load-bearing. Pulling the wrong cluster first can force you to export a shared internal (widening the surface) or land you on a cluster with no test coverage to prove the move safe. Within the chosen file, rank candidate clusters by **self-containment × existing-green-test coverage**, and extract the **most-provable first**:

- **Self-containment** — how few shared internals (a private `pool`, a module-level cache, a helper several clusters use) the cluster touches. A cluster that closes over shared mutable state is *not* a clean first move; untangle that shared state in a setup cycle first (see the shared-mutable-state trap in [TECHNIQUES.md](TECHNIQUES.md)).
- **Green-test coverage** — a cluster already exercised by a green suite gives you a behavioral gate for free; extract it before clusters that only the byte-identical manifest can vouch for. Early cycles should be the *safest to prove*, building a trail of green checkpoints before you reach the gnarlier seams.
- **Run the reverse-reference scan per candidate cluster** (grep every symbol across the file + all importers) to see what it shares before you commit to the order. **Trust the scan over any handoff/masterplan prose about coverage or cohesion** — inherited notes drift; the scan is ground truth.
- **Extract-the-wedge-first.** When an *unrelated* block sits wedged between two halves of a cohesive cluster, extract the wedge first: it makes the target cluster contiguous, so the next cycle becomes a trivial verbatim slice instead of two scattered moves. Spotting the wedge is a direct payoff of re-ranking every cycle (the terrain that looked like one hard cluster is often one easy wedge + one easy remainder).

This produces a within-file worklist: easiest-and-best-covered first, shared-state untangling as an explicit setup cycle, the leaky/entangled clusters last. Record it in the masterplan worklist, re-ranked each cycle like everything else.

## Re-rank every cycle

Earlier cycles change the terrain (a split can reveal or dissolve a later target). Re-run a quick selection pass at the top of each cycle and update the worklist. Only the *doctrine* (this file) is fixed up front; the worklist is not.
