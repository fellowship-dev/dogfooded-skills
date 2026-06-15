# The Verification Gates

This is the heart of the skill. The gates are what make an autonomous refactoring loop *trustworthy* instead of *plausible*. Each gate catches a different failure class; layer them, run cheap→expensive, **revert on the first red**.

The governing rule: **the agent reports what the gate says, not what it thinks.** A gate is a script with an exit code. "Looks correct" is not a gate.

## The ladder

| # | Gate | Catches | Mechanism |
|---|------|---------|-----------|
| −1 | **Oracle validation** (pre-flight, once per target) | a green-but-worthless suite; "plausible but wrong" surviving where byte-identical can't apply | **mutation-test** the existing tests on the target (Stryker/mutmut/PIT); surviving mutants = unpinned behavior → write characterization tests to kill them *before* trusting the suite |
| 0 | **Static** — compile / typecheck / lint | dropped imports, broken symbols, missed dynamic refs | compiler + linter exit code |
| 1 | **Byte-identical API/bundle diff** | *any* unintended change in a "pure move" | diff the exported-symbol manifest or composed bundle against the pre-cycle snapshot — must be empty |
| 1.5 | **AST node-count tripwire** | LLM "lazy coding": code silently dropped, elided, or replaced with `// ... unchanged` | a pure extraction/move preserves total AST node count across the affected files; a drop means code was elided → revert. Cheap, language-agnostic (any parser). From aider's refactor benchmark |
| 2 | **Characterization / golden-master** | behavior drift where output isn't byte-stable | record outputs pre-cycle (fixed seed; scrub nondeterminism); re-run; compare; any delta → revert (**never** auto-accept a new snapshot) |
| 3 | **Full existing suite** | regressions in covered behavior | exit 0; assert no skips were silently added |
| 4 | **Scope & idempotency** | edits leaking outside the target domain; non-reapplying steps | assert no files changed outside declared paths; re-running the step is a no-op |
| 5 | **Two-stage adversarial review** | logic the tests don't assert; scope creep; behavior smuggled into a structure cycle | fresh-context subagent sees only diff + spec; stage 1 spec-compliance, stage 2 quality |
| 6 | **Deep-module quality** (the SELECTION acceptance test) | a "split" that made things shallower / leakier | interface width (exported symbols) vs implementation depth per new module; reject unless the interface narrowed, cross-boundary connascence dropped, or predicted change-amplification fell |

Gate −1 is the gate most published refactoring tools lack the discipline to run: **prove the oracle catches bugs before relying on it.** A green suite is a false friend if it's weak. Gate 1.5 is the gate human refactorers don't need but agents do.

## <a id="byte-identical"></a>Gate 1 — Byte-identical (the headline gate)

For pure re-organization (barrel-split, compose-behind-factory, move-behind-facade) the **strongest and cheapest** oracle is an *empty diff*. If the refactor is genuinely structure-only, then:
- the **public API surface** (the set of exported names + their shapes) is unchanged, and/or
- the **composed/bundled output** is byte-identical.

