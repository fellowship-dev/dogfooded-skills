# The Cycle Protocol

One cycle = **one structural change, proven behavior-preserving, committed in isolation.** Keep cycles small enough that the diff is reviewable in one sitting and revertable in one command.

## Steps

> **Once per repo, before cycle 1:** run pre-flight ([PREREQUISITES.md](PREREQUISITES.md)). No trustworthy oracle → no refactor. Validate the oracle with mutation testing before relying on it.

### a. Pick target + technique
- From the masterplan worklist, take the **worst-first** item — ranked by **churn × complexity**, not size ([SELECTION.md](SELECTION.md)). Re-confirm it's still the worst with a quick `Explore` pass (terrain shifts between cycles).
- Confirm the **direction** (split vs consolidate) from the smell, and pick the **risk tier** ([CATALOG.md](CATALOG.md)) — prefer T1–T3; a god-file split is T5 (characterization-first, staged).
- Choose the technique by shape (see [TECHNIQUES.md](TECHNIQUES.md)):
  - pure-export / helper module → **barrel-split**
  - factory/handler module → **compose-behind-factory**
  - one cohesive cluster inside a bigger file → **extract module**
  - risky replacement of a live path → **strangler-fig**
- Write a one-paragraph **cycle spec**: the target, the technique, the exact files, and — critically — the **done condition as a runnable check** (e.g. "bundle diff empty AND `tests/` exit 0 AND no files touched outside `src/<domain>/`").

