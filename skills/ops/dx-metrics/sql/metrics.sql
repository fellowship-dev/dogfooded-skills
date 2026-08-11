-- dx-metrics — metric views and metric_catalog additions.            [W4]
--
-- Applied by scripts/dxm-aggregate.sh on EVERY run, before aggregating.
-- Everything here is idempotent: DROP VIEW / CREATE VIEW and INSERT OR IGNORE.
-- schema.sql is never edited; new metrics arrive here (CONTRACT.md §9, §11).
--
-- WHY THESE VIEWS EXIST
-- ---------------------
-- schema.sql defines bucketing ONCE, but it exposes it as three *columns*
-- (day_start / week_start / month_start). Aggregation needs to pick one at
-- runtime, and SQL cannot parameterise a column name. Rather than have the
-- shell splice a column name into every query -- which is how a bucketing bug
-- gets copy-pasted into fifteen places -- these views pivot the three columns
-- into (period_kind, period_start) rows with UNION ALL. Every downstream query
-- then says WHERE period_kind = 'week' and nothing re-derives a boundary.
--
-- They also apply, in one place, the two population rules from CONTRACT.md §13:
--   * bots and manually-excluded identities are removed;
--   * shallow repos are removed (their history is truncated, so any time series
--     computed from them is confidently wrong).
--
-- The ONE exception to "bucketing is defined once" is v_prs_opened_bucketed:
-- v_prs_enriched buckets PRs by merged_at only, and agg_org_period.prs_opened /
-- agg_author_period.prs_opened need a created_at axis. That view therefore
-- repeats the three bucket expressions verbatim. It is not left on trust:
-- v_bucket_expression_check re-derives the merge-date buckets with the SAME
-- expressions and compares them against v_prs_enriched row by row, and
-- dxm-aggregate.sh refuses to run (exit 2) if a single row disagrees. If
-- schema.sql ever changes its bucketing, that check fails loudly here instead
-- of silently producing two different weeks.

-- ===========================================================================
-- VIEWS — period-pivoted read surface
-- ===========================================================================

-- Commits, one row per (commit, period_kind). Merge commits are KEPT here and
-- filtered by the caller, so that "how many merge commits did we exclude" stays
-- an answerable question instead of a silent subtraction.
-- THE POPULATION RULE, stated in the terms of the attribution pair:
--   keep an execution when its steerer is a KNOWN human, or when its steerer is
--   UNKNOWN. Drop it when the steerer is a MACHINE (a bot or agent account) —
--   that is the mandatory bot exclusion of CONTRACT.md decision 10.
--
-- An unknown steerer is deliberately KEPT and deliberately NOT relabelled as a
-- human. It is a real execution that happened; dropping it would understate the
-- work, and calling it human is the bug this whole model exists to fix
-- (measured: 25% of one org's commits were counted as human on no evidence,
-- and manufactured an AI-adoption ramp out of identity resolution improving).
-- Downstream, steerer_state travels with every row so
-- each metric declares which population it is over.
DROP VIEW IF EXISTS v_commits_bucketed;
CREATE VIEW v_commits_bucketed AS
  SELECT period_kind, period_start,
         commit_id, repo_id, repo_full_name, owner, sha,
         author_identity_id, author_login, authored_at,
         is_merge, pr_number, insertions, deletions, files_changed,
         is_ai_assisted, is_unattributed,
         steerer_state, executor_state, executor_confidence, executor_agent_key
    FROM (
      SELECT 'day'   AS period_kind, c.day_start   AS period_start, c.* FROM v_commits_enriched c
      UNION ALL
      SELECT 'week',                 c.week_start,                  c.* FROM v_commits_enriched c
      UNION ALL
      SELECT 'month',                c.month_start,                 c.* FROM v_commits_enriched c
    )
   WHERE repo_id IN (SELECT repo_id FROM repos WHERE is_shallow = 0)
     AND steerer_state IN ('known', 'unknown');

