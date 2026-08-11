# PR classification — rules, vocabulary and the LLM-fallback protocol

Owner: W3. Implemented by `scripts/dxm-classify.sh` +
`scripts/dxm-classify-rules.awk`. Verified by `scripts/dxm-classify-selftest.sh`.

This document and the code must agree. `dxm-classify.sh --dump-rules` prints the
precedence table as JSON so the two can be diffed rather than trusted.

---

## 1. What this step is for

Quality (defect ratio, revert rate) and Impact (innovation ratio) are the two
DX Core 4 pillars that cannot be counted directly — they need to know *what kind
of change* each merged PR was. This step decides that, deterministically, and
reports precisely how much it could not decide.

**The headline output is the coverage percentage, not the classes.** A rule
table that honestly covers 77% with a specified backlog is worth more than one
that guesses its way to 100%.

Measured on 500 real merged PRs (5 repos, deliberately different cultures):

| Repo | Coverage | Pure-script | Character |
| ------ | ---------- | ------------- | ----------- |
| private repo A | 100% | 88% | strict conventional commits |
| private repo B | 93% | 89% | conventional commits |
| `kubernetes/kubernetes` | 71% | 3% | component-prefixed prose |
| `rails/rails` | 69% | 1% | prose titles, good labels |
| `facebook/react` | 55% | 3% | `[Subsystem] Prose` titles |
| **overall** | **77.6%** | **36.8%** | |

With `--no-heuristics` the same corpus drops to ~48%. That gap *is* the
heuristics' contribution, and it is the number to quote when someone asks how
much of this is guesswork.

---

## 2. Class vocabulary — and a deliberate divergence from the brief

`schema.sql` is authoritative. The values written to `pr_classifications.class`
are exactly:

```text
feature | bugfix | refactor | chore | docs | test | revert | deps | unclassified
```

The brief asked for `feature | bugfix | hotfix | release | revert | dependency |
chore`. Three of those are spelled differently here, on purpose:

| Brief | Stored as | Why |
| ------- | ----------- | ----- |
| `dependency` | `deps` | The frozen schema's spelling. |
| `hotfix` | `bugfix` + subtype `hotfix` | `agg_org_period` has `prs_bugfix`, `prs_feature`, `prs_revert`, `prs_unclassified` and no other class column. A `hotfix` class would fall out of every ratio silently. |
| `release` | `chore` + subtype `release` | Same reason. |

The distinction is not lost: it is carried in `pr_classifications.rule` (rule
families `cc:hotfix`, `hotfix:*`, `release:*`, `verb:release`) and counted in the
`subtypes` block of the run envelope. If a later contract revision adds the class
values, the change here is a two-line map edit and a re-run — no re-fetch.

`unclassified` (not `unknown`) is the give-up value, because that is the string
`v_prs_enriched` already produces via `COALESCE(cl.class,'unclassified')` and the
name `agg_org_period.prs_unclassified` already uses. Any W4 query that counts
`class='unclassified'` off the view gets the right answer whether or not a row
exists.

---

## 3. Precedence

Rules are tried in this order and the **first** one that fires wins. Order is the
whole design: a revert that also says "fix" is a revert, and a release PR carries
the labels of everything inside it.

