# Techniques

Each technique is a *named, mechanical* move with a known safety profile. Pick by the shape of the target. The first two keep the change **byte-identical at the public surface**, which is why they're the workhorses of a behavior-preserving loop.

> **Reach for a semantic tool before hand-editing.** Where the language has one, prefer an **LSP "move/rename"** or a **codemod** (ast-grep / jscodeshift / comby) over text edits — it updates every call site, import, and type atomically and eliminates the dropped-reference failure class. This is *the* safety lever: approachability tracks determinism (see [CATALOG.md](CATALOG.md)). Hand-editing is the fallback for languages/moves with no tool, and it leans on the reverse-reference scan + the AST node-count tripwire ([GATES.md](GATES.md)).

> **Language-agnostic.** Examples below use JS/Node syntax (`export *`, `makeXApi(deps)`) and `git` for illustration. The moves are universal — map them to your stack: a "barrel" is a re-export facade (Python `__init__.py` re-exporting submodules, a Go package's exported surface, a Java package-info/facade, a Rust `mod.rs` `pub use`); "compose-behind-factory" is any constructor/provider that assembles sub-providers; "revert" is whatever gives you a clean rollback in your VCS. Keep the *public surface* identical; the mechanics are local.

## Barrel-split — for pure-export / helper modules

A big module that is mostly independent exported functions (a `utils`, a `db`, a helpers file).

1. Split the file into `<dir>/<domain>.mjs` sub-files, grouped by cohesion.
2. Replace the original file with a **barrel** that re-exports them:
   `export * from "./<dir>/identity.mjs"; export * from "./<dir>/billing.mjs"; …`
   The `export … from` line is self-documenting — **do not annotate it with process comments** ("extracted in cycle 3", "re-exported so importers stay unchanged"). That story lives in the commit/PR, not the source (see [CYCLE.md](CYCLE.md#cycle-hygiene)).
3. Every importer keeps its original `import { … } from "<original>"` unchanged.

**Why it's safe:** the public import path and surface are untouched → the byte-identical *manifest* gate is trivially satisfiable. Note the equivalence is **manifest-identical, not bundle/AST-identical**: extracting to a new file always adds an import + a barrel re-export line, so the bundle and AST node-count *grow* by that scaffolding — gate them with the surface-identical variant ("delta small & explained," not `==0`), see [GATES.md](GATES.md#surface-identical). Watch for **shared internals** (a private helper several domains use): move it to `<dir>/_core.mjs` and have the domain files import it. Before deciding move-vs-share, grep every moved symbol across the original file + all importers (the reverse-reference scan).

### The shared-mutable-state trap (the crux of splitting a DB/service god-file)

The most common reason a barrel-split *looks* trivial but isn't: many of the functions you want to move all read a **private, mutable, module-level binding** via closure — a `let pool` (the DB connection), a `let cache`, a `let _ready` flag — assigned in some `init()` and read by ~everything. This is **connascence of state through a shared mutable binding**: strong, and (once you split) *distant*. A naive move breaks two ways:
- the moved sub-file can't see the private binding → **won't compile**; or
- you "fix" that by **exporting** `pool` from the original file → the public surface widens, the module gets *shallower*, and you **fail the deep-module acceptance test** (Gate 6). The barrel was supposed to hide internals, not leak them.

So the move-vs-share decision the reverse-reference scan feeds isn't only about helpers — it's about **shared mutable state**, and the fix is a dedicated holder, not a wider export:

1. **Introduce a private holder module** (`<dir>/_state.mjs` / `_pool.mjs`) that owns the mutable bindings and exposes them as **live bindings + setters** — in ES modules: `export let pool = null;` plus `export function setPool(p){ pool = p; }`. The `init()` core writes via the setters; every other module **imports the live binding** and reads the current value (ES live bindings update at the import site when the holder reassigns — verify your language has this semantic; in CommonJS/Python you'd export a getter `() => pool` or a small holder object instead).
2. **Do this as its own setup cycle first** (a branch-by-abstraction / Mikado leaf) — *before* moving any domain functions. It legitimately changes the bundle (the setters + import), so it's gated with the **surface-identical variant**, not byte-identical ([GATES.md](GATES.md#surface-identical)).
3. **Then the domain extractions are pure verbatim moves** — each carved-out module imports the live `pool`/`ready` from the holder, the original file's public surface stays byte-identical, and `_state.mjs` is **not** re-exported from the barrel (it's a private internal, which is exactly what keeps the module deep).

This sequence — *untangle shared mutable state into a private live-binding holder, then move* — is what makes splitting any connection-pooled DB layer or stateful service module safe. It's the worked form of "inject deps as getters" from compose-behind-factory, applied to a barrel-split.

**Shared *immutable* constants are a lighter case — don't over-engineer them with a holder.** A `const COLS = "..."` (or any frozen value) shared by two clusters you're separating doesn't need setters or a live-binding holder; nothing reassigns it. Either move it *with* the cluster that owns it and have the other import it, or — when two non-contiguous regions split across separate cycles both need it — use a **temporary private re-import bridge**: the first cycle exports the const from its new module, the second imports it, and once both regions have moved you collapse the const into its final private home. Reserve the holder+setters pattern for state that is genuinely *mutated at runtime*; for immutable shared values a plain move/import is the behavior-preserving fix.

## Compose-behind-factory — for factory / handler modules

A fat `makeXApi(deps)` (or class) that builds and returns many handlers.

1. Split into per-domain sub-files, each exporting `makeX<Domain>(deps)` that returns its slice of handlers.
2. The original factory **composes** them: it calls each sub-factory and merges the returned handler objects.
3. Callers keep `import { makeXApi } from "<original>"` and the same wiring.

**Why it's safe:** the factory's external contract (its returned shape) is unchanged → byte-identical surface. Watch for deps that are *reassigned at runtime* (e.g. via a reload): inject them as **getters** (`() => dep`), not captured values, or the sub-module sees a stale binding.

**The load-bearing safety check when you wrap the factory in a lazy singleton** (`let _api; const api = () => (_api ??= makeXApi(deps))`): a lazy holder is behavior-preserving **only if the factory does no observable work at construction time.** Probe explicitly — *does `makeXApi` invoke any injected, side-effecting dep in its body (not inside a returned handler)?* If it just destructures deps and returns closures (the common case), lazy-init is invisible. But if it *eagerly calls* a side-effecting dep (opens a connection, constructs a client, fires a request) at construction, the lazy holder shifts **when** that side effect fires — from module-load to first-use — which can be observable. Safe-by-default holds when the injected deps are themselves already lazy/memoized (e.g. a `getClient()` that self-memoizes on first await); confirm that, don't assume it.

## Extract module — for one cohesive cluster inside a bigger file

When a fat file has one clear domain you can lift out.

1. Identify the cluster: functions sharing state/types/tables, called together.
2. Move them verbatim into a new module; export the minimal surface the rest of the file needs.
3. Re-import that surface back into the original. Keep the moved bodies **byte-identical** (slice, don't retype).

**The shared-mutable-state trap applies here too**, not just to barrel-split: if the moved cluster closes over a module-local binding (a `let COSTS_DB`, a cached handle assigned in some `init()`), you must re-home that binding. Re-declare the same-named binding inside the new module and add a single `initX(args)` setter the host calls at the same point the old inline init ran (see the holder pattern above). One extra rule when the **host keeps its own derived value** from that init (e.g. a `const HAS_SQLITE = sqliteAvailable()` the host reads elsewhere): have `initX()` **set the module-local AND return the derived value**, and have the host assign its const from that return — *one* evaluation, so the module's copy and the host's const **cannot diverge**. Recomputing the flag independently on the host side is the bug this avoids. (This is the lightweight, single-module form of the live-binding holder — use it when only one host consumes the state; promote to a separate `_state.mjs` holder when several modules do.)

Prefer **language-server "move symbol"** / codemods so every call site and import updates atomically. The deletion test confirms the cluster was worth extracting: if deleting the new module would re-scatter complexity across callers, it's earning its keep.

## Strangler-fig — for risky replacement of a live path

When you must replace a behavior, not just relocate it.

1. Stand up the new implementation **beside** the old, behind a seam (adapter / feature flag).
2. Route consumers to it **incrementally**, one at a time; run both in parallel and verify equivalence.
3. Once all traffic is on the new path and verified, delete the old.

This is a *behavior* change track — it gets behavior gates (golden-master, staging/canary), not just byte-identical.

## Branch by Abstraction — the in-process strangler

When the thing to replace is **deep in the stack** (upstream callers you can't intercept at a perimeter), use Branch by Abstraction instead of Strangler-fig:

1. Introduce an **abstraction** capturing the client↔supplier interaction; route **all** clients through it.
2. Build the new implementation behind the same interface (optionally behind a feature flag); the system **builds and runs correctly at all times**.
3. Switch clients over progressively; remove the old supplier, then possibly the abstraction.

This is the in-process analog of strangler-fig, and it maps almost exactly onto **compose-behind-factory**: split a fat module behind a stable interface, build the new internals, verify identical output, retire the old. Use it for large structural changes on trunk without a long-lived branch.

## <a id="mikado"></a>Mikado discovery — for "I don't know what will break"

To **discover** a safe decomposition order empirically instead of guessing:

1. Attempt the change you want (the goal).
2. Note everything that breaks. Those are **prerequisites** — children of the goal in the graph.
3. **Revert** the attempt (`git reset --hard` / discard). The tree stays green.
4. Recurse into each prerequisite until you reach a **leaf**: a change that breaks nothing.
5. Execute leaves bottom-up, each as its own green-verified cycle.

**Why it's powerful:** the breakage *tells you* the dependency structure — no upfront guessing. The Mikado graph (checked/unchecked nodes) doubles as the masterplan and the handoff. The discipline that makes it work: **never commit a broken attempt; revert and record instead.**

## Choosing

| Target shape | Technique | Gate emphasis |
|---|---|---|
| exported-helpers file | barrel-split | byte-identical surface |
| `makeXApi` / handler factory | compose-behind-factory | byte-identical surface |
| one domain inside a fat file | extract module | byte-identical + reverse-ref scan |
| replace impl deep in the stack | branch-by-abstraction | byte-identical surface, then golden-master |
| behavior must change (perimeter) | strangler-fig | golden-master + staging |
| unknown breakage | Mikado (then one of the above per leaf) | revert-on-red |
