-- dx-metrics — SQLite schema
--
-- Design rules baked into this file (see CONTRACT.md for the full contract):
--
--   1. RAW is sacred, DERIVED is disposable.
--      Everything under "RAW" is a faithful record of what git / the GitHub API
--      said. Everything under "DERIVED" can be dropped and rebuilt from RAW.
--      A bucketing bug, a classifier bug, or a metric-formula bug must be a
--      re-run of the aggregate step -- NEVER a re-ingest.
--
--   2. Bucketing lives in VIEWS, not in stored columns.
--      Raw rows store UTC timestamps only. Day/week/month buckets are computed
--      by v_commits_enriched / v_prs_enriched. Fixing a bucketing bug is
--      DROP VIEW + CREATE VIEW + re-aggregate. No migration, no re-fetch.
--
--   3. Every number that reaches a human has a metric_catalog row.
--      The catalog carries the proxy statement and the "what this cannot see"
--      text. A metric with no catalog row MUST NOT be rendered. This is the
--      mechanism that enforces the project's hard rule on proxy declaration.
--
--   4. Per-person tables exist, but per-person OUTPUT is opt-in and narrow.
--      agg_author_period is computed so that risk (ownership / bus factor) and
--      AI-adoption timing can be answered. It is NOT a throughput leaderboard
--      and must never be rendered as one. See metric_catalog.privacy_class.
--
-- Timestamps: TEXT, ISO-8601, UTC, 'YYYY-MM-DDTHH:MM:SSZ'. Verified to parse
-- correctly under SQLite's date()/strftime(). Never store local time.
-- Booleans: INTEGER 0/1.

PRAGMA journal_mode = WAL;
PRAGMA foreign_keys = ON;

-- ===========================================================================
-- META
-- ===========================================================================

-- WHY: lets a future version detect an old DB and refuse / migrate instead of
-- silently producing numbers computed against a schema it no longer matches.
CREATE TABLE IF NOT EXISTS schema_meta (
  key        TEXT PRIMARY KEY,
  value      TEXT NOT NULL,
  updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now'))
);
INSERT OR IGNORE INTO schema_meta(key, value) VALUES
  ('schema_version', '1'),
  ('bucket_timezone', 'UTC'),
  ('week_start', 'monday');

-- WHY: skill-level settings that must survive between runs so that two runs a
-- week apart produce comparable numbers (e.g. the window start everyone agreed
-- on). Config that changes the meaning of a number belongs here, not in argv.
CREATE TABLE IF NOT EXISTS config (
  key        TEXT PRIMARY KEY,
  value      TEXT NOT NULL,
  set_by     TEXT,
  updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now'))
);

-- ===========================================================================
-- RAW — repos
-- ===========================================================================

-- WHY: the unit of ingestion. Also the place where the anti-footgun assertions
-- live: a shallow clone silently truncates history and produces a confident,
-- wrong time series, so we record the shallow check as data and refuse to
-- aggregate a repo whose last check said shallow.
CREATE TABLE IF NOT EXISTS repos (
  repo_id            INTEGER PRIMARY KEY,
  owner              TEXT NOT NULL,
  name               TEXT NOT NULL,
  full_name          TEXT NOT NULL UNIQUE,          -- 'owner/name', the key humans use
  default_branch     TEXT,
  clone_path         TEXT,                          -- absolute path to the local working clone / mirror
  is_shallow         INTEGER NOT NULL DEFAULT 1,    -- 1 until proven otherwise; refuse to analyse while 1
  shallow_checked_at TEXT,
  first_commit_at    TEXT,                          -- earliest authored_at seen; bounds the honest reporting window
  last_commit_at     TEXT,
  added_at           TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
  UNIQUE(owner, name)
);

-- ===========================================================================
-- RAW — identity
-- ===========================================================================

-- WHY: the analysis groups by GitHub login, because the GitHub API resolves a
-- commit email to a login server-side (including corporate emails). One row per
-- distinct login. Bot flags live here so every downstream query can exclude
-- bots by joining one place instead of re-implementing a regex.
CREATE TABLE IF NOT EXISTS identities (
  identity_id   INTEGER PRIMARY KEY,
  login         TEXT NOT NULL UNIQUE,               -- GitHub login. The canonical person key.
  display_name  TEXT,
  account_type  TEXT,                               -- 'User' | 'Bot' | 'Organization' | NULL
  is_bot        INTEGER NOT NULL DEFAULT 0,
  bot_reason    TEXT,                               -- which rule flagged it; evidence, not a guess
  is_excluded   INTEGER NOT NULL DEFAULT 0,         -- manual exclusion (e.g. a service account not matching any pattern)
  exclude_reason TEXT,
  first_seen_at TEXT,
  last_seen_at  TEXT,
  ingested_at   TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now'))
);

-- WHY: the email -> login mapping learned from the GitHub commits API
-- (.author.login). identity_id IS NULL means GitHub could not resolve it; those
-- rows -- and ONLY those rows -- are the human-attention queue. There is
-- deliberately no email-mining / regex-guessing path: an unresolved email stays
-- unresolved and visible rather than being silently attached to the wrong person.
CREATE TABLE IF NOT EXISTS identity_emails (
  email             TEXT PRIMARY KEY,               -- lowercased commit author email
  identity_id       INTEGER REFERENCES identities(identity_id),
  resolution_source TEXT NOT NULL,                  -- 'github_api' | 'mailmap' | 'manual' | 'unresolved'
  sample_repo_id    INTEGER REFERENCES repos(repo_id),
  sample_sha        TEXT,                           -- evidence: the commit the resolution came from
  commit_count      INTEGER NOT NULL DEFAULT 0,     -- how much is at stake if this one is wrong
  resolved_at       TEXT,
  updated_at        TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now'))
);
CREATE INDEX IF NOT EXISTS idx_identity_emails_identity ON identity_emails(identity_id);

