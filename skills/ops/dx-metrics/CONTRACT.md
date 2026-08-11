# dx-metrics — implementation contract

This is the interface every script in this skill must honour. Five workstreams
build against it in parallel. If your script disagrees with this document, your
script is wrong.

---

## 0. What this skill is

It measures **AI adoption and its effect on software delivery**, computed from
git and the GitHub API, using DX Core 4 as the frame.

**It is not a performance-measurement tool.** That is a design constraint, not a
disclaimer — see §8.

---

## 1. Non-negotiable decisions

These are settled. Do not relitigate them in your PR.

| # | Decision |
| --- | ---------- |
| 1 | No compiled binary, no Docker, no Postgres, no Python venv. Shell scripts + `sqlite3` + `gh`. |
| 2 | The **only** external dependency is the GitHub CLI (`gh`). It carries auth. **Never write token-plumbing code.** Prefer `gh api` / `gh api graphql` over raw `curl`. |
| 3 | Storage is SQLite. **Raw events and derived aggregates are separate.** Aggregates must be rebuildable from raw so a bucketing bug is a re-run, not a re-ingest. |
| 4 | Time buckets are calendar-aligned **day / week / month at UTC-0**. Weeks start **Monday** (ISO-8601). |
| 5 | Resumable and incremental. Re-running next week fetches only what is new, and produces numbers comparable to last week's. |
| 6 | **Minimise LLM tokens.** Anything a deterministic script can compute MUST NOT be computed by a model. The agent shells out and reads small JSON. It never reads raw `git log`. |
| 7 | Identity resolution is **server-side**: `gh api repos/{owner}/{repo}/commits` → `.author.login`. This resolves corporate emails too. Group by login. Only emails where login is null need human attention. **No regex email-mining.** |
| 8 | AI attribution is **`Co-Authored-By` trailers ONLY**. `git shortlog -sn --group=trailer:co-authored-by HEAD` gives per-agent counts free. **No text/label guessing on PR bodies** — a PR that merely discusses ChatGPT is not an AI PR. |
| 9 | Deploy-branch detection is an **optional module, OFF by default**. Not needed for Core 4. Do not make anything depend on it. |
| 10 | **Bot exclusion is mandatory** — dependabot, renovate, claude bots, in-house app accounts, `*[bot]`. |

---

## 2. File layout and ownership

Each workstream owns a **disjoint** set of files. Do not edit a file you do not
own. If you need a change in someone else's file, note it in your PR body.

```text
skills/ops/dx-metrics/
├── SKILL.md                       W5
├── CONTRACT.md                    W0  (frozen — this file)
├── schema.sql                     W0  (frozen — see §11 to propose a change)
├── lib/
│   └── dxm-common.sh              W0  (frozen — shared plumbing, already tested)
├── scripts/
│   ├── dxm-ingest-git.sh          W1
│   ├── dxm-ingest-github.sh       W2
│   ├── dxm-classify.sh            W3
│   ├── dxm-aggregate.sh           W4
│   ├── dxm-report.sh              W5
│   ├── dxm-doctor.sh              W5
│   ├── dxm-run.sh                 W5  (orchestrator)
│   ├── dxm-backfill-body.sh       W6  (added post-build — see §10c)
│   └── dxm-trends.sh              W6  (added post-build — see §10c)
├── sql/
│   ├── metrics.sql                W4  (metric views; never edit schema.sql)
│   └── report.sql                 W5  (read-only queries the renderer runs)
├── references/
│   ├── github-queries.md          W2  (GraphQL documents + pagination notes)
│   └── classification-rules.md    W3  (rule table + LLM-fallback protocol)
└── templates/
    ├── dashboard.html             W5
    └── trends.html                W6  (added post-build — see §10c)
```

`scripts/dxm-ingest-deploy.sh`, `sql/deploy.sql` — the optional deploy module.
**Not in the first draft.** Nobody owns them yet.

---

## 3. Environment and DB location

Resolved by `lib/dxm-common.sh`. Never hardcode a path.

| Variable | Default | Meaning |
| ---------- | --------- | --------- |
| `DXM_HOME` | `$HOME/.dx-metrics` | Root for everything this skill persists |
| `DXM_DB` | `$DXM_HOME/dxm.db` | The SQLite database |
| `DXM_CACHE` | `$DXM_HOME/cache` | Local clones / mirrors |
| `DXM_OUT` | `$DXM_HOME/out` | Rendered dashboards and JSON reports |

