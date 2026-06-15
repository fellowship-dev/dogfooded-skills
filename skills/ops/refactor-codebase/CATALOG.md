# The Refactoring Catalog & Risk Ladder

This file is the **menu of moves**, ranked by how safely an autonomous agent can perform them. [SELECTION.md](SELECTION.md) tells you *what* to target and *which direction*; this file tells you *which named refactoring* to apply and *what to expect* when you do.

> **Governing principle: approachability == determinism.** A refactoring is safe to the exact degree that a deterministic tool (compiler, type-checker, LSP, codemod) can perform and verify it. Text generation is unreliable for structural transforms. So an autonomous loop should spend **most cycles in tiers T1–T3**, gate **T4** on "all callers in-repo + green oracle," and treat **T5** as characterization-test-first, tiny-step, reviewed work — never a one-shot generative rewrite.

## The risk / approachability ladder

| Tier | Refactorings | Why here | Tooling | Blast radius | Provability |
|---|---|---|---|---|---|
| **T1 — Safest** | Rename, Extract/Inline Variable, Extract/Inline Function (local), Remove Dead Code, Replace Magic Literal | mechanically behavior-preserving; LSP computes a workspace-wide edit from the symbol graph | fully automated (LSP/IDE) | tiny–wide but **mechanical** | trivial; compiler/type-checker |
| **T2 — Low** | Change Function Declaration (internal), Decompose/Consolidate Conditional, Guard Clauses, Split Variable, Replace Temp with Query, Introduce Parameter Object, Slide/Move Statements | local or single-signature; deterministic recipe, edits ripple to call sites | mostly automated | function → call sites | tests at the function boundary |
| **T3 — Medium** | Move Method/Field, Extract Class, Inline Class, Hide Delegate, Encapsulate Field/Collection, Replace Conditional with Polymorphism, Pull Up/Push Down | cross-object; references, imports, visibility, `this`-binding must propagate | partial (IntelliJ strong, weaker elsewhere) | multi-file | needs integration tests |
| **T4 — High** | Change a **public/exported** API or signature, Split Phase, Combine Functions into Class, Replace Error Code with Exception, Substitute Algorithm, Replace Primitive with Object across a domain | crosses module/package boundary; **callers you cannot see**; semantics can shift | codemods help, need review | whole module + downstream | hard — callers may be out of repo |
| **T5 — Riskiest** | **Split a god-file / decompose a fat module**, Replace Inheritance with Delegation (& inverse), Extract/Collapse Hierarchy, change architecture/layering | no single deterministic transform; design judgment; many hand-written delegations; easy to silently break | mostly manual | whole subsystem | very hard; only characterization/behavioral tests catch regressions |

**Note the consequence for this skill's original instinct:** "decompose the big files" is **T5 — the hardest, riskiest tier.** Do not treat it as the default. Reach for it when SELECTION.md flags a genuine churning hotspot, OR when a file is simply too large for an agent to read whole (the agent-navigability objective — see [SELECTION.md](SELECTION.md)) — **and** in both cases only when the deep-module acceptance test will hold AND you have a trustworthy oracle. Even then it's *staged*: many small, independently-verified commits, never a one-shot rewrite. Often the higher-ROI, lower-risk win is a cluster of T1–T3 moves inside the hotspot first.

## What a finding looks like, expected effort, expected diff

| Tier | What the opportunity looks like | Typical effort | Typical diff |
|---|---|---|---|
| **T1** | cryptic name; an expression repeated 3×; a one-letter temp; an unreferenced symbol | seconds–minutes (one IDE action) | 1–30 lines; a rename may touch many files but is mechanical |
| **T2** | a 60-line function doing 3 things; a nested `if/else` pyramid; a boolean flag arg; a long parameter list | minutes–~1 hr | 20–100 lines, localized |
| **T3** | a method referencing another class's data more than its own (Feature Envy → Move); a class with two responsibilities (→ Extract Class); a `switch` on a type code (→ polymorphism) | 1–4 hrs incl. tests | 100–400 lines across a few files |
| **T4** | a widely-imported function with a wrong signature; an error-code convention threaded through a layer; a raw primitive used as a domain concept everywhere | half-day–days; coordination | hundreds–thousands of lines (call-site fan-out) |
| **T5** | a 2,000-line god file that is also a churning hotspot; an inheritance tree used only for code reuse; a layering violation | days–weeks, **staged** | very large — **must be split into many small, independently-reviewed commits** |