-- WHY: bot exclusion is mandatory, and the rule set must be inspectable and
-- editable without a code change. Seeded with the known offenders; matching is
-- done by the ingest step and the result is written to identities.is_bot so the
-- regex runs once, not in every metric query.
CREATE TABLE IF NOT EXISTS bot_patterns (
  pattern_id INTEGER PRIMARY KEY,
  pattern    TEXT NOT NULL UNIQUE,                  -- POSIX ERE, matched case-insensitively against login
  note       TEXT,
  enabled    INTEGER NOT NULL DEFAULT 1
);
INSERT OR IGNORE INTO bot_patterns(pattern, note) VALUES
  ('\[bot\]$',                  'GitHub App accounts always end in [bot]'),
  ('^dependabot',               'Dependabot'),
  ('^renovate',                 'Renovate'),
  ('^snyk-',                    'Snyk'),
  ('^greenkeeper',              'Greenkeeper'),
  ('^github-actions',           'GitHub Actions'),
  ('^ci-agent-app$',            'EXAMPLE: an in-house coding-agent GitHub App. Rename for yours.'),
  ('^claude(-|$)',              'Claude bot accounts'),
  ('^copilot(-|$)',             'GitHub Copilot agent accounts'),
  ('^web-flow$',                'GitHub web UI merge-commit author'),
  ('^imgbot',                   'ImgBot'),
  ('^allcontributors',          'All Contributors bot'),
  ('^codecov',                  'Codecov'),
  ('^semantic-release-bot$',    'semantic-release'),
  -- Coding agents that push under a plain User account, so `[bot]` and
  -- account_type=Bot both miss them. Left out, they are counted as human
  -- contributors and inflate active_contributors and bus_factor.
  -- Synthetic machine identities minted by an `email` line in the override
  -- file. A devbox address such as worker@ci-agent.local has no GitHub account, so
  -- it can only ever be an UNKNOWN steerer; mapping it to a dxm-machine-* login
  -- states "this is a machine, and no human steerer is identifiable" instead of
  -- leaving it in the unknown bucket where it looks like a resolution failure.
  ('^dxm-machine-',             'Synthetic machine identity from identity-overrides.tsv'),
  ('^cursoragent$',             'Cursor Background Agent'),
  ('^devin-ai-integration',     'Devin'),
  ('^sweep-ai',                 'Sweep AI'),
  ('^codegen-sh',               'Codegen'),
  ('^ona-agent',                'Ona / Gitpod agent');

-- ===========================================================================
-- RAW — commits
-- ===========================================================================

-- WHY: the base fact table. One row per commit per repo. Everything about
-- speed, adoption and ownership is derived from here. Deliberately stores only
-- the subject line (not the body) -- bodies are large, and the only body
-- content we care about is trailers, which get their own table.
CREATE TABLE IF NOT EXISTS commits (
  commit_id      INTEGER PRIMARY KEY,
  repo_id        INTEGER NOT NULL REFERENCES repos(repo_id),
  sha            TEXT NOT NULL,
  author_email   TEXT,                              -- lowercased; joins to identity_emails
  author_name    TEXT,
  author_identity_id INTEGER REFERENCES identities(identity_id),  -- denormalised for query speed; rebuildable
  authored_at    TEXT NOT NULL,                     -- UTC ISO-8601. THE time axis. Not committed_at.
  committed_at   TEXT,
  is_merge       INTEGER NOT NULL DEFAULT 0,        -- merge commits are excluded from most counts
  subject        TEXT,
  files_changed  INTEGER,
  insertions     INTEGER,
  deletions      INTEGER,
  pr_number      INTEGER,                           -- filled by the GitHub step when the commit belongs to a PR
  on_default_branch INTEGER NOT NULL DEFAULT 1,     -- ingested from the default branch unless a module says otherwise
  -- THE MULTI-LINE SIGNAL. Persisted, never recomputed in a renderer.
  --   has_body   = 1 when, after dropping the subject line, dropping every
  --                TRAILER-SHAPED line (^\s*[A-Za-z-]+:\s) and dropping blanks,
  --                anything at all remains. 0 when nothing remains.
  --                NULL = not yet backfilled (scripts/dxm-backfill-body.sh).
  --   body_chars = characters retained by that same filter.
  -- Stripping trailers is MANDATORY and is the whole reason this is a stored
  -- column rather than a `subject <> message` test: without it the
  -- `Co-Authored-By:` line that DEFINES executor_state='agent' leaks into the
  -- feature, and "multi-line predicts AI-trailered" becomes circular.
  -- NULL is a third state on purpose: a commit whose SHA is no longer reachable
  -- in the cached clone (history rewrite) cannot be measured, and must be
  -- dropped from a ratio denominator rather than silently counted as 0.
  has_body       INTEGER,
  body_chars     INTEGER,
  ingested_at    TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
  UNIQUE(repo_id, sha)
);
CREATE INDEX IF NOT EXISTS idx_commits_repo_time     ON commits(repo_id, authored_at);
CREATE INDEX IF NOT EXISTS idx_commits_identity_time ON commits(author_identity_id, authored_at);
CREATE INDEX IF NOT EXISTS idx_commits_pr            ON commits(repo_id, pr_number);
CREATE INDEX IF NOT EXISTS idx_commits_email         ON commits(author_email);
CREATE INDEX IF NOT EXISTS idx_commits_has_body      ON commits(repo_id, has_body);

-- ===========================================================================
-- RAW — AI attribution
-- ===========================================================================

-- WHY: AI attribution is Co-Authored-By trailers and NOTHING ELSE. No text
-- guessing on PR bodies (a PR that merely discusses ChatGPT is not an AI PR).
-- One row per trailer per commit, kept raw so a change to the agent-normalising
-- table is a re-map, not a re-parse of every commit.
CREATE TABLE IF NOT EXISTS ai_trailers (
  trailer_id  INTEGER PRIMARY KEY,
  repo_id     INTEGER NOT NULL REFERENCES repos(repo_id),
  sha         TEXT NOT NULL,
  raw_name    TEXT,                                 -- verbatim trailer name
  raw_email   TEXT,                                 -- verbatim trailer email, lowercased
  agent_key   TEXT,                                 -- normalised via ai_agents; NULL until mapped
  is_ai       INTEGER NOT NULL DEFAULT 0,           -- 0 = a human co-author, still recorded
  ingested_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
  UNIQUE(repo_id, sha, raw_email)
);
CREATE INDEX IF NOT EXISTS idx_ai_trailers_sha   ON ai_trailers(repo_id, sha);
CREATE INDEX IF NOT EXISTS idx_ai_trailers_agent ON ai_trailers(agent_key);