The DB lives **outside the repo being measured** and outside this skill's
directory. It is state, not source. Never commit a `.db` file.

---

## 4. Invocation conventions

Every script:

* is `bash`, starts with `#!/usr/bin/env bash` and `set -euo pipefail`;
* is executable (`chmod +x`) and lives in `scripts/`;
* sources the shared lib as its first real statement:

  ```bash
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  . "$SCRIPT_DIR/../lib/dxm-common.sh"
  ```

* accepts **long flags only**, `--flag value` (no bundled short flags);
* supports `--help` and prints usage to **stdout**, then exits 0;
* calls `dxm_init_db` before touching the database.

### Standard flags

| Flag | Meaning |
| ------ | --------- |
| `--repo owner/name` | Target repo. Repeatable. Required by ingest scripts. |
| `--org owner` | Target org. Ingest scripts expand it to repos via `gh`. |
| `--since YYYY-MM-DD` | Backfill floor. Ignored on incremental runs unless `--rebuild`. |
| `--until YYYY-MM-DD` | Analysis ceiling. Defaults to today, UTC. |
| `--rebuild` | Ignore watermarks / drop derived rows and recompute. Never re-fetches raw unless the script is an ingest script and `--refetch` is also given. |
| `--period day\|week\|month` | Bucket granularity. Default `week`. |
| `--include-individuals` | **Opt-in only.** Enables per-person output. See §8. |
| `--dry-run` | Do everything except write. Still emits the envelope. |
| `--json` | Default and implicit. There is no human-formatted stdout mode. |

Unknown flags are a **usage error (exit 1)**, not a warning. Silent
flag-swallowing is how two runs stop being comparable.

---

## 5. stdout, stderr, exit codes

**stdout gets exactly one line: a single JSON object, printed once, at the end.**
Everything else — progress, warnings, counts, git output — goes to **stderr**.

Keep the envelope under ~2 KB. It is read by an LLM. Never put rows, lists of
SHAs, PR titles or log text in it. Aggregate counts only.

Emit it with `dxm_emit`:

```bash
dxm_emit true "$(basename "$0")" "$RUN_ID" '"repo":"acme/api","commits_new":128,"prs_new":14'
```

which produces:

```json
{"ok":true,"script":"dxm-ingest-git.sh","run_id":42,"skill_version":"0.1.0",
 "db":"/Users/x/.dx-metrics/dxm.db","repo":"acme/api","commits_new":128,"prs_new":14,
 "coverage":{"total":14,"script":13,"script_with_fallback":0,"llm":1,"coverage_pct":92.9}}
```

`coverage` is appended automatically. Do not build it yourself.

### Exit codes

| Code | Meaning | Envelope |
| ------ | --------- | ---------- |
| 0 | Success | `"ok":true` |
| 1 | Usage error (bad/unknown flag, bad `owner/name`) | none required |
| 2 | Precondition failure — shallow clone, missing `gh`/`sqlite3`, schema mismatch, unreadable DB | `"ok":false,"error":"..."` |
| 3 | **Partial** — rate limited or interrupted. Data written so far is valid; **watermarks were not advanced.** | `"ok":false,"partial":true` |
| 4 | Data error — the API returned something the script cannot reconcile | `"ok":false,"error":"..."` |

Exit 3 is a first-class outcome, not a failure. The orchestrator re-runs and the
watermark makes it pick up where it stopped.

---

## 6. Resumability

The contract lives in `ingest_watermarks`, keyed `(repo_id, source)`.

**Sources and their cursors:**

| `source` | `cursor_kind` | `cursor_value` | Owner |
| ---------- | --------------- | ---------------- | ------- |
| `git_commits` | `sha` | last ingested commit SHA on the default branch | W1 |
| `git_trailers` | `sha` | last commit SHA scanned for trailers | W1 |
| `github_prs` | `timestamp` | max `github_updated_at` seen | W2 |
| `github_identities` | `timestamp` | last identity-resolution sweep | W2 |
| `deploys` | `sha` | optional module | — |

**The protocol, in order:**

1. `dxm_watermark_touch <repo_id> <source> <kind>` — before fetching. Records the
   attempt without moving the cursor.
2. Read `dxm_watermark_get <repo_id> <source>`. **Empty means never ingested** →
   full backfill (bounded by `--since` if given).
