---
name: refactor-codebase
description: Autonomously refactor a codebase across many verified cycles — decompose fat files by domain, deepen shallow modules, pay down architectural debt — driven by a persistent masterplan and behavior-preserving gates. Use when the user wants to refactor at scale, split god-files, decompose a large module, run an ongoing architecture-improvement loop, or do a multi-session refactor that must not change behavior. Complements (does not replace) improve-codebase-architecture, which only finds and reports opportunities.
---

# Refactor Codebase

Run a **behavior-preserving refactoring loop** over a codebase: confirm the repo is safe to refactor (**pre-flight**), discover and rank the work into a **masterplan**, execute it as discrete **cycles** (one verified change each), prove each change preserved behavior, and **hand off** cleanly so any fresh session can resume. Built for the case `improve-codebase-architecture` can only point at: actually *doing* the refactor, safely, over many sessions, on codebases you may not own.

The unit of progress is **one cycle = one structural change, proven not to alter behavior, committed in isolation.** Slow is smooth, smooth is fast — one clean cycle beats five half-finished branches.

## The prime invariant (non-negotiable)

> **Never commit or hand off a state where the build is red, the behavior oracle diffs, or the public surface changed unintentionally.**

Three corollaries:
- **One hat per cycle** (Beck). A cycle changes *structure* OR *behavior*, never both. Refactoring keeps observable behavior identical. A bug you find mid-cycle gets *recorded* and fixed in a separate, labeled, behavior-changing change — never smuggled into a structure cycle. This is the #1 discipline failure for LLM agents.
- **Plausible ≠ correct.** An edit that *looks* right but drops one import in a nested module ships a runtime failure. Every edit is a *proposal*, accepted only when a deterministic gate (script/test exit code) says so — never on the model's own judgment.
- **No oracle, no refactor.** You cannot prove behavior preserved without a trustworthy test oracle. If the repo has none, establishing one is the work — see [PREREQUISITES.md](PREREQUISITES.md).

If you cannot define "done" for a cycle as a **binary, bounded, runnable check** before you start it, you are not ready to start it.

## When to use / not use

**Use** for: splitting a god-file, decomposing a large module by domain, an ongoing "pay down the hotspots" loop, untangling tightly-coupled modules, making a codebase more testable/AI-navigable — at a scale that spans multiple sessions.

**Don't use** for: a single small edit (just do it), a behavior change / bug fix (that's not refactoring — wear the other hat), or merely *finding* opportunities without executing (use `improve-codebase-architecture` and stop).

## What targets, and why NOT just "big files"

The instinct to "split files over N lines" is the **least evidence-backed trigger** for defect/maintainability ROI, and often makes designs worse. Target by **churn × complexity** (hotspots), **cross-boundary coupling** (connascence / temporal coupling), and the two high-signal smells (God Class, Long Method) — not by size alone. **But size is still a first-class *secondary* objective for a reason humans don't have: an agent must hold a file in its context window to change it safely** — a file too big to read whole drives duplication and drift, which matters most on fresh repos with no docs or tests. So aim files under a context-friendly soft ceiling (~1,000 lines) *as a goal*, while letting churn×complexity *prioritize* and the deep-module acceptance test *govern how*. And remember the risk ladder: **splitting a god-file is the riskiest tier (T5)**, not a reflex. The full target model (and how these three signals compose) is in [SELECTION.md](SELECTION.md); the move menu and risk tiers are in [CATALOG.md](CATALOG.md).

## Three artifacts (state lives in files, never in chat)

Context windows have a smart zone (early) and a dumb zone (late); conflating workflow state with session state breaks resumption. So all durable state is external:

1. **Masterplan** — the persistent plan + doctrine + scoreboard. A file or tracking issue. See [MASTERPLAN.md](MASTERPLAN.md).
2. **Cycle log** — what each cycle did + its evidence. Appended to the scoreboard. See [CYCLE.md](CYCLE.md).
3. **Handoff** — the minimal note a fresh session reads to resume. See [HANDOFF.md](HANDOFF.md).

## <a id="environment"></a>Adapt to the environment and toolchain (do this first)

This skill is language-, toolchain-, and environment-agnostic. The forms in these files (`.mjs`, `export *`, an esbuild hash, `git`) are **illustrative**, not requirements. Before the loop, detect and adapt:

**1. Isolation — match it to where you're running.** The requirement is only ever *a clean baseline and a one-command revert*.
- **Ephemeral box (sandbox, devbox, CI container, throwaway VM):** you own the machine — **work directly on a branch, no worktree.** Use everything it offers: start services, seed the DB, run integration/e2e, hit real ports. Revert = `git reset --hard` / re-checkout.
- **Shared workstation (a personal computer with other work in progress):** use a **worktree or dedicated clone** so the loop can't disturb other branches and parallel cycles can't collide.

**2. Toolchain — discover the project's real verification affordances; use all of them.** Do **not** assume `tests/` or `npm test`. Find how *this* project proves itself correct (its real test command incl. integration/e2e, DB seeds/fixtures, linter/type-checker/formatter, build system, services it needs, and especially its **CI config** — the canonical "how this project verifies itself") and wire those into your gates. Full detection + bootstrap guidance in [PREREQUISITES.md](PREREQUISITES.md).

Map every gate and technique to your stack's equivalent (Python `__init__` re-exports, Go package split, a public-API snapshot tool, a deterministic compiler artifact). The concepts — deep modules, facade/barrel, byte-identical surface, characterization tests — are universal; only the commands change.

## The loop