-- WHY: the trailer text -> agent mapping, as data. New coding agents appear
-- monthly; adding one must be an INSERT, not a code change and a re-ingest.
-- `pattern` is a POSIX ERE matched case-insensitively against 'name <email>'.
CREATE TABLE IF NOT EXISTS ai_agents (
  agent_id   INTEGER PRIMARY KEY,
  agent_key  TEXT NOT NULL UNIQUE,                  -- stable key used in aggregates
  label      TEXT NOT NULL,                         -- human label for the dashboard
  pattern    TEXT NOT NULL,
  vendor     TEXT,
  enabled    INTEGER NOT NULL DEFAULT 1
);
INSERT OR IGNORE INTO ai_agents(agent_key, label, pattern, vendor) VALUES
  ('claude',    'Claude / Claude Code',   '(^|[^a-z])claude([^a-z]|$)|anthropic\.com|noreply@anthropic',      'Anthropic'),
  ('copilot',   'GitHub Copilot',         'copilot',                                                          'GitHub'),
  ('codex',     'OpenAI Codex',           '(^|[^a-z])codex([^a-z]|$)|chatgpt|openai\.com',                    'OpenAI'),
  ('cursor',    'Cursor',                 'cursor(agent|\.(com|sh))|@cursor',                                 'Cursor'),
  ('devin',     'Devin',                  'devin(-ai)?|cognition',                                            'Cognition'),
  ('gemini',    'Gemini / Jules',         'gemini|google-labs-jules|jules@',                                  'Google'),
  ('aider',     'Aider',                  'aider(\.chat)?',                                                   'Aider'),
  ('windsurf',  'Windsurf / Codeium',     'windsurf|codeium',                                                 'Codeium'),
  ('amp',       'Amp',                    'ampcode|@amp\.',                                                   'Sourcegraph'),
  ('ona',       'Ona / Gitpod agent',     'ona\.com|@ona\b|gitpod',                                           'Gitpod'),
  ('opencode',  'OpenCode / OpenHands',   'opencode|openhands|all-hands',                                     NULL),
  -- EXAMPLE ROW — your in-house agent goes here. Rename the key, the label and
  -- the token; delete it if you have no in-house agent. It is shipped because
  -- the single most common measurement gap is a home-grown agent that signs
  -- itself six different ways and is therefore counted as a human co-author.
  ('ci-agent',  'In-house CI agent',      '(^|[^a-z])ci-agent([^a-z]|$)',                                     NULL),
  -- NOT '\[bot\]'. That catch-all classified every bot co-author as an AI
  -- executor, and the largest population it caught was DEPENDABOT: 94 trailers
  -- in the first real database. A dependency-bump bot is not a coding agent,
  -- and counting it inflates a metric whose entire value is being a FLOOR
  -- nobody can accuse of overclaiming. A '[bot]' co-author that is genuinely an
  -- agent belongs in a NAMED row above (that is why the in-house example row
  -- exists); anything else stays an UNKNOWN executor, the safe direction.
  ('other-ai',  'Other AI agent',         'noreply@.*(ai|agent)|@[a-z0-9.-]*\.ai($|>)',                       NULL);

-- Reconciliation, for the same reason as metric_catalog above: the seed is
-- INSERT OR IGNORE, so a pattern fixed here never reaches a database that
-- already exists. Agent patterns are the single highest-consequence data in
-- this schema — a missing one does not produce a gap, it produces a confident
-- and wrong exclusivity claim ("100% of AI commits are Claude").
UPDATE ai_agents SET pattern = 'ona\.com|@ona\b|gitpod'
 WHERE agent_key = 'ona' AND pattern <> 'ona\.com|@ona\b|gitpod';

-- Same reconciliation, for the '[bot]' overclaim. An existing database keeps
-- serving the old pattern otherwise, which is precisely the database somebody
-- has already shown to a client.
--
-- Changing this pattern does NOT re-map rows already in ai_trailers: the
-- mapping is applied at ingest. Re-run the git ingest with --refetch to remap
-- (the INSERT carries ON CONFLICT DO UPDATE on agent_key/is_ai, so it repairs
-- rather than duplicates). Until you do, the old classification stands.
-- Compare against the WANTED value, never against a fragment of the old one.
-- The first attempt used LIKE '%[bot]%', which cannot match the stored pattern
-- '\[bot\]|...' — the characters are [ b o t \ ] and LIKE has no escapes, so
-- the guard silently matched nothing and the fix silently did not apply. A
-- reconciliation that no-ops is worse than none: it looks applied.
UPDATE ai_agents SET pattern = 'noreply@.*(ai|agent)|@[a-z0-9.-]*\.ai($|>)'
 WHERE agent_key = 'other-ai'
   AND pattern <> 'noreply@.*(ai|agent)|@[a-z0-9.-]*\.ai($|>)';

-- The in-house-agent lesson, kept because it generalises. A home-grown agent
-- signs itself in every shape its authors ever shipped: 'CI Agent
-- <worker@ci-agent.local>', '<worker@ci-agent.internal>', 'CI Agent Operator
-- <operator@ci-agent.dev>', 'ci-agent-app[bot]', and half a dozen more. A
-- token match on the AGENT NAME covers them all; an address-shaped pattern
-- missed 68 of them in the first real database, every one of which then read
-- as a HUMAN co-author and quietly deflated the AI floor.
--
-- The token stays scoped to the trailer's 'name <email>' — never to message
-- text. That scoping is what keeps a name-shaped pattern in the
-- zero-false-positive tier; the same characters matched against prose reach a
-- 1.64% false-positive rate on pre-2021 history, which is larger than the
-- signal it would be trying to recover.
UPDATE ai_agents SET pattern = '(^|[^a-z])ci-agent([^a-z]|$)'
 WHERE agent_key = 'ci-agent' AND pattern <> '(^|[^a-z])ci-agent([^a-z]|$)';

-- ===========================================================================
-- RAW — pull requests
-- ===========================================================================

-- WHY: PRs are the unit for speed (throughput, cycle time), quality (defect
-- ratio, revert rate) and impact (innovation ratio). github_updated_at is the
-- incremental key: a re-run pulls PRs ordered by UPDATED_AT desc and stops at
-- the stored watermark, so next week's run fetches only what moved.
CREATE TABLE IF NOT EXISTS pull_requests (
  pr_id             INTEGER PRIMARY KEY,
  repo_id           INTEGER NOT NULL REFERENCES repos(repo_id),
  number            INTEGER NOT NULL,
  title             TEXT,
  state             TEXT,                           -- 'OPEN' | 'CLOSED' | 'MERGED'
  author_login      TEXT,
  author_identity_id INTEGER REFERENCES identities(identity_id),
  merged_by_login   TEXT,
  created_at        TEXT,
  merged_at         TEXT,                           -- NULL unless state='MERGED'. THE time axis for throughput.
  closed_at         TEXT,
  first_commit_at   TEXT,                           -- earliest authored_at among the PR's commits; cycle-time start
  github_updated_at TEXT,                           -- incremental watermark key
  additions         INTEGER,
  deletions         INTEGER,
  changed_files     INTEGER,
  commit_count      INTEGER,
  base_ref          TEXT,
  head_ref          TEXT,
  is_draft          INTEGER NOT NULL DEFAULT 0,
  label_csv         TEXT,                           -- comma-joined labels; classification input, kept raw
  body_excerpt      TEXT,                           -- first ~500 chars, classification input only. Never rendered.
  ingested_at       TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
  UNIQUE(repo_id, number)
);
CREATE INDEX IF NOT EXISTS idx_pr_repo_merged  ON pull_requests(repo_id, merged_at);
CREATE INDEX IF NOT EXISTS idx_pr_repo_updated ON pull_requests(repo_id, github_updated_at);
CREATE INDEX IF NOT EXISTS idx_pr_identity     ON pull_requests(author_identity_id, merged_at);

