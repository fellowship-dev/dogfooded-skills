---
name: dx-metrics
description: Use when measuring AI-coding-agent adoption and its effect on software delivery for a repo or org — leverage per human steerer, DX Core 4 speed/quality/impact, AI-execution floors, cycle time, ownership risk — computed from git and the GitHub API into a self-contained HTML dashboard. Attributes every commit to a steerer AND an executor rather than classifying it human-or-AI.
user-invocable: true
allowed-tools: Read, Write, Bash, Glob, Grep
argument-hint: "[org/repo | --org owner] [--since YYYY-MM-DD] [--period week|month]"
---

# dx-metrics

Measures **AI adoption and its effect on software delivery**, computed from git
and the GitHub API, framed as DX Core 4.

It answers four questions with numbers a client CTO can defend:

* **How much output does one human steer?** Commits and merged PRs per distinct
  steerer, per period. On a team where agents do the committing, this is the
  headline — it is what a seat buys, and an AI percentage cannot answer it.
* **How much of the work was agent-executed?** A **floor**, from
  `Co-Authored-By` trailers, labelled as a floor everywhere it appears.
* **What happened to delivery?** Throughput, cycle time, defect ratio,
  innovation ratio — before and after each person's first trailer.
* **What can this method not see?** Declared inline, on every number, every time.

---

## THE ATTRIBUTION MODEL: every commit is a PAIR

Read this first. Everything else on the page depends on it.

**A commit is not human XOR AI.** It carries **two** attributions, and either
one may be absent:

| axis | states | meaning |
| --- | --- | --- |
| **steerer** | `known` · `unknown` · `machine` | the human who directed the work |
| **executor** | `agent` · `unknown` | the agent that produced the diff |

`octocat@workstation.local` is not an unattributed commit. It is
**(that engineer, an agent)** — a human steered, an agent executed, on the
human's own laptop. On an agent-assisted team that pair is the normal case, not
an edge case.

### The two rules that make it honest

1. **A missing trailer is NOT evidence of human execution.** Trailer discipline
   arrived late in every repository this has been pointed at, so untrailered
   history is **unknown executor** — never "no executor", never "human". There
   is deliberately **no `executor_state='human'`**, in the schema or anywhere
   else: nothing in git can produce that value, and offering it would mean
   inferring human authorship from an absence.
2. **An unresolvable author is NOT a human.** It is an **unknown steerer** — a
   measurement gap, not a person. Such commits stay in execution denominators
   (they really happened), and are excluded from every per-person view and from
   the leverage numerator. They are never counted as human work.

Rule 2 is a fix, not a nicety. The previous version treated
`author_identity_id IS NULL` as passing the human filter. On one measured org
that was **1,514 of 5,993 commits (25%)**, and it manufactured an AI-adoption
ramp: the reported series read 62% → 79% → 80% while the attributed-only series
read 84% → 82% → 88% (flat). The "ramp" was tracking identity-resolution
quality, and nothing on the page said so.

### What the fix buys you, and what it does not

The dashboard now publishes **two** AI-share series side by side — over all
executions, and over known-steerer executions only. **Divergence between them
is the attribution artifact**, made visible instead of argued about. If they
drift apart across the window, what you are watching is identity resolution.

**The gate:** `meta.unknown_steerer_share` is the run's own quality signal.
**Above ~10%, do not present an adoption trend at all** — present the AI floor
for the most recent complete period and say plainly that the trend is not yet
measurable. The dashboard prints this as a headline card and enforces the
distinction in its banner.

The way to move that number is `identity-overrides.tsv`, not code.

Everything is deterministic shell. No Docker, no Postgres, no Python, no
compiled binary. The agent shells out and reads a ~1 KB JSON line; it never
reads raw `git log`.

### Prerequisites