3. Fetch only what is newer than the cursor. For PRs: order by `UPDATED_AT desc`
   and **stop** at the stored timestamp.
4. Write rows with `INSERT OR IGNORE` / `INSERT ... ON CONFLICT DO UPDATE`.
   **Every ingest must be idempotent** — running twice must not double-count.
5. `dxm_watermark_set ... <run_id> <rows_added>` — **only after a clean, complete
   pass.** A partial pass leaves the cursor where it was. Re-fetching an overlap
   is cheap; a hole in the time series is undetectable and permanent.

Wrap bulk work in one transaction per batch (`BEGIN; … COMMIT;` via
`dxm_sql_stdin`), not one `sqlite3` process per row.

### Run bookkeeping

Every script opens a run and guarantees it closes:

```bash
RUN_ID=$(dxm_run_start "$(basename "$0")" "$*" "$REPO")
trap 'dxm_run_trap '"$RUN_ID"' $?' EXIT
```

A row stuck in `status='running'` means a previous invocation died. `dxm-doctor.sh`
reports these; watermarks touched by such a run are suspect.

---

## 7. Coverage logging — the self-measured metric

Every **unit of output** logs exactly one `coverage_log` row saying how it was
decided:

| `method` | Meaning |
| ---------- | --------- |
| `script` | A deterministic rule decided it outright. |
| `script-with-fallback` | A script decided it, but only via a weaker secondary signal (e.g. labels because the title had no prefix). Counts as covered; tracked separately as a degradation signal. |
| `llm` | No script could decide it; a model was asked. **This is the backlog.** |

```bash
dxm_coverage "$RUN_ID" pr_classification "acme/api#1407" script "conventional-commit:fix"
```

In loops, batch it — TSV on stdin, one process:

```bash
printf '%s\t%s\t%s\t%s\n' "$kind" "$key" "$method" "$detail" | dxm_coverage_batch "$RUN_ID"
```

**`detail` is mandatory.** On `script`/`script-with-fallback` it names the rule
that fired (evidence for any verdict a human disputes). On `llm` it names *why
the script gave up* — that string is the specification for the rule that should
have existed. `v_llm_backlog` ranks them by frequency.

**Unit kinds** (do not invent new ones without updating this table):
`pr_classification` · `identity_resolution` · `ai_attribution` · `metric` ·
`deploy_detection` · `commit_body` · `trend_chart`

`commit_body` logs **one row per repository**, not per commit: the unit of work
is "this repo's messages were read and the strip rule applied", and 34k rows per
run would bury every other kind in the same table. Its `detail` carries the
counts, including how many commits stayed NULL because their SHA is unreachable
in the cached clone. `trend_chart` logs one row per rendered chart.

**The formula is defined once**, in `v_coverage_by_run` (schema.sql):

```text
coverage_pct   = 100 * (script + script-with-fallback) / total
pure_script_pct = 100 *  script                        / total
```

No script recomputes this. Read the view.

For this first draft: get coverage as high as you can. There is no fixed target.
An honest 70% with a well-specified backlog beats a fake 100%.

---

## 8. Privacy — binding

Read this section twice. This output goes to a client CTO who may forward it to
his management.

1. **The default dashboard contains no personal information.** Structurally, not
   by convention: the default render reads `agg_org_period` and `agg_metric`,
   which have no identity column.
2. **Per-person output is opt-in**, behind `--include-individuals`. Absent the
   flag, no script may write a login, name or email to stdout, to a report, or
   to any file in `DXM_OUT`.
3. **No per-person throughput leaderboard exists — opt-in or not.** There is no
   flag that produces one. Do not add one.
4. Individual-level data is legitimate for exactly two things:
   * **risk** — ownership concentration, bus factor, SPOF;
   * **adoption timing** — when a person's first AI trailer appears.

   Both are marked `privacy_class='individual_ok'` in `metric_catalog`.
   Everything else is `aggregate_only`.
5. **SKILL.md and the dashboard must both state, in their own words**, that this
   is sensitive information and that it **must not be used to measure individual
   performance or feed performance evaluations.** Not a footnote — visible where
   the numbers are.
6. `agg_author_period` exists in the DB to make (4) computable. It is not an
   export surface. Nothing reads it into a report except the risk and adoption
   metrics.

---

## 9. Proxy declaration — hard rule