## The catalog by category (Fowler)

Use these names in cycle specs and commit messages so reviews are unambiguous. Full catalog: refactoring.com/catalog; taxonomy: refactoring.guru.

- **Composing Methods** — Extract/Inline Function, Extract/Inline Variable, Replace Temp with Query, Split Variable, Replace Method with Method Object, Substitute Algorithm.
- **Moving Features** — Move Method, Move Field, Extract Class, Inline Class, Hide Delegate, Remove Middle Man.
- **Organizing Data** — Encapsulate Field/Collection, Replace Magic Number with Constant, Replace Primitive with Object, Replace Type Code with Subclasses/Strategy.
- **Simplifying Conditionals** — Decompose/Consolidate Conditional, Replace Nested Conditional with Guard Clauses, Replace Conditional with Polymorphism, Introduce Special Case (Null Object).
- **Simplifying Method Calls** — Change Function Declaration (rename/add/remove param), Introduce Parameter Object, Preserve Whole Object, Separate Query from Modifier, Replace Constructor with Factory.
- **Dealing with Generalization** — Pull Up / Push Down Field/Method, Extract Super/Subclass/Interface, Collapse Hierarchy, **Replace Inheritance with Delegation** (T5 — no deterministic transform; choose what to delegate by hand).

## Smell → refactoring map (diagnosis to move)

| Smell | Refactoring | Tier |
|---|---|---|
| Long Method | Extract Function; Decompose Conditional; Replace Temp with Query | T1–T2 |
| Large / God Class | Extract Class; Extract Subclass; Extract Interface | T3 (→T5 if it's the whole god-file) |
| Feature Envy | Move Method; Extract+Move | T3 |
| Data Class | Move behavior to the data; Encapsulate Field | T2–T3 |
| Long Parameter List | Introduce Parameter Object; Preserve Whole Object | T2 |
| Primitive Obsession | Replace Primitive with Object | T4 |
| Switch on type code | Replace Conditional with Polymorphism | T3 |
| Duplicated Code | Extract Function/Class; Pull Up Method | T1–T3 |
| Shotgun Surgery | Move Method/Field; Inline Class (consolidate) | T3 |
| Divergent Change | Extract Class (split by reason-to-change) | T3–T5 |

## Tool support (automation correlates with safety)

- **Deterministic, reliable:** Rename, Extract/Inline, Change signature, Move file/symbol — via LSP-backed IDEs. **IntelliJ/Rider** are the gold standard; **gopls** (Go), **rope** (Python), TS/JS language servers.
- **Scripted at scale:** mechanical pattern migrations via **jscodeshift** / **ast-grep** / **comby** (AST-aware, far safer than regex). Robust for ultra-large codebases.
- **Manual judgment required:** god-file split, architecture change, inheritance→delegation, algorithm substitution. These get characterization tests + small reviewed steps, not generation.

**Rule:** prefer a semantic tool over hand text-edits whenever one exists for the language — it updates every call site/import/type atomically and kills the dropped-reference failure class. When none exists, move bodies **verbatim** and lean on the reverse-reference scan + the AST node-count tripwire ([GATES.md](GATES.md)).

## Scale guidance

- **Small (<10k LOC):** favor T1–T3 by hand/IDE in single PRs; prioritize readability smells (fast ROI, near-zero risk). Often the right move is *consolidating* shallow files, not splitting.
- **Medium (10k–100k):** Extract Class / Move Method / module splits (T3) become the high-value plays. Public-API changes (T4) are now real — identify in-repo vs out-of-repo callers first. Codemods start paying off.
- **Large (100k+/monorepo):** automate the repetitive low-value work with codemods; **split big changes into independently-tested chunks** (the Google "Rosie" model). Prerequisites (consistent formatters first) enable everything. Outside Google you won't have global test-against-all-users infra, so your leverage is: deterministic codemods + tiny verified diffs + a strong oracle.