-- WHY: the PR <-> commit link. Needed for (a) cycle time first-commit -> merge
-- and (b) deciding whether a PR carries AI trailers, which is a property of its
-- commits, not of the PR row.
CREATE TABLE IF NOT EXISTS pr_commits (
  pr_id   INTEGER NOT NULL REFERENCES pull_requests(pr_id) ON DELETE CASCADE,
  repo_id INTEGER NOT NULL REFERENCES repos(repo_id),
  sha     TEXT NOT NULL,
  PRIMARY KEY (pr_id, sha)
);
CREATE INDEX IF NOT EXISTS idx_pr_commits_sha ON pr_commits(repo_id, sha);

-- ===========================================================================
-- DERIVED — classification
-- ===========================================================================

-- WHY: separated from pull_requests so that improving the classifier is a
-- DELETE FROM pr_classifications + re-run, never a re-fetch of GitHub. `method`
-- is the coverage signal (how much of Quality/Impact a script could decide on
-- its own) and `rule` is the evidence for any single verdict a human disputes.
CREATE TABLE IF NOT EXISTS pr_classifications (
  pr_id              INTEGER PRIMARY KEY REFERENCES pull_requests(pr_id) ON DELETE CASCADE,
  class              TEXT NOT NULL,                 -- 'bugfix'|'feature'|'refactor'|'chore'|'docs'|'test'|'revert'|'deps'|'unknown'
  is_revert          INTEGER NOT NULL DEFAULT 0,    -- structural: revert PRs are counted separately from bugfixes
  confidence         REAL,                          -- 0..1
  method             TEXT NOT NULL,                 -- 'script' | 'script-with-fallback' | 'llm'
  rule               TEXT,                          -- which rule fired, e.g. 'conventional-commit:fix'
  classifier_version TEXT NOT NULL,
  classified_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now'))
);
CREATE INDEX IF NOT EXISTS idx_pr_class_class ON pr_classifications(class);

-- ===========================================================================
-- RESUMABILITY
-- ===========================================================================

-- WHY: one row per script invocation. Gives every fact in the DB a provenance
-- chain (which run wrote it, with which args, against which skill version) and
-- gives coverage_log something to hang off. Also the crash record: a run left
-- in status='running' means the previous invocation died and the watermark for
-- that source must NOT be trusted as complete.
CREATE TABLE IF NOT EXISTS runs (
  run_id        INTEGER PRIMARY KEY,
  script        TEXT NOT NULL,                      -- basename, e.g. 'dxm-ingest-git.sh'
  args          TEXT,                               -- argv, joined. Reproducibility.
  repo_full_name TEXT,                              -- NULL for org-wide / non-repo scripts
  started_at    TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
  finished_at   TEXT,
  status        TEXT NOT NULL DEFAULT 'running',    -- 'running' | 'ok' | 'partial' | 'error'
  exit_code     INTEGER,
  error         TEXT,
  skill_version TEXT,
  host          TEXT
);
CREATE INDEX IF NOT EXISTS idx_runs_script_time ON runs(script, started_at);

-- WHY: THE resumability contract. Before fetching anything a script reads its
-- (repo, source) row and starts from cursor_value; after a clean pass it writes
-- the new cursor. A row is only advanced when the run finished 'ok' -- a partial
-- run leaves the watermark where it was, so the next run re-fetches the overlap
-- rather than leaving a silent hole in the time series.
CREATE TABLE IF NOT EXISTS ingest_watermarks (
  repo_id          INTEGER NOT NULL REFERENCES repos(repo_id),
  source           TEXT NOT NULL,                   -- 'git_commits'|'git_trailers'|'github_prs'|'github_identities'|'deploys'
  cursor_kind      TEXT NOT NULL,                   -- 'sha' | 'timestamp' | 'pr_number'
  cursor_value     TEXT,                            -- NULL = never ingested; do a full backfill
  record_count     INTEGER NOT NULL DEFAULT 0,      -- cumulative rows written by this source
  last_success_run_id INTEGER REFERENCES runs(run_id),
  last_success_at  TEXT,
  last_attempt_at  TEXT,
  PRIMARY KEY (repo_id, source)
);

-- ===========================================================================
-- SELF-MEASUREMENT — script coverage
-- ===========================================================================

-- WHY: this skill measures itself. Every unit of output records which
-- resolution path produced it. coverage % = (script + script-with-fallback) /
-- total; the method='llm' rows ARE the engineering backlog -- each one names a
-- deterministic rule that does not exist yet. Without this table "minimise LLM
-- tokens" is an aspiration instead of a number.
CREATE TABLE IF NOT EXISTS coverage_log (
  coverage_id INTEGER PRIMARY KEY,
  run_id      INTEGER NOT NULL REFERENCES runs(run_id),
  unit_kind   TEXT NOT NULL,                        -- 'pr_classification'|'identity_resolution'|'ai_attribution'|'metric'|'deploy_detection'
  unit_key    TEXT NOT NULL,                        -- e.g. 'owner/repo#1407', 'owner/repo:email', 'speed.pr_throughput'
  method      TEXT NOT NULL,                        -- 'script' | 'script-with-fallback' | 'llm'
  detail      TEXT,                                 -- rule name on success; the reason a script gave up on 'llm'
  created_at  TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now'))
);
CREATE INDEX IF NOT EXISTS idx_coverage_run  ON coverage_log(run_id);
CREATE INDEX IF NOT EXISTS idx_coverage_kind ON coverage_log(unit_kind, method);

-- ===========================================================================
-- METRIC CATALOG — the proxy-declaration enforcement point
-- ===========================================================================

-- WHY: the hard rule of this project is that a proxy metric declares itself in
-- its own output, every time. Making that a data dependency rather than a
-- convention means it cannot be forgotten: a renderer looks up the catalog row
-- to get the label, and gets proxy_statement and cannot_see in the same row.
-- A metric_key with no catalog row MUST NOT be rendered.
--
-- computable=0 rows are not failures -- they are the honest statement that this
-- number cannot come from git. DXI is the flagship example.
--
-- privacy_class:
--   'aggregate_only'  -- may only ever be shown at team/org level. No per-person
--                        rendering exists for these, opt-in or not.
--   'individual_ok'   -- legitimately per-person: ownership/SPOF risk and
--                        AI-adoption timing. Still gated behind the explicit
--                        individual opt-in flag.
CREATE TABLE IF NOT EXISTS metric_catalog (
  metric_key      TEXT PRIMARY KEY,
  pillar          TEXT NOT NULL,                    -- 'speed'|'quality'|'impact'|'effectiveness'|'adoption'|'risk'|'meta'
  label           TEXT NOT NULL,
  unit            TEXT NOT NULL,                    -- 'count'|'ratio'|'percent'|'hours'|'days'|'date'
  is_proxy        INTEGER NOT NULL,
  computable      INTEGER NOT NULL DEFAULT 1,       -- 0 = cannot be derived from git/GitHub; emit as unavailable
  privacy_class   TEXT NOT NULL,                    -- 'aggregate_only' | 'individual_ok'
  proxy_statement TEXT,                             -- rendered INLINE next to the number, every time
  cannot_see      TEXT,                             -- the explicit blind spot
  higher_is       TEXT                              -- 'better'|'worse'|'neither' — 'neither' where direction is a judgement
);