`git`, `awk`, `jq`, `sqlite3` (**≥ 3.33** — earlier builds have no `-json`, which
the dashboard requires), and `gh` **authenticated** (`gh auth login`). `gh`
carries all auth; this skill contains no token plumbing. Check everything at
once with `run.sh --doctor`, which verifies gh auth (not merely gh's presence)
and prints **which binary** and **which login**. On Ubuntu 20.04 / Debian 10 the
stock `sqlite3` is too old.

### WHICH `gh` — this is not a detail

If the `gh` first on your PATH is a shim that mints per-repo tokens, **org
enumeration is silently wrong**. Measured on the machine this was built on:

```text
gh repo list acme-corp                 ->  0 repos, exit 0, no error text
/usr/local/bin/gh repo list acme-corp  -> 28 repos
```

A zero-repo org produces a complete, well-formatted, entirely empty dashboard.
So:

* `--gh-path PATH` (or `DXM_GH`) selects the binary. It is recorded in the run
  envelope as `gh.binary` / `gh.login` — publish it next to any org number.
* `GH_TOKEN` / `GITHUB_TOKEN` / `GH_ENTERPRISE_TOKEN` are **cleared for every
  gh call** so an ambient token cannot override `gh auth login`. Set
  `DXM_GH_CLEAR_TOKENS=0` if you really are driving this from a CI token.
* **An org that enumerates to zero repos is a hard failure (exit 2), always.**
  `--min-org-repos N` asserts a floor above zero. Never let an empty org run.

```bash
DXM_GH=/usr/local/bin/gh GH_TOKEN= GITHUB_TOKEN= \
  ./run.sh --org acme-corp --min-org-repos 20
```

---

## THIS IS NOT A PERFORMANCE-MEASUREMENT TOOL

Read this before you run it, and repeat it to whoever receives the output.

* **The default dashboard is designed to contain no personal information**, and
  it holds no names, logins or email addresses. This is a **procedural**
  guarantee enforced by the queries, not a structural one — an earlier version
  of this file claimed the render "reads tables that have no identity column",
  which was false: the default render joins `v_human_identities` and projects
  counts and dates out of it. Believing the structural claim is how the
  adoption curve came to publish three `{date, n:1}` points that re-identified
  three named people against `git log` in about a minute.
* **Small buckets are the leak, not columns.** Any aggregate over one or two
  people is a per-person report wearing a chart. Two floors now apply by
  default (`--min-cohort`, default 3): adoption-curve buckets below the floor
  are withheld and the withholding is stated, and per-contributor throughput is
  withheld when the contributor denominator is below it. If you add an
  aggregate, ask what it says when n=1 before you ship it.
* **Leverage is a per-person rate and is gated like one.** `commits per steerer`
  and `merged PRs per steerer` are withheld when the steerer count is below
  `--min-cohort` (default 3), because "142 commits / 1 steerer" is one named
  person's output with the name filed off. The steerer *count* survives — a
  headcount is a fact about the system.
* **Per-person data is opt-in**, behind `--include-individuals`, and unlocks
  exactly two things: **ownership/SPOF risk** and **AI-adoption timing**. That
  render is written to a **different filename** (`…-INDIVIDUALS-do-not-
  circulate.html`) so it can never silently overwrite the shareable copy.
* **There is no per-person throughput leaderboard — opt-in or not.** No flag
  produces one. Do not add one.
* **Files on disk are `chmod 600`**: the rendered dashboards, the generated
  `mailmap`, and `identity-review.tsv` (which is a list of real contributor
  email addresses).
* This output is **sensitive information**. It **must not be used to measure
  individual performance or to feed performance evaluations.** A commit count is
  not a contribution and cycle time is a property of a system, not of a person.

If someone asks you to rank engineers with this, the answer is no. Point them at
the aggregate view.

---

## Weekly trend charts — `dxm-trends.sh`

`dxm-dashboard.sh` answers "where are we now". `dxm-trends.sh` answers "what
changed", as **one self-contained HTML file per org** with six weekly series:

| # | Series | Where it renders |
| --- | --- | --- |
| 1 | commits per **person** per week | `--include-individuals` only |
| 2 | merged PRs per **person** per week | `--include-individuals` only |
| 3 | commits per **repo** per week | default |
| 4 | merged PRs per **repo** per week | default |
| 5 | multi-line commit ratio per **person** per week | `--include-individuals` only |
| 6 | multi-line commit ratio per **org** per week | default |

```bash
scripts/dxm-backfill-body.sh                 # once; git only, no API calls
scripts/dxm-trends.sh --org acme-corp
scripts/dxm-trends.sh --org acme-corp --include-individuals  # separate file
```

Every bucket is an **ISO calendar week** (`2026-W33`), labelled on every axis and
in every tooltip. The current, unfinished week is drawn hollow and dashed at the
right edge and is excluded from every total, every change table and every
headline. The boilerplate is stated **once**, globally, at the top of the page —
not repeated on each card.

**There is no JavaScript in the output at all.** Every `<svg>` is generated
server-side by awk; tooltips are native SVG `<title>` elements. That is a
hardening choice: `dashboard.html` builds its charts in the browser, and a
render-time exception there produces a blank page while the file size, the byte
count and the `ok:true` envelope all still look healthy. A page with no script
cannot fail that way, and it is trivially CSP-safe.

### The multi-line signal — what it is, and what it is NOT

`commits.has_body` is a **stored** column, populated by `dxm-backfill-body.sh`:
take the commit message, drop the subject line, drop every trailer-shaped line
(`^\s*[A-Za-z-]+:\s`), drop blanks — `has_body = 1` if anything remains.

**Stripping trailers is the measurement, not a tidy-up.** `Co-Authored-By` is
the line that *defines* `executor_state='agent'`. Leave it in and "multi-line
predicts AI-trailered" is not a finding, it is the same column twice.

Measured across four scopes with deliberately different trailer cultures, after
the strip:

| Scope | multi-line | declared trailer | precision | recall |
| --- | --- | --- | --- | --- |
| agent-native repo (non-merge, machine-steered in) | 73.6% | 73.8% | **91.1%** | 82.5% |
| agent-native repo (machine-steered out) | 67.2% | 75.0% | 93.9% | 84.1% |
| agent-assisted org, 104 weeks | 57.0% | 58.2% | 90.3% | 88.5% |
| low-trailer org, 104 weeks | 3.1% | 1.3% | **36.0%** | 82.9% |

Read the last row before quoting the first. **The proxy's precision tracks the
base rate**: the identical rule is 91% precise where trailers are at 74% and 36%
precise where they are at 1.3%. So:

* label it an **agentic-usage proxy**, *never* "AI usage";
* **always publish the declared-trailer base rate on the same axes** — the page
  does this automatically and refuses to draw one line without the other;
* it detects **agentic** use, where the agent writes the commit message. It is
  **blind to assistive** use — Copilot autocomplete, pasted ChatGPT — where the
  human writes it. It also cannot distinguish an agent from a human who writes
  thorough commit messages.

`has_body IS NULL` means *not measurable* (the SHA is unreachable in the cached
clone). It is excluded from ratio denominators, never counted as single-line.

### Privacy, enforced by a test rather than a promise

The default render is per-repo and per-org only. Before writing it,
`dxm-trends.sh` greps its own output bytes for every login, every display name
and anything email-shaped in the database, and **exits 4 rather than write a
file containing one**. A hit that is a substring of an in-scope *repository*
name is allowed and reported (`acme/jdoe-website` is a repo identifier), and its
count travels in the envelope as `pii_repo_name_collisions`. Per-person output
requires `--include-individuals` and lands in a separate
`…-INDIVIDUALS-do-not-circulate.html` that can never overwrite the shareable
copy. Both files state, where the numbers are, that this must not be used for
individual performance evaluation.

---

## Proxy declaration — the hard rule

**Every number that is a proxy says so, inline, next to itself, every time.**

For everything stored in `agg_metric` this is enforced by the database, not by
review: `agg_metric.metric_key` is a foreign key into `metric_catalog`, so a
metric with no catalog row — and therefore no `proxy_statement` and no declared
`cannot_see` — **cannot be stored**. Renderers fail loudly on a missing catalog
row rather than print a bare number.

**The FK does not cover the headline.** The "At a glance" cards read
`agg_org_period` directly and never touch `metric_catalog`, so they inherit no
disclosure automatically. Their caveats are written by hand in the template and
have to be maintained by hand. If you add a headline card, write its disclosure
in the same commit — that section is the one that gets screenshotted.

The blind spots you must never let a reader forget:

| Metric | Proxy statement | Cannot see |
| --- | --- | --- |
| **AI-executed share** | **FLOOR**, not a measurement — counts only executions with a declared agent `Co-Authored-By` trailer. Labelled `— FLOOR` in the catalog, the JSON and the HTML. | Which untrailered commits an agent wrote. Because trailer discipline arrived at different times, the **shape** of the series is less trustworthy than its floor. |
| **Leverage per steerer** | Output with a *known* steerer ÷ distinct known steerers | Executions with no identifiable steerer (left out of the numerator, so it understates), work steered but not committed, review and pairing. Withheld entirely below `--min-cohort`. |
| Unknown-steerer share | Not a proxy — it is the gap itself | Who steered them. **Not counted as human.** Its size gates whether any trend on the page is presentable. |
| Defect / innovation ratio | A classifier's opinion read from titles, labels and branch names | An actual defect tracker; a bug fixed inside a feature PR |
| Cycle time | `merged_at − first_commit_at` | Time before the first commit — thinking, spec, review queueing |
| Throughput | Merged PRs per active contributor | PR size; a 4000-line PR and a typo fix count the same |
| Bus factor | Measured over commits, not files | That one person owns the payments module |
| **DXI (Effectiveness)** | **Not computable.** DXI is a survey instrument. | Rendered as explicitly unavailable with the reason. **Never faked, never substituted with a git-derived stand-in.** |

---

## Quick start

```bash
SKILL_DIR=skills/ops/dx-metrics          # wherever the skill was synced

# one org, weekly + monthly buckets, dashboard at the end
$SKILL_DIR/run.sh --org acme-corp --period week --period month

# specific repos, bounded window (SAY SO in any report — a truncated window is
# a truncated conclusion)
$SKILL_DIR/run.sh --repo acme-corp/web-app --since 2025-02-01

# preconditions, DB state, dangling runs, the rule backlog
$SKILL_DIR/run.sh --doctor

# opt-in individual section: ownership risk + adoption timing ONLY
$SKILL_DIR/run.sh --org acme --include-individuals
```

`run.sh` is a thin shim over `scripts/dxm-run.sh`, which is the orchestrator.

**Read the JSON line on stdout. Ignore stderr unless something failed.** Every
script prints exactly one line of JSON on stdout at the end; all progress goes
to stderr. That is the whole point — do not pipe raw git or API output into your
context.

---

## What it runs, and why in that order

| # | Stage | Script | Writes |
| --- | --- | --- | --- |
| 1 | git ingest | `dxm-ingest-git.sh` | `commits`, `ai_trailers` |
| 2 | GitHub ingest | `dxm-ingest-github.sh` | `pull_requests`, `pr_commits`, `identities`, backfills |
| 3 | identity | `dxm-identity.sh` | mailmap, overrides, review queue, bot flags, steerer backfill |
| 4 | classification | `dxm-classify.sh` | `pr_classifications` |
| 5 | aggregation | `dxm-aggregate.sh` | `agg_org_period`, `agg_author_period`, `agg_metric` |
| 6 | dashboard | `dxm-dashboard.sh` | one self-contained HTML file in `$DXM_OUT` |
| 6b | message bodies | `dxm-backfill-body.sh` | `commits.has_body`, `commits.body_chars` (git only, no network) |
| 6c | weekly trends | `dxm-trends.sh` | one self-contained HTML file per org in `$DXM_OUT` |

* **git before GitHub** — identity resolution reads the commit emails git wrote.
* **identity before classify** — classify skips bot-authored PRs, which needs
  `identities.is_bot` already set.
* **classify before aggregate** — the defect and innovation ratios read
  `pr_classifications`.
* **aggregate before dashboard** — the dashboard renders `agg_metric` and
  refuses to invent a number that is not there.

The identity stage runs with `--backfill-commits`, which the orchestrator passes
deliberately. The GitHub ingest fills `commits.author_identity_id` at stage 2 —
*before* the override file is read at stage 3, and only where it is still NULL.
Without the backfill, a mapping you added to `identity-overrides.tsv` changed
nothing in the run that applied it, and the unknown-steerer share would not move
until the *next* run for reasons nothing on the page explained.

### The override file is the highest-leverage thing an operator touches

`$DXM_HOME/identity/identity-overrides.tsv`, created on first run from
`references/identity-overrides.seed.tsv` (copied, never merged into an existing
file). Two different fixes live in it and they must not be confused:

* **a human committing from a machine** → map the address to that human's login.
  A person on their own laptop is still that person steering; the agent is the
  executor.
* **a machine with no identifiable human behind it** → map it to a
  `dxm-machine-*` login. `^dxm-machine-` is a seeded `bot_patterns` rule, so
  those are excluded from delivery metrics rather than inflating the human
  population.

The `email` key may be a **glob** (`ubuntu@*.ec2.internal`), because machine
addresses come in families and a new devbox mints a new hostname. Globs never
pre-seed a row — there is no single address to insert.

An address you cannot evidence stays unmapped. That is a legitimate outcome: it
becomes an unknown steerer and is reported as one. Guessing is not.

**Ingest runs serially, one repo at a time.** There is no `--parallel` flag.
Several simultaneous clones saturate a laptop's disk and network, make the run
slower rather than faster, and make a failure impossible to attribute.

---

## The four measurement decisions that make this trustworthy

1. **AI attribution is `Co-Authored-By` trailers only.** No text or label
   guessing on PR bodies — a PR that merely *discusses* ChatGPT is not an AI PR.
   Consequence: the AI share is a **floor**, and it says so on every card. The
   complement of that floor is **unknown executor**, never human.
2. **Identity is resolved server-side.** `gh api repos/{o}/{r}/commits` →
   `.author.login`, asked once per *distinct email* (a 20k-commit repo usually
   has ~40). This resolves corporate addresses too. No regex email-mining.
   Emails GitHub cannot link stay unresolved, become **unknown steerer**, and
   are reported as a named population — never guessed, never called human.
3. **Shallow clones are refused, not warned about.** A `--depth` clone silently
   truncates history and produces a confident, wrong time series — every
   "adoption started in March" conclusion would be an artefact of clone depth.
   `dxm-ingest-git.sh` asserts `git rev-parse --is-shallow-repository`, records
   it in `repos.is_shallow`, and exits 2.
4. **Partial buckets are marked and rendered differently.** A partial week that
   looks like a decline is the single most common way this class of dashboard
   lies.

### Calibrate the floor before you quote it

**A low AI share is a statement about the metric, not about the team.** Repos
that are unambiguously AI-native — projects whose maintainers say publicly that
almost all of the code is agent-written — measure **0.2%–1.3%** on
trailer-based detection. That is the calibration point to carry into every
conversation about a number under, say, 20%.

So the correct reading of a 1% AI share is *"trailer discipline does not exist
in this repo and the metric cannot see the tooling"* — never *"this team barely
uses AI"*. The two claims are indistinguishable from git alone, and only one of
them is safe to say out loud. Quote the floor, quote the calibration, and let
the reader draw the conclusion the evidence actually supports.

The way to raise a floor is to make the tools emit trailers, not to loosen the
detector.

### NEVER match a bare agent name — the rule that costs you the metric

Loosening the detector is the obvious next move, and it is a trap. **Do not
match `Cursor`, `Claude`, `Cline`, `Cody`, `Devin` (or any other agent name) as
standalone words** in commit messages, PR bodies, branch names or author names.

Measured on **124,985 commits authored before 2021** — history that predates
every one of these tools, so *every* hit is by construction a false positive —
bare-name matching reaches a **1.64% false-positive rate**. Read that against
the calibration above: the noise floor of the loose rule is **larger than the
real signal it is trying to recover**. You do not get a better metric, you get
the same number with the evidence removed.

The reason is mundane. Real people are named Claude. "Cursor" is an ordinary
noun in any codebase with a database or a text editor in it. "Cody", "Devin"
and "Cline" are surnames and given names.

The tiers that survive the same corpus are the ones this skill ships:

| tier | rule | false positives on 124,985 pre-2021 commits |
| --- | --- | --- |
| high | a declared `Co-Authored-By` trailer naming a known agent identity | **zero** |
| medium | an agent's own account or a vendor-owned address (`noreply@…`, `…[bot]`) | **zero** |
| low | the agent's name appearing as a bare word anywhere | 1.64% — **rejected** |

`ai_agents.pattern` is therefore matched **only against the `name <email>` of a
`Co-Authored-By` trailer** — never against a subject, a body, a branch or a
label. That single scoping decision is what keeps the shipped patterns in the
zero-false-positive tiers even where they contain a word like `claude`: a
declared co-author is evidence, the same characters in prose are not. The
residual risk is a human co-author who happens to be *named* like an agent, and
the override file's `human` directive exists to settle exactly that case (see
`references/identity-overrides.md`). If you add an agent row, anchor it on a
vendor address or an account-shaped token, and keep it out of message text. A
pattern that would fire on prose is a bug even while its number looks better.

