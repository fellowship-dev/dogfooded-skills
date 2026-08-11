#!/usr/bin/env bash
# dxm-aggregate.sh — DX Core 4 + AI adoption, computed from ingested raw data.
#                                                                          [W4]
#
# Reads:  v_commits_enriched / v_prs_enriched / v_human_identities (schema.sql)
#         through the period-pivoted views in sql/metrics.sql.
# Writes: agg_org_period, agg_author_period, agg_metric, agg_adoption_timeline,
#         metric_catalog (additions, via sql/metrics.sql).
#
# It NEVER touches the network and never reads raw git. Everything it produces
# is rebuildable: DELETE the agg_* rows, re-run, get the same numbers back.
#
# Two properties are worth knowing before reading the SQL:
#
#   1. agg_version is a hash of this script plus sql/metrics.sql. Change a
#      formula and the version changes; the next run notices the mismatch and
#      rebuilds from the beginning by itself. A metric bug can never survive as
#      a stale row next to a fresh one.
#
#   2. agg_metric rows are derived from agg_org_period rather than recomputed
#      from raw, so the two surfaces the dashboard reads cannot disagree with
#      each other. Both are rebuilt in the same transaction.
#
# See CONTRACT.md for flags, exit codes, the envelope and the privacy rules.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/../lib/dxm-common.sh"

SELF="$(basename "$0")"
METRICS_SQL="$SCRIPT_DIR/../sql/metrics.sql"

# Minimum merged PRs on EACH side of a contributor's first AI trailer before
# their before/after cycle-time change is allowed into the median. Two PRs
# either side is noise wearing a percentage sign.
MIN_PRS_PER_PHASE=3

usage() {
  cat <<'EOF'
dxm-aggregate.sh — compute DX Core 4 and AI-adoption aggregates from ingested data.

USAGE
  dxm-aggregate.sh [--repo owner/name]... [--org owner]... [options]

SCOPE
  --repo owner/name        Repo to aggregate. Repeatable. Must already be ingested.
  --org owner              All ingested repos of this owner. Repeatable.
  (neither)                Every ingested repo in the database.

  Org-level rows are always produced for the owners involved, and they roll up
  ALL ingested repos of that owner -- not only the ones named on this command
  line -- because an org number computed from a subset is a wrong number.

OPTIONS
  --period day|week|month  Bucket granularity. Default: week. One kind per run;
                           run three times for three granularities.
  --since YYYY-MM-DD       Backfill floor. Honoured on a full/rebuild pass only;
                           ignored on an incremental pass (CONTRACT.md §4).
  --until YYYY-MM-DD       Analysis ceiling. Default: today (UTC). Never exceeds
                           today: buckets are not projected into the future.
  --rebuild                Drop derived rows for the selected scopes and
                           recompute from the earliest commit. Never re-fetches.
  --adoption-window-days N Symmetric before/after window around each
                           contributor's first AI trailer. Default: 90.
  --include-individuals    Accepted for interface compatibility. It changes
                           NOTHING here: agg_author_period and
                           agg_adoption_timeline are always computed because the
                           org-level risk and adoption metrics are derived from
                           them (CONTRACT.md §8.6). This script writes no login,
                           name or email to stdout or to any file, with or
                           without the flag. The flag gates RENDERING, in
                           dxm-report.sh.
  --dry-run                Compute everything, roll the transaction back, and
                           report what would have been written.
  --json                   Implicit. There is no human-formatted stdout mode.
  --help                   This text.

OUTPUT
  One line of JSON on stdout. Progress and warnings on stderr.

EXIT CODES
  0 ok · 1 usage · 2 precondition (shallow repo, unknown repo, bucketing drift)
  3 partial · 4 data error

PRIVACY
  This output is sensitive.
  It must not be used to measure individual performance or feed performance
  evaluations. No per-person throughput output exists in this tool, opt-in or
  not. Individual-level data is computed for exactly two purposes:
  concentration/SPOF risk, and AI-adoption timing.
EOF
}

# ---------------------------------------------------------------------------
# Flags
# ---------------------------------------------------------------------------
PERIOD="week"; SINCE=""; UNTIL=""; REBUILD=0; DRYRUN=0; INDIVIDUALS=0
ADOPT_WIN=90
REPOS=""; ORGS=""
ARGS_ALL="$*"

while [ $# -gt 0 ]; do
  case "$1" in
    --repo)   [ $# -ge 2 ] || dxm_die "--repo needs a value" 1; REPOS="$REPOS $2"; shift 2 ;;
    --org)    [ $# -ge 2 ] || dxm_die "--org needs a value" 1;  ORGS="$ORGS $2";  shift 2 ;;
    --period) [ $# -ge 2 ] || dxm_die "--period needs a value" 1; PERIOD="$2"; shift 2 ;;
    --since)  [ $# -ge 2 ] || dxm_die "--since needs a value" 1; SINCE="$2"; shift 2 ;;
    --until)  [ $# -ge 2 ] || dxm_die "--until needs a value" 1; UNTIL="$2"; shift 2 ;;
    --adoption-window-days) [ $# -ge 2 ] || dxm_die "--adoption-window-days needs a value" 1; ADOPT_WIN="$2"; shift 2 ;;
    --rebuild)             REBUILD=1; shift ;;
    --include-individuals) INDIVIDUALS=1; shift ;;
    --dry-run)             DRYRUN=1; shift ;;
    --json)                shift ;;
    --help|-h)             usage; exit 0 ;;
    *) dxm_die "unknown flag: $1 (see --help)" 1 ;;
  esac
done

case "$PERIOD" in day|week|month) ;; *) dxm_die "--period must be day, week or month; got: $PERIOD" 1 ;; esac
case "$ADOPT_WIN" in ''|*[!0-9]*) dxm_die "--adoption-window-days must be a positive integer" 1 ;; esac
[ "$ADOPT_WIN" -gt 0 ] || dxm_die "--adoption-window-days must be a positive integer" 1
_datefmt() { case "$1" in [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) return 0 ;; *) return 1 ;; esac; }
[ -z "$SINCE" ] || _datefmt "$SINCE" || dxm_die "--since must be YYYY-MM-DD; got: $SINCE" 1
[ -z "$UNTIL" ] || _datefmt "$UNTIL" || dxm_die "--until must be YYYY-MM-DD; got: $UNTIL" 1

PK="$PERIOD"

# ---------------------------------------------------------------------------
# Preconditions
# ---------------------------------------------------------------------------
dxm_init_db
[ -f "$METRICS_SQL" ] || dxm_die "sql/metrics.sql not found at $METRICS_SQL" 2

RUN_ID="$(dxm_run_start "$SELF" "$ARGS_ALL" "")"
trap 'dxm_run_trap '"$RUN_ID"' $?' EXIT

# Exit non-zero the way CONTRACT.md §5 requires: close the run, and still put an
# envelope on stdout so the caller reads a failure rather than empty output.
dxm_fail() {
  local code="$1" msg="$2"
  dxm_warn "$msg"
  dxm_run_finish "$RUN_ID" error "$code" "$msg"
  dxm_emit false "$SELF" "$RUN_ID" "\"error\":$(dxm_json_str "$msg")"
  exit "$code"
}

# agg_version = 1 + a digest of the two files that define every formula. A
# formula edit therefore forces a full rebuild on the next run, automatically.
_digest() {
  if command -v shasum >/dev/null 2>&1; then cat "$@" | shasum -a 1 | cut -c1-10
  else cat "$@" | cksum | tr -d ' ' | cut -c1-10; fi
}
AGGV="1-$(_digest "$SCRIPT_DIR/$SELF" "$METRICS_SQL")"

dxm_log "applying sql/metrics.sql (views + metric_catalog additions)"
dxm_sql_stdin < "$METRICS_SQL" >/dev/null || dxm_fail 2 "failed to apply sql/metrics.sql"

# The bucketing guard. sql/metrics.sql repeats schema.sql's bucket expressions
# once (created_at has no bucket columns in v_prs_enriched). These two checks
# make that duplication safe instead of merely documented.
PROP_BAD="$(dxm_sql1 "SELECT violations FROM v_bucket_property_check;")"
[ "${PROP_BAD:-1}" = "0" ] || dxm_fail 2 "week-bucket expression failed its property check (violations=$PROP_BAD) — refusing to produce a time series"
BUCK="$(dxm_sql1 "SELECT mismatches || '/' || rows_checked FROM v_bucket_expression_check;")"
BUCK_BAD="${BUCK%%/*}"; BUCK_ROWS="${BUCK##*/}"
[ "${BUCK_BAD:-1}" = "0" ] || dxm_fail 2 "bucket expressions in sql/metrics.sql disagree with schema.sql on $BUCK_BAD of $BUCK_ROWS rows — fix before aggregating"