INSERT OR IGNORE INTO metric_catalog
  (metric_key, pillar, label, unit, is_proxy, computable, privacy_class, proxy_statement, cannot_see, higher_is) VALUES

-- ---- Speed -------------------------------------------------------------
('speed.pr_throughput_per_contributor_week', 'speed',
 'Merged PRs per active contributor per week', 'count', 1, 1, 'aggregate_only',
 'Proxy. Counts merged pull requests, not delivered value. A PR is a unit of review, not a unit of work.',
 'PR size, work that never becomes a PR, commits pushed straight to the default branch, and work done outside this repo.',
 'neither'),

('speed.cycle_time_first_commit_to_merge_p50', 'speed',
 'Cycle time, first commit to merge (median)', 'hours', 1, 1, 'aggregate_only',
 'Proxy. The clock starts at the first commit on the branch, which is not when the work started.',
 'Time spent thinking, specifying, or blocked before the first commit; and PRs whose history was rebased or squashed, which understate the true span.',
 'worse'),

('speed.cycle_time_first_commit_to_merge_p75', 'speed',
 'Cycle time, first commit to merge (75th percentile)', 'hours', 1, 1, 'aggregate_only',
 'Proxy. The clock starts at the first commit on the branch, which is not when the work started.',
 'Time spent thinking, specifying, or blocked before the first commit; and PRs whose history was rebased or squashed.',
 'worse'),

('speed.active_contributors', 'speed',
 'Active contributors', 'count', 1, 1, 'aggregate_only',
 'Proxy. Counts distinct non-bot logins with at least one merged PR in the period.',
 'People who reviewed, paired, specified, or supported without authoring a merged PR.',
 'neither'),

-- ---- Quality -----------------------------------------------------------
('quality.defect_ratio', 'quality',
 'Share of merged PRs that are bug fixes', 'percent', 1, 1, 'aggregate_only',
 'Proxy, and a classifier''s opinion. Derived from PR titles, labels and conventional-commit prefixes -- not from a defect tracker.',
 'Bugs never filed, bugs fixed inside a feature PR, severity, and customer impact. A team that labels carefully will look worse than one that does not.',
 'worse'),

('quality.revert_rate', 'quality',
 'Share of merged PRs that revert earlier work', 'percent', 1, 1, 'aggregate_only',
 'Proxy. Detected structurally, from revert commits and PR titles matching the git revert form.',
 'Reverts done by hand as an ordinary "fix" PR, roll-forwards, and feature-flag kills -- all of which are reverts in practice and invisible here.',
 'worse'),

-- ---- Impact ------------------------------------------------------------
('impact.innovation_ratio', 'impact',
 'Share of merged PRs that add new capability', 'percent', 1, 1, 'aggregate_only',
 'Proxy, and a classifier''s opinion. New capability is inferred from PR text, not from a roadmap or a product outcome.',
 'Whether the new capability was used, wanted, or valuable. This measures direction of effort, never impact on customers.',
 'neither'),

-- ---- Effectiveness -----------------------------------------------------
('effectiveness.dxi', 'effectiveness',
 'Developer Experience Index (DXI)', 'count', 0, 0, 'aggregate_only',
 'NOT COMPUTABLE from git or the GitHub API. DXI is a survey instrument. Any number presented here would be fabricated.',
 'Everything DXI measures: perceived friction, flow, confidence, and clarity. Collect it with a survey or leave it empty.',
 'better'),

-- ---- AI adoption -------------------------------------------------------
('adoption.ai_commit_share', 'adoption',
 'Share of commits carrying an AI co-author trailer', 'percent', 1, 1, 'aggregate_only',
 'Proxy, and a FLOOR rather than a measurement. Counts only commits with a Co-Authored-By trailer naming a known AI agent.',
 'AI used without a trailer -- autocomplete, chat-window copy-paste, any tool not configured to add a trailer, and squashes that dropped the trailer. Real usage is higher than this number, by an unknown amount.',
 'neither'),

('adoption.ai_pr_share', 'adoption',
 'Share of merged PRs with at least one AI-co-authored commit', 'percent', 1, 1, 'aggregate_only',
 'Proxy, and a floor. A PR counts as AI-assisted if any of its commits carries an AI Co-Authored-By trailer.',
 'How much of the PR the AI actually wrote, and any AI assistance that left no trailer.',
 'neither'),

('adoption.first_ai_trailer_date', 'adoption',
 'First AI-co-authored commit', 'date', 1, 1, 'individual_ok',
 'Proxy for when a person started using an AI coding tool. It is when the TRAILER first appears, which is when the tooling was configured, not necessarily when use began.',
 'Adoption of tools that emit no trailer, and any use before the tooling was set up correctly.',
 'neither'),

('adoption.agent_mix', 'adoption',
 'Mix of AI agents by trailer', 'percent', 1, 1, 'aggregate_only',
 'Proxy. Reflects which agents are configured to write a trailer, not which agents are used most.',
 'Any agent that does not write a trailer is absent from this chart entirely.',
 'neither'),

-- ---- Risk (individual-level is legitimate here) ------------------------
('risk.ownership_concentration', 'risk',
 'Share of changes to a path owned by its top contributor', 'percent', 1, 1, 'individual_ok',
 'Proxy for single-point-of-failure risk. Derived from who touched the files, not from who understands them.',
 'Knowledge held by reviewers and pairs, documentation, and whether the owner is actually still on the team.',
 'worse'),

('risk.bus_factor', 'risk',
 'Contributors needed to cover half of all changes', 'count', 1, 1, 'individual_ok',
 'Proxy for concentration risk. Counts contributors by volume of change, not by depth of understanding.',
 'Review coverage, pairing, and documented knowledge -- all of which reduce real risk without moving this number.',
 'better'),

-- ---- Meta --------------------------------------------------------------
('meta.script_coverage_pct', 'meta',
 'Share of outputs decided by deterministic scripts', 'percent', 0, 1, 'aggregate_only',
 NULL,
 NULL,
 'better'),

('meta.identity_resolution_pct', 'meta',
 'Share of commit emails resolved to a GitHub login', 'percent', 0, 1, 'aggregate_only',
 NULL,
 'Commits whose email GitHub cannot resolve are excluded from per-person views and counted here instead.',
 'better');