### The caveat that matters most on an agent-native team

**Bot exclusion is mandatory (decision 10), and on a team where agents open
their own PRs it removes the majority of the delivery output from every metric.**

Measured, not hypothesised, on the first real run:

| Scope | Merged PRs excluded as bot-authored | Non-merge commits excluded as bot-authored |
| --- | --- | --- |
| agent-native org, 6 repos, all history | 803 of 1753 (46%) | 1248 of 4480 (28%) |
| agent-assisted org, one month | 30 of 43 (70%) | 82 of 114 (72%) |

So "13 PRs merged this month" is the **humans'** throughput. The system shipped 43.
Both numbers are true and they answer different questions. DX Core 4 is a measure
of the human engineering system; an agent account's own output sits outside it by
design.

When you summarise, say which one you are quoting. The dashboard's *What was
counted* table gives you both — read `commits_bot` and `prs_merged` from it
before writing a sentence with a number in it.

---

## Script coverage — the self-measured metric

Every unit of output logs **one** `coverage_log` row saying how it was decided:

| method | meaning |
| --- | --- |
| `script` | a deterministic rule decided it outright |
| `script-with-fallback` | decided by a script, but via a weaker secondary signal (labels because the title had no prefix) |
| `llm` | no script could decide it — **this is the backlog** |