-- Merged PRs, one row per (pr, period_kind), bucketed on merged_at.
-- "Merged" is state='MERGED' AND merged_at IS NOT NULL (CONTRACT.md §13):
-- closed-unmerged PRs are never throughput.
DROP VIEW IF EXISTS v_prs_bucketed;
CREATE VIEW v_prs_bucketed AS
  SELECT period_kind, period_start,
         pr_id, repo_id, repo_full_name, owner, number,
         author_identity_id, author_login,
         created_at, first_commit_at, merged_at, cycle_time_hours,
         additions, deletions, changed_files, commit_count,
         class, is_revert, class_method, is_ai_assisted,
         steerer_state, executor_state, executor_confidence
    FROM (
      SELECT 'day'   AS period_kind, p.merged_day_start   AS period_start, p.* FROM v_prs_enriched p
      UNION ALL
      SELECT 'week',                 p.merged_week_start,                  p.* FROM v_prs_enriched p
      UNION ALL
      SELECT 'month',                p.merged_month_start,                 p.* FROM v_prs_enriched p
    )
   WHERE state = 'MERGED' AND merged_at IS NOT NULL
     AND repo_id IN (SELECT repo_id FROM repos WHERE is_shallow = 0)
     AND steerer_state IN ('known', 'unknown');

-- PRs bucketed on created_at. See the header: this is the single place outside
-- schema.sql that writes a bucket expression, and v_bucket_expression_check
-- guards it.
DROP VIEW IF EXISTS v_prs_opened_bucketed;
CREATE VIEW v_prs_opened_bucketed AS
  SELECT period_kind, period_start,
         pr_id, repo_id, repo_full_name, owner, number,
         author_identity_id, created_at, merged_at, state, steerer_state
    FROM (
      SELECT 'day'   AS period_kind, strftime('%Y-%m-%d', p.created_at)         AS period_start, p.* FROM v_prs_enriched p
      UNION ALL
      SELECT 'week',                 date(p.created_at, '-6 days', 'weekday 1'),                 p.* FROM v_prs_enriched p
      UNION ALL
      SELECT 'month',                strftime('%Y-%m-01', p.created_at),                         p.* FROM v_prs_enriched p
    )
   WHERE created_at IS NOT NULL
     AND repo_id IN (SELECT repo_id FROM repos WHERE is_shallow = 0)
     AND steerer_state IN ('known', 'unknown');

-- Bots and excluded identities that the views above filtered out. Kept as a
-- view so "we removed N bot PRs" is reportable rather than invisible.
DROP VIEW IF EXISTS v_excluded_actor_counts;
CREATE VIEW v_excluded_actor_counts AS
  SELECT
    (SELECT COUNT(*) FROM commits c
       JOIN identities i ON i.identity_id = c.author_identity_id
      WHERE (i.is_bot = 1 OR i.is_excluded = 1) AND c.is_merge = 0)            AS bot_commits,
    (SELECT COUNT(*) FROM pull_requests p
       JOIN identities i ON i.identity_id = p.author_identity_id
      WHERE (i.is_bot = 1 OR i.is_excluded = 1)
        AND p.state = 'MERGED' AND p.merged_at IS NOT NULL)                    AS bot_prs_merged;

-- ===========================================================================
-- The bucketing assertion
-- ===========================================================================
-- Re-derives day/week/month from merged_at and authored_at using the same
-- expressions v_prs_opened_bucketed uses, and compares against the buckets
-- schema.sql already computed. mismatches MUST be 0. dxm-aggregate.sh exits 2
-- otherwise. This is what makes the one duplicated expression safe.
DROP VIEW IF EXISTS v_bucket_expression_check;
CREATE VIEW v_bucket_expression_check AS
  SELECT COALESCE(SUM(bad), 0) AS mismatches, COALESCE(SUM(1), 0) AS rows_checked
    FROM (
      SELECT CASE WHEN date(merged_at, '-6 days', 'weekday 1') <> merged_week_start
                    OR strftime('%Y-%m-%d', merged_at)          <> merged_day_start
                    OR strftime('%Y-%m-01', merged_at)          <> merged_month_start
                  THEN 1 ELSE 0 END AS bad
        FROM v_prs_enriched WHERE merged_at IS NOT NULL
      UNION ALL
      SELECT CASE WHEN date(authored_at, '-6 days', 'weekday 1') <> week_start
                    OR strftime('%Y-%m-%d', authored_at)          <> day_start
                    OR strftime('%Y-%m-01', authored_at)          <> month_start
                  THEN 1 ELSE 0 END
        FROM v_commits_enriched
    );