**If a number is a proxy, the output says so, inline, every time.**

A metric that admits what it cannot see beats one that quietly overclaims.

The enforcement mechanism is `metric_catalog`. `agg_metric.metric_key` is a
foreign key into it, so **a metric with no catalog row cannot be stored** — this
is enforced by SQLite, not by review. The catalog row carries:

* `is_proxy`
* `proxy_statement` — rendered next to the number, every time
* `cannot_see` — the explicit blind spot
* `computable` — `0` means it cannot come from git; render as **unavailable**,
  never as `0` or a dash
* `privacy_class`

**Renderers must fail loudly on a missing catalog row rather than render a bare
number.** Adding a metric means adding a catalog row in the same PR (W4/W5 add
theirs via `INSERT OR IGNORE` in `sql/metrics.sql`, not by editing `schema.sql`).

**DXI is `computable=0`.** Effectiveness is a survey instrument. Emit it as
explicitly unavailable with the reason. Do not fake it, do not substitute a
git-derived stand-in and call it DXI.

`agg_metric` stores `numerator`, `denominator` and `sample_size` alongside
`value`. Render them: a 100% defect ratio over 2 PRs is not a signal, and the
reader must be able to see that.

---

## 10. Table write-ownership

One writer per table. Anyone may read anything.

| Table | Written by |
| ------- | ----------- |
| `repos` | W1 (creates, sets `is_shallow`, `clone_path`, commit bounds) |
| `commits` | W1 |
| `ai_trailers` | W1 |
| `identities`, `identity_emails` | W2 |
| `commits.author_identity_id`, `commits.pr_number` | W2 (backfill UPDATE only) |
| `commits.has_body`, `commits.body_chars` | `dxm-backfill-body.sh` (UPDATE only) |
| `pull_requests`, `pr_commits` | W2 |
| `pr_classifications` | W3 |
| `agg_author_period`, `agg_org_period`, `agg_metric`, `agg_adoption_timeline` | W4 |
| `metric_catalog` (additions) | W4, via `sql/metrics.sql` |
| `runs`, `ingest_watermarks`, `coverage_log` | everyone, **only** through `lib/dxm-common.sh` |
| `deploys`, `prod_branch_patterns` | nobody in the first draft |

**Read only through the views.** Bucketing, bot exclusion and AI attribution are
defined once in `schema.sql`:

| View | Use it for |
| ------ | ----------- |
| `v_commits_enriched` | commits with `day_start` / `week_start` / `month_start`, `is_ai_assisted`, `is_bot`, `is_unattributed`, **`steerer_state`, `executor_state`, `executor_confidence`, `executor_agent_key`** |
| `v_prs_enriched` | PRs with merged-period buckets, `cycle_time_hours`, `class`, `is_ai_assisted`, `is_bot`, **`steerer_state`, `executor_state`, `executor_confidence`** |
| `v_human_identities` | the non-bot, non-excluded population |
| `v_unresolved_emails` | the human-attention queue |
| `v_coverage_by_run`, `v_llm_backlog` | coverage and its backlog |
| `v_unsafe_repos` | repos that must not be analysed |

Do not re-derive a week boundary in your own SQL. If bucketing is wrong, we fix
the view and re-aggregate — that is the whole point of keeping it there.

---

## 10b. Additive changes made after the parallel build (declared per §11)

The parallel build is over; these landed together, in one pass, and are all
additive:

* `schema.sql` — the attribution-pair columns on `v_commits_enriched` /
  `v_prs_enriched` (views are `DROP`+`CREATE`, so no migration exists or is
  needed); a `^dxm-machine-` bot pattern; catalog reconciliation `UPDATE`s that
  relabel the AI-share metrics as **floors**. **No table gained a column** —
  every new per-bucket fact is long-form in `agg_metric`, which is what that
  table is for, so an existing database needs no migration at all.
* `lib/dxm-common.sh` — `DXM_GH` (which gh binary) and `DXM_GH_CLEAR_TOKENS`
  (refuse ambient `GH_TOKEN` / `GITHUB_TOKEN`), plus `dxm_gh_run` /
  `dxm_gh_login`. Rationale in SKILL.md: a per-repo token shim enumerated a
  28-repo org as **zero repos, exit 0**.
* `sql/metrics.sql` — new `leverage.*`, `meta.unknown_steerer_share`,
  `adoption.executor_unknown_share`,
  `adoption.ai_commit_share_known_steerer` catalog rows and a new `leverage`
  pillar.