`coverage_pct = 100 * (script + script-with-fallback) / total`, defined once in
`v_coverage_by_run`. On `llm` rows the `detail` column states *why the script
gave up*; that string is the specification for the rule that should have
existed. `v_llm_backlog` ranks them by frequency — `run.sh --doctor` prints the
top of it.

An honest 70% with a well-specified backlog beats a fake 100%.

---

## Storage and state

| Variable | Default | Meaning |
| --- | --- | --- |
| `DXM_HOME` | `$HOME/.dx-metrics` | root for everything persisted |
| `DXM_DB` | `$DXM_HOME/dxm.db` | the SQLite database |
| `DXM_CACHE` | `$DXM_HOME/cache` | full mirror clones (never shallow) |
| `DXM_OUT` | `$DXM_HOME/out` | rendered dashboards |

The DB lives **outside** both the measured repo and this skill's directory. It
is state, not source. **Never commit a `.db` file, a mailmap, or the identity
review queue** — the last two contain contributor names and email addresses and
carry a SENSITIVE header saying so.

**Raw events and derived aggregates are separate**, and aggregates are always
rebuildable from raw. A bucketing bug is a `--rebuild`, not a re-ingest.

**Resumable and incremental.** Watermarks in `ingest_watermarks` advance only
after a clean, complete pass. A rate limit exits **3** — a first-class outcome,
not a crash — leaves the cursor alone, and the next run resumes. Re-fetching an
overlap is cheap; a hole in the time series is permanent and undetectable.