# ---------------------------------------------------------------------------
# Scope resolution. Reads the DB only; aggregation never expands an org over
# the network, so it can run offline and stays comparable between runs.
# ---------------------------------------------------------------------------
FILTER="1=1"
if [ -n "$REPOS" ] || [ -n "$ORGS" ]; then
  FILTER="0=1"
  for r in $REPOS; do
    case "$r" in */*) ;; *) dxm_die "--repo must be owner/name; got: $r" 1 ;; esac
    FILTER="$FILTER OR full_name=$(dxm_q "$r")"
  done
  for o in $ORGS; do FILTER="$FILTER OR owner=$(dxm_q "$o")"; done
fi

# A repo named on the command line that was never ingested is a precondition
# failure, not an empty result: silently returning zero rows for a typo'd repo
# is exactly how a dashboard ends up understating a team.
for r in $REPOS; do
  n="$(dxm_sql1 "SELECT COUNT(*) FROM repos WHERE full_name=$(dxm_q "$r");")"
  [ "$n" = "1" ] || dxm_fail 2 "repo not in database (ingest it first): $r"
done

# A shallow clone has truncated history, so any series computed from it is
# confidently wrong. Naming one explicitly is a hard stop — the caller asked for
# that repo by name and must not receive a quietly empty answer. A shallow repo
# reached by expanding --org (or by aggregating everything) is instead excluded
# and disclosed, on every org row and in the envelope: one bad repo should not
# block the other nineteen, and an undisclosed exclusion is the actual sin.
SHALLOW_NAMED=0
for r in $REPOS; do
  s="$(dxm_sql1 "SELECT is_shallow FROM repos WHERE full_name=$(dxm_q "$r");")"
  if [ "$s" = "1" ]; then
    dxm_warn "refusing $r — shallow clone, or not yet verified non-shallow by the git ingest"
    SHALLOW_NAMED=$((SHALLOW_NAMED+1))
  fi
done
if [ "$SHALLOW_NAMED" -gt 0 ]; then
  dxm_run_finish "$RUN_ID" error 2 "shallow repos named explicitly"
  dxm_emit false "$SELF" "$RUN_ID" "\"error\":\"$SHALLOW_NAMED repo(s) named with --repo are shallow or not yet verified non-shallow; history is truncated so no time series is safe to compute. Run the git ingest first.\",\"shallow_repos\":$SHALLOW_NAMED"
  exit 2
fi

IDS="$(dxm_sql1 "SELECT COALESCE(group_concat(repo_id),'') FROM repos WHERE ($FILTER) AND is_shallow=0;")"
if [ -z "$IDS" ]; then
  dxm_run_finish "$RUN_ID" error 2 "no ingested repos matched"
  dxm_emit false "$SELF" "$RUN_ID" '"error":"no ingested, non-shallow repos matched the selection"'
  exit 2
fi
# quote() lets SQLite do the escaping, so no owner name can break out of a literal.
OWNERS="$(dxm_sql1 "SELECT COALESCE(group_concat(DISTINCT quote(owner)),'') FROM repos WHERE repo_id IN ($IDS);")"
N_REPOS="$(dxm_sql1 "SELECT COUNT(*) FROM repos WHERE repo_id IN ($IDS);")"
N_ORGS="$(dxm_sql1 "SELECT COUNT(DISTINCT owner) FROM repos WHERE repo_id IN ($IDS);")"
# Repos of the same owners that are shallow: excluded from the org rollup, and
# said so on every org row rather than quietly dropped.
ORG_SHALLOW="$(dxm_sql1 "SELECT COUNT(*) FROM repos WHERE owner IN ($OWNERS) AND is_shallow=1;")"

# ---------------------------------------------------------------------------
# Period arithmetic. All of it is done by SQLite, because BSD date(1) cannot do
# calendar maths and GNU date(1) does not exist on macOS.
# ---------------------------------------------------------------------------
case "$PK" in
  day)   BUMP="'+1 day'";   LOOKBACK="'-2 days'";   BUCKET_LABEL="day" ;;
  week)  BUMP="'+7 days'";  LOOKBACK="'-14 days'";  BUCKET_LABEL="week" ;;
  month) BUMP="'+1 month'"; LOOKBACK="'-2 months'"; BUCKET_LABEL="month" ;;
esac
snap() { # snap($1) -> the bucket start containing the date expression $1
  case "$PK" in
    day)   printf "date(%s)" "$1" ;;
    week)  printf "date(%s,'-6 days','weekday 1')" "$1" ;;
    month) printf "strftime('%%Y-%%m-01',%s)" "$1" ;;
  esac
}

TODAY="$(dxm_sql1 "SELECT date('now');")"
[ -n "$UNTIL" ] || UNTIL="$TODAY"
# Never bucket into the future. ( [[ ]] && x  as a bare statement would exit the
# script under set -e when the test is false — hence the explicit if. )
U="$UNTIL"; if [[ "$U" > "$TODAY" ]]; then U="$TODAY"; fi

# Full pass or incremental? Three things force a full pass: --rebuild, nothing
# aggregated yet, and an agg_version mismatch (a formula changed under us).
PRIOR="$(dxm_sql1 "SELECT COUNT(*) FROM agg_org_period WHERE period_kind=$(dxm_q "$PK") AND scope='repo' AND scope_key IN (SELECT full_name FROM repos WHERE repo_id IN ($IDS));")"
STALE="$(dxm_sql1 "SELECT COUNT(*) FROM agg_org_period WHERE period_kind=$(dxm_q "$PK") AND agg_version<>$(dxm_q "$AGGV") AND scope='repo' AND scope_key IN (SELECT full_name FROM repos WHERE repo_id IN ($IDS));")"
FULL=0
MODE="incremental"
if [ "$REBUILD" = "1" ]; then FULL=1; MODE="rebuild"
elif [ "${PRIOR:-0}" = "0" ]; then FULL=1; MODE="first-run"
elif [ "${STALE:-0}" -gt 0 ]; then FULL=1; MODE="version-change"; fi

if [ "$FULL" = "1" ]; then
  if [ -n "$SINCE" ]; then BASE="$SINCE"
  else
    BASE="$(dxm_sql1 "SELECT COALESCE(MIN(substr(first_commit_at,1,10)),
                                      (SELECT MIN(substr(authored_at,1,10)) FROM commits WHERE repo_id IN ($IDS)),
                                      date('now'))
                        FROM repos WHERE repo_id IN ($IDS);")"
  fi
else
  # Incremental floor = the earliest bucket that could possibly have changed:
  # anything ingested or re-classified since the last aggregation, and always
  # at least the last two buckets (their 'partial period' status moves with the
  # calendar even when no new data arrived).
  LASTAGG="$(dxm_sql1 "SELECT COALESCE(MAX(computed_at),'0000') FROM agg_org_period WHERE period_kind=$(dxm_q "$PK") AND scope='repo' AND scope_key IN (SELECT full_name FROM repos WHERE repo_id IN ($IDS));")"
  MAXP="$(dxm_sql1 "SELECT COALESCE(MAX(period_start),date('now')) FROM agg_org_period WHERE period_kind=$(dxm_q "$PK") AND scope='repo' AND scope_key IN (SELECT full_name FROM repos WHERE repo_id IN ($IDS));")"
  BASE="$(dxm_sql1 "
    SELECT MIN(d) FROM (
      SELECT date($(dxm_q "$MAXP"), $LOOKBACK) AS d
      UNION ALL SELECT MIN(substr(authored_at,1,10)) FROM commits
                 WHERE repo_id IN ($IDS) AND ingested_at >= $(dxm_q "$LASTAGG")
      UNION ALL SELECT MIN(substr(COALESCE(merged_at,created_at),1,10)) FROM pull_requests
                 WHERE repo_id IN ($IDS) AND ingested_at >= $(dxm_q "$LASTAGG")
      UNION ALL SELECT MIN(substr(created_at,1,10)) FROM pull_requests
                 WHERE repo_id IN ($IDS) AND ingested_at >= $(dxm_q "$LASTAGG")
      UNION ALL SELECT MIN(substr(COALESCE(p.merged_at,p.created_at),1,10)) FROM pr_classifications c
                 JOIN pull_requests p ON p.pr_id=c.pr_id
                 WHERE p.repo_id IN ($IDS) AND c.classified_at >= $(dxm_q "$LASTAGG")
    ) WHERE d IS NOT NULL;")"
  [ -n "$BASE" ] || BASE="$MAXP"
fi
W="$(dxm_sql1 "SELECT $(snap "$(dxm_q "$BASE")");")"
[ -n "$W" ] || dxm_fail 4 "could not resolve a window start from base date '$BASE'"
if [[ "$W" > "$U" ]]; then W="$(dxm_sql1 "SELECT $(snap "$(dxm_q "$U")");")"; fi

dxm_log "scope: $N_REPOS repo(s), $N_ORGS org(s) | period=$PK | window $W..$U | mode=$MODE | agg_version=$AGGV"

# ---------------------------------------------------------------------------
# SQL generation.
#
# Everything below is written to one file and executed by ONE sqlite3 process
# inside ONE transaction, for three reasons: TEMP tables survive across
# statements only within a connection; a half-written aggregate is worse than
# none; and --dry-run is then just ROLLBACK instead of COMMIT.
# ---------------------------------------------------------------------------
SQLF="$(mktemp "${TMPDIR:-/tmp}/dxm-agg.XXXXXX")"
trap 'rm -f "$SQLF"; dxm_run_trap '"$RUN_ID"' $?' EXIT

QPK="$(dxm_q "$PK")"; QW="$(dxm_q "$W")"; QU="$(dxm_q "$U")"; QAGGV="$(dxm_q "$AGGV")"

# 'partial period' for a bucket whose end runs past the analysis ceiling.
# CONTRACT.md §13: the current incomplete bucket must be marked, because a
# half-finished week that looks like a decline is how this class of dashboard
# lies. Composite notes keep 'partial period' as a PREFIX — match it with
# LIKE 'partial period%'.
partial_expr() { printf "CASE WHEN date(%s.period_start, %s) > date(%s,'+1 day') THEN 'partial period' END" "$1" "$BUMP" "$QU"; }

# An org rollup that silently drops a repo with truncated history is a lie of
# omission. When one exists, every org-scoped row says so in its own note.
org_caveat_expr() {
  if [ "${ORG_SHALLOW:-0}" -gt 0 ]; then
    printf "CASE WHEN %s.scope='org' THEN 'org rollup excludes %s repo(s) whose history is truncated' END" "$1" "$ORG_SHALLOW"
  else
    printf 'NULL'
  fi
}

# note = 'partial period' marker first (renderers match LIKE 'partial period%'),
# then the bucket-specific caveat, then the org caveat, '; '-joined, NULL if all
# three are absent.
_cat2() { # _cat2 <a> <b> -> SQL expression joining two nullable notes with '; '
  printf "NULLIF(TRIM(COALESCE((%s),'') || CASE WHEN (%s) IS NOT NULL AND (%s) IS NOT NULL THEN '; ' ELSE '' END || COALESCE((%s),'')),'')" \
    "$1" "$1" "$2" "$2"
}
# note_expr <table-alias> <extra-note-sql>
note_expr() { _cat2 "$(_cat2 "$(partial_expr "$1")" "$2")" "$(org_caveat_expr "$1")"; }

COV_MAP=""   # accumulated INSERTs into _cov_map, one per metric emitted
add_cov() { COV_MAP="$COV_MAP
INSERT OR REPLACE INTO _cov_map(metric_key,method,detail) VALUES($(dxm_q "$1"),$(dxm_q "$2"),$(dxm_q "$3"));"; }

# add_metric <key> <value> <numerator> <denominator> <sample> <extra-note> <coverage-detail>
add_metric() {
  local key="$1" val="$2" num="$3" den="$4" samp="$5" extra="$6" cov="$7"
  cat >>"$SQLF" <<SQL
INSERT INTO agg_metric(metric_key,scope,scope_key,period_kind,period_start,value,numerator,denominator,sample_size,note,agg_version)
SELECT $(dxm_q "$key"), a.scope, a.scope_key, a.period_kind, a.period_start,
       $val, $num, $den, $samp,
       $(note_expr a "$extra"),
       $QAGGV
  FROM agg_org_period a
  LEFT JOIN _agg_pr     pu ON pu.scope=a.scope AND pu.scope_key=a.scope_key AND pu.period_start=a.period_start
  LEFT JOIN _ctp        ct ON ct.scope=a.scope AND ct.scope_key=a.scope_key AND ct.period_start=a.period_start
  LEFT JOIN _agg_cm      g ON  g.scope=a.scope AND  g.scope_key=a.scope_key AND  g.period_start=a.period_start
  LEFT JOIN _bf         bf ON bf.scope=a.scope AND bf.scope_key=a.scope_key AND bf.period_start=a.period_start
  LEFT JOIN _adopt_bucket ab ON ab.scope=a.scope AND ab.scope_key=a.scope_key AND ab.period_start=a.period_start
  LEFT JOIN _agent_top   at ON at.scope=a.scope AND at.scope_key=a.scope_key AND at.period_start=a.period_start
 WHERE a.period_kind=$QPK AND a.period_start BETWEEN $QW AND $QU
   AND (a.scope,a.scope_key) IN (SELECT scope,scope_key FROM _scope_keys);
SQL
  add_cov "$key" script "$cov"
}

# --- shared note fragments -------------------------------------------------
N_UNCLASSIFIED="CASE WHEN a.prs_unclassified > 0 THEN a.prs_unclassified || ' of ' || a.prs_merged || ' merged PRs are unclassified and are excluded from the denominator' END"
N_NOCYCLE="CASE WHEN a.prs_merged - COALESCE(ct.n,0) > 0 THEN (a.prs_merged - COALESCE(ct.n,0)) || ' of ' || a.prs_merged || ' merged PRs have no first-commit timestamp and are excluded' END"

# ===========================================================================
# Part 1 — working sets
# ===========================================================================
cat >"$SQLF" <<SQL
-- generated by $SELF; agg_version=$AGGV; do not edit
PRAGMA foreign_keys=ON;
BEGIN IMMEDIATE;

CREATE TEMP TABLE _scope(scope TEXT, scope_key TEXT, repo_id INTEGER);
INSERT INTO _scope SELECT 'repo', full_name, repo_id FROM repos WHERE repo_id IN ($IDS);
INSERT INTO _scope SELECT 'org',  owner,     repo_id FROM repos WHERE owner IN ($OWNERS) AND is_shallow=0;
CREATE INDEX _scope_ix ON _scope(repo_id);
CREATE TEMP TABLE _scope_keys AS SELECT DISTINCT scope, scope_key FROM _scope;

-- ---- materialise the read surface ONCE ------------------------------------
-- The views are cheap to scan once and ruinous to scan per contributor: the
-- adoption maths asks "this person's commits either side of date X" for every
-- contributor, and against a view that is a three-way UNION with a correlated
-- EXISTS for AI attribution, that is a full rescan each time. Materialising
-- both fact tables here, indexed, turns the adoption section from quadratic
-- into index lookups. Only the two period kinds actually needed are kept:
-- the run's own granularity, and 'day' (which yields each underlying row
-- exactly once, for the history-wide adoption questions).
CREATE TEMP TABLE _cf AS
  SELECT s.scope, s.scope_key, c.period_kind, c.period_start, c.repo_id,
         c.commit_id, c.sha, c.authored_at, c.author_identity_id,
         c.is_ai_assisted, c.is_unattributed, c.is_merge,
         c.steerer_state, c.executor_state,
         COALESCE(c.insertions,0) AS insertions, COALESCE(c.deletions,0) AS deletions,
         COALESCE(c.files_changed,0) AS files_changed
    FROM v_commits_bucketed c JOIN _scope s ON s.repo_id = c.repo_id
   WHERE c.period_kind IN ('day', $QPK);
CREATE INDEX _cf_ix1 ON _cf(period_kind, scope, scope_key, period_start);
CREATE INDEX _cf_ix2 ON _cf(period_kind, scope, scope_key, author_identity_id, authored_at);

CREATE TEMP TABLE _prf AS
  SELECT s.scope, s.scope_key, p.period_kind, p.period_start, p.pr_id, p.repo_id,
         p.author_identity_id, p.merged_at, p.cycle_time_hours,
         p.class, p.is_revert, p.class_method, p.is_ai_assisted,
         p.steerer_state, p.executor_state,
         COALESCE(p.additions,0) AS additions, COALESCE(p.deletions,0) AS deletions
    FROM v_prs_bucketed p JOIN _scope s ON s.repo_id = p.repo_id
   WHERE p.period_kind IN ('day', $QPK);
CREATE INDEX _prf_ix1 ON _prf(period_kind, scope, scope_key, period_start);
CREATE INDEX _prf_ix2 ON _prf(period_kind, scope, scope_key, author_identity_id, merged_at);

-- Merged PRs in scope and window. v_prs_bucketed has already applied
-- 'merged means state=MERGED and merged_at is not null', bot exclusion and the
-- shallow-repo exclusion, so none of that is re-implemented here.
CREATE TEMP TABLE _pr AS
  SELECT scope, scope_key, period_start, pr_id, repo_id,
         author_identity_id, merged_at, cycle_time_hours,
         class, is_revert, class_method, is_ai_assisted,
         steerer_state, executor_state, additions, deletions
    FROM _prf
   WHERE period_kind=$QPK
     AND period_start BETWEEN $QW AND $QU
     AND substr(merged_at,1,10) <= $QU;
CREATE INDEX _pr_ix ON _pr(scope, scope_key, period_start);

-- PRs opened, on the created_at axis.
CREATE TEMP TABLE _pro AS
  SELECT s.scope, s.scope_key, o.period_start, o.pr_id, o.repo_id, o.author_identity_id
    FROM v_prs_opened_bucketed o JOIN _scope s ON s.repo_id = o.repo_id
   WHERE o.period_kind=$QPK
     AND o.period_start BETWEEN $QW AND $QU
     AND substr(o.created_at,1,10) <= $QU;
CREATE INDEX _pro_ix ON _pro(scope, scope_key, period_start);

-- Non-merge commits. Merge commits are excluded from counts and from authorship
-- attribution (CONTRACT.md §13); they are counted once, separately, for the
-- envelope, so the exclusion is visible rather than silent.
CREATE TEMP TABLE _cm AS
  SELECT scope, scope_key, period_start, commit_id, repo_id, sha,
         author_identity_id, is_ai_assisted, is_unattributed,
         steerer_state, executor_state,
         insertions, deletions, files_changed
    FROM _cf
   WHERE period_kind=$QPK
     AND period_start BETWEEN $QW AND $QU
     AND is_merge=0
     AND substr(authored_at,1,10) <= $QU;
CREATE INDEX _cm_ix ON _cm(scope, scope_key, period_start);

-- ---- bucket-level rollups -------------------------------------------------
CREATE TEMP TABLE _agg_pr AS
  SELECT scope, scope_key, period_start,
         COUNT(*)                                    AS prs_merged,
         COUNT(DISTINCT author_identity_id)          AS active_contributors,
         SUM(is_ai_assisted)                         AS ai_prs_merged,
         SUM(class='bugfix')                         AS prs_bugfix,
         SUM(class='feature')                        AS prs_feature,
         SUM(is_revert=1)                            AS prs_revert,
         SUM(class='unclassified')                   AS prs_unclassified,
         SUM(class<>'unclassified')                  AS prs_classified,
         SUM(COALESCE(class_method,'')='llm')        AS prs_class_llm,
         SUM(COALESCE(class_method,'') IN ('llm','script-with-fallback')) AS prs_class_weak,
         SUM(author_identity_id IS NULL)             AS prs_unattributed,
         -- attribution pair, on the PR axis
         SUM(steerer_state='known')                  AS prs_known_steerer,
         SUM(steerer_state='unknown')                AS prs_unknown_steerer,
         SUM(steerer_state='known' AND is_ai_assisted=1) AS ai_prs_known_steerer,
         COUNT(DISTINCT CASE WHEN steerer_state='known' THEN author_identity_id END) AS pr_steerers,
         SUM(additions) AS additions, SUM(deletions) AS deletions
    FROM _pr GROUP BY 1,2,3;

CREATE TEMP TABLE _agg_pro AS
  SELECT scope, scope_key, period_start, COUNT(*) AS prs_opened FROM _pro GROUP BY 1,2,3;

-- The attribution pair, counted per bucket. Both axes are counted separately
-- and NEITHER is inferred from the other:
--   steerer_state  'known' | 'unknown'  ('machine' never reaches _cm)
--   executor_state 'agent' | 'unknown'  -- 'unknown' is NOT 'human'
CREATE TEMP TABLE _agg_cm AS
  SELECT scope, scope_key, period_start,
         COUNT(*) AS commits, SUM(is_ai_assisted) AS ai_commits,
         SUM(is_unattributed) AS unattributed_commits,
         SUM(steerer_state='known')   AS commits_known_steerer,
         SUM(steerer_state='unknown') AS commits_unknown_steerer,
         SUM(executor_state='agent')   AS commits_agent_executor,
         SUM(executor_state='unknown') AS commits_unknown_executor,
         SUM(steerer_state='known' AND executor_state='agent') AS ai_commits_known_steerer,
         COUNT(DISTINCT CASE WHEN steerer_state='known' THEN author_identity_id END) AS steerers,
         SUM(insertions) AS insertions, SUM(deletions) AS deletions
    FROM _cm GROUP BY 1,2,3;

-- Cycle-time percentiles. SQLite has no percentile(); nearest-rank via
-- ROW_NUMBER is exact and needs no extension. p50 averages the two middle
-- values on an even count; p75 is nearest-rank ceil(0.75n) in integer maths.
CREATE TEMP TABLE _ct_rank AS
  SELECT scope, scope_key, period_start, cycle_time_hours AS v,
         ROW_NUMBER() OVER (PARTITION BY scope,scope_key,period_start ORDER BY cycle_time_hours) AS rn,
         COUNT(*)     OVER (PARTITION BY scope,scope_key,period_start) AS n
    FROM _pr WHERE cycle_time_hours IS NOT NULL;
CREATE TEMP TABLE _ctp AS
  SELECT scope, scope_key, period_start,
         AVG(CASE WHEN rn IN ((n+1)/2,(n+2)/2)       THEN v END) AS p50,
         AVG(CASE WHEN rn = max(1,(n*75+99)/100)     THEN v END) AS p75,
         MAX(n) AS n
    FROM _ct_rank GROUP BY 1,2,3;

-- Concentration risk. bus_factor = how many contributors it takes to cover half
-- the commits in the bucket; top_share = the largest single contributor's share.
CREATE TEMP TABLE _bf_rank AS
  WITH per_author AS (
    SELECT scope, scope_key, period_start, author_identity_id, COUNT(*) AS n
      FROM _cm WHERE author_identity_id IS NOT NULL GROUP BY 1,2,3,4)
  SELECT scope, scope_key, period_start, n,
         SUM(n) OVER (PARTITION BY scope,scope_key,period_start
                      ORDER BY n DESC, author_identity_id
                      ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS cum,
         SUM(n) OVER (PARTITION BY scope,scope_key,period_start)         AS tot,
         ROW_NUMBER() OVER (PARTITION BY scope,scope_key,period_start
                            ORDER BY n DESC, author_identity_id)          AS rk
    FROM per_author;
CREATE TEMP TABLE _bf AS
  SELECT scope, scope_key, period_start,
         MIN(CASE WHEN cum*2 >= tot THEN rk END)        AS bus_factor,
         MAX(CASE WHEN rk=1 THEN 100.0*n/tot END)       AS top_share,
         MAX(tot)                                       AS total_commits
    FROM _bf_rank GROUP BY 1,2,3;

-- Per-agent AI commit counts. A commit crediting two agents counts once for
-- each, so agent shares can sum above 100%. Said so on every row.
CREATE TEMP TABLE _agent AS
  SELECT x.scope, x.scope_key, x.period_start, x.agent_key,
         COUNT(DISTINCT x.commit_id) AS n, MAX(g.ai_commits) AS total_ai
    FROM (SELECT c.scope, c.scope_key, c.period_start, t.agent_key, c.commit_id
            FROM _cm c JOIN ai_trailers t
              ON t.repo_id=c.repo_id AND t.sha=c.sha AND t.is_ai=1
           WHERE t.agent_key IS NOT NULL) x
    JOIN _agg_cm g ON g.scope=x.scope AND g.scope_key=x.scope_key AND g.period_start=x.period_start
   GROUP BY 1,2,3,4;
CREATE INDEX _agent_ix ON _agent(scope, scope_key, period_start);
CREATE TEMP TABLE _agent_top AS
  SELECT t.scope, t.scope_key, t.period_start, t.agent_key, t.n, t.total_ai,
         (SELECT label FROM ai_agents a2 WHERE a2.agent_key=t.agent_key) AS label
    FROM _agent t
   WHERE t.n = (SELECT MAX(t2.n) FROM _agent t2
                 WHERE t2.scope=t.scope AND t2.scope_key=t.scope_key AND t2.period_start=t.period_start)
   GROUP BY t.scope, t.scope_key, t.period_start;

-- Classification quality per scope: drives the coverage method of the metrics
-- that depend on the classifier (defect ratio, revert rate, innovation ratio).
CREATE TEMP TABLE _clsq AS
  SELECT scope, scope_key, COUNT(*) AS total,
         SUM(class<>'unclassified') AS classified,
         SUM(COALESCE(class_method,'')='llm') AS n_llm,
         SUM(COALESCE(class_method,'') IN ('llm','script-with-fallback')) AS n_weak
    FROM _pr GROUP BY 1,2;

-- ---- AI adoption, per contributor ----------------------------------------
-- Everyone who has ever committed or merged a PR in each scope, over ALL of
-- history rather than the window: adoption timing is a property of a person,
-- not of the reporting window. period_kind='day' is used purely to take each
-- underlying row exactly once out of the three-way pivot.
CREATE TEMP TABLE _actors AS
  SELECT DISTINCT scope, scope_key, author_identity_id AS identity_id
    FROM _cf
   WHERE period_kind='day' AND is_merge=0 AND author_identity_id IS NOT NULL
  UNION
  SELECT DISTINCT scope, scope_key, author_identity_id
    FROM _prf
   WHERE period_kind='day' AND author_identity_id IS NOT NULL;

CREATE TEMP TABLE _fa AS
  SELECT scope, scope_key, author_identity_id AS identity_id,
         MIN(authored_at) AS first_ai_at
    FROM _cf
   WHERE period_kind='day' AND is_merge=0 AND is_ai_assisted=1
     AND author_identity_id IS NOT NULL
   GROUP BY 1,2,3;

CREATE TEMP TABLE _first_ai AS
  SELECT a.scope, a.scope_key, a.identity_id, f.first_ai_at
    FROM _actors a
    LEFT JOIN _fa f ON f.scope=a.scope AND f.scope_key=a.scope_key AND f.identity_id=a.identity_id;
CREATE INDEX _first_ai_ix ON _first_ai(scope, scope_key, identity_id);

-- Before/after windows. Timestamps are rebuilt with strftime in the stored
-- 'YYYY-MM-DDTHH:MM:SSZ' shape: datetime() returns a space-separated form that
-- would compare wrong against the column as a string.
CREATE TEMP TABLE _ba AS
  SELECT f.scope, f.scope_key, f.identity_id, f.first_ai_at,
         CASE WHEN date(f.first_ai_at, '+$ADOPT_WIN days') <= $QU THEN 1 ELSE 0 END AS mature,
         (SELECT t.agent_key FROM _cf vc
            JOIN ai_trailers t ON t.repo_id=vc.repo_id AND t.sha=vc.sha AND t.is_ai=1 AND t.agent_key IS NOT NULL
           WHERE vc.period_kind='day' AND vc.scope=f.scope AND vc.scope_key=f.scope_key
             AND vc.author_identity_id=f.identity_id AND vc.authored_at=f.first_ai_at
           ORDER BY t.agent_key LIMIT 1) AS first_agent_key,
         (SELECT COUNT(*) FROM _cf c
           WHERE c.period_kind='day' AND c.scope=f.scope AND c.scope_key=f.scope_key
             AND c.is_merge=0 AND c.author_identity_id=f.identity_id
             AND c.authored_at >= strftime('%Y-%m-%dT%H:%M:%SZ', f.first_ai_at, '-$ADOPT_WIN days')
             AND c.authored_at <  f.first_ai_at) AS commits_before,
         (SELECT COUNT(*) FROM _cf c
           WHERE c.period_kind='day' AND c.scope=f.scope AND c.scope_key=f.scope_key
             AND c.is_merge=0 AND c.author_identity_id=f.identity_id
             AND c.authored_at >= f.first_ai_at
             AND c.authored_at <  strftime('%Y-%m-%dT%H:%M:%SZ', f.first_ai_at, '+$ADOPT_WIN days')) AS commits_after
    FROM _first_ai f WHERE f.first_ai_at IS NOT NULL;

-- Cycle time either side of the first trailer, per contributor.
CREATE TEMP TABLE _pa AS
  SELECT b.scope, b.scope_key, b.identity_id,
         CASE WHEN p.merged_at < b.first_ai_at THEN 0 ELSE 1 END AS phase,
         p.cycle_time_hours AS v
    FROM _ba b
    JOIN _prf p
      ON p.period_kind='day' AND p.scope=b.scope AND p.scope_key=b.scope_key
     AND p.author_identity_id=b.identity_id
     AND p.cycle_time_hours IS NOT NULL
     AND p.merged_at >= strftime('%Y-%m-%dT%H:%M:%SZ', b.first_ai_at, '-$ADOPT_WIN days')
     AND p.merged_at <  strftime('%Y-%m-%dT%H:%M:%SZ', b.first_ai_at, '+$ADOPT_WIN days')
   WHERE b.mature=1;
CREATE TEMP TABLE _pa_rank AS
  SELECT scope, scope_key, identity_id, phase, v,
         ROW_NUMBER() OVER (PARTITION BY scope,scope_key,identity_id,phase ORDER BY v) AS rn,
         COUNT(*)     OVER (PARTITION BY scope,scope_key,identity_id,phase) AS n
    FROM _pa;
CREATE TEMP TABLE _pa_med AS
  SELECT scope, scope_key, identity_id, phase,
         AVG(CASE WHEN rn IN ((n+1)/2,(n+2)/2) THEN v END) AS med, MAX(n) AS n
    FROM _pa_rank GROUP BY 1,2,3,4;
CREATE TEMP TABLE _ct_delta AS
  SELECT bef.scope, bef.scope_key, bef.identity_id,
         100.0*(aft.med - bef.med)/bef.med AS pct
    FROM _pa_med bef
    JOIN _pa_med aft ON aft.scope=bef.scope AND aft.scope_key=bef.scope_key
                    AND aft.identity_id=bef.identity_id AND aft.phase=1
   WHERE bef.phase=0 AND bef.med > 0
     AND bef.n >= $MIN_PRS_PER_PHASE AND aft.n >= $MIN_PRS_PER_PHASE;
CREATE TEMP TABLE _ct_delta_rank AS
  SELECT scope, scope_key, pct,
         ROW_NUMBER() OVER (PARTITION BY scope,scope_key ORDER BY pct) AS rn,
         COUNT(*)     OVER (PARTITION BY scope,scope_key) AS n
    FROM _ct_delta;
CREATE TEMP TABLE _cv_delta AS
  SELECT scope, scope_key, identity_id,
         100.0*(commits_after - commits_before)/commits_before AS pct
    FROM _ba WHERE mature=1 AND commits_before > 0;
CREATE TEMP TABLE _cv_delta_rank AS
  SELECT scope, scope_key, pct,
         ROW_NUMBER() OVER (PARTITION BY scope,scope_key ORDER BY pct) AS rn,
         COUNT(*)     OVER (PARTITION BY scope,scope_key) AS n
    FROM _cv_delta;

-- ---- the dense bucket spine ----------------------------------------------
-- Every bucket in the window gets a row even when nothing happened in it. A
-- missing week and a zero week look identical in a line chart otherwise, and
-- only one of them is true.
CREATE TEMP TABLE _spine AS
  WITH RECURSIVE b(p) AS (
    SELECT $(snap "$QW")
    UNION ALL SELECT date(p, $BUMP) FROM b WHERE date(p, $BUMP) <= $QU
  )
  SELECT k.scope, k.scope_key, b.p AS period_start FROM _scope_keys k, b;
CREATE INDEX _spine_ix ON _spine(scope, scope_key, period_start);

-- Adopters per bucket: cumulative (ever adopted by the end of this bucket) and
-- active (contributors who merged a PR in this bucket and had already adopted).
CREATE TEMP TABLE _adopt_bucket AS
  SELECT s.scope, s.scope_key, s.period_start,
         (SELECT COUNT(*) FROM _first_ai f
           WHERE f.scope=s.scope AND f.scope_key=s.scope_key AND f.first_ai_at IS NOT NULL
             AND substr(f.first_ai_at,1,10) <= date(s.period_start, $BUMP, '-1 day')) AS adopters_cum,
         (SELECT COUNT(DISTINCT p.author_identity_id) FROM _pr p
            JOIN _first_ai f ON f.scope=p.scope AND f.scope_key=p.scope_key
                            AND f.identity_id=p.author_identity_id
           WHERE p.scope=s.scope AND p.scope_key=s.scope_key AND p.period_start=s.period_start
             AND f.first_ai_at IS NOT NULL AND f.first_ai_at <= p.merged_at) AS adopters_active
    FROM _spine s;

-- ===========================================================================
-- Part 2 — clear the window, then write the aggregates
-- ===========================================================================
DELETE FROM agg_org_period
 WHERE period_kind=$QPK AND period_start BETWEEN $QW AND $QU
   AND (scope,scope_key) IN (SELECT scope,scope_key FROM _scope_keys);
DELETE FROM agg_author_period
 WHERE period_kind=$QPK AND period_start BETWEEN $QW AND $QU
   AND repo_id IN (SELECT repo_id FROM _scope WHERE scope='repo');
DELETE FROM agg_metric
 WHERE (scope,scope_key) IN (SELECT scope,scope_key FROM _scope_keys)
   AND ((period_kind=$QPK AND period_start BETWEEN $QW AND $QU) OR period_kind='all');
DELETE FROM agg_adoption_timeline
 WHERE (scope,scope_key) IN (SELECT scope,scope_key FROM _scope_keys);

INSERT INTO agg_org_period
  (scope,scope_key,period_kind,period_start,active_contributors,commits,ai_commits,
   prs_opened,prs_merged,ai_prs_merged,prs_bugfix,prs_feature,prs_revert,prs_unclassified,
   cycle_time_p50_h,cycle_time_p75_h,insertions,deletions,agg_version)
SELECT s.scope, s.scope_key, $QPK, s.period_start,
       COALESCE(pr.active_contributors,0), COALESCE(cm.commits,0), COALESCE(cm.ai_commits,0),
       COALESCE(po.prs_opened,0), COALESCE(pr.prs_merged,0), COALESCE(pr.ai_prs_merged,0),
       COALESCE(pr.prs_bugfix,0), COALESCE(pr.prs_feature,0), COALESCE(pr.prs_revert,0),
       COALESCE(pr.prs_unclassified,0),
       ct.p50, ct.p75,
       COALESCE(cm.insertions,0), COALESCE(cm.deletions,0), $QAGGV
  FROM _spine s
  LEFT JOIN _agg_pr  pr ON pr.scope=s.scope AND pr.scope_key=s.scope_key AND pr.period_start=s.period_start
  LEFT JOIN _agg_pro po ON po.scope=s.scope AND po.scope_key=s.scope_key AND po.period_start=s.period_start
  LEFT JOIN _agg_cm  cm ON cm.scope=s.scope AND cm.scope_key=s.scope_key AND cm.period_start=s.period_start
  LEFT JOIN _ctp     ct ON ct.scope=s.scope AND ct.scope_key=s.scope_key AND ct.period_start=s.period_start;

-- Per-author, per-repo. Exists so that concentration risk and adoption timing
-- are answerable (CONTRACT.md §8.4). It is not a throughput leaderboard and
-- there is no code path in this skill that renders it as one.
-- Grouped once per source and joined, rather than a correlated subquery per
-- column: there is one key row per (person, repo, bucket), so the subquery form
-- costs a full scan of the commit set for every cell and does not survive a
-- real repo.
CREATE TEMP TABLE _ap_cm AS
  SELECT repo_id, author_identity_id AS identity_id, period_start,
         COUNT(*) AS commits, SUM(is_ai_assisted) AS ai_commits,
         SUM(insertions) AS insertions, SUM(deletions) AS deletions,
         SUM(files_changed) AS files_touched
    FROM _cm WHERE scope='repo' AND author_identity_id IS NOT NULL GROUP BY 1,2,3;
CREATE UNIQUE INDEX _ap_cm_ix ON _ap_cm(repo_id, identity_id, period_start);

CREATE TEMP TABLE _ap_pr AS
  SELECT repo_id, author_identity_id AS identity_id, period_start,
         COUNT(*) AS prs_merged, SUM(is_ai_assisted) AS ai_prs_merged
    FROM _pr WHERE scope='repo' AND author_identity_id IS NOT NULL GROUP BY 1,2,3;
CREATE UNIQUE INDEX _ap_pr_ix ON _ap_pr(repo_id, identity_id, period_start);

CREATE TEMP TABLE _ap_pro AS
  SELECT repo_id, author_identity_id AS identity_id, period_start, COUNT(*) AS prs_opened
    FROM _pro WHERE scope='repo' AND author_identity_id IS NOT NULL GROUP BY 1,2,3;
CREATE UNIQUE INDEX _ap_pro_ix ON _ap_pro(repo_id, identity_id, period_start);

CREATE TEMP TABLE _ap_keys AS
  SELECT identity_id, repo_id, period_start FROM _ap_cm
  UNION SELECT identity_id, repo_id, period_start FROM _ap_pr
  UNION SELECT identity_id, repo_id, period_start FROM _ap_pro;

INSERT INTO agg_author_period
  (identity_id,repo_id,period_kind,period_start,commits,ai_commits,prs_opened,prs_merged,
   ai_prs_merged,insertions,deletions,files_touched,agg_version)
SELECT k.identity_id, k.repo_id, $QPK, k.period_start,
       COALESCE(c.commits,0), COALESCE(c.ai_commits,0),
       COALESCE(o.prs_opened,0), COALESCE(p.prs_merged,0), COALESCE(p.ai_prs_merged,0),
       COALESCE(c.insertions,0), COALESCE(c.deletions,0),
       -- sum of per-commit file counts, NOT distinct files: paths are not ingested
       COALESCE(c.files_touched,0),
       $QAGGV
  FROM _ap_keys k
  LEFT JOIN _ap_cm  c ON c.repo_id=k.repo_id AND c.identity_id=k.identity_id AND c.period_start=k.period_start
  LEFT JOIN _ap_pr  p ON p.repo_id=k.repo_id AND p.identity_id=k.identity_id AND p.period_start=k.period_start
  LEFT JOIN _ap_pro o ON o.repo_id=k.repo_id AND o.identity_id=k.identity_id AND o.period_start=k.period_start;

-- Adoption timing, per contributor per scope. Non-adopters get a row with NULL
-- first_ai_trailer_at: "we looked and there is nothing" is information, and an
-- absent row is indistinguishable from a person we never saw.
INSERT INTO agg_adoption_timeline
  (identity_id,scope,scope_key,first_ai_trailer_at,first_agent_key,commits_before,commits_after,window_days,agg_version)
SELECT f.identity_id, f.scope, f.scope_key, f.first_ai_at,
       b.first_agent_key,
       CASE WHEN b.mature=1 THEN b.commits_before END,
       CASE WHEN b.mature=1 THEN b.commits_after  END,
       $ADOPT_WIN, $QAGGV
  FROM _first_ai f
  LEFT JOIN _ba b ON b.scope=f.scope AND b.scope_key=f.scope_key AND b.identity_id=f.identity_id;

-- Coverage bookkeeping for the metrics written below. Populated by the shell
-- so that each metric declares, next to its formula, how it was decided.
CREATE TEMP TABLE _cov_map(metric_key TEXT PRIMARY KEY, method TEXT, detail TEXT);
SQL

# ===========================================================================
# Part 3 — the metrics
# ===========================================================================

# ---- Speed ---------------------------------------------------------------
add_metric 'speed.active_contributors' \
  'a.active_contributors' 'a.active_contributors' 'NULL' 'a.prs_merged' \
  "CASE WHEN COALESCE(pu.prs_unattributed,0) > 0 THEN COALESCE(pu.prs_unattributed,0) || ' merged PR(s) in this bucket have an author GitHub could not resolve and are not counted as a contributor' END" \
  'distinct non-bot PR authors with >=1 merged PR in the bucket'

add_metric 'speed.prs_merged' \
  'a.prs_merged' 'a.prs_merged' 'NULL' 'a.prs_merged' 'NULL' \
  'count of state=MERGED PRs bucketed on merged_at'

add_metric 'speed.prs_opened' \
  'a.prs_opened' 'a.prs_opened' 'NULL' 'a.prs_opened' 'NULL' \
  'count of PRs bucketed on created_at'

if [ "$PK" = "week" ]; then
  add_metric 'speed.pr_throughput_per_contributor_week' \
    'CASE WHEN a.active_contributors>0 THEN 1.0*a.prs_merged/a.active_contributors END' \
    'a.prs_merged' 'NULLIF(a.active_contributors,0)' 'a.prs_merged' 'NULL' \
    'merged PRs / distinct merged-PR authors, per calendar week'
else
  dxm_log "note: speed.pr_throughput_per_contributor_week is defined per week and is skipped for --period $PK (speed.prs_merged is emitted instead)"
fi

add_metric 'speed.cycle_time_first_commit_to_merge_p50' \
  'ct.p50' 'NULL' 'ct.n' 'a.prs_merged' "$N_NOCYCLE" \
  'nearest-rank median of merged_at - first_commit_at over merged PRs in the bucket'

add_metric 'speed.cycle_time_first_commit_to_merge_p75' \
  'ct.p75' 'NULL' 'ct.n' 'a.prs_merged' "$N_NOCYCLE" \
  'nearest-rank 75th percentile of merged_at - first_commit_at'

# ---- Quality -------------------------------------------------------------
add_metric 'quality.defect_ratio' \
  '100.0*a.prs_bugfix/NULLIF(a.prs_merged - a.prs_unclassified,0)' \
  'a.prs_bugfix' 'NULLIF(a.prs_merged - a.prs_unclassified,0)' 'a.prs_merged' "$N_UNCLASSIFIED" \
  'bugfix-classified merged PRs / classified merged PRs'

add_metric 'quality.revert_rate' \
  '100.0*a.prs_revert/NULLIF(a.prs_merged - a.prs_unclassified,0)' \
  'a.prs_revert' 'NULLIF(a.prs_merged - a.prs_unclassified,0)' 'a.prs_merged' "$N_UNCLASSIFIED" \
  'PRs flagged is_revert / classified merged PRs'

# ---- Impact --------------------------------------------------------------
add_metric 'impact.innovation_ratio' \
  '100.0*a.prs_feature/NULLIF(a.prs_merged - a.prs_unclassified,0)' \
  'a.prs_feature' 'NULLIF(a.prs_merged - a.prs_unclassified,0)' 'a.prs_merged' "$N_UNCLASSIFIED" \
  'feature-classified merged PRs / classified merged PRs'

# ---- Effectiveness -------------------------------------------------------
# CONTRACT.md §9: DXI is computable=0. A row is written for every bucket with a
# NULL value and the reason, so the dashboard renders an explicit "unavailable"
# instead of quietly having no Effectiveness pillar at all.
add_metric 'effectiveness.dxi' \
  'NULL' 'NULL' 'NULL' 'NULL' \
  "'UNAVAILABLE — DXI is a survey instrument and cannot be derived from git or the GitHub API. Run the survey or leave this empty; any number here would be fabricated.'" \
  'declared unavailable: metric_catalog.computable=0 (survey-only instrument)'

# ---- Leverage ------------------------------------------------------------
# The number that answers "what do we get per seat" on an agentic team. The
# numerator is restricted to executions with a KNOWN steerer so it cannot be
# inflated by machine output that nobody can attribute; that makes it a floor,
# and the note says so with the exact count that was left out.
N_LEV_GAP="CASE WHEN COALESCE(g.commits_unknown_steerer,0) > 0
                THEN COALESCE(g.commits_unknown_steerer,0) || ' of ' || a.commits ||
                     ' executions in this bucket have no identifiable steerer and are excluded from the numerator, so this UNDERSTATES leverage'
           END"
add_metric 'leverage.commits_per_steerer' \
  'CASE WHEN COALESCE(g.steerers,0)>0 THEN 1.0*COALESCE(g.commits_known_steerer,0)/g.steerers END' \
  'COALESCE(g.commits_known_steerer,0)' 'NULLIF(COALESCE(g.steerers,0),0)' 'COALESCE(g.steerers,0)' \
  "$N_LEV_GAP" \
  'commits with a known human steerer / distinct known steerers in the bucket'

add_metric 'leverage.merged_prs_per_steerer' \
  'CASE WHEN COALESCE(pu.pr_steerers,0)>0 THEN 1.0*COALESCE(pu.prs_known_steerer,0)/pu.pr_steerers END' \
  'COALESCE(pu.prs_known_steerer,0)' 'NULLIF(COALESCE(pu.pr_steerers,0),0)' 'COALESCE(pu.pr_steerers,0)' \
  "CASE WHEN COALESCE(pu.prs_unknown_steerer,0) > 0 THEN COALESCE(pu.prs_unknown_steerer,0) || ' merged PR(s) here have no identifiable steerer and are excluded from the numerator' END" \
  'merged PRs with a known human steerer / distinct known PR steerers in the bucket'

add_metric 'leverage.steerers' \
  'COALESCE(g.steerers,0)' 'COALESCE(g.steerers,0)' 'NULL' 'a.commits' \
  "CASE WHEN COALESCE(g.steerers,0)=0 AND a.commits>0 THEN 'every execution in this bucket has an unknown steerer' END" \
  'distinct identities with >=1 non-merge commit and steerer_state=known'

# ---- AI adoption ---------------------------------------------------------
# AI share is a share of EXECUTIONS and it is a FLOOR. Denominator: every
# execution in scope, whatever its steerer. Numerator: executions with a
# DECLARED agent executor. The remainder is unknown-executor, never human.
add_metric 'adoption.ai_commit_share' \
  '100.0*a.ai_commits/NULLIF(a.commits,0)' 'a.ai_commits' 'NULLIF(a.commits,0)' 'a.commits' \
  "'FLOOR of agent-executed share: the ' || (a.commits - a.ai_commits) || ' remaining execution(s) in this bucket have an UNKNOWN executor, which is not the same as a human one' ||
   CASE WHEN COALESCE(g.commits_unknown_steerer,0) > 0
        THEN '; ' || COALESCE(g.commits_unknown_steerer,0) || ' of the ' || a.commits || ' executions in this denominator have no identifiable steerer'
        ELSE '' END" \
  'commits with a declared AI Co-Authored-By trailer / all non-merge commits in scope'

# The same ratio over the subset whose steerer is identified. Divergence between
# this series and the one above IS the attribution artifact, made visible instead
# of being argued about.
add_metric 'adoption.ai_commit_share_known_steerer' \
  '100.0*COALESCE(g.ai_commits_known_steerer,0)/NULLIF(COALESCE(g.commits_known_steerer,0),0)' \
  'COALESCE(g.ai_commits_known_steerer,0)' 'NULLIF(COALESCE(g.commits_known_steerer,0),0)' \
  'COALESCE(g.commits_known_steerer,0)' \
  "'restricted to the ' || COALESCE(g.commits_known_steerer,0) || ' of ' || a.commits ||
   ' execution(s) whose steerer is identified; compare with the headline AI share — a gap between them is an attribution artifact, not behaviour'" \
  'agent-executed commits with a known steerer / commits with a known steerer'

add_metric 'adoption.executor_unknown_share' \
  '100.0*COALESCE(g.commits_unknown_executor,0)/NULLIF(a.commits,0)' \
  'COALESCE(g.commits_unknown_executor,0)' 'NULLIF(a.commits,0)' 'a.commits' \
  "'UNKNOWN EXECUTOR IS NOT HUMAN EXECUTOR. These commits carry no agent trailer; trailer discipline arrived late, so this is the uncertainty band on every AI share on this page, not a human share.'" \
  'commits with no declared AI trailer / all non-merge commits in scope'

add_metric 'adoption.ai_pr_share' \
  '100.0*a.ai_prs_merged/NULLIF(a.prs_merged,0)' 'a.ai_prs_merged' 'NULLIF(a.prs_merged,0)' 'a.prs_merged' \
  "'floor, not a measurement: a squashed merge that dropped the trailer looks human'" \
  'merged PRs with >=1 AI-co-authored commit / merged PRs'

add_metric 'adoption.contributors_with_ai_share' \
  '100.0*ab.adopters_active/NULLIF(a.active_contributors,0)' \
  'ab.adopters_active' 'NULLIF(a.active_contributors,0)' 'a.active_contributors' \
  "'counts a contributor as an adopter from their first trailer onward; it does not detect stopping'" \
  'active contributors whose first AI trailer predates this bucket / active contributors'

add_metric 'adoption.adopters' \
  'ab.adopters_cum' 'ab.adopters_cum' 'NULL' 'a.active_contributors' \
  "'cumulative: contributors who had emitted at least one AI trailer in this scope by the end of the bucket'" \
  'cumulative distinct contributors with a first AI trailer on or before the bucket end'

add_metric 'adoption.agent_mix' \
  '100.0*at.n/NULLIF(at.total_ai,0)' 'at.n' 'NULLIF(at.total_ai,0)' 'a.ai_commits' \
  "CASE WHEN at.label IS NOT NULL THEN 'largest agent: ' || at.label || '; per-agent detail in adoption.agent_share.*; shares can sum above 100% when one commit credits two agents' END" \
  'largest per-agent share of AI-co-authored commits in the bucket'

# ---- Risk ----------------------------------------------------------------
add_metric 'risk.bus_factor' \
  'bf.bus_factor' 'bf.bus_factor' 'bf.total_commits' 'a.commits' \
  "'contributors needed to cover half the commits in this bucket; a short bucket makes this look worse than the team is'" \
  'smallest N whose commit counts cover >=50% of bucket commits'

add_metric 'risk.top_contributor_commit_share' \
  'bf.top_share' 'NULL' 'bf.total_commits' 'a.commits' \
  "'measured over commits, not over files: it cannot tell you that one person owns the payments module'" \
  'largest single contributor commit count / bucket commits'

add_metric 'risk.ownership_concentration' \
  'NULL' 'NULL' 'NULL' 'NULL' \
  "'UNAVAILABLE — this metric is defined per file path and this build does not ingest file paths. The repo-level substitute is risk.top_contributor_commit_share, which is a weaker signal and says so.'" \
  'declared unavailable: file-path attribution is not ingested'

# ---- Meta ----------------------------------------------------------------
add_metric 'meta.unattributed_commits' \
  'COALESCE(g.unattributed_commits,0)' 'COALESCE(g.unattributed_commits,0)' 'NULLIF(a.commits,0)' 'a.commits' \
  "CASE WHEN COALESCE(g.unattributed_commits,0) > 0 THEN 'unknown steerer: excluded from every per-person view and from the leverage numerator, NOT counted as human, and still counted as executions' END" \
  'commits whose steerer_state is unknown'

add_metric 'meta.unknown_steerer_share' \
  '100.0*COALESCE(g.commits_unknown_steerer,0)/NULLIF(a.commits,0)' \
  'COALESCE(g.commits_unknown_steerer,0)' 'NULLIF(a.commits,0)' 'a.commits' \
  "CASE WHEN 100.0*COALESCE(g.commits_unknown_steerer,0)/NULLIF(a.commits,0) >= 10
        THEN 'ABOVE THE 10% BAR — while this holds, no attribution-derived TREND on this page is presentable; quote the most recent complete period''s AI floor instead'
   END" \
  'commits with steerer_state=unknown / all non-merge commits in scope'

add_metric 'meta.identity_resolution_pct' \
  '100.0*(a.commits - COALESCE(g.unattributed_commits,0))/NULLIF(a.commits,0)' \
  '(a.commits - COALESCE(g.unattributed_commits,0))' 'NULLIF(a.commits,0)' 'a.commits' 'NULL' \
  'commits with a resolved GitHub login / non-merge commits'

add_metric 'meta.unclassified_pr_share' \
  '100.0*a.prs_unclassified/NULLIF(a.prs_merged,0)' \
  'a.prs_unclassified' 'NULLIF(a.prs_merged,0)' 'a.prs_merged' 'NULL' \
  'merged PRs with no classification row / merged PRs'

# ---- Per-agent shares (one metric_key per agent seen) --------------------
cat >>"$SQLF" <<SQL
INSERT INTO agg_metric(metric_key,scope,scope_key,period_kind,period_start,value,numerator,denominator,sample_size,note,agg_version)
SELECT 'adoption.agent_share.' || ag.agent_key, ag.scope, ag.scope_key, $QPK, ag.period_start,
       100.0*ag.n/NULLIF(ag.total_ai,0), ag.n, NULLIF(ag.total_ai,0), ag.total_ai,
       $(note_expr ag "'shares can sum above 100%: a commit crediting two agents counts once for each'"),
       $QAGGV
  FROM _agent ag;
INSERT OR REPLACE INTO _cov_map(metric_key,method,detail)
SELECT DISTINCT 'adoption.agent_share.' || agent_key, 'script',
       'commits whose Co-Authored-By trailer maps to this agent / AI-co-authored commits'
  FROM _agent;
SQL

# ---- Scope-wide metrics (period_kind='all') ------------------------------
# These do not vary by bucket. They are stored with period_kind='all' and
# period_start = the analysis ceiling. RENDERERS MUST NOT assume every
# agg_metric row shares the run's period_kind.
cat >>"$SQLF" <<SQL
INSERT INTO agg_metric(metric_key,scope,scope_key,period_kind,period_start,value,numerator,denominator,sample_size,note,agg_version)
SELECT 'adoption.cycle_time_delta_pct_after_adoption', k.scope, k.scope_key, 'all', $QU,
       (SELECT AVG(CASE WHEN r.rn IN ((r.n+1)/2,(r.n+2)/2) THEN r.pct END)
          FROM _ct_delta_rank r WHERE r.scope=k.scope AND r.scope_key=k.scope_key),
       NULL,
       (SELECT COUNT(*) FROM _ct_delta d WHERE d.scope=k.scope AND d.scope_key=k.scope_key),
       (SELECT COUNT(*) FROM _ct_delta d WHERE d.scope=k.scope AND d.scope_key=k.scope_key),
       'median of per-contributor changes over symmetric ${ADOPT_WIN}-day windows; a contributor is included only with >=$MIN_PRS_PER_PHASE merged PRs on each side; CORRELATION ONLY — there is no control group and nothing else was held constant',
       $QAGGV
  FROM _scope_keys k;

INSERT INTO agg_metric(metric_key,scope,scope_key,period_kind,period_start,value,numerator,denominator,sample_size,note,agg_version)
SELECT 'adoption.commit_volume_delta_pct_after_adoption', k.scope, k.scope_key, 'all', $QU,
       (SELECT AVG(CASE WHEN r.rn IN ((r.n+1)/2,(r.n+2)/2) THEN r.pct END)
          FROM _cv_delta_rank r WHERE r.scope=k.scope AND r.scope_key=k.scope_key),
       NULL,
       (SELECT COUNT(*) FROM _cv_delta d WHERE d.scope=k.scope AND d.scope_key=k.scope_key),
       (SELECT COUNT(*) FROM _cv_delta d WHERE d.scope=k.scope AND d.scope_key=k.scope_key),
       'median of per-contributor changes over symmetric ${ADOPT_WIN}-day windows, contributors whose window has fully elapsed only; commit count measures activity, not output; CORRELATION ONLY',
       $QAGGV
  FROM _scope_keys k;

-- Placeholder row. The real value is filled in AFTER this run's own coverage
-- rows are written -- otherwise the number always lags by exactly one run, and
-- a self-measured metric that cannot see its own run is worth very little.
INSERT INTO agg_metric(metric_key,scope,scope_key,period_kind,period_start,value,numerator,denominator,sample_size,note,agg_version)
SELECT 'meta.script_coverage_pct', k.scope, k.scope_key, 'all', $QU,
       NULL, NULL, NULL, NULL,
       'database-wide, not scope-specific: coverage_log is keyed by run, not by repo',
       $QAGGV
  FROM _scope_keys k;
SQL
add_cov 'adoption.cycle_time_delta_pct_after_adoption' script "median of per-contributor before/after medians, >=$MIN_PRS_PER_PHASE PRs each side"
add_cov 'adoption.commit_volume_delta_pct_after_adoption' script 'median of per-contributor before/after commit counts'
add_cov 'meta.script_coverage_pct' script 'read from v_coverage_by_run'

# ===========================================================================
# Part 4 — coverage rows, summary counters, commit
# ===========================================================================
printf '%s\n' "$COV_MAP" >>"$SQLF"

cat >>"$SQLF" <<SQL
-- Metrics whose inputs came from the PR classifier inherit the classifier's
-- weakness. A metric computed over a denominator that is mostly LLM-decided is
-- not a script-covered number, and pretending otherwise is how a coverage
-- figure becomes decorative.
CREATE TEMP TABLE _cov_rows AS
  SELECT DISTINCT a.metric_key, a.scope, a.scope_key, m.method, m.detail
    FROM agg_metric a JOIN _cov_map m ON m.metric_key = a.metric_key
   WHERE a.agg_version=$QAGGV
     AND (a.scope,a.scope_key) IN (SELECT scope,scope_key FROM _scope_keys)
     AND ((a.period_kind=$QPK AND a.period_start BETWEEN $QW AND $QU) OR a.period_kind='all');

UPDATE _cov_rows SET
  method = COALESCE((SELECT CASE WHEN c.classified=0 THEN 'script'
                                 WHEN c.n_llm*2 > c.classified THEN 'llm'
                                 WHEN c.n_weak   > 0           THEN 'script-with-fallback'
                                 ELSE 'script' END
                       FROM _clsq c WHERE c.scope=_cov_rows.scope AND c.scope_key=_cov_rows.scope_key), 'script'),
  detail = COALESCE((SELECT CASE WHEN c.classified=0 THEN 'no classified PRs in window; ratio emitted as unavailable'
                                 WHEN c.n_llm*2 > c.classified THEN 'no deterministic rule covered the majority of this denominator: ' || c.n_llm || ' of ' || c.classified || ' contributing PRs were classified by a model'
                                 WHEN c.n_weak   > 0           THEN c.n_weak || ' of ' || c.classified || ' contributing PRs were classified by a weaker secondary signal'
                                 ELSE detail END
                       FROM _clsq c WHERE c.scope=_cov_rows.scope AND c.scope_key=_cov_rows.scope_key), detail)
 WHERE metric_key IN ('quality.defect_ratio','quality.revert_rate','impact.innovation_ratio');

SELECT 'COV' || char(9) || 'metric' || char(9) || scope_key || ':' || metric_key
                || char(9) || method || char(9) || detail
  FROM _cov_rows;

-- Summary counters for the stdout envelope. Aggregate counts only: no logins,
-- no names, no emails, no SHAs, no titles.
SELECT 'SUM' || char(9) || 'buckets'        || char(9) || (SELECT COUNT(*) FROM _spine);
SELECT 'SUM' || char(9) || 'org_rows'       || char(9) || (SELECT COUNT(*) FROM agg_org_period WHERE agg_version=$QAGGV AND period_kind=$QPK AND period_start BETWEEN $QW AND $QU AND (scope,scope_key) IN (SELECT scope,scope_key FROM _scope_keys));
SELECT 'SUM' || char(9) || 'author_rows'    || char(9) || (SELECT COUNT(*) FROM _ap_keys);
SELECT 'SUM' || char(9) || 'metric_rows'    || char(9) || (SELECT COUNT(*) FROM agg_metric WHERE agg_version=$QAGGV AND (scope,scope_key) IN (SELECT scope,scope_key FROM _scope_keys) AND ((period_kind=$QPK AND period_start BETWEEN $QW AND $QU) OR period_kind='all'));
SELECT 'SUM' || char(9) || 'metric_keys'    || char(9) || (SELECT COUNT(DISTINCT metric_key) FROM _cov_rows);
-- Metrics DECLARED unavailable (catalog says they cannot come from git, or the
-- formula refused to guess) — not merely NULL because a bucket was empty. The
-- two are different facts and conflating them hides the honest ones.
SELECT 'SUM' || char(9) || 'unavailable'    || char(9) ||
  (SELECT COUNT(DISTINCT m.metric_key) FROM agg_metric m JOIN metric_catalog mc ON mc.metric_key=m.metric_key
    WHERE m.agg_version=$QAGGV AND (m.scope,m.scope_key) IN (SELECT scope,scope_key FROM _scope_keys)
      AND (mc.computable=0 OR m.note LIKE '%UNAVAILABLE%'));
SELECT 'SUM' || char(9) || 'null_value_rows' || char(9) ||
  (SELECT COUNT(*) FROM agg_metric m WHERE m.agg_version=$QAGGV AND m.value IS NULL
      AND (m.scope,m.scope_key) IN (SELECT scope,scope_key FROM _scope_keys)
      AND ((m.period_kind=$QPK AND m.period_start BETWEEN $QW AND $QU) OR m.period_kind='all'));
SELECT 'SUM' || char(9) || 'partial_buckets'|| char(9) || (SELECT COUNT(*) FROM agg_metric WHERE agg_version=$QAGGV AND note LIKE 'partial period%' AND (scope,scope_key) IN (SELECT scope,scope_key FROM _scope_keys));
SELECT 'SUM' || char(9) || 'prs_merged'     || char(9) || (SELECT COUNT(*) FROM _pr WHERE scope='repo');
SELECT 'SUM' || char(9) || 'commits'        || char(9) || (SELECT COUNT(*) FROM _cm WHERE scope='repo');
SELECT 'SUM' || char(9) || 'ai_commits'     || char(9) || (SELECT COALESCE(SUM(is_ai_assisted),0) FROM _cm WHERE scope='repo');
SELECT 'SUM' || char(9) || 'merge_commits_excluded' || char(9) || (SELECT COUNT(*) FROM _cf WHERE scope='repo' AND period_kind=$QPK AND period_start BETWEEN $QW AND $QU AND is_merge=1);
SELECT 'SUM' || char(9) || 'unattributed_commits' || char(9) || (SELECT COALESCE(SUM(is_unattributed),0) FROM _cm WHERE scope='repo');
-- The attribution pair, as counts, so the envelope states both axes rather than
-- letting the reader infer one from the other.
SELECT 'SUM' || char(9) || 'steerer_known'    || char(9) || (SELECT COALESCE(SUM(steerer_state='known'),0)    FROM _cm WHERE scope='repo');
SELECT 'SUM' || char(9) || 'steerer_unknown'  || char(9) || (SELECT COALESCE(SUM(steerer_state='unknown'),0)  FROM _cm WHERE scope='repo');
SELECT 'SUM' || char(9) || 'executor_agent'   || char(9) || (SELECT COALESCE(SUM(executor_state='agent'),0)   FROM _cm WHERE scope='repo');
SELECT 'SUM' || char(9) || 'executor_unknown' || char(9) || (SELECT COALESCE(SUM(executor_state='unknown'),0) FROM _cm WHERE scope='repo');
SELECT 'SUM' || char(9) || 'steerers'         || char(9) || (SELECT COUNT(DISTINCT author_identity_id) FROM _cm WHERE scope='repo' AND steerer_state='known');
SELECT 'SUM' || char(9) || 'unclassified_prs' || char(9) || (SELECT COALESCE(SUM(class='unclassified'),0) FROM _pr WHERE scope='repo');
-- Bots removed from the selected repos inside the window. Counted here so that
-- "we excluded bots" is a number the reader can see, not an unverifiable claim.
SELECT 'SUM' || char(9) || 'bot_commits_excluded' || char(9) ||
  (SELECT COUNT(*) FROM commits c JOIN identities i ON i.identity_id=c.author_identity_id
    WHERE (i.is_bot=1 OR i.is_excluded=1) AND c.is_merge=0 AND c.repo_id IN ($IDS)
      AND substr(c.authored_at,1,10) BETWEEN $QW AND $QU);
SELECT 'SUM' || char(9) || 'bot_prs_excluded'     || char(9) ||
  (SELECT COUNT(*) FROM pull_requests p JOIN identities i ON i.identity_id=p.author_identity_id
    WHERE (i.is_bot=1 OR i.is_excluded=1) AND p.state='MERGED' AND p.merged_at IS NOT NULL
      AND p.repo_id IN ($IDS) AND substr(p.merged_at,1,10) BETWEEN $QW AND $QU);
SELECT 'SUM' || char(9) || 'contributors'   || char(9) || (SELECT COUNT(*) FROM _first_ai WHERE scope='repo');
SELECT 'SUM' || char(9) || 'adopters'       || char(9) || (SELECT COUNT(*) FROM _first_ai WHERE scope='repo' AND first_ai_at IS NOT NULL);
SELECT 'SUM' || char(9) || 'adoption_deltas_measurable' || char(9) || (SELECT COUNT(*) FROM _ct_delta);
SQL

if [ "$DRYRUN" = "1" ]; then echo "ROLLBACK;" >>"$SQLF"; else echo "COMMIT;" >>"$SQLF"; fi

# ---------------------------------------------------------------------------
# Execute. One process, one transaction. Output is captured, never leaked to
# stdout — stdout belongs to the envelope alone.
# ---------------------------------------------------------------------------
OUT=""
if ! OUT="$(dxm_sql_stdin < "$SQLF" 2>&1)"; then
  dxm_warn "aggregation failed; the transaction was rolled back and no aggregate row changed"
  printf '%s\n' "$OUT" | tail -n 20 >&2
  dxm_run_finish "$RUN_ID" error 4 "aggregation SQL failed"
  dxm_emit false "$SELF" "$RUN_ID" "\"error\":\"aggregation SQL failed; see stderr\",\"period\":\"$PK\",\"window_start\":\"$W\",\"window_end\":\"$U\""
  exit 4
fi

get() { printf '%s\n' "$OUT" | awk -F'\t' -v k="$2" '$1=="SUM" && $2==k {print $3; exit}'; }
V_BUCKETS="$(get x buckets)";            V_ORG="$(get x org_rows)"
V_AUTHOR="$(get x author_rows)";         V_METRIC="$(get x metric_rows)"
V_KEYS="$(get x metric_keys)";           V_UNAVAIL="$(get x unavailable)"
V_NULLROWS="$(get x null_value_rows)"
V_PARTIAL="$(get x partial_buckets)";    V_PRS="$(get x prs_merged)"
V_COMMITS="$(get x commits)";            V_AI="$(get x ai_commits)"
V_MERGE="$(get x merge_commits_excluded)"; V_UNATTR="$(get x unattributed_commits)"
V_UNCLASS="$(get x unclassified_prs)";   V_BOTC="$(get x bot_commits_excluded)"
V_BOTP="$(get x bot_prs_excluded)";      V_CONTRIB="$(get x contributors)"
V_ADOPT="$(get x adopters)";             V_DELTA="$(get x adoption_deltas_measurable)"
V_SK="$(get x steerer_known)";           V_SU="$(get x steerer_unknown)"
V_XA="$(get x executor_agent)";          V_XU="$(get x executor_unknown)"
V_STEERERS="$(get x steerers)"

# Coverage: written through lib/dxm-common.sh, as the contract requires.
if [ "$DRYRUN" = "1" ]; then
  dxm_log "dry run: transaction rolled back; no coverage rows written"
else
  COVLINES="$(printf '%s\n' "$OUT" | grep "^COV$(printf '\t')" || true)"
  if [ -n "$COVLINES" ]; then
    printf '%s\n' "$COVLINES" | cut -f2- | dxm_coverage_batch "$RUN_ID"
  fi
  # Now that this run's coverage rows exist, fill in the self-measured metric.
  # The formula itself is read from v_coverage_by_run and never recomputed here
  # (CONTRACT.md §7) — this only decides WHEN it is read.
  dxm_sql "UPDATE agg_metric SET
             value       = (SELECT ROUND(100.0*SUM(n_script+n_script_fallback)/NULLIF(SUM(total),0),1) FROM v_coverage_by_run),
             numerator   = (SELECT SUM(n_script+n_script_fallback) FROM v_coverage_by_run),
             denominator = (SELECT SUM(total) FROM v_coverage_by_run),
             sample_size = (SELECT SUM(total) FROM v_coverage_by_run)
           WHERE metric_key='meta.script_coverage_pct' AND agg_version=$(dxm_q "$AGGV")
             AND (scope,scope_key) IN (SELECT 'repo',full_name FROM repos WHERE repo_id IN ($IDS)
                                       UNION SELECT 'org',owner FROM repos WHERE repo_id IN ($IDS));"
fi

dxm_run_finish "$RUN_ID" ok 0

PAYLOAD="\"period\":\"$BUCKET_LABEL\",\"window_start\":\"$W\",\"window_end\":\"$U\",\"mode\":\"$MODE\""
PAYLOAD="$PAYLOAD,\"agg_version\":\"$AGGV\",\"dry_run\":$([ "$DRYRUN" = 1 ] && echo true || echo false)"
PAYLOAD="$PAYLOAD,\"repos\":$N_REPOS,\"orgs\":$N_ORGS,\"repos_excluded_shallow\":${ORG_SHALLOW:-0}"
PAYLOAD="$PAYLOAD,\"buckets\":${V_BUCKETS:-0}"
PAYLOAD="$PAYLOAD,\"rows\":{\"agg_org_period\":${V_ORG:-0},\"agg_author_period\":${V_AUTHOR:-0},\"agg_metric\":${V_METRIC:-0}}"
PAYLOAD="$PAYLOAD,\"metric_keys\":${V_KEYS:-0},\"metrics_declared_unavailable\":${V_UNAVAIL:-0}"
PAYLOAD="$PAYLOAD,\"null_value_rows\":${V_NULLROWS:-0},\"partial_bucket_rows\":${V_PARTIAL:-0}"
PAYLOAD="$PAYLOAD,\"inputs\":{\"commits\":${V_COMMITS:-0},\"ai_commits\":${V_AI:-0},\"prs_merged\":${V_PRS:-0}}"
PAYLOAD="$PAYLOAD,\"attribution\":{\"steerer_known\":${V_SK:-0},\"steerer_unknown\":${V_SU:-0},\"steerers\":${V_STEERERS:-0},\"executor_agent\":${V_XA:-0},\"executor_unknown\":${V_XU:-0},\"note\":\"two axes, neither inferred from the other; executor_unknown is NOT human execution\"}"
PAYLOAD="$PAYLOAD,\"gaps\":{\"unattributed_commits\":${V_UNATTR:-0},\"unclassified_prs\":${V_UNCLASS:-0},\"merge_commits_excluded\":${V_MERGE:-0},\"bot_commits_excluded\":${V_BOTC:-0},\"bot_prs_excluded\":${V_BOTP:-0}}"
PAYLOAD="$PAYLOAD,\"adoption\":{\"contributors\":${V_CONTRIB:-0},\"adopters\":${V_ADOPT:-0},\"before_after_measurable\":${V_DELTA:-0},\"window_days\":$ADOPT_WIN}"
PAYLOAD="$PAYLOAD,\"individuals_flag\":$([ "$INDIVIDUALS" = 1 ] && echo true || echo false)"
PAYLOAD="$PAYLOAD,\"proxy_note\":\"every speed/quality/impact/adoption number here is a proxy and carries its own proxy_statement and cannot_see in metric_catalog; DXI is unavailable by design\""

dxm_emit true "$SELF" "$RUN_ID" "$PAYLOAD"
exit 0