-- ---------------------------------------------------------------------------
-- Catalog reconciliation.
--
-- The seed above is INSERT OR IGNORE, so editing a disclosure string there has
-- no effect on a database that already exists — the very databases holding the
-- numbers someone already showed a client. Disclosures must therefore be
-- reconciled on every schema apply, not seeded once.
--
-- What is being repaired: bot-authored PRs are removed from every PR-derived
-- metric, and none of these rows said so. On an agent-native team that is the
-- single largest distortion on the page (measured: 46% of merged PRs in one
-- org, 90% in one month), and a disclosure block that omits it while listing
-- smaller caveats is worse than no disclosure at all.
-- ---------------------------------------------------------------------------
UPDATE metric_catalog
   SET cannot_see = cannot_see ||
       ' Bot- and agent-authored PRs are excluded entirely, so on a team where agents open their own PRs this counts the human share of delivery, not the delivered total.'
 WHERE metric_key IN (
         'speed.pr_throughput_per_contributor_week',
         'speed.cycle_time_first_commit_to_merge_p50',
         'speed.cycle_time_first_commit_to_merge_p75',
         'speed.active_contributors',
         'quality.defect_ratio',
         'quality.revert_rate',
         'impact.innovation_ratio',
         'adoption.ai_pr_share')
   AND cannot_see IS NOT NULL
   AND cannot_see NOT LIKE '%Bot- and agent-authored PRs are excluded%';

-- ---------------------------------------------------------------------------
-- The attribution-pair relabel.
--
-- adoption.ai_commit_share used to be described as a share of "commits", inside
-- a pipeline that treated every unresolvable author as a human. It is now a
-- share of EXECUTIONS with a declared agent executor, over every execution in
-- scope whatever its steerer, and it is a FLOOR in both directions: an
-- untrailered commit is an UNKNOWN executor, never a human one.
-- ---------------------------------------------------------------------------
UPDATE metric_catalog
   SET label = 'AI-executed share of commits — FLOOR',
       proxy_statement = 'Proxy, and a FLOOR. Numerator: commits whose Co-Authored-By trailer names a known AI agent (executor = agent, confidence = declared trailer). Denominator: every non-merge commit in scope, whatever its steerer. The remainder is UNKNOWN executor, not human execution — a missing trailer is not evidence a human wrote the commit.',
       cannot_see = 'Which of the untrailered commits an agent actually wrote. Trailer discipline arrived late in every repo measured here, so early buckets understate agent execution by an unknown and NON-UNIFORM amount, which means the SHAPE of this series is not trustworthy either — only its floor. Also invisible: autocomplete, chat-window copy-paste, any tool not configured to write a trailer, and squashes that dropped one.'
 WHERE metric_key = 'adoption.ai_commit_share'
   AND label <> 'AI-executed share of commits — FLOOR';

UPDATE metric_catalog
   SET label = 'AI-executed share of merged PRs — FLOOR',
       proxy_statement = 'Proxy, and a FLOOR. A PR counts as agent-executed when at least one of its commits carries an AI Co-Authored-By trailer. The remainder is UNKNOWN executor, never human executor.',
       cannot_see = 'How much of the PR the agent wrote, any assistance that left no trailer, and squash merges that dropped the trailer entirely. Bot- and agent-authored PRs are excluded entirely, so on a team where agents open their own PRs this counts the human-steered share of delivery, not the delivered total.'
 WHERE metric_key = 'adoption.ai_pr_share'
   AND label <> 'AI-executed share of merged PRs — FLOOR';

UPDATE metric_catalog
   SET label = 'Commits with no identifiable steerer',
       cannot_see = 'Who steered them. They are NOT counted as human — they are counted here, as a named gap, and they remain in execution denominators because they are real executions. The size of this number is the quality signal for the whole run: while it is large and moving, no attribution-derived trend on this page is trustworthy.'
 WHERE metric_key = 'meta.unattributed_commits'
   AND label <> 'Commits with no identifiable steerer';

-- risk.ownership_concentration is catalogued computable=1 but nothing in this
-- build ingests file paths, so it can never produce a value. A card that says
-- "no value for this week" reads as a temporal gap the reader will expect to
-- fill in next week; the truth is structural.
UPDATE metric_catalog
   SET computable = 0,
       proxy_statement = 'NOT COMPUTABLE in this build. Ownership concentration needs per-file change attribution, and this tool does not ingest file paths. No value will ever appear here until that module exists.'
 WHERE metric_key = 'risk.ownership_concentration' AND computable = 1;

-- ===========================================================================
-- DERIVED — aggregates
-- ===========================================================================
-- Everything below is disposable. DELETE FROM these tables and re-run the
-- aggregate step and you must get byte-identical numbers back from RAW.
-- period_kind is 'day' | 'week' | 'month'; period_start is the UTC calendar
-- start of the bucket ('YYYY-MM-DD'; weeks start Monday).

-- WHY: per-person, per-period counts. This table exists to answer OWNERSHIP /
-- SPOF RISK and AI-ADOPTION TIMING, which are legitimate individual questions.
-- It is NOT a throughput leaderboard: the renderer has no per-person output
-- path, opt-in or not. Reading it for performance evaluation is a misuse.
CREATE TABLE IF NOT EXISTS agg_author_period (
  identity_id    INTEGER NOT NULL REFERENCES identities(identity_id),
  repo_id        INTEGER NOT NULL REFERENCES repos(repo_id),
  period_kind    TEXT NOT NULL,
  period_start   TEXT NOT NULL,
  commits        INTEGER NOT NULL DEFAULT 0,
  ai_commits     INTEGER NOT NULL DEFAULT 0,
  prs_opened     INTEGER NOT NULL DEFAULT 0,
  prs_merged     INTEGER NOT NULL DEFAULT 0,
  ai_prs_merged  INTEGER NOT NULL DEFAULT 0,
  insertions     INTEGER NOT NULL DEFAULT 0,
  deletions      INTEGER NOT NULL DEFAULT 0,
  files_touched  INTEGER NOT NULL DEFAULT 0,
  agg_version    TEXT NOT NULL,
  computed_at    TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
  PRIMARY KEY (identity_id, repo_id, period_kind, period_start)
);
CREATE INDEX IF NOT EXISTS idx_agg_author_period ON agg_author_period(period_kind, period_start);

-- WHY: the default dashboard reads from here and ONLY from here. Contains no
-- personal information by construction -- there is no identity column. This is
-- what makes "the default dashboard contains no personal information" a
-- structural property rather than a promise the renderer has to keep.
CREATE TABLE IF NOT EXISTS agg_org_period (
  scope             TEXT NOT NULL,                  -- 'org' | 'repo'
  scope_key         TEXT NOT NULL,                  -- 'owner' or 'owner/name'
  period_kind       TEXT NOT NULL,
  period_start      TEXT NOT NULL,
  active_contributors INTEGER NOT NULL DEFAULT 0,
  commits           INTEGER NOT NULL DEFAULT 0,
  ai_commits        INTEGER NOT NULL DEFAULT 0,
  prs_opened        INTEGER NOT NULL DEFAULT 0,
  prs_merged        INTEGER NOT NULL DEFAULT 0,
  ai_prs_merged     INTEGER NOT NULL DEFAULT 0,
  prs_bugfix        INTEGER NOT NULL DEFAULT 0,
  prs_feature       INTEGER NOT NULL DEFAULT 0,
  prs_revert        INTEGER NOT NULL DEFAULT 0,
  prs_unclassified  INTEGER NOT NULL DEFAULT 0,     -- honesty: the denominator gap for defect/innovation ratios
  cycle_time_p50_h  REAL,
  cycle_time_p75_h  REAL,
  insertions        INTEGER NOT NULL DEFAULT 0,
  deletions         INTEGER NOT NULL DEFAULT 0,
  agg_version       TEXT NOT NULL,
  computed_at       TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
  PRIMARY KEY (scope, scope_key, period_kind, period_start)
);
CREATE INDEX IF NOT EXISTS idx_agg_org_period ON agg_org_period(period_kind, period_start);