-- A data-independent property check, for the case where the DB is still empty
-- and the comparison above is vacuous. For 21 consecutive days it asserts that
-- date(d,'-6 days','weekday 1') is (a) a Monday, (b) not in the future relative
-- to d, and (c) within the preceding 7 days. Those three properties uniquely
-- define "the Monday of this week" without hardcoding a calendar.
DROP VIEW IF EXISTS v_bucket_property_check;
CREATE VIEW v_bucket_property_check AS
  WITH RECURSIVE seq(n) AS (SELECT 0 UNION ALL SELECT n + 1 FROM seq WHERE n < 20),
  d AS (SELECT date('2026-01-01', '+' || n || ' days') AS ts FROM seq)
  SELECT COALESCE(SUM(
           CASE WHEN strftime('%w', date(ts, '-6 days', 'weekday 1')) <> '1' THEN 1
                WHEN date(ts, '-6 days', 'weekday 1') > ts             THEN 1
                WHEN date(ts, '-6 days', 'weekday 1') <= date(ts, '-7 days') THEN 1
                ELSE 0 END), 0) AS violations,
         COUNT(*) AS days_checked
    FROM d;

-- ===========================================================================
-- METRIC CATALOG ADDITIONS
-- ===========================================================================
-- CONTRACT.md §9: a number with no catalog row cannot be stored -- agg_metric
-- has a foreign key into metric_catalog, so SQLite refuses the INSERT. Every
-- metric dxm-aggregate.sh emits therefore has a row here or in schema.sql.
-- is_proxy=1 rows MUST carry proxy_statement and cannot_see; those two strings
-- are rendered inline next to the number, every single time.

INSERT OR IGNORE INTO metric_catalog
  (metric_key, pillar, label, unit, is_proxy, computable, privacy_class, proxy_statement, cannot_see, higher_is) VALUES

-- ---- Speed -------------------------------------------------------------
-- speed.pr_throughput_per_contributor_week (schema.sql) is defined per WEEK and
-- is only emitted for --period week. Day and month runs get this raw count
-- instead, so that a non-weekly run is not silently missing its Speed number.
('speed.prs_merged', 'speed',
 'Merged pull requests', 'count', 1, 1, 'aggregate_only',
 'Proxy. Counts merged pull requests, not delivered value. One team''s PR is another team''s commit.',
 'PR size, work that never becomes a PR, commits pushed straight to the default branch, and work done in another repo.',
 'neither'),

('speed.prs_opened', 'speed',
 'Pull requests opened', 'count', 1, 1, 'aggregate_only',
 'Proxy for work started, bucketed on the date the PR was opened -- which is when it became visible, not when it began.',
 'Work in progress that has not been pushed, and branches that never became a PR.',
 'neither'),

-- ---- Quality / Impact denominators -------------------------------------
('meta.unclassified_pr_share', 'meta',
 'Share of merged PRs the classifier could not label', 'percent', 0, 1, 'aggregate_only',
 NULL,
 'Nothing -- this IS the blind spot. Defect ratio and innovation ratio are computed over the classified remainder only; this number is the size of the hole in their denominator.',
 'worse'),

('meta.unattributed_commits', 'meta',
 'Commits whose author could not be resolved to a GitHub login', 'count', 0, 1, 'aggregate_only',
 NULL,
 'Who wrote them. They are excluded from every per-person view and counted here instead, so the gap is visible rather than silently dropped.',
 'worse'),

-- The run's own quality signal, as a percentage rather than a raw count so it
-- can be read against the ~10% bar in SKILL.md without arithmetic.
('meta.unknown_steerer_share', 'meta',
 'Share of executions with no identifiable steerer', 'percent', 0, 1, 'aggregate_only',
 NULL,
 'Who steered them. These commits are NOT counted as human-steered -- that error is what manufactured a fake AI-adoption ramp in the first draft of this tool. They stay in execution denominators because they really happened. THIS NUMBER IS THE QUALITY GATE FOR THE PAGE: above roughly 10%, no attribution-derived trend here is presentable, and only the most recent complete period''s AI floor should be quoted.',
 'worse'),