* `dxm-identity.sh` — glob keys on the `email` directive; a second bot-pattern
  pass after the override file (an override can *create* an identity, which the
  first pass never saw); the shipped override seed.

## 10c. The weekly-trends surface and the multi-line signal (declared per §11)

Also additive. Nothing existing changed meaning; two columns and two scripts
were added, and one function was added to the shared lib.

* **`schema.sql` — `commits.has_body` and `commits.body_chars`, both nullable.**
  This is the first time a *table* has gained a column, so read the migration
  note below; it is the part that is easy to get wrong. `v_commits_enriched`
  gained the same two columns (views are `DROP`+`CREATE`, so no migration), plus
  an index `idx_commits_has_body`.
* **`lib/dxm-common.sh` — `dxm_add_column` and `dxm_migrate_columns`, called
  from `dxm_init_db` BEFORE `schema.sql` is applied.** This ordering is
  load-bearing, not stylistic. `CREATE TABLE IF NOT EXISTS` is a no-op against
  an existing database, so a column added to `schema.sql` reaches a fresh DB and
  never reaches a live one — and then the first index or view in `schema.sql`
  that mentions it fails the whole apply with `no such column`, which takes
  every script in the skill down at once, not just the new one. SQLite has no
  `ADD COLUMN IF NOT EXISTS`, so the migration is feature-detected via
  `pragma_table_info`. **Adding a nullable column to `schema.sql` now means
  adding one line to `dxm_migrate_columns` in the same commit.**
* **`scripts/dxm-backfill-body.sh` (new)** — populates those two columns from the
  cached bare clones. Reads git only, never the network. `has_body = 1` when the
  message still has content after the subject line, every trailer-shaped line
  (`^\s*[A-Za-z-]+:\s`) and every blank line are removed. **The trailer strip is
  the measurement**: `Co-Authored-By` is the line that defines
  `executor_state='agent'`, so leaving it in makes any comparison against AI
  attribution circular. `NULL` is a real third state — a commit whose SHA is
  unreachable in the clone is *not measurable* and must be excluded from a ratio
  denominator rather than counted as single-line.
* **`scripts/dxm-trends.sh` + `templates/trends.html` (new)** — weekly trend
  charts, one self-contained HTML file per org, **with no JavaScript at all**.
  Every `<svg>` is generated server-side by awk and every tooltip is a native
  SVG `<title>`. This is a deliberate departure from `dashboard.html`, which
  builds its charts in the browser: a render-time exception there yields a blank
  page that the shell cannot detect, and nothing in the envelope, byte count or
  exit code disagrees.
* **`sql/metrics.sql`** — `adoption.multiline_commit_share` and
  `adoption.multiline_precision_vs_trailer` catalog rows, so the proxy statement
  for the multi-line signal has exactly one home.
* **New privacy obligation, binding like the rest of §8.** The multi-line ratio
  is a **proxy for AGENTIC AI use** — where the agent writes the commit message.
  It is **blind to assistive use** (Copilot autocomplete, pasted ChatGPT), and it
  cannot tell an agent apart from a human who writes thorough commit messages.
  It must be labelled as an agentic-usage proxy and **never as "AI usage"**, and
  it must be **published next to the declared-trailer base rate, every time**:
  precision of the rule tracks the base rate, so ~91% precision at a 74% base
  rate says nothing about the same rule at a 2% base rate.
* **`dxm-trends.sh` verifies its own privacy claim before writing.** In the
  default (no-flag) mode it greps the rendered bytes for every login, every
  display name and anything email-shaped in the database, and exits 4 rather
  than write a file that contains one. A hit that is a substring of an in-scope
  **repository name** is reported and allowed — `acme/jdoe-website` is a
  repository identifier, not a per-person metric — and the count travels in the
  envelope as `pii_repo_name_collisions`.

---

## 11. Changing the frozen files

`schema.sql`, `CONTRACT.md` and `lib/dxm-common.sh` are frozen for the duration
of the parallel build. If you need a change:

* **Additive and unambiguous** (a new index, a new nullable column your table
  needs): make it, and say so loudly at the top of your PR body.
* **Anything else** (renaming a column, changing a view's semantics, changing the
  envelope): do not do it. Raise it on the tracking issue and keep building
  against the current contract.