### b. Pin behavior (establish the oracle BEFORE editing)
- Run the **project's real suite** (the one CI runs — include integration/e2e and DB-seeded tests where the environment allows, not just unit tests) on a clean tree; **record the baseline** (must be green, or a known-stable set — see note). If the documented command is stale or the suite won't run cleanly, first make it runnable and reconcile it against the actual test files — see [PREREQUISITES.md](PREREQUISITES.md#make-the-suite-actually-runnable). Derive green from the **parsed pass/fail tally**, not the runner's exit code, which can lie (open handles, force-exit, teardown warnings).
- Capture the **API-surface / bundle snapshot** that the byte-identical gate will diff against (exported-symbol manifest, or a bundler output hash). See [GATES.md](GATES.md#byte-identical).
- If coverage of the target is thin: write **characterization tests** that pin what the code *actually does today* (warts and all). Optionally **mutation-test** the existing tests first — surviving mutants show exactly where the oracle is blind; add characterization tests there before you trust it. See [GATES.md](GATES.md#oracle).

> **Stable-red baselines.** If the suite already has failures, a "byte-identical before/after" comparison still works as a *delta* oracle — but it only proves you didn't make things *worse*, not that the code is correct. Prefer to green the suite first. If you can't, record the exact pre-existing failure set in the cycle spec and assert it is **unchanged**, never just "still fails."

### c. Implement (clean baseline, fresh context)
- Work from a **clean baseline with a one-command revert**. Pick isolation by environment (see SKILL.md → [Adapt to the environment](SKILL.md#environment)):
  - **Ephemeral box (sandbox / devbox / CI container):** you own the machine — work **directly on a branch** and use everything it offers (services, DB seeds, integration suite). No worktree. Revert = reset / re-checkout.
  - **Shared workstation:** use a worktree or dedicated clone so the loop can't disturb other in-progress work, and so parallel cycles don't collide.
- Prefer a **fresh subagent** handed the cycle spec — it executes without the noise of the planning conversation.
- Where the toolchain supports it, prefer **semantic tools** (LSP move/rename; codemods: ast-grep / jscodeshift / comby) over hand text-edits, especially on large files — they update every call site, import, and type atomically and kill the dropped-reference failure class. Otherwise move bodies **verbatim** and rely on the reverse-reference scan.

### d. Gate ladder (cheap → expensive; revert on first red)
Run in order so it fails fast. Full definitions in [GATES.md](GATES.md):
1. typecheck / compile / lint
2. **byte-identical API-surface or bundle diff** (the headline gate for pure re-org). For a *setup* cycle that introduces an abstraction/indirection before a later move (branch-by-abstraction / Mikado leaf), use the **surface-identical variant** instead: exported-symbol manifest empty-diff + moved bodies byte-identical + bundle/AST delta "small & explained," not `== 0` ([GATES.md](GATES.md#surface-identical))
3. characterization / golden-master diff
4. full existing test suite (exit 0; no silently-added skips)
5. scope & idempotency (no edits outside declared paths; re-running the step is a no-op)
6. **two-stage adversarial review** — a fresh-context grader sees only the diff + spec (grader ≠ worker): stage 1 spec-compliance, stage 2 code/deep-module quality
7. deep-module quality check (did the interface actually narrow? exported-symbol count vs LOC)

### e. Commit + record
- **All green:** commit exactly one structural change with a message that states target + technique + evidence. Update the masterplan scoreboard.
- **Any red:** revert to the last green checkpoint. Diagnose, shrink the cycle, retry. Do not patch forward on top of a red gate.

## Cycle hygiene
- One domain / one concern per commit — never batch unrelated moves.
- Every commit is a clean rollback point and an independently-reviewable diff.
- A failure in cycle N must never poison cycles 1..N-1.
- If a cycle keeps failing the same gate, that's the masterplan telling you the split is wrong — revisit the plan, don't brute-force the code.
- **Run the full mandatory gate set every cycle; never silently downgrade.** Later "trivial" cycles must still run the mandatory gates ([GATES.md](GATES.md#which-gates-run-every-cycle-no-silent-erosion)); any gate you scale down for a provably-safe move must be **recorded with a reason in the scoreboard**. An unrecorded downgrade is a gate violation.
- **No process-narrating comments in the code.** The refactor's story (cycle numbers, "extracted from X", "re-exported here so importers stay unchanged") belongs in the commit message and the PR, **never** in source comments. A comment like `// Extracted to db/ledger.mjs (cycle 3/N). Re-exported so the public surface stays unchanged.` is noise that ages instantly and leaks the migration process into the code. Comments explain *what the code does and why*, not how it got here. **Enforce this with a grep gate, not willpower** — a prose-only rule gets violated under autonomy (especially when the file you're carving *already* contains inherited process comments and the worker mirrors the surrounding convention). Fail the cycle if the diff *adds* lines matching, case-insensitive, roughly: `extracted (to|from)|re-exported here|public surface (stays|unchanged)|cycle \d+\s*\/\s*N|importers stay unchanged`. Scope the grep to **added** lines in **new/edited** files so it never trips on inherited comments you were told to leave alone. The barrel/re-export is self-evident from the `export … from` line; if it genuinely needs a note, one terse line about the *design* (e.g. why state lives in a private holder), not the *process*. **Write NEW files clean — but don't scrub *inherited* process comments mid-cycle.** If earlier cycles (or another author) left older-convention process comments in files you're not otherwise touching, leave them: reformatting them is out-of-scope churn that bloats the diff and violates one-hat. Sweep them in a dedicated, separately-labeled cleanup cycle if they're worth removing.
- **Update docs the change touches, in the same commit/PR.** If a cycle renames or relocates something the docs reference, or makes a documented command/setup step wrong, fix the doc as part of the cycle (see [PREREQUISITES.md](PREREQUISITES.md#docs-are-part-of-the-refactor)). Don't defer it to a follow-up. **But scope this to what *your change* broke** — a doc/command your move made wrong is in-scope; a doc/command that was *already* stale and sits **outside your move's blast radius** (e.g. a `scripts/test.sh` that names a test file deleted three cycles ago, which you didn't touch and your move doesn't depend on) is **flag-for-followup, not an in-PR fix** — folding it in is the scope creep the one-hat rule forbids. The test: did this cycle make it wrong, or is the cycle merely *near* something already wrong? Fix the former; record the latter.
- **Removing your OWN now-dead scaffold is completing the move, not scope creep.** A temporary bridge you added earlier in the same multi-cycle move (a temp re-export/import, a transitional shim) that the current cycle makes dead should be deleted *in that cycle* — that's finishing the move you started, and the scope gate should accept it. This is the opposite of the "leave *inherited* artifacts alone" rule: you own this scaffold and the move isn't done until it's gone. (Reviewers and the scope gate can read it as creep — call it out in the cycle spec so it's clearly in-scope.)