Use the **strongest equivalence check your toolchain supports** — pick from, ideally combine:
- **Exported-symbol manifest** (works in every language): enumerate every public export of the affected entrypoints (names, and for typed languages their signatures/types). Sort, hash. Re-generate post-cycle; diff. This is the universal form. **If the module has import-time side effects** (opens a DB/socket, reads env on load) so you can't safely `import` it just to read `Object.keys`, enumerate the exports by **static-parsing the export statements (AST)** instead of importing — same manifest, no execution.
- **Deterministic build/compile artifact** (strongest, where one exists): build/bundle/compile the entrypoint deterministically (mark deps external; disable minify, timestamps, and content hashing). Hash the output; re-build post-cycle; diff. Zero new build warnings is part of the gate. (For interpreted languages with no build step, lean on the manifest + AST checks instead.) **Sandbox caveat:** a locked-down environment (allow-scripts / no-postinstall) may leave a bundler like `esbuild` with its native binary un-installed, so this form simply **cannot run** — do not burn turns fighting it. The **manifest empty-diff + per-body byte-identical + AST no-shrink trio is a complete substitute** for Gate 1; the bundle hash is the strongest form *where available*, not a requirement.
- **AST node-count invariant** (cheap corroboration, any language with a parser): a pure extraction preserves total AST node count across the affected files — a drop means code was elided. (From aider's refactor benchmark.)

This gate is what most published refactoring tools *lack* — they gate on tests only. Lead with whichever form your stack supports; let tests corroborate.

### <a id="surface-identical"></a>Gate 1b — surface-identical (NOT output-identical): the prerequisite-cycle variant

Gate 1 (bundle hash `== 0`) and Gate 1.5 (AST node-count "preserved") assume a **pure move** — nothing added, only relocated. But the riskiest splits need a *setup cycle* first: a **branch-by-abstraction / Mikado leaf** that legitimately **adds** a little scaffolding (an indirection module, getters/setters, a re-export line) so the *next* cycle's move is safe. That setup cycle is behavior-preserving but **not** byte-identical: the bundle and the AST node-count both grow by the scaffolding you added. A literal reading of the headline gate red-lights a *correct* cycle, and an agent may wrongly revert it.

For these surface-preserving-but-not-output-identical cycles, the real gate is:
- **Exported-symbol manifest: empty diff** (the public surface is unchanged — this is non-negotiable), AND
- **Moved/changed bodies byte-identical** where they were *moved* (diff each relocated body against its pre-cycle source), AND
- **Behavioral gates green** (tests, characterization).
- **Bundle hash and AST node-count: delta must be small and fully accounted-for** — every added node maps to a named piece of scaffolding in the cycle spec. Treat these as "minimal & explained," **not** "== 0." An *unexplained* delta is still a red. Note the AST invariant precisely: **gate on NO SHRINKAGE, not on an exact delta.** The node-count *grows* by an amount that scales with the number of re-export specifiers + import statements you added (seen in practice: +17 / +23 / +20 across cycles) — it is not a fixed number, so chasing an exact count is a rabbit hole. The AST gate's job is only "nothing was *elided*" (a drop ⇒ code dropped ⇒ revert). The gate that proves "nothing was *added or altered*" is the **byte-diff of each moved body against its pre-cycle source** (must be empty) — make that the definitive move-integrity gate; let AST cover shrinkage and the manifest cover the surface.

> **Keep the move-integrity diff byte-exact — do NOT re-indent a moved body to "fix" its nesting.** When a technique re-nests a body (**compose-behind-factory** wraps it in `makeXApi(deps){ … }`, adding an indent level), the temptation is to re-indent to the idiomatic depth — but that turns every moved line into a diff hunk and forces you to *judge* "is this whitespace-only?" The robust doctrine: **leave the moved body at its original column inside the wrapper**, so `diff base head` over that body is a literal **zero-token, zero-whitespace** diff and stays a clean mechanical oracle. (Functions hoist; indentation depth ≠ scope, so under-indented bodies run identically.) Do **not** reach for `diff -w` to paper over re-indentation — whitespace *inside* multiline string literals is behavior, and `-w` would mask a real change there. The cost is cosmetic: the new module looks under-indented inside its factory. **Acknowledge that as deferred lint debt in the cycle log; do not fix it mid-cycle** (a reindent pass is its own separately-labeled cosmetic cycle, never smuggled into the structural one).

Decide up front which variant a cycle is: a **pure move** gets `== 0`; an **abstraction-introduction leaf** gets "manifest empty + delta explained." State which one in the cycle spec's done-condition so the gate isn't ambiguous mid-run.

### Reading a gate's result honestly — the runner's exit code can lie

A gate is "a script with an exit code," but some test runners **emit a failure exit code (or a file-level "fail" line) on conditions that are not test failures** — e.g. an open handle / leaked process at exit, a forced-exit flag, a teardown warning. On such a toolchain `exit 0` is **not** a usable green signal: derive green from the **parsed report** (the per-test pass/fail tally), not from `$?`. Before trusting any runner as a gate, confirm what its exit code actually reflects on a known-green run; if the exit code and the tally disagree, gate on the tally and record the quirk in the masterplan's gate contract.

### Regression vs flake (isolate before you blame the cycle)

A "new" failure after your cycle is the single most likely thing to wrongly trip a revert — most "failures" on a real repo are pre-existing, not caused by you. Do not treat a full-suite delta as a regression on its face. Two discriminator arms; **run the base-sha arm FIRST — it is the more common answer:**
- **Base-sha arm (do this first):** re-run the failing suite on the **pre-cycle base sha**. Fails *identically* on base → **pre-existing stable-RED** (missing AWS/S3/service stubs, env gaps), not your regression. Record it in the stable-red set; do not revert. On a real infra repo this is the answer the large majority of the time. **Switch to the base sha with a separate `git worktree add <tmp> <base-sha>` (preferred) or, only for a quick foreground run, `git stash -u` — NEVER a plain `git stash`.** Prefer the worktree: it is non-destructive to your working tree, so if the base-arm run is long or gets interrupted/killed (e.g. a backgrounded run), nothing is left in a half-stashed state needing a manual `git stash pop` to recover. A bare `git stash` leaves your cycle's *new untracked module* in the tree, so the "base" run executes the old caller against an orphan file — a false base reading (harmless when the orphan is unused; a silently-wrong verdict when the new file shadows a name). For any cycle that *adds* files, the base-sha arm must run against a tree that genuinely lacks them.
- **Isolation arm (for nondeterministic suites):** if base-vs-head is inconclusive because the count *swings run-to-run* (server/DB-spawning suites that leak state), re-run the suite *in isolation*. Passes alone + full-run count inside the known flaky band → **flake**, not a regression. Record; do not revert. Note the failure mode: a leaky DB-spawning suite (PGlite, Testcontainers) run deep in a rapid sequence often returns a **wrong pass/fail count** (e.g. 6/2 where it should be 8/0), not a hang — so a surprising *count* mid-sweep is a flake signal, and re-running that one suite alone (a few times) is the fix. **On a stable-flaky suite, a SINGLE base-vs-head comparison is actively misleading** — a one-shot `86/37` head vs `85/38` base reads like a real +1 improvement until you run both arms 3× and watch each swing across an `80–86` band. Take **≥3 runs on BOTH arms and compare the bands, not the single counts**, before concluding regression-or-flake; a delta that stays inside the shared band is noise.
- **Real regression** = fails on head but **not** on base, and reproduces in isolation → revert.

Two recurring flake *classes* on service-spawning suites, distinct from a wrong pass/fail count: (a) **subprocess-startup timeout** — "gateway did not start on port X within Nms" when an integration test boots the whole app in a child process and the port-bind races under load; (b) **leaked-port / address-in-use** from a prior suite's un-reaped server. Both are environment/timing, not behavior. For a **pure move**, prefer an **in-process oracle** (e.g. an embedded-DB/PGlite test that drives the moved module in the same process) as the *authoritative* behavioral check, and treat heavyweight subprocess-spawn integration suites as corroboration only — a flaky port-bind must not make a byte-identical extraction look broken.

This is why the **surface-identical / AST gate is the load-bearing oracle on a flaky-suite repo** (it's deterministic); the full suite corroborates per-target, in isolation. Record each target's isolated-green suites + the full-suite flaky band in the masterplan so the next cycle reuses the discriminator instead of re-deriving it.

## <a id="oracle"></a>Gates 2–3 — Validate the oracle, then trust it

A green suite is a **false friend if it's weak**. Two protections:
- **Characterization tests** pin actual current behavior before you touch anything. They are not "correct behavior" tests — they capture *what is*, so any inadvertent change shows up as a diff. (Feathers; golden-master / approval testing.)
- **Mutation-test the existing tests once, pre-flight** (where a mutation tool exists for your language — e.g. Stryker, mutmut, PIT; otherwise inject a few faults by hand and confirm the suite catches them). Surviving mutants are behavior the suite does not actually pin. Write characterization tests to kill them *before* refactoring. This is the gate that catches "plausible but wrong" when byte-identical doesn't apply (i.e. once you move beyond pure re-org).

## Gate 5 — Two-stage adversarial review (grader ≠ worker)

The agent that wrote the diff is the worst judge of it. Dispatch a **fresh-context** reviewer (a subagent if your harness has them; otherwise a cleared/new session) that sees only the diff and the cycle spec — not the reasoning that produced it.

> **Pin the reviewer to the exact worktree.** On a shared workstation with multiple worktrees/clones of the same repo, a fresh reviewer will often default to reading a *sibling* checkout (e.g. the stale main checkout) and return a **false REJECT** — "phantom missing file," "symbol not found" — because it's looking at the wrong tree. Always give the reviewer the **absolute path of your worktree** and explicitly forbid it from reading any other checkout of the repo. (Cost when skipped: a full wasted review round-trip.)

The two stages:
- **Stage 1 — spec compliance:** does the diff do exactly what the spec said, nothing more? Flag scope creep, behavior changes smuggled into a structure cycle.
- **Stage 2 — quality:** is the new module actually *deep*? Are names from the domain glossary? Any seam leaks?
Each stage re-loops until it approves or rejects with a concrete reason. For higher assurance, use *N* independent reviewers prompted to **refute**, and require a majority to pass.

## Gate 6 — Deep-module quality (did it actually improve?)

Passing tests proves you didn't break it; it does not prove you *improved* it. A "split" that turns one 800-line file into ten 80-line files that import each other's internals has made the system **shallower** and *increased* change-amplification. Check, per new module:
- exported-symbol count (interface width) — should be small
- LOC behind it (implementation depth) — should be substantial
- inbound coupling — callers depend on the narrow interface, not internals

Reject splits that fail this even when tests pass. Depth, not line count, is the goal (Ousterhout).

## Which gates run every cycle (no silent erosion)

A subtle failure mode: the early cycles run the full ladder, then later "trivial" cycles quietly run a *lighter* set — drop a slow suite, skip the AST tripwire, skip the adversarial review — while the cycle log still reads "ran smoothly." Nothing breaks *this* time, but the trust contract has eroded and the next reviewer over-credits the weakly-gated cycles. Forbid this explicitly:

- **Mandatory every cycle, no exceptions:** static/compile, the **exported-symbol manifest empty-diff** (Gate 1/1b), the **full must-stay-green suite contract** recorded in the masterplan (every suite in it, every cycle — not a convenient subset), and the **two-stage adversarial review**. These are the gates that catch the failures an agent can't see in its own diff.
- **May be scaled to the move's risk** (e.g. characterization/golden-master for a pure verbatim 2-function move): only the gates whose failure mode the move provably cannot trigger. The bar is *provably cannot*, not *probably won't*.
- **If you downgrade any gate, you must record WHY in the scoreboard row** ("ledger: 2 fns moved verbatim, golden-master N/A — no output path") so the downgrade is visible and auditable. An unrecorded downgrade is a gate violation, not a shortcut.
- **The PR/impact evidence must be per-cycle**, never the first cycle's numbers carried forward as if they covered all of them (see [IMPACT.md](IMPACT.md)).

## Failure semantics

- On **any** gate red: **revert to the last green checkpoint.** Never stack edits on a red gate.
- A cycle that can't pass a gate after a bounded retry is a **plan** problem — kick it back to the masterplan, don't brute-force.
- The loop has three legitimate stops: success (worklist empty), blocked (record it), budget (cap hit). A missing failure-stop is how loops thrash on a broken state.