### 0. Orient (every session)
Read the project's docs — `README`, `CONTEXT.md` / glossary, `docs/adr/` (ADRs record decisions you must not re-litigate), and the canonical "how to run/verify" doc. Reading docs is part of the work, not a nicety: they name the seams to split along and the commands your gates depend on. **If a doc your refactor touches turns out to be stale** (a dead test command, a renamed module, an obsolete setup step), **fix it in the same PR** — never just flag it for later ([PREREQUISITES.md](PREREQUISITES.md#docs-are-part-of-the-refactor)). Look for an existing masterplan or handoff. **If one exists, resume from its next unchecked item.** If not, **read the resume state off the repo tree itself**: a domain subdir beside a fat file (`db/` next to `db.mjs`) plus a barrel of `export … from "./db/*"` lines *is* an in-flight decomposition — the already-extracted modules are completed cycles, and the clusters still inline in the fat file are the remaining worklist. Reconstruct the worklist by seam-ranking what's left ([SELECTION.md](SELECTION.md#once-a-file-is-picked-rank-the-intra-file-seams)) rather than re-deriving from zero or (worse) re-extracting an already-moved cluster. Then bootstrap the masterplan from that inferred state (steps 0.5 → 1).

### 0.5 Pre-flight — is this repo safe to refactor? ([PREREQUISITES.md](PREREQUISITES.md))
Before planning any move, run the pre-flight checklist and apply its decision rule: **hard-gate** (no/flaky oracle, red build → bootstrap an oracle or STOP), **auto-bootstrap** the cheap missing pieces (test entrypoint, version pins, lint baseline, seed determinism), and **flag for human** the expensive/owned ones (staging for infra refactors). Validate the oracle itself with mutation testing before you trust it. **No oracle → no refactor.**

### 1. Masterplan — discover & rank the work ([SELECTION.md](SELECTION.md))
Fan out read-only `Explore` subagents to map the codebase. Rank targets by **churn × complexity** (from `git log`) crossed with cohesion/coupling signals — not by line count. Diagnose each candidate's *direction* (split vs consolidate) from its smell. Record the masterplan: the doctrine (from SELECTION), the ranked worklist, the gates ([GATES.md](GATES.md)), and an empty scoreboard. Do **not** pre-commit a rigid plan for every file — re-rank from a fresh `Explore` pass each cycle.

Optional for risky (T4/T5) targets: **Mikado discovery** — attempt the move, record what breaks as prerequisites, then **revert**. Repeat until the leaves are safe to execute. The graph *is* the plan and the handoff. See [TECHNIQUES.md](TECHNIQUES.md#mikado).

### 2. Cycle — execute one verified change ([CYCLE.md](CYCLE.md))
- **a. Pick** the worst-first hotspot and the **technique by risk tier** ([CATALOG.md](CATALOG.md)) — prefer T1–T3 moves; treat T5 god-file splits as characterization-first, staged work.
- **b. Pin behavior.** Establish the oracle *before* editing: green baseline + a captured API-surface / bundle snapshot. If coverage is thin, write characterization tests first (validated via mutation testing). See [GATES.md](GATES.md).
- **c. Implement** from a clean baseline with one-command revert. Prefer a fresh subagent handed the cycle spec. Prefer **semantic tools** (LSP move/rename; codemods: ast-grep / jscodeshift / comby) over hand text-edits on large files; otherwise move bodies **verbatim**.
- **d. Run the gate ladder** (cheap→expensive, revert on any red): static → **byte-identical API/bundle diff** → **AST node-count tripwire** → characterization/golden-master → full suite → scope & idempotency → **two-stage adversarial review** (fresh-context grader ≠ worker) → **deep-module quality check** (did the interface narrow? — the SELECTION acceptance test). Full ladder in [GATES.md](GATES.md). Run the **mandatory** gates every cycle — including the "trivial" ones; any gate scaled down for a provably-safe move must be **recorded with a reason in the scoreboard**, never silently dropped.
- **e. Commit** one unit. Update the scoreboard. **On any red: revert to the last green checkpoint — never patch forward.**

### 3. Impact, handoff & loop
Produce the **per-PR impact report** ([IMPACT.md](IMPACT.md)) so reviewers and stakeholders see the value in their own unit. Refresh the handoff/scoreboard so the next session resumes unambiguously. Then continue to the next cycle.

## Autonomy & stopping criteria

Every loop needs three explicit stops, or it thrashes:
- **Success stop** — worklist empty / target metric reached.
- **Blocked stop** — unrecoverable after bounded retry (incl. a failed hard-gate: no oracle and can't bootstrap one). Record the blocker in the handoff and surface it.
- **Budget stop** — max cycles / token cap; hand off cleanly.

## Distribution

`npx skills add`-installable. To publish: place this directory in a public GitHub repo and share `npx skills add <owner>/<repo> --skill refactor-codebase`. Validate locally with `npx skills add .`.

## Reference files
- [PREREQUISITES.md](PREREQUISITES.md) — pre-flight: the oracle + environment, with hard-gate/bootstrap/flag decision rule
- [SELECTION.md](SELECTION.md) — what to target & in what order (churn×complexity, connascence, the deep-module acceptance test)
- [CATALOG.md](CATALOG.md) — the refactoring menu, T1–T5 risk ladder, expected findings/effort/diff/scale
- [MASTERPLAN.md](MASTERPLAN.md) — masterplan format + scoreboard
- [CYCLE.md](CYCLE.md) — the per-cycle protocol
- [GATES.md](GATES.md) — the verification ladder (the heart of the skill)
- [TECHNIQUES.md](TECHNIQUES.md) — barrel-split, compose-behind-factory, strangler, branch-by-abstraction, extract, Mikado, LSP-move
- [IMPACT.md](IMPACT.md) — the business case + per-PR impact report
- [HANDOFF.md](HANDOFF.md) — handoff document format
