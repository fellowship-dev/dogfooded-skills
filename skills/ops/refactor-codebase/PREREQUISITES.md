# Pre-Flight: Prerequisites for Safe Refactoring

**Run this BEFORE the masterplan, every time you start on a repo — especially a repo you don't own.** Refactoring is behavior-preserving by definition, and behavior preservation requires (1) an **oracle** you can trust and (2) a **reproducible environment** to consult it in. No oracle, no refactor.

> Fowler's law: the two most important tools for refactoring are **self-testing code** and **continuous integration** — and "you aren't really doing continuous integration unless you have self-testing code." If the repo has neither, your first job is to establish an oracle, not to move code.

## The decision rule

After the checklist, every repo lands in one of three states:

1. **HARD GATE — do not refactor.** No usable test oracle on the target surface AND it can't be cheaply characterization-tested; OR the suite is **genuinely** flaky; OR the build is **genuinely** red at baseline. → Bootstrap an oracle (golden-master tests, quarantine flakes) or STOP and report.

> **First, rule out RED-vs-MIS-RUN — the hard gate's most common false trip.** A suite that fails on a fresh checkout is *usually* mis-run, not broken: it needs an undocumented env var, a service/DB stub, a seed, or a runner flag (or it *hangs* on a leaked handle, which a literal reading mistakes for "stuck → broken"). Aborting here on a healthy repo is the costliest pre-flight mistake. **Cheap discriminator:** bisect **one passing test vs one failing test** and diff their setup — if the only difference is environment (an env var, a stub, a fixture the failing test assumes), it's a **MIS-RUN → auto-bootstrap a run-wrapper** (state 2), not a red build. Only conclude "genuinely red" after the same minimal env makes a representative test pass. A *hanging* suite ≠ a *failing* suite: add a per-test timeout + force-exit and re-judge from the parsed tally before calling it flaky or broken.