| # | Family | Rules | Method | Conf |
| --- | -------- | ------- | -------- | ------ |
| 1 | **revert** | `revert:head-branch` (`revert-<n>-…`, GitHub's auto branch) · `revert:cc-prefix` · `revert:title` (`Revert "…"`) · `revert:reapply-rollforward` · `revert:head-prefix` · `revert:label` | script / s-w-f | .60–.99 |
| 2 | **deps** | `deps:bot-author` · `deps:head-branch` (`dependabot/…`, `renovate/…`) · `deps:cc-scope` (`chore(deps):`) · `deps:bump-title` (`Bump X from A to B`) · `deps:label` | script / s-w-f | .85–.99 |
| 3 | **conventional commit** | `cc:<type>` — `feat` `fix` `hotfix` `security` `perf` `refactor` `style` `docs` `test` `spec` `build` `ci` `chore` `deps` `release` `revert` `remove` `cleanup` `deprecate` `config` | script | .95 |
| 4 | **release** | `release:title` (`Release 2.4.0`, `v1.2.3`) · `release:head-branch` (`release/*`, `rc/*`) | s-w-f | .70–.75 |
| 5 | **label** | `label:<name>` — only when the mapped labels **agree**. Conflicting labels decide nothing. | s-w-f | .80 |
| 6 | **branch** | `branch:<first-segment>` — `feature/` `fix/` `hotfix/` `chore/` `docs/` `refactor/` `test/` `release/` … | s-w-f | .70 |
| 7 | **release promotion** | `release:promotion` — head in {develop, dev, staging, release, rc} → base in {main, master, production, prod, stable} | s-w-f | .60 |
| 7b | **backport** | `backport:cherry-pick` — `Automated cherry pick of …`, `[backport] …`, `backport/*` branches, `backport` label | s-w-f | .80 |
| 8 | **leading verb** | `verb:release` · `verb:bump` · `verb:docs` · `verb:test` · `verb:fix` · `verb:refactor` · `verb:add`. **Disabled by `--no-heuristics`.** | s-w-f | .55–.60 |
| 9 | **give up** | `needs-llm` | llm | — |

`s-w-f` = `script-with-fallback`: a script decided it, but from a weaker
secondary signal. It counts as covered (CONTRACT §7) and is tracked separately;
the run envelope reports it as `weak_decisions` when confidence < 0.70.

### Judgement calls, stated openly

* **`Reapply "…"` is not a revert.** GitHub uses it for a revert-of-a-revert,
  which is a roll-forward. Counting it would report one incident twice, so it is
  `chore` with rule `revert:reapply-rollforward`.
* **Backports are not bugfixes.** The original PR was already counted; the
  cherry-pick is the same defect a second time. `chore`.
* **`perf` is `refactor`**, not a feature. It changes how existing capability
  works, not what exists.
* **`refactor` is the safe dumping ground.** The broad stage-8 verb list routes
  ambiguity there rather than into `bugfix` or `feature`, because those two are
  the only classes the defect and innovation ratios read. A mis-bucketed
  refactor moves no headline number; a mis-bucketed bugfix does.
* **Title normalisation is verb-stage only.** `[8-1-stable] Warn when …` and
  `test/images: bump agnhost` have their leading tag stripped before verb
  matching. Conventional-commit parsing always runs against the untouched title,
  so this can never manufacture a `cc:` prefix that was not written.

---

## 4. The give-up protocol

There is **no LLM call in this module.** When no rule fires, the PR is written as
`class='unclassified'`, `method='llm'`, and:

* `pr_classifications.rule` gets the **per-PR specifics** —
  `needs-llm labels=[…] head=[…]` — which is what a human or a model needs to
  actually decide it;
* `coverage_log.detail` gets a **canonical, PR-independent reason token
  string**, so `v_llm_backlog` groups meaningfully instead of fragmenting into
  one row per PR.

Reason tokens, joined with `+`:

| Token | Means |
| ------- | ------- |
| `no-cc-prefix` | The title has no `type:` prefix at all. |
| `unmapped-cc-prefix(<type>)` | It has one, and the map does not know it. **Directly actionable** — the fix is one line in the `CC[]` map. |
| `no-labels` | The PR carries no labels. |
| `no-mapped-label` | It has labels, none of which map to a class. |
| `label-conflict` | Two labels imply different classes; deciding would be a coin flip. |
| `no-head-ref` / `no-branch-pattern` | The branch name says nothing. |
| `no-title-verb` | The heuristic verb list did not match. |
| `heuristics-disabled` | Stage 8 was switched off, so the PR was never offered to it. |
| `has-issue-link` | The body links an issue (`Fixes #N`). Not a decision — a **note that the evidence exists elsewhere**: fetching the linked issue's labels is the single highest-value rule this module does not have yet. |

`--emit-unresolved <path>` writes the same set as TSV
(`repo, number, title, labels, head_ref, base_ref, reason`) for whatever runs the
fallback. It contains **no author login, name or email** — the dependency-bot
test is evaluated in SQL and only a boolean leaves the database, so no identity
can reach a temp file or the queue.

Because unresolved PRs get a row stamped with the current
`classifier_version`, a later run does **not** re-log them and does not inflate
the backlog counts. They are retried when the classifier version changes, or on
`--rebuild`.

---

## 5. Incrementality

Classification has no watermark row — it is not an ingest source, and inventing
one would be a contract change. `pr_classifications` is its own cursor:

* no row → classify;
* row with a different `classifier_version` → re-classify (improving the rules is
  a re-run, never a re-fetch);
* row with the current version → skip.

`--rebuild` deletes the rows in scope and starts over. `--limit` defers the
remainder and says so in the envelope as `deferred_by_limit`, so a truncated run
can never be mistaken for a complete one.

---

## 6. Scope defaults, and why

* **Merged PRs only.** Every Core 4 metric counts merged PRs; classifying open
  ones would put PRs into the coverage denominator that no metric reads.
  `--all-states` widens it.
* **Non-bot authors only.** Dependabot PRs are trivially classifiable, so
  including them by default would inflate the coverage percentage with work the
  metrics then throw away. `--include-bots` widens it. Either way the counts are
  reported in `skipped`.

---

## 7. Known gaps (the backlog, in priority order)

1. **Linked-issue labels.** `Fixes #N` in the body is already detected; fetching
   that issue's labels would resolve a large share of the prose-title PRs. Needs
   a GitHub call, so it belongs with W2's ingest, not here.
2. **Per-repo learned prefixes.** `[Fiber]`, `kubeadm:`, `analytics:` are
   component tags, not types. A per-repo frequency pass could learn the tag
   vocabulary and strip it before verb matching.
3. **Commit-message trailers.** The PR title is one signal; the squashed commit
   subject and body are another, and W1 already stores subjects.
4. **File-path signals.** A PR touching only `docs/` or only `*_test.go` is a
   `docs` / `test` PR regardless of what its title says. `pull_requests` already
   stores `changed_files` as a count, not a list — so this needs an ingest
   change first.