-- WHY: the long-form table for anything expressed as a rate, ratio or index.
-- Every row must reference a metric_catalog row, so every number carries its
-- proxy statement, its blind spot and its privacy class wherever it is read.
-- numerator/denominator are stored alongside value so a reader can always see
-- how thin the sample is (a 100% defect ratio over 2 PRs is not a signal).
CREATE TABLE IF NOT EXISTS agg_metric (
  metric_key   TEXT NOT NULL REFERENCES metric_catalog(metric_key),
  scope        TEXT NOT NULL,                       -- 'org' | 'repo'
  scope_key    TEXT NOT NULL,
  period_kind  TEXT NOT NULL,
  period_start TEXT NOT NULL,
  value        REAL,                                -- NULL = not computable for this bucket; render as such, never as 0
  numerator    REAL,
  denominator  REAL,
  sample_size  INTEGER,
  note         TEXT,                                -- bucket-specific caveat, e.g. 'partial week'
  agg_version  TEXT NOT NULL,
  computed_at  TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
  PRIMARY KEY (metric_key, scope, scope_key, period_kind, period_start)
);
CREATE INDEX IF NOT EXISTS idx_agg_metric_period ON agg_metric(period_kind, period_start);

-- WHY: AI adoption is a before/after question, and the before/after boundary is
-- per person (their first trailer), not a single org-wide date. This table is
-- the one individual-level derived output that is legitimate, and it is
-- adoption TIMING plus deltas -- never a ranking.
CREATE TABLE IF NOT EXISTS agg_adoption_timeline (
  identity_id        INTEGER NOT NULL REFERENCES identities(identity_id),
  scope              TEXT NOT NULL,                 -- 'org' | 'repo'
  scope_key          TEXT NOT NULL,
  first_ai_trailer_at TEXT,                         -- NULL = no AI trailer ever observed
  first_agent_key    TEXT,
  commits_before     INTEGER,
  commits_after      INTEGER,
  window_days        INTEGER,                       -- symmetric window used for the before/after comparison
  agg_version        TEXT NOT NULL,
  computed_at        TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
  PRIMARY KEY (identity_id, scope, scope_key)
);

-- ===========================================================================
-- OPTIONAL MODULE — deploy detection (OFF BY DEFAULT)
-- ===========================================================================
-- WHY the table exists but nothing writes to it by default: DX Core 4 does not
-- need deployment frequency, and branch-based deploy inference is the single
-- least portable part of this kind of tool. The table is defined so that
-- enabling the module later is a code change, not a schema migration. Nothing
-- in the default dashboard may read from here.
CREATE TABLE IF NOT EXISTS deploys (
  deploy_id     INTEGER PRIMARY KEY,
  repo_id       INTEGER NOT NULL REFERENCES repos(repo_id),
  sha           TEXT NOT NULL,
  ref           TEXT,
  deployed_at   TEXT NOT NULL,
  detection     TEXT NOT NULL,                      -- 'prod_branch_merge'|'tag'|'github_deployment'|'release'
  confidence    REAL,
  ingested_at   TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
  UNIQUE(repo_id, sha, detection)
);

CREATE TABLE IF NOT EXISTS prod_branch_patterns (
  pattern_id INTEGER PRIMARY KEY,
  repo_id    INTEGER REFERENCES repos(repo_id),     -- NULL = applies to every repo
  pattern    TEXT NOT NULL,                         -- POSIX ERE against the branch/ref name
  enabled    INTEGER NOT NULL DEFAULT 0             -- OFF by default. Deliberate.
);

-- ===========================================================================
-- VIEWS — the canonical read surface
-- ===========================================================================
-- Bucketing, bot exclusion and AI attribution are defined ONCE, here. No
-- aggregate query may re-implement them. Fixing a bucketing bug is
-- DROP VIEW / CREATE VIEW plus a re-aggregate -- never a re-ingest.
--
-- Week bucket: date(ts, '-6 days', 'weekday 1') -> the Monday of the week
-- containing ts. Verified against Monday, midweek and Sunday inputs.

DROP VIEW IF EXISTS v_human_identities;
CREATE VIEW v_human_identities AS
  SELECT * FROM identities
   WHERE is_bot = 0 AND is_excluded = 0;

DROP VIEW IF EXISTS v_unresolved_emails;
CREATE VIEW v_unresolved_emails AS
  SELECT e.email, e.commit_count, e.sample_sha, r.full_name AS sample_repo
    FROM identity_emails e
    LEFT JOIN repos r ON r.repo_id = e.sample_repo_id
   WHERE e.identity_id IS NULL
   ORDER BY e.commit_count DESC;