---

## Interpreting the output responsibly

* **Quote the window.** If you passed `--since`, say so. Never present a bounded
  backfill as full history.
* **Read `numerator` / `denominator` / `sample_size`, not just `value`.** A 100%
  defect ratio over 2 PRs is not a signal, and the dashboard shows the counts so
  the reader can tell.
* **Quote the unknown-steerer share, always, and check it before quoting a
  trend.** It is in the dashboard envelope as `unknown_steerer_pct` and in the
  aggregate envelope as `attribution.steerer_unknown`. Above ~10%, quote the
  most recent complete period's AI **floor** and say the trend is not yet
  measurable.
* **Never say "human" about an untrailered commit, or about an unresolvable
  one.** The right words are *unknown executor* and *unknown steerer*. The whole
  model exists to keep those two things from silently becoming "human".
* **Report the gaps the envelope gives you**: `attribution.*`,
  `unattributed_commits`, `unclassified_prs`, `merged_prs_with_no_git_commit`.
  They size the uncertainty. A dashboard with a 30% unclassified remainder is
  not wrong, but a summary that omits it is.
* **Correlation only.** The before/after adoption deltas have no control group
  and nothing else was held constant. The catalog rows say `CORRELATION ONLY`;
  keep that phrase when you summarise them.
* **Do not name individuals** in a summary unless `--include-individuals` was
  used *and* the question is ownership risk or adoption timing.

