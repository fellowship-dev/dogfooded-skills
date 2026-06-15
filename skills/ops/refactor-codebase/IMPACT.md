# The Impact Case: Selling the Refactor

A refactor nobody understands the value of doesn't get merged. This file gives the agent (a) the **hard numbers** that make the general case and (b) a **per-PR impact report** that makes the specific case — so the dev, the lead, the PM, and the CTO each see value in their own unit.

> **One-line thesis:** internal quality is not a speed-vs-quality tradeoff. The strongest evidence converges — unhealthy code is ~2× slower to change, ~15× buggier, and far less predictable, and firms that pay debt down grow revenue ~20% faster. As Fowler puts it, the cost of quality is **negative**.

## The stat table (cite these; they're the credibility anchor)

| Statistic | Figure | Source |
|---|---|---|
| Defects: unhealthy vs healthy code | **15× more** | CodeScene "Code Red" (peer-reviewed, 39 production codebases, arXiv 2203.04374) |
| Time to resolve an issue in low-quality code | **+124% (~2×) longer** | Code Red |
| Worst-case cycle-time (predictability) | **9× longer** | Code Red |
| Developer time lost to tech debt / bad code | **23–42%** | Code Red / Stripe |
| Dev hours/week fixing the past | **17.3 of 41.1 (~42%)** | Stripe, *The Developer Coefficient* (2018) |
| "New product" budget diverted to debt | **~30%** | McKinsey, *Reclaiming Tech Equity* (220 orgs) |
| Tech debt as share of tech estate value | **20–40%** | McKinsey |
| Revenue growth: top vs bottom debt-managers | **+20%** | McKinsey |
| Engineering time freed by managing debt | **up to +50%** | McKinsey |
| US cost of poor software quality (2022) | **$2.41T** (debt ≈ $1.52T) | CISQ |
| Developers' #1 frustration | **tech debt (62–63%)** | Stack Overflow Survey 2024 |
| Window before poor quality slows you | **"a few weeks"** | Fowler, *Is High Quality Software Worth the Cost?* |

The four most defensible anchors: CodeScene's **2× / 15× / 9×** (peer-reviewed, real code), McKinsey's **30% / 20–40% / +20%** (the money frame), Stripe's **42%** (the developer frame), Fowler's **negative cost of quality** (rebuts every "no time" objection).

## Per-audience framing (same truth, their unit)

- **Developers — "less friction, less fear, more flow."** They care about feedback speed, fear of breaking things, cognitive load. Pitch: "You're spending ~42% of your week fighting bad code; after this, changes here take half as long and break 15× less." Show before/after complexity + coverage from the actual PR — engineers trust numbers, not slogans. (Tech debt is *their* #1 frustration; only ~20% are happy at work.)
- **Team lead / eng manager — "predictable velocity, less firefighting, lower bus-factor."** Pitch: "This hotspot swings cycle times up to 9×, which is why estimates miss. Stabilizing it cuts unplanned work and lets a new hire ramp in weeks not months." Metrics: 9× predictability gap, +50% reclaimed capacity, onboarding drag in dollars.
- **Project manager — "fewer slipped deadlines, lower delivery risk."** Pitch: "Estimate misses here aren't the team's fault — low-quality code carries 9× worst-case variance. Reducing that variance is the most effective way to hit dates." Frame refactoring as **schedule insurance**, not gold-plating.
- **CTO / CEO — "money, time-to-market, talent, growth."** Pitch: "Debt taxes ~30% of our new-product budget and equals 20–40% of our tech estate; firms that pay it down grow revenue ~20% faster. This converts hidden tax into roadmap capacity — and retains the seniors who quit over legacy code." Translate to dollars and strategic optionality, never code smells.

## The per-PR impact report (attach to every refactoring PR)

Pair *before/after objective metrics* with *projected business value*. Template:

```markdown
## Refactoring impact

**Target:** <file/module> — selected as a churn × complexity hotspot
(<N> commits in last 12mo × <complexity>), ranked #<k> in the repo.

**Behavior preserved:** ✅ <suite> green (<n> tests); <byte-identical bundle / 
golden-master diff empty / AST node-count unchanged>. No behavior change.

| Metric | Before | After |
|---|---|---|
| Cognitive complexity (target) | … | … |
| Public surface (exported symbols) | … | … (narrower = deeper module) |
| Max function length | … | … |
| Test coverage on surface | … | … |
| Files touched per typical change (blast radius) | … | … |
| Hotspot rank | #k | dropped out of top-N |

**Projected value:** this hotspot accounted for ~<X>% of recent changes here;
at the ~2× faster change-time multiplier for healthy code, expect ~<Y>
engineer-hours/quarter reclaimed and lower defect risk in this area.
```

The headline is the **complexity/health delta + the behavior-preservation proof** — the first ties to the 2×/15× multipliers, the second is the trust anchor that answers "is refactoring risky?" for every skeptical reader.

> **When a PR bundles several cycles, report behavior-preservation evidence PER CYCLE — never carry the first cycle's numbers forward as if they covered all of them.** "52 tests green, AST node-count unchanged" stated once for a three-cycle PR silently over-credits the later cycles if they actually ran a lighter gate set (and is exactly how a [silent gate downgrade](GATES.md#which-gates-run-every-cycle-no-silent-erosion) hides in a PR body). Give each cycle its own one-line evidence row — the suites it ran, its surface-diff result, whether it got an adversarial review — so a reviewer can see every cycle was gated, not just the first. If a cycle legitimately scaled a gate down for a provably-safe move, say so in that row; an honest "ledger: 2 fns verbatim, golden-master N/A" beats a blanket claim that doesn't hold.

## Counterargument rebuttals (have these ready)

| Objection | Rebuttal |
|---|---|
| "Refactoring is risky." | Behavior-preserving refactoring with a green oracle and small diffs is *lower* risk than continuing to change unhealthy code (15× defects, 9× variance). The risk is in *not* doing it. |
| "It doesn't add features." | It adds future feature *capacity* — high internal quality reduces the cost of every future feature (Fowler). |
| "We don't have time." | You're already paying ~42% of dev time / ~30% of budget. Poor quality slows you within "a few weeks." |
| "Speed vs quality is a tradeoff." | DORA's multi-year data: elite teams achieve both; quality practices correlate with +50% delivery / +30% org performance. |
| "Prove the ROI first." | Top-quintile debt-managers grow revenue ~20% faster; pair that with the specific before/after PR metrics above. |
| "Let's do one big rewrite later." | Continuous small refactorings minimize risk vs big-bang; debt compounds and morale declines while you wait. |