-- ---------------------------------------------------------------------------
-- THE ATTRIBUTION PAIR
--
-- A commit is NOT human XOR AI. It carries TWO attributions, either of which
-- may be absent:
--
--   steerer   — the human who directed the work.   steerer_state:
--                 'known'   author_identity_id resolves to a human identity
--                 'machine' it resolves to a bot / agent / machine account, so
--                           no human steerer is identifiable from this commit
--                 'unknown' the author email resolved to nobody. This is a
--                           MEASUREMENT GAP, not a person, and it must never be
--                           counted as evidence that a human wrote the commit.
--
--   executor  — the agent that produced the diff.  executor_state:
--                 'agent'   at least one Co-Authored-By trailer names a known
--                           AI agent. executor_confidence='declared-trailer'.
--                 'unknown' no such trailer. executor_confidence='no-evidence'.
--
-- THE RULE THAT MATTERS: a missing trailer is NOT evidence of human execution.
-- Trailer discipline arrived late in every repo measured so far, so untrailered
-- history is UNKNOWN executor, never "no executor" and never "human executor".
-- There is deliberately no executor_state='human' — nothing in git can produce
-- that value, so the schema refuses to offer it.
-- ---------------------------------------------------------------------------
DROP VIEW IF EXISTS v_commits_enriched;
CREATE VIEW v_commits_enriched AS
  SELECT
    c.commit_id, c.repo_id, r.full_name AS repo_full_name, r.owner,
    c.sha, c.author_identity_id, i.login AS author_login,
    c.authored_at,
    strftime('%Y-%m-%d', c.authored_at)                  AS day_start,
    date(c.authored_at, '-6 days', 'weekday 1')          AS week_start,
    strftime('%Y-%m-01', c.authored_at)                  AS month_start,
    c.is_merge, c.pr_number, c.insertions, c.deletions, c.files_changed,
    -- The multi-line signal, exposed here so no query re-derives it and no
    -- renderer recomputes it. NULL means "not measurable", NOT 0 — see the
    -- column comment on commits.has_body.
    c.has_body, c.body_chars,
    COALESCE(x.has_agent, 0)                              AS is_ai_assisted,
    CASE WHEN i.identity_id IS NULL THEN 1 ELSE 0 END     AS is_unattributed,
    COALESCE(i.is_bot, 0)                                 AS is_bot,
    -- steerer axis
    c.author_identity_id                                  AS steerer_identity_id,
    CASE WHEN i.identity_id IS NULL              THEN 'unknown'
         WHEN i.is_bot = 1 OR i.is_excluded = 1  THEN 'machine'
         ELSE 'known' END                                 AS steerer_state,
    -- executor axis
    CASE WHEN x.has_agent = 1 THEN 'agent' ELSE 'unknown' END          AS executor_state,
    CASE WHEN x.has_agent = 1 THEN 'declared-trailer' ELSE 'no-evidence' END AS executor_confidence,
    x.agent_key                                           AS executor_agent_key
  FROM commits c
  JOIN repos r      ON r.repo_id = c.repo_id
  LEFT JOIN identities i ON i.identity_id = c.author_identity_id
  -- ONE grouped join, not four correlated subqueries. The pair model needs four
  -- facts about a commit's trailers (is it agent-executed, its state, its
  -- confidence, which agent); asking ai_trailers separately for each turned a
  -- 24k-commit dashboard render from ~3 minutes into ~15. MIN(agent_key)
  -- ignores NULLs, which reproduces the old "first non-null agent_key in
  -- alphabetical order" exactly.
  LEFT JOIN (SELECT repo_id, sha, 1 AS has_agent, MIN(agent_key) AS agent_key
               FROM ai_trailers WHERE is_ai = 1
              GROUP BY repo_id, sha) x
         ON x.repo_id = c.repo_id AND x.sha = c.sha;

DROP VIEW IF EXISTS v_prs_enriched;
CREATE VIEW v_prs_enriched AS
  SELECT
    p.pr_id, p.repo_id, r.full_name AS repo_full_name, r.owner,
    p.number, p.author_identity_id, i.login AS author_login,
    p.state, p.created_at, p.first_commit_at, p.merged_at,
    strftime('%Y-%m-%d', p.merged_at)                     AS merged_day_start,
    date(p.merged_at, '-6 days', 'weekday 1')             AS merged_week_start,
    strftime('%Y-%m-01', p.merged_at)                     AS merged_month_start,
    CASE WHEN p.merged_at IS NOT NULL AND p.first_commit_at IS NOT NULL
         THEN (julianday(p.merged_at) - julianday(p.first_commit_at)) * 24.0
    END                                                   AS cycle_time_hours,
    p.additions, p.deletions, p.changed_files, p.commit_count,
    COALESCE(cl.class, 'unclassified')                    AS class,
    COALESCE(cl.is_revert, 0)                             AS is_revert,
    cl.method                                             AS class_method,
    CASE WHEN EXISTS (
      SELECT 1 FROM pr_commits pc
       JOIN ai_trailers t ON t.repo_id = pc.repo_id AND t.sha = pc.sha AND t.is_ai = 1
       WHERE pc.pr_id = p.pr_id
    ) THEN 1 ELSE 0 END                                   AS is_ai_assisted,
    COALESCE(i.is_bot, 0)                                 AS is_bot,
    -- The same attribution pair as v_commits_enriched. A PR's executor is
    -- 'agent' when ANY of its commits carries an AI trailer; 'unknown'
    -- otherwise — never 'human'.
    p.author_identity_id                                  AS steerer_identity_id,
    CASE WHEN i.identity_id IS NULL              THEN 'unknown'
         WHEN i.is_bot = 1 OR i.is_excluded = 1  THEN 'machine'
         ELSE 'known' END                                 AS steerer_state,
    CASE WHEN EXISTS (
      SELECT 1 FROM pr_commits pc
       JOIN ai_trailers t ON t.repo_id = pc.repo_id AND t.sha = pc.sha AND t.is_ai = 1
       WHERE pc.pr_id = p.pr_id
    ) THEN 'agent' ELSE 'unknown' END                     AS executor_state,
    CASE WHEN EXISTS (
      SELECT 1 FROM pr_commits pc
       JOIN ai_trailers t ON t.repo_id = pc.repo_id AND t.sha = pc.sha AND t.is_ai = 1
       WHERE pc.pr_id = p.pr_id
    ) THEN 'declared-trailer' ELSE 'no-evidence' END      AS executor_confidence
  FROM pull_requests p
  JOIN repos r ON r.repo_id = p.repo_id
  LEFT JOIN identities i        ON i.identity_id = p.author_identity_id
  LEFT JOIN pr_classifications cl ON cl.pr_id = p.pr_id;

-- Coverage, per run. coverage_pct is defined ONCE, here, so every script and
-- the report agree on the number.
DROP VIEW IF EXISTS v_coverage_by_run;
CREATE VIEW v_coverage_by_run AS
  SELECT
    run_id,
    unit_kind,
    COUNT(*)                                                        AS total,
    SUM(method = 'script')                                          AS n_script,
    SUM(method = 'script-with-fallback')                            AS n_script_fallback,
    SUM(method = 'llm')                                             AS n_llm,
    ROUND(100.0 * SUM(method IN ('script','script-with-fallback')) / COUNT(*), 1) AS coverage_pct,
    ROUND(100.0 * SUM(method = 'script') / COUNT(*), 1)             AS pure_script_pct
  FROM coverage_log
  GROUP BY run_id, unit_kind;

-- The LLM-fallback backlog: each row is a deterministic rule that does not
-- exist yet, ranked by how often it was needed.
DROP VIEW IF EXISTS v_llm_backlog;
CREATE VIEW v_llm_backlog AS
  SELECT unit_kind, COALESCE(detail, '(no reason recorded)') AS reason, COUNT(*) AS hits
    FROM coverage_log
   WHERE method = 'llm'
   GROUP BY unit_kind, reason
   ORDER BY hits DESC;

-- Repos that must not be analysed: shallow clone = silently truncated history.
DROP VIEW IF EXISTS v_unsafe_repos;
CREATE VIEW v_unsafe_repos AS
  SELECT full_name, 'shallow clone — history is truncated, time series would be wrong' AS reason
    FROM repos WHERE is_shallow = 1;