Never edit another workstream's file to make your own work. Integration resolves
conflicts once, at the end, not five times in parallel.

---

## 12. Verified gotchas — do not rediscover these

* **`git shortlog` with no rev argument reads stdin** in non-tty contexts and
  silently returns nothing in an agent shell. **Always pass `HEAD` or `--all`.**
* **Shallow clones silently truncate history** and produce confident, wrong time
  series. Assert `git rev-parse --is-shallow-repository` is `false`, record it in
  `repos.is_shallow`, and **refuse to analyse** (exit 2) if shallow.
* **macOS is BSD.** `date -d` does not exist (GNU only) — use
  `date -u -j -f` or, better, let SQLite do date maths. `stat -f %m`, not `-c`.
  `sed -i ''`, not `sed -i`.
* **`gh` may be shimmed** in this environment and cannot always resolve the repo
  from cwd. **Always pass `-R owner/repo`** (or export `GH_REPO`) on every call.
* **GitHub API: 5000 req/hr authenticated.** Prefer GraphQL for bulk PR pulls
  (~100 nodes/query). The API is not the bottleneck — handle 403/429 by exiting 3
  and leaving the watermark alone, but do not over-engineer a backoff ladder.
* **SQLite `last_insert_rowid()` does not survive across connections.** An INSERT
  and its rowid read must be in the same `sqlite3` invocation. (This already bit
  `dxm_run_start` once; it is fixed there.)
* SQLite parses `YYYY-MM-DDTHH:MM:SSZ` correctly. Store UTC with the `Z`. Verified.
* Week bucket expression: `date(ts, '-6 days', 'weekday 1')` → the Monday of the
  week containing `ts`. Verified against Monday, midweek and Sunday inputs.

---

## 13. Definitions everyone must share

Divergence here silently produces two different dashboards.

* **Active contributor** — a distinct non-bot, non-excluded `identities.login`
  with ≥1 **merged** PR in the period.
* **Merged PR** — `state='MERGED'` and `merged_at IS NOT NULL`. Closed-unmerged
  PRs are never throughput.
* **Cycle time** — `merged_at − first_commit_at`, in hours. Undefined (NULL) when
  either is missing. Never substitute `created_at` for `first_commit_at` without
  saying so in `agg_metric.note`.
* **Attribution is a PAIR, on every commit and every PR.** Two axes, neither
  inferred from the other:
  * **steerer** — the human who directed the work. `steerer_state` is
    `known` (resolves to a human identity), `machine` (resolves to a bot/agent
    account) or `unknown` (resolved to nobody).
  * **executor** — the agent that produced the diff. `executor_state` is
    `agent` (a `Co-Authored-By` trailer names a known AI agent, so
    `executor_confidence='declared-trailer'`) or `unknown`
    (`executor_confidence='no-evidence'`).

  **There is no `executor_state='human'` and there must never be one.** Nothing
  in git can produce it. A missing trailer is not evidence of human execution —
  trailer discipline arrived late everywhere this has been run, so untrailered
  history is genuinely unknown.
* **AI-assisted commit** — has ≥1 `ai_trailers` row with `is_ai=1`; equivalently
  `executor_state='agent'`.
* **AI-assisted PR** — ≥1 of its commits is AI-assisted.
* **AI share is a share of EXECUTIONS and is a FLOOR**, and must be labelled as
  a floor wherever it appears — catalog label, JSON and HTML.
* **Merge commits** (`is_merge=1`) are excluded from commit counts and from
  authorship attribution.
* **Unattributed commits** (`author_identity_id IS NULL`) are **unknown
  steerer**. They are **NOT counted as human** — that was a real defect, worth
  25% of one org's commits, and it manufactured an AI-adoption ramp out of
  identity resolution improving. They remain in execution denominators (they
  happened), are excluded from every per-person view and from the leverage
  numerator, and are **reported as their own named population** whose size is
  the run's quality signal.
* **Steerer** (for leverage) — a distinct identity with `steerer_state='known'`
  and ≥1 non-merge commit in the period. **Leverage** = output with a known
  steerer ÷ distinct known steerers. It is a per-person rate and is subject to
  the same cohort floor as any other per-person rate.
* **Partial buckets** — the current, incomplete day/week/month must be marked
  `agg_metric.note='partial period'` and rendered visibly differently. A partial
  week that looks like a decline is the single most common way this class of
  dashboard lies.