-- ---- Leverage ----------------------------------------------------------
-- The headline question on an agent-native team is not "what percentage of the
-- work was AI" -- that number is a floor with an untrustworthy shape. It is
-- "how much output does one human steer", which is what a seat actually buys.
('leverage.commits_per_steerer', 'leverage',
 'Commits per steerer', 'count', 1, 1, 'aggregate_only',
 'Proxy for leverage: executions with a KNOWN human steerer, divided by the number of distinct known steerers in the period. It counts commits, not value, and a team that commits in small increments will look more leveraged than one that does not.',
 'Executions whose steerer could not be identified (they are excluded from the numerator, so this UNDERSTATES leverage whenever that gap is large), work steered but not committed, review and pairing, and whether any of it shipped. Withheld entirely below the minimum cohort, because output per steerer over one or two people is that person''s output.',
 'neither'),

('leverage.merged_prs_per_steerer', 'leverage',
 'Merged pull requests per steerer', 'count', 1, 1, 'aggregate_only',
 'Proxy for leverage at the delivery unit rather than the commit: merged PRs with a known human steerer, divided by distinct known steerers in the period. A PR is a unit of review, not a unit of work.',
 'PR size -- a 4000-line PR and a typo fix count the same. Bot- and agent-authored PRs are excluded entirely, so on a team where agents open their own PRs this is the human-steered share of delivery, not the delivered total. Withheld below the minimum cohort.',
 'neither'),

('leverage.steerers', 'leverage',
 'Distinct steerers', 'count', 1, 1, 'aggregate_only',
 'Proxy for how many humans were directing work in the period: distinct known steerers with at least one commit. It is the denominator of the two leverage numbers above and is shown so the reader can see how thin it is.',
 'People who steered without committing, and anyone whose commits landed under an address that could not be resolved.',
 'neither'),

-- ---- Executor axis -----------------------------------------------------
('adoption.executor_unknown_share', 'adoption',
 'Share of commits with an UNKNOWN executor', 'percent', 0, 1, 'aggregate_only',
 NULL,
 'Nothing -- this IS the blind spot, stated as its own number rather than left as the implied remainder of the AI share. These commits carry no Co-Authored-By trailer naming an agent. That is NOT evidence a human wrote them: trailer discipline arrived late everywhere this tool has been pointed, so an unknown executor is genuinely unknown. Read it as the width of the uncertainty band on every AI-share number on this page.',
 'neither'),

('adoption.ai_commit_share_known_steerer', 'adoption',
 'AI-executed share, known steerers only — FLOOR', 'percent', 1, 1, 'aggregate_only',
 'Proxy, and a FLOOR. The same numerator and denominator as the headline AI share, restricted to executions whose human steerer is identified. Published NEXT TO the headline on purpose: where the two series diverge or move apart over time, the headline trend is tracking identity-resolution quality rather than behaviour, and the difference between them is the size of that artifact.',
 'Everything the headline AI share cannot see, plus the behaviour of everyone whose commits are still unattributed. When the unknown-steerer share is large this series is computed over a biased subset -- the people the tool happens to be able to name.',
 'neither'),

-- ---- Risk --------------------------------------------------------------
-- risk.ownership_concentration (schema.sql) is defined at FILE-PATH level and
-- this build does not ingest file paths, so it is emitted as unavailable with a
-- reason. This is the honest repo-level substitute, under its own honest label.
('risk.top_contributor_commit_share', 'risk',
 'Share of commits by the single largest contributor', 'percent', 1, 1, 'individual_ok',
 'Proxy for concentration risk, measured over COMMITS in the period, not over files or subsystems. A repo-wide number cannot tell you that one person owns the payments module.',
 'Which parts of the codebase are concentrated, knowledge held by reviewers and pairs, and whether the top contributor is still on the team.',
 'worse'),

-- ---- AI adoption -------------------------------------------------------
('adoption.contributors_with_ai_share', 'adoption',
 'Share of active contributors who have ever emitted an AI trailer', 'percent', 1, 1, 'aggregate_only',
 'Proxy, and a floor. A contributor counts as an adopter from the date of their first AI Co-Authored-By trailer onward, forever -- it measures having started, not still using.',
 'Anyone using an AI tool that writes no trailer, and anyone who adopted and then stopped.',
 'neither'),

('adoption.cycle_time_delta_pct_after_adoption', 'adoption',
 'Change in cycle time after a contributor''s first AI trailer', 'percent', 1, 1, 'aggregate_only',
 'Proxy, and CORRELATION ONLY -- never causation. For each contributor with enough merged PRs on both sides of their first AI trailer, the median cycle time in the window after is compared with the window before; the reported number is the median of those per-contributor changes.',
 'Everything else that changed at the same time: team, project, seniority, release cadence, on-call, holidays. There is no control group. A negative number is a coincidence until an experiment says otherwise.',
 'worse'),