---

## Exit codes

| code | meaning |
| --- | --- |
| 0 | success |
| 1 | usage error — unknown flag, bad `owner/name`, bad date |
| 2 | precondition — shallow clone, missing `gh`/`sqlite3`/`jq`, schema mismatch |
| 3 | **partial** — rate limited or a repo failed. Data written is valid; watermarks were held. Re-run to resume. |
| 4 | data error the script cannot reconcile |

---

## Known limits

* **A bounded first ingest leaves a sticky watermark, and nothing ever backfills
  behind it.** If the first run for a repo used `--since`, the GitHub watermark
  is set at that bound and every later run resumes *forward* from it. History
  before the bound is never fetched, not by a re-run, not by dropping `--since`,
  not by `--rebuild`. The bound itself is recorded (as a pseudo-source in
  `ingest_watermarks`) so downstream readers can refuse to present pre-bound
  buckets as complete — but the data does not arrive later. **This is unfixed.**
  The workaround is to know it in advance: if you might ever want full history,
  do the first ingest of a repo unbounded, or delete that repo's watermark rows
  and re-ingest deliberately.
* `sql/report.sql` and `scripts/dxm-report.sh` are not built. The dashboard
  renders directly from inline queries; there is no separate JSON report surface.
* Deploy-branch detection (`scripts/dxm-ingest-deploy.sh`) is an optional module
  and **is not implemented**. DX Core 4 does not need it; nothing depends on it.