> **Stable-RED has a sibling: stable-FLAKY — and it does NOT mean STOP.** "Never refactor under a flaky oracle" (checklist #2) means *don't trust a flaky run as your green signal* — not *abort if the full suite is non-deterministic*. Real repos often have a whole suite whose fail count swings run-to-run (server/DB-spawning integration tests leaking state) that you cannot cheaply green. You can still refactor safely if you **(a)** make the deterministic **surface-identical / byte-identical / AST gate the load-bearing oracle**, and **(b)** pin a **per-target deterministic subset** (the unit suites that exercise the moved code, which pass reliably *in isolation*) as corroboration, judged via the regression-vs-flake discriminator ([GATES.md](GATES.md#regression-vs-flake-isolate-before-you-blame-the-cycle)). Record the full-suite flaky band + each target's isolated-green subset in the masterplan. This is AUTO-BOOTSTRAP (pin a trustworthy subset), not HARD-GATE STOP. Only a suite that is flaky *and* offers no deterministic subset *and* no surface gate (i.e. genuine behavior changes you can't byte-verify) is a true STOP.
2. **AUTO-BOOTSTRAP (cheap, do it).** Missing canonical test entrypoint, `.tool-versions`/devcontainer, lint baseline, or seed determinism. → Generate them and point at the tool.
3. **FLAG FOR HUMAN (expensive / owned).** No staging for an infra/backend refactor; no Docker for Testcontainers; low mutation score on a high-risk module. → Surface it; do not self-certify "done" without it.

### The suite isn't green at baseline → which case is it? (one box)

Four distinct diagnoses, only one is a STOP. Diagnose before you react — they look alike and the wrong call either aborts a healthy repo or refactors on a blind oracle:

| Diagnosis | Tell | Action |
|---|---|---|
| **MIS-RUN** | fails on missing env/stub/flag, or *hangs* | bootstrap a run-wrapper (env + force-exit + timeout); re-judge from the parsed tally. NOT a stop. |
| **Stable-RED** | fails **identically on the base sha** (run the base-sha arm) — missing AWS/S3/service backends in the harness | record the exact red set, assert it stays **unchanged**; the deterministic **surface/byte-identical gate is your oracle**. Proceed. |
| **Stable-FLAKY** | fail count **swings run-to-run** (server/DB-spawning, state leaks) — incl. *miscount-under-load* | pin a deterministic per-target subset that passes **in isolation**; surface gate is load-bearing. Proceed. |
| **Genuinely RED** | reproducibly broken on base AND no deterministic subset AND no surface gate (real behavior you can't byte-verify) | **HARD-GATE STOP** — bootstrap an oracle or report. |

Stable-RED ≠ stable-FLAKY (different diagnosis — base-sha arm vs isolation arm — same escape hatch: lean on the deterministic surface gate). Full mechanics in [GATES.md](GATES.md#regression-vs-flake-isolate-before-you-blame-the-cycle).

## The pre-flight checklist

| # | Prerequisite | Why | How to detect | If missing |
|---|---|---|---|---|
| 1 | **Trustworthy test suite (oracle)** | can't prove behavior preserved without it | find `test/ tests/ spec/ __tests__ *_test.*`; run them | thin/absent → write **characterization / golden-master** tests on the public surface first |
| 2 | **Deterministic suite (no flakes)** | a flaky suite is a non-oracle | run 3–5×, diff results; grep tests for `Date.now`, `random`, `sleep`, network | quarantine flakes; inject a clock, seed RNG, isolate state. **Never refactor under a flaky oracle.** |
| 3 | **Oracle actually catches bugs** | green ≠ trustworthy; coverage tells you code *ran*, not that it's *asserted* | mutation test the target file (Stryker / mutmut / PIT); aim mutation score >70% | kill surviving mutants with characterization tests *before* trusting the suite |
| 4 | **Reproducible dev env (one command)** | autonomous work must stand the project up identically every run | `.devcontainer/`, `docker-compose.yml`, `Dockerfile`, `flake.nix`/`devbox.json`, `.tool-versions`, `Makefile` | generate a `devcontainer.json` (image + features + `postCreateCommand` that installs deps and runs the suite) |
| 5 | **Pinned runtime versions** | drift breaks the oracle | `.tool-versions`, `mise.toml`, `.nvmrc`, `engines`, `go.mod`, `rust-toolchain.toml` | create `.tool-versions` matching the CI matrix; Nix/devbox for polyglot |
| 6 | **Deterministic test data** | integration oracle needs reproducible data | `db/seeds`, `factories/`, `fixtures/`, factory_bot/Fishery/factory-boy, unseeded Faker | add factories/fixtures; **seed Faker**; reset sequences between tests |
| 7 | **Ephemeral DB / services for tests** | shared mutable state = flaky oracle | hardcoded `localhost:5432`? Testcontainers/in-memory present? | Testcontainers (real Postgres/Redis per run) or PGlite; avoid SQLite-in-memory when prod is Postgres (parity gap) |
| 8 | **One canonical "run all tests" command** | the loop needs one unambiguous verify | `make test`, `npm test`, `Taskfile`, CI's test step | add one entrypoint wrapping the native runner (vitest/jest, pytest, `go test`, `cargo test`, rspec, JUnit). **Present-but-stale counts as missing** — see below |
| 9 | **CI config as source of truth** | CI *is* the project's definition of correct; mirror it | `.github/workflows/*.yml`, `.gitlab-ci.yml`, `Jenkinsfile` | replicate CI's exact commands/flags/versions locally (optionally `act`). Note: many pipelines merge upstream first — reproduce that |
| 10 | **Static analysis baseline** | millisecond gates catch whole regression classes | `.eslintrc`, prettier, `ruff.toml`, `mypy.ini`, `tsconfig`, golangci-lint | record current warning count, fail only on **new** findings (refactor a noisy legacy repo without first cleaning it) |
| 11 | **Clean build at baseline** | "preserved behavior" vs a broken build is meaningless | run the build | refuse to start until green |
| 12 | **Staging / pre-prod (backend/infra)** | green tests can still hide prod-parity gaps (12-factor dev/prod parity) | staging deploy target? non-prod env config? | FLAG: staging evidence is a human-owned prerequisite before "done" |

## Make the suite actually runnable

(The step between "find the command" and "take the baseline.") The checklist's #8 covers a *missing* entrypoint. Real repos have a worse case: an entrypoint that **exists but is stale** — a `scripts/test.sh` / `make test` that names files long since renamed or deleted, a documented command that no longer runs the real suite. This is more dangerous than *missing*, because it looks authoritative while running nothing (or the wrong thing). Do not trust a documented command until you've confirmed it executes the real test files.

Before taking a baseline:
1. **Reconcile the documented command against reality.** List the actual test files (`find` for `*_test.*` / `*.test.*` / `*.spec.*`), then check the canonical command actually runs them. A command that runs 2 files when 70 exist is stale.
2. **Build a working run-wrapper** (env vars + stub/seed + runner flags + per-test timeout/force-exit), and use *that* as your gate harness for the whole loop. On a repo you don't own, keep it in a scratch dir (not committed) unless you're fixing the repo's own command — see the docs rule below.
3. **Confirm determinism on the wrapper** (run it 3–5×), then record the exact invocation in the masterplan's gate contract so every cycle verifies identically.
4. **Watch for host/runtime gotchas in the wrapper itself** — they masquerade as a broken suite and burn turns. Record the ones you hit in the gate contract. Examples seen in the wild: ES modules ignore `NODE_PATH` (install gate deps into the package, e.g. `npm install --no-save`, don't rely on a global path); **a gate script that `import`s a dep (acorn/esbuild) must itself LIVE inside the package dir** — ESM resolves `node_modules` by walking up from the *script file's* directory, not the cwd, so a script in `/tmp` can't import a dep installed in `pkg/node_modules` even when you run it from `pkg/`; keep gate scripts in a gitignored scratch subdir *inside* the package (`pkg/.scratch/gate.mjs`) — but **verify it's actually ignored** (`git check-ignore pkg/.scratch/x`): a conventional-looking `.scratch/` is *not* ignored unless the repo's `.gitignore` says so, and if it isn't, a reflexive `git add -A` will stage all your gate artifacts into the PR. When in doubt, **stage the real files explicitly by path, never `git add -A`**, and check `git diff --cached --stat` before committing. Run the scope/leak check on the **staged set** (`git diff --cached --name-only | grep …`), not on `git status` — `git status` lists *untracked* scratch files too, which trips a false "scratch artifact is in the PR!" alarm when nothing is actually staged; `node --test <dir>` may need an explicit glob (`<dir>/*.test.mjs`) to discover files; macOS has no `timeout` (use the runner's own `--test-timeout`, `gtimeout`, or a `perl -e 'alarm shift; exec @ARGV'` wrapper); a relative path passed to a gate script (e.g. `./db.mjs`) resolves against the *script file's* dir under ESM import, not the invocation cwd — resolve it explicitly (`pathToFileURL(resolve(process.cwd(), arg))`); `node --test` reports pass/fail as `ℹ pass N` / `ℹ fail N` summary lines (not TAP `# pass`/`1..N`) — grep those when tallying from output. The class is general: the wrapper failing ≠ the code failing. **Harness hygiene over a long loop:** route per-suite/per-cycle test output to a single *reused* scratch file, not a growing pile of per-run logs — across dozens of cycles the accumulation can fill the harness tmpfs (ENOSPC) and kill the loop mid-run. Bigger hazard: **running the *entire* stable-red suite each cycle** (dozens of subprocess-spawning integration tests each timing out at 120s) is itself the main tmpfs/time sink — once you've recorded the baseline, run only the **deterministic per-target subset**, never the whole suite per cycle.

## Docs are part of the refactor

Read them; fix stale ones in the same PR. Reading the project's docs is **part of pre-flight**, not optional: `README`, test/setup docs, `CONTEXT.md`, `docs/adr/`, and whatever the canonical "how to run/verify" doc is. Two consequences:
- **Read before you plan.** ADRs and the domain glossary record decisions you must not re-litigate and seams you should split along.
- **A refactor that touches something the docs describe must update those docs in the *same* PR.** If pre-flight finds a doc that is *stale* (a dead test command, a renamed module, an obsolete setup step) and your refactor is in that area, **fix it in the same PR** — do not merely flag it as a follow-up. Stale docs are debt the refactor is uniquely positioned to pay down, and leaving them wrong re-pays the discovery cost onto the next agent. (A doc fix is a *behavior-preserving* change to the repo's documentation surface — it does not break the one-hat rule for code.)

## What "bootstrap an oracle" means in practice

When coverage on the target is thin (the common case on a god-file hotspot), **do not refactor first**. Instead:

1. Pick the public surface of the target (its exported functions / API / rendered output).
2. Write **characterization tests / golden-master snapshots** that capture what it does *today*, warts and bugs included. The trick: assert a deliberately-wrong value, run it, copy the *actual* observed output into the assertion. You're pinning current behavior, not asserting correctness.
3. **Scrub nondeterminism** (timestamps, GUIDs, hash-ordered maps, absolute paths) so diffs reflect real change, not noise.
4. Treat any later snapshot diff as a **hard stop** requiring justification — never auto-accept a new snapshot (that's how a regression gets "approved").

Golden-master beats unit tests when behavior is poorly understood, coverage is thin, the output is large/structured, or you're exploring an unfamiliar codebase — exactly the autonomous-on-someone-else's-repo situation.

## What this skill does NOT do

It **flags and points**, it does not deeply build these for you. Standing up a full devcontainer, a Testcontainers harness, a seed library, or a staging environment are their own pieces of work. When a prerequisite is missing and expensive, the skill's output is a clear, specific recommendation ("this repo has no deterministic seed data; add Fishery factories + seed Faker before integration tests can serve as the oracle") — surfaced to the human, not silently worked around.