('adoption.commit_volume_delta_pct_after_adoption', 'adoption',
 'Change in commit volume after a contributor''s first AI trailer', 'percent', 1, 1, 'aggregate_only',
 'Proxy, and CORRELATION ONLY. Compares commit counts in a symmetric window either side of each contributor''s first AI trailer, then reports the median per-contributor change. Commit count is a measure of activity, not of output.',
 'Whether the extra commits shipped anything, commit-splitting habits that change with tooling, and every confounder listed for the cycle-time version of this metric.',
 'neither'),

('adoption.adopters', 'adoption',
 'Contributors with at least one AI-co-authored commit', 'count', 1, 1, 'aggregate_only',
 'Proxy, and a floor. Counts distinct contributors who have emitted at least one AI Co-Authored-By trailer in this scope, ever.',
 'AI use that leaves no trailer, which is most of it in most teams.',
 'neither'),

-- ---- The multi-line signal ---------------------------------------------
-- Read commits.has_body (scripts/dxm-backfill-body.sh) rather than any
-- message-shape test written at query time: the trailer strip is the whole
-- measurement, and doing it in a renderer is how it gets forgotten.
--
-- These two rows exist so the proxy statement below has EXACTLY ONE home. The
-- trend renderer reads them; anything that later aggregates the ratio into
-- agg_metric can store it without inventing a second wording.
('adoption.multiline_commit_share', 'adoption',
 'Multi-line commit ratio -- agentic-usage proxy', 'percent', 1, 1, 'aggregate_only',
 'PROXY FOR AGENTIC AI USE, NOT FOR "AI USAGE". The share of non-merge commits whose message still has content once the subject line, every trailer-shaped line (^\s*[A-Za-z-]+:\s) and every blank line are removed. Stripping trailers is mandatory and not cosmetic: Co-Authored-By is the line that DEFINES the AI attribution this is compared against, so leaving it in makes the correlation circular. MUST BE PUBLISHED NEXT TO THE DECLARED-TRAILER BASE RATE, always: this rule was measured at ~91% precision / ~83% recall against a 74% base rate on one repo, and precision of any such rule collapses towards the base rate as the base rate falls -- at a 2% base rate the same rule is worth single-digit percent. Never quote the ratio alone.',
 'ASSISTIVE AI use -- Copilot autocomplete, pasted ChatGPT output -- where the human writes the commit message; it is invisible here. Also blind to a team whose humans simply write thorough commit messages, which is indistinguishable from an agent doing it. Commits whose SHA is unreachable in the cached clone are NULL and are excluded from the denominator rather than counted as single-line.',
 'neither'),

('adoption.multiline_precision_vs_trailer', 'adoption',
 'Agreement between the multi-line proxy and the declared AI trailer', 'percent', 1, 1, 'aggregate_only',
 'Not a delivery metric -- it is the proxy auditing itself. Precision = share of multi-line commits that also carry a declared AI trailer; recall = share of trailered commits that are multi-line. Published so a reader can see how well the stand-in tracks the thing it stands in for, on their own data, instead of trusting a number measured on someone else''s repo.',
 'Nothing about the commits that carry no trailer, which is exactly the population the proxy exists to reach. High precision at a high base rate says almost nothing about behaviour at a low one.',
 'higher');

-- Per-agent share of AI-co-authored commits. Generated from the ai_agents table
-- rather than hardcoded, so adding a coding agent stays an INSERT into
-- ai_agents (schema.sql's design) and its catalog row appears on the next run.
INSERT OR IGNORE INTO metric_catalog
  (metric_key, pillar, label, unit, is_proxy, computable, privacy_class, proxy_statement, cannot_see, higher_is)
SELECT 'adoption.agent_share.' || agent_key,
       'adoption',
       'Share of AI-co-authored commits crediting ' || label,
       'percent', 1, 1, 'aggregate_only',
       'Proxy. Reflects which agents are configured to write a Co-Authored-By trailer, not which agents people actually use most.',
       'Any agent that writes no trailer is absent from this chart entirely, and a squashed merge that dropped the trailer takes its agent with it.',
       'neither'
  FROM ai_agents;