* `pull_requests` has no `review_count` column in schema v1. Review counts are
  fetched and discarded; `dxm-ingest-github.sh` feature-detects the column and
  will populate it the moment it is added.
* PRs whose merge commit was orphaned by a later history rewrite have no linked
  git commit, read as *not* AI-assisted, and therefore **understate adoption**.
  Counted as `merged_prs_with_no_git_commit` in the ingest envelope.
* Rows are only as good as the trailers. A team using AI without
  `Co-Authored-By` is invisible here, and the dashboard says so on every AI card.
* **The SHAPE of an AI series is weaker than its floor.** Trailer discipline
  arrived at different dates in different repos, so an upward slope is partly
  the adoption of *trailers*. The floor is defensible; the ramp is not, on its
  own.
* **An agent account with a known human owner still reads as `machine`.** Under
  the pair model that commit is really (that human, agent) — but "who owns this
  bot" is a configuration fact, not a git fact, so the tool refuses to guess it
  and the mandatory bot exclusion applies. Where it matters, decide it
  explicitly in the override file and say so in the deliverable. The count of
  machine-steered executions is printed on the dashboard so the size of what
  was set aside is visible rather than missing.
* **`risk.*` denominators are computed over known steerers only** and still
  carry no per-metric reduced-denominator disclosure inline; the attribution
  banner says it instead. Unchanged from the first draft.
* **The coverage panel and LLM backlog are database-wide, not scope-scoped.** A
  dashboard scoped to one org can display another org's coverage row. Unchanged.
* **The multi-line ratio cannot separate an agent from a verbose human.** It is
  a proxy for *agentic* use only, its precision falls with the base rate, and on
  a low-trailer org it is close to worthless on its own — which is why the page
  will not render it without the base rate beside it. See the table above.
* **`dxm-trends.sh` does not write `agg_metric`.** Its series are computed in the
  renderer from the views, like the dashboard's agent mix, and logged as such in
  `coverage_log`. The catalog rows exist (`adoption.multiline_commit_share`,
  `adoption.multiline_precision_vs_trailer`) so the wording has one home, but
  nothing yet persists the weekly ratio as a stored metric.
* **`dxm-trends.sh` is not wired into `run.sh` / `dxm-run.sh`.** It is run
  directly, after `dxm-backfill-body.sh`.

---

## Reference

* `CONTRACT.md` — the interface every script honours. Read it before editing one.
* `references/classification-rules.md` — the PR rule table, precedence, and the
  measured coverage per repo culture.
* `references/identity-overrides.md` — the override file format, globs, and the
  steerer-vs-machine distinction.
* `references/identity-overrides.seed.tsv` — the shipped starting point, copied
  into `$DXM_HOME` on first run.
* `references/github-queries.md` — the GraphQL documents and pagination reasoning.

### Test suites

```bash
scripts/dxm-classify-selftest.sh    # 49  classifier rules
scripts/dxm-agents-selftest.sh      # 21  which trailers are an agent, and which are NOT
scripts/dxm-identity.test.sh        # 94  identity, overrides, the pair columns
scripts/dxm-aggregate.test.sh       # 96  metric arithmetic, hand-computed
scripts/dxm-dashboard.test.sh       # 37  render, privacy, cohort floors
scripts/dxm-trends.test.sh          # 66  the trailer strip, ISO weeks, trend privacy
```

`dxm-trends.test.sh` builds a **real git repository** with nine hand-written
message shapes and asserts `has_body` on each, because the failure that matters
is silent: if the trailer strip regresses, the multi-line signal becomes a
restatement of the AI trailer and every conclusion drawn from it is circular
while every number still looks plausible. It also asserts the login, the display
name and the email are absent from the default render and present in the opt-in
one, so "the default is safe" is a test result rather than a claim.

The dashboard suite executes the template's own JavaScript under a DOM shim.
That is not belt-and-braces: a render-time exception leaves the page blank apart
from the `<noscript>`, while the file, the byte count and the `ok:true` envelope
all look healthy. Nothing in the shell can catch it.
