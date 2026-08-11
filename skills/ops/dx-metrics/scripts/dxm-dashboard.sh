#!/usr/bin/env bash
# dxm-dashboard.sh — render the DX / AI-adoption dashboard as ONE self-contained
# HTML file that opens by double-click.
#
# WHY a single file with the data inlined: a browser cannot open a .sqlite file,
# and this skill is not allowed a server, a CDN, WASM or an external font. So the
# renderer runs the queries here, serialises small JSON, and pastes it into a
# template that carries its own CSS and its own hand-rolled SVG charts.
#
# WHAT IT READS (never writes): metric_catalog, agg_metric, agg_org_period,
# agg_adoption_timeline, and the read-only views. It computes no metric of its
# own except the AI-agent mix, which has no per-agent dimension in agg_metric —
# and that one is logged as 'script-with-fallback' so it shows up as a gap.
#
# PRIVACY: the default render reads agg_org_period / agg_metric, which have no
# identity column, so "no personal information by default" is structural rather
# than a promise this script has to keep. --include-individuals unlocks exactly
# one extra table: adoption timing (login, first-trailer date, first agent).
# There is no per-person throughput output, with or without the flag, and no
# flag adds one.
#
# OWNERSHIP: W-dashboard. Owns only scripts/dxm-dashboard.sh and
# templates/dashboard.html. Touches no other file.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/../lib/dxm-common.sh"

TEMPLATE="$DXM_SKILL_DIR/templates/dashboard.html"
SELF="$(basename "$0")"

# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------
usage() {
  cat <<'EOF'
dxm-dashboard.sh — render a single self-contained HTML dashboard from the
dx-metrics database. No server, no network, no chart library.

USAGE
  dxm-dashboard.sh [--org OWNER | --repo OWNER/NAME] [options]

SCOPE
  --org OWNER              Render org scope. Shorthand for --scope org --scope-key OWNER.
  --repo OWNER/NAME        Render repo scope. Shorthand for --scope repo --scope-key OWNER/NAME.
  --scope org|repo         Aggregate scope to read. Default: inferred from the DB.
  --scope-key KEY          'owner' for org scope, 'owner/name' for repo scope.
                           Default: inferred when the DB holds exactly one.

WINDOW
  --period day|week|month  Bucket granularity. Default: week.
  --since YYYY-MM-DD       First bucket. Default: 90 days / 26 weeks / 24 months back.
  --until YYYY-MM-DD       Last bucket. Default: today, UTC.

OUTPUT
  --out PATH               Write here. Default: $DXM_OUT/dx-metrics-<scope>-<period>-<date>.html
  --dry-run                Do everything except write the file.
  --json                   Accepted and ignored; JSON on stdout is the only mode.

PRIVACY
  --include-individuals    Opt in to the per-person adoption-timing table.
                           SENSITIVE. Adds names to the file. Never enables any
                           per-person throughput, volume or quality output —
                           no flag does, and none exists.
  --min-cohort N           Suppress the aggregate adoption curve when the
                           contributor population is below N. Default 3.

  --help                   This text.

OUTPUT CONTRACT
  Exactly one line of JSON on stdout. Everything else on stderr.
  Exit 0 ok · 1 usage · 2 precondition · 3 partial · 4 data error.

THE NUMBERS THIS RENDERS ARE PROXIES AND THE PAGE SAYS SO NEXT TO EVERY ONE OF
THEM. The output must not be used to measure individual performance or to feed
performance evaluations.
EOF
}

# ---------------------------------------------------------------------------
# Flags. Unknown flag = usage error; silent flag-swallowing is how two runs stop
# being comparable.
# ---------------------------------------------------------------------------
SCOPE=""; SCOPE_KEY=""; PERIOD="week"; SINCE=""; UNTIL=""
OUT_PATH=""; DRY_RUN=0; INCLUDE_INDIVIDUALS=0; MIN_COHORT=3

while [ $# -gt 0 ]; do
  case "$1" in
    --help|-h)              usage; exit 0 ;;
    --org)                  SCOPE="org";  SCOPE_KEY="${2:-}"; shift 2 ;;
    --repo)                 SCOPE="repo"; SCOPE_KEY="${2:-}"; shift 2 ;;
    --scope)                SCOPE="${2:-}"; shift 2 ;;
    --scope-key)            SCOPE_KEY="${2:-}"; shift 2 ;;
    --period)               PERIOD="${2:-}"; shift 2 ;;
    --since)                SINCE="${2:-}"; shift 2 ;;
    --until)                UNTIL="${2:-}"; shift 2 ;;
    --out)                  OUT_PATH="${2:-}"; shift 2 ;;
    --min-cohort)           MIN_COHORT="${2:-}"; shift 2 ;;
    --dry-run)              DRY_RUN=1; shift ;;
    --include-individuals)  INCLUDE_INDIVIDUALS=1; shift ;;
    --json)                 shift ;;
    *) dxm_die "unknown flag: $1 (try --help)" 1 ;;
  esac
done

case "$PERIOD" in day|week|month) ;; *) dxm_die "--period must be day|week|month, got: $PERIOD" 1 ;; esac
case "$SCOPE" in ""|org|repo) ;; *) dxm_die "--scope must be org|repo, got: $SCOPE" 1 ;; esac
case "$MIN_COHORT" in ''|*[!0-9]*) dxm_die "--min-cohort must be a non-negative integer" 1 ;; esac
for d in "$SINCE" "$UNTIL"; do
  [ -z "$d" ] && continue
  case "$d" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;;
    *) dxm_die "dates must be YYYY-MM-DD, got: $d" 1 ;;
  esac
done
[ -f "$TEMPLATE" ] || dxm_die "template not found: $TEMPLATE" 2

# ---------------------------------------------------------------------------
# DB + run bookkeeping
# ---------------------------------------------------------------------------
dxm_init_db
RUN_ID="$(dxm_run_start "$SELF" "$*" "")"
trap 'dxm_run_trap '"$RUN_ID"' $?' EXIT

fail() {  # fail <exit_code> <message>
  local code="$1" msg="$2"
  dxm_run_finish "$RUN_ID" error "$code" "$msg"
  dxm_emit false "$SELF" "$RUN_ID" "\"error\":$(dxm_json_str "$msg")"
  exit "$code"
}

# ---------------------------------------------------------------------------
# Resolve scope. Inference is deliberately conservative: it only guesses when
# there is exactly one candidate, otherwise it makes the operator choose. A
# dashboard that silently picks a different scope next week is worse than one
# that refuses to render.
# ---------------------------------------------------------------------------
if [ -z "$SCOPE" ]; then
  SCOPE="$(dxm_sql1 "SELECT scope FROM agg_org_period GROUP BY scope ORDER BY (scope='org') DESC, COUNT(*) DESC LIMIT 1;")"
  [ -n "$SCOPE" ] || SCOPE="repo"
fi
if [ -z "$SCOPE_KEY" ]; then
  n_keys="$(dxm_sql1 "SELECT COUNT(DISTINCT scope_key) FROM agg_org_period WHERE scope=$(dxm_q "$SCOPE");")"
  if [ "${n_keys:-0}" = "1" ]; then
    SCOPE_KEY="$(dxm_sql1 "SELECT scope_key FROM agg_org_period WHERE scope=$(dxm_q "$SCOPE") LIMIT 1;")"
  elif [ "${n_keys:-0}" = "0" ]; then
    # No aggregates yet — fall back to the repos table so an empty-state page
    # still names the thing it found nothing for.
    if [ "$SCOPE" = "org" ]; then
      SCOPE_KEY="$(dxm_sql1 "SELECT owner FROM repos GROUP BY owner ORDER BY COUNT(*) DESC LIMIT 1;")"
    else
      SCOPE_KEY="$(dxm_sql1 "SELECT full_name FROM repos ORDER BY repo_id LIMIT 1;")"
    fi
    [ -n "$SCOPE_KEY" ] || fail 4 "no aggregates and no repos in the database; run the ingest and aggregate steps first"
    dxm_warn "no agg_org_period rows; defaulting scope-key to $SCOPE_KEY"
  else
    dxm_log "candidate scope keys for scope=$SCOPE:"
    dxm_sql "SELECT DISTINCT scope_key FROM agg_org_period WHERE scope=$(dxm_q "$SCOPE") ORDER BY 1;" >&2
    fail 1 "$n_keys scope keys available for scope=$SCOPE; pass --scope-key"
  fi
fi
if [ "$SCOPE" = "repo" ]; then
  case "$SCOPE_KEY" in */*) ;; *) fail 1 "repo scope-key must be owner/name, got: $SCOPE_KEY" ;; esac
fi

QSCOPE="$(dxm_q "$SCOPE")"; QKEY="$(dxm_q "$SCOPE_KEY")"; QPERIOD="$(dxm_q "$PERIOD")"

# ---------------------------------------------------------------------------
# Window. All date maths goes through SQLite — macOS `date` has no -d and the
# BSD -j -f form is a trap waiting to be mistyped.
# ---------------------------------------------------------------------------
[ -n "$UNTIL" ] || UNTIL="$(dxm_sql1 "SELECT date('now');")"
if [ -z "$SINCE" ]; then
  # SQLite has NO 'weeks' modifier — 'NNN weeks' returns NULL, which silently
  # becomes an empty floor and then a NULL comparison that matches no rows at
  # all. 26 weeks is spelled -182 days on purpose.
  case "$PERIOD" in
    day)   SINCE="$(dxm_sql1 "SELECT date('now','-90 days');")" ;;
    week)  SINCE="$(dxm_sql1 "SELECT date('now','-182 days','-6 days','weekday 1');")" ;;
    month) SINCE="$(dxm_sql1 "SELECT strftime('%Y-%m-01', date('now','-23 months'));")" ;;
  esac
fi
# An empty bound is not a wide window, it is a NULL comparison that matches
# nothing. Refuse rather than render a confident empty dashboard.
[ -n "$SINCE" ] || fail 4 "could not compute a default --since for period=$PERIOD"
[ -n "$UNTIL" ] || fail 4 "could not compute a default --until"
[ "$SINCE" \< "$UNTIL" ] || [ "$SINCE" = "$UNTIL" ] || fail 1 "--since ($SINCE) is after --until ($UNTIL)"

# The current, incomplete bucket. Same expression as v_commits_enriched uses for
# week bucketing, so "is this bucket the current one" cannot disagree with the
# view's own boundaries.
case "$PERIOD" in
  day)   CUR_BUCKET="$(dxm_sql1 "SELECT date('now');")" ;;
  week)  CUR_BUCKET="$(dxm_sql1 "SELECT date('now','-6 days','weekday 1');")" ;;
  month) CUR_BUCKET="$(dxm_sql1 "SELECT strftime('%Y-%m-01','now');")" ;;
esac
QCUR="$(dxm_q "$CUR_BUCKET")"
QSINCE="$(dxm_q "$SINCE")"; QUNTIL="$(dxm_q "$UNTIL")"
UNTIL_EXCL="$(dxm_sql1 "SELECT date($QUNTIL,'+1 day');")"
QUNTIL_EXCL="$(dxm_q "$UNTIL_EXCL")"

# Scope filters. v_commits_enriched / v_prs_enriched expose owner and
# repo_full_name, so no query below re-derives a repo set.
if [ "$SCOPE" = "org" ]; then
  F_COMMITS="c.owner = $QKEY"; F_PRS="p.owner = $QKEY"; F_REPOS="r.owner = $QKEY"
else
  F_COMMITS="c.repo_full_name = $QKEY"; F_PRS="p.repo_full_name = $QKEY"; F_REPOS="r.full_name = $QKEY"
fi
W_COMMITS="c.authored_at >= $QSINCE AND c.authored_at < $QUNTIL_EXCL"
W_PRS="p.merged_at >= $QSINCE AND p.merged_at < $QUNTIL_EXCL"

# ---------------------------------------------------------------------------
# Integrity assertions before rendering anything.
# ---------------------------------------------------------------------------
# §9: a number with no metric_catalog row cannot be rendered. The FK makes this
# impossible to violate, so this check is a tripwire for a DB built by hand or
# by a future migration that dropped the constraint. Fail loudly, do not render.
ORPHANS="$(dxm_sql1 "SELECT COUNT(*) FROM agg_metric m
                      LEFT JOIN metric_catalog mc ON mc.metric_key = m.metric_key
                     WHERE mc.metric_key IS NULL;")"
[ "${ORPHANS:-0}" = "0" ] || fail 4 "$ORPHANS agg_metric rows have no metric_catalog row; refusing to render bare numbers"

STUCK="$(dxm_sql1 "SELECT COUNT(*) FROM runs WHERE status='running' AND run_id <> $RUN_ID;")"
[ "${STUCK:-0}" = "0" ] || dxm_warn "$STUCK previous run(s) still marked 'running' — some watermarks may be untrustworthy (see dxm-doctor)"

# ---------------------------------------------------------------------------
# Queries. Everything below is a read.
# ---------------------------------------------------------------------------
jarr() {  # jarr <sql> -> a JSON array, '[]' when there are no rows
  local r; r="$(dxm_sql_json "$1")"; printf '%s' "${r:-[]}"
}
jobj() {  # jobj <sql returning one json_object()> -> a JSON object
  local r; r="$(dxm_sql1 "$1")"
  if [ -z "$r" ]; then printf '{}'; else printf '%s' "$r"; fi
}

dxm_log "scope=$SCOPE key=$SCOPE_KEY period=$PERIOD window=$SINCE..$UNTIL current_bucket=$CUR_BUCKET"

J_CATALOG="$(jarr "
  SELECT metric_key, pillar, label, unit, is_proxy, computable, privacy_class,
         proxy_statement, cannot_see, higher_is
    FROM metric_catalog
   ORDER BY pillar, metric_key;")"

# PR-completeness floor for this scope. A scope is only as complete as its
# LEAST complete repo, hence MAX. Empty string = every in-scope repo had an
# unbounded PR pull and no bucket needs a truncation caveat.
PR_FLOOR="$(dxm_sql1 "
  SELECT MAX(w.cursor_value) FROM ingest_watermarks w
    JOIN repos r ON r.repo_id = w.repo_id
   WHERE w.source = 'github_prs_floor' AND w.cursor_value IS NOT NULL AND $F_REPOS;")"
PR_FLOOR="${PR_FLOOR:-}"
if [ -n "$PR_FLOOR" ]; then
  dxm_warn "PR history for this scope begins $PR_FLOOR; earlier buckets are marked partial"
  # Mark the bucket CONTAINING the floor too — a floor mid-month truncates that
  # month as well.
  case "$PERIOD" in
    day)   PR_FLOOR_BUCKET="$PR_FLOOR" ;;
    week)  PR_FLOOR_BUCKET="$(dxm_sql1 "SELECT date($(dxm_q "$PR_FLOOR"),'-6 days','weekday 1');")" ;;
    month) PR_FLOOR_BUCKET="$(dxm_sql1 "SELECT strftime('%Y-%m-01',$(dxm_q "$PR_FLOOR"));")" ;;
    *)     PR_FLOOR_BUCKET="$PR_FLOOR" ;;
  esac
  QFLOOR="$(dxm_q "$PR_FLOOR_BUCKET")"
  PR_TRUNC_METRICS="'speed.prs_merged','speed.pr_throughput_per_contributor_week',
    'speed.cycle_time_first_commit_to_merge_p50','speed.cycle_time_first_commit_to_merge_p75',
    'speed.active_contributors','quality.defect_ratio','quality.revert_rate',
    'impact.innovation_ratio','adoption.ai_pr_share'"
  # isPartial() in the template keys on is_current OR a note matching /partial/,
  # so injecting the caveat into note reuses the existing machinery: the bucket
  # is drawn hollow, excluded from the headline, and named on the card.
  M_PARTIAL="CASE WHEN period_start = $QCUR THEN 1
                  WHEN metric_key IN ($PR_TRUNC_METRICS) AND period_start <= $QFLOOR THEN 1
                  ELSE 0 END"
  M_NOTE="CASE WHEN metric_key IN ($PR_TRUNC_METRICS) AND period_start <= $QFLOOR
               THEN 'PARTIAL — pull-request history for this scope begins ' || $QFLOOR ||
                    '. This bucket contains only the PRs that happened to be updated after that date, so every PR count here understates reality by an unknown amount. Do not read it as a baseline.' ||
                    COALESCE(' ' || note, '')
               ELSE note END"
  O_PARTIAL="CASE WHEN period_start = $QCUR OR period_start <= $QFLOOR THEN 1 ELSE 0 END"
else
  M_PARTIAL="CASE WHEN period_start = $QCUR THEN 1 ELSE 0 END"
  M_NOTE="note"
  O_PARTIAL="CASE WHEN period_start = $QCUR THEN 1 ELSE 0 END"
fi

# Per-contributor throughput with a denominator below the cohort floor is not
# an aggregate — "28 PRs / 1 contributor" IS one identifiable person's weekly
# output, printed on the default page with no flag. The skill's own rule is that
# no per-person throughput exists, opt-in or not, so the number is withheld and
# the withholding is stated. The denominator survives because "1 active
# contributor" is a legitimate and important aggregate about the system.
#
# The leverage metrics are per-steerer rates and fall under exactly the same
# rule: "142 commits / 1 steerer" is one named person's output with the name
# filed off. They are withheld below the floor too; leverage.steerers itself
# survives because a headcount is a fact about the system, not about a person.
SMALL_DEN="metric_key IN ('speed.pr_throughput_per_contributor_week',
                          'leverage.commits_per_steerer',
                          'leverage.merged_prs_per_steerer')
             AND denominator IS NOT NULL AND denominator < $MIN_COHORT"

J_METRICS="$(jarr "
  SELECT metric_key, period_start,
         CASE WHEN $SMALL_DEN THEN NULL ELSE value END      AS value,
         CASE WHEN $SMALL_DEN THEN NULL ELSE numerator END  AS numerator,
         denominator, sample_size,
         CASE WHEN $SMALL_DEN
              THEN 'WITHHELD — only ' || CAST(denominator AS TEXT) ||
                   ' person/people in the denominator for this bucket, below the minimum cohort of $MIN_COHORT. ' ||
                   'A per-person rate over that few people is one identifiable person''s output, ' ||
                   'so it is not published. The headcount itself is shown because it is a fact ' ||
                   'about the system, not about a person.' || COALESCE(' ' || ($M_NOTE), '')
              ELSE $M_NOTE END AS note,
         $M_PARTIAL AS is_current
    FROM agg_metric
   WHERE scope = $QSCOPE AND scope_key = $QKEY AND period_kind = $QPERIOD
     AND period_start >= $QSINCE AND period_start <= $QUNTIL
   ORDER BY metric_key, period_start;")"

J_ORGPER="$(jarr "
  SELECT period_start, active_contributors, commits, ai_commits, prs_opened, prs_merged,
         ai_prs_merged, prs_bugfix, prs_feature, prs_revert, prs_unclassified,
         cycle_time_p50_h, cycle_time_p75_h, insertions, deletions,
         $O_PARTIAL AS partial
    FROM agg_org_period
   WHERE scope = $QSCOPE AND scope_key = $QKEY AND period_kind = $QPERIOD
     AND period_start >= $QSINCE AND period_start <= $QUNTIL
   ORDER BY period_start;")"

# AI-agent mix. agg_metric has no per-agent dimension (its PK is
# metric_key/scope/period), so this breakdown cannot come from the aggregate
# tables and is computed here. It reads through v_commits_enriched so bot
# exclusion and merge exclusion stay defined in exactly one place.
J_AGENTS="$(jarr "
  SELECT COALESCE(a.label, t.agent_key, 'Unmapped agent') AS label,
         COALESCE(t.agent_key, 'unmapped')                AS agent_key,
         COUNT(DISTINCT c.commit_id)                      AS commits
    FROM v_commits_enriched c
    JOIN ai_trailers t ON t.repo_id = c.repo_id AND t.sha = c.sha AND t.is_ai = 1
    LEFT JOIN ai_agents a ON a.agent_key = t.agent_key
   WHERE $F_COMMITS AND $W_COMMITS AND c.is_bot = 0 AND c.is_merge = 0
   GROUP BY 1, 2
   ORDER BY commits DESC;")"

#
# TWO scans, not eleven. Each of these used to be its own subquery over the same
# window, so an org-scope render read the commit table six times and the PR
# table four times. On a 28-repo org that is minutes of wall clock per page, for
# eleven integers.
J_INTEG_C="$(jobj "
  SELECT json_object(
    'commits_total',        COUNT(*),
    'commits_merge',        SUM(c.is_merge = 1),
    'commits_bot',          SUM(c.is_bot = 1),
    'commits_unattributed', SUM(c.is_unattributed = 1),
    'ai_commits',           SUM(c.is_ai_assisted = 1 AND c.is_merge = 0 AND c.is_bot = 0)
  ) FROM v_commits_enriched c WHERE $F_COMMITS AND $W_COMMITS;")"
J_INTEG_P="$(jobj "
  SELECT json_object(
    'prs_total',        COUNT(*),
    'prs_bot',          SUM(p.is_bot = 1),
    'prs_merged',       SUM(p.is_bot = 0),
    'prs_unclassified', SUM(p.is_bot = 0 AND p.class = 'unclassified')
  ) FROM v_prs_enriched p WHERE $F_PRS AND $W_PRS;")"
J_INTEG_S="$(jobj "
  SELECT json_object(
    'repo_count',        (SELECT COUNT(*) FROM repos r WHERE $F_REPOS),
    'unresolved_emails', (SELECT COUNT(*) FROM v_unresolved_emails)
  );")"
# Splice the three objects into one. A window with no rows yields SUM()=NULL
# rather than 0, and the template renders a null count as an em dash — which is
# honest ("no data") and distinct from a real zero, so it is left alone.
_inner() { local s="${1#\{}"; printf '%s' "${s%\}}"; }
J_INTEGRITY_SCALARS="{$(_inner "$J_INTEG_S"),$(_inner "$J_INTEG_C"),$(_inner "$J_INTEG_P")}"

# ---- the attribution pair, over the same window ---------------------------
# Two axes, counted independently. Merge commits are out (they are not
# authorship) and machine-steered commits are out (mandatory bot exclusion), so
# these four numbers describe exactly the population every metric on the page is
# computed over. steerer_unknown + steerer_known = commits; likewise executor.
#
# executor_human does not exist and must never be added. Nothing in git can
# produce it: an untrailered commit is an UNKNOWN executor.
#
# ONE scan, conditional aggregation. Eleven separate COUNT(*) subqueries over
# the same window read the fact table eleven times, and on a 28-repo org that
# was minutes per dashboard rather than seconds.
J_PAIR="$(jobj "
  SELECT json_object(
    'commits',          SUM(c.steerer_state <> 'machine'),
    'steerer_known',    SUM(c.steerer_state =  'known'),
    'steerer_unknown',  SUM(c.steerer_state =  'unknown'),
    'steerer_machine',  SUM(c.steerer_state =  'machine'),
    'steerers',         COUNT(DISTINCT CASE WHEN c.steerer_state='known' THEN c.author_identity_id END),
    'executor_agent',   SUM(c.steerer_state <> 'machine' AND c.executor_state='agent'),
    'executor_unknown', SUM(c.steerer_state <> 'machine' AND c.executor_state='unknown'),
    'pair_known_agent', SUM(c.steerer_state='known'   AND c.executor_state='agent'),
    'pair_known_unk',   SUM(c.steerer_state='known'   AND c.executor_state='unknown'),
    'pair_unk_agent',   SUM(c.steerer_state='unknown' AND c.executor_state='agent'),
    'pair_unk_unk',     SUM(c.steerer_state='unknown' AND c.executor_state='unknown')
  )
  FROM v_commits_enriched c
 WHERE $F_COMMITS AND $W_COMMITS AND c.is_merge = 0;")"

# v_unresolved_emails carries email addresses. Only its COUNT is ever read; the
# rows themselves must never reach the rendered file.
J_UNSAFE="$(jarr "
  SELECT v.full_name, v.reason
    FROM v_unsafe_repos v
   WHERE v.full_name IN (SELECT r.full_name FROM repos r WHERE $F_REPOS);")"

J_COVERAGE="$(jarr "
  SELECT r.script, v.unit_kind, v.total, v.n_script, v.n_script_fallback, v.n_llm,
         v.coverage_pct, v.pure_script_pct
    FROM v_coverage_by_run v
    JOIN runs r ON r.run_id = v.run_id
   WHERE v.run_id IN (SELECT MAX(run_id) FROM runs WHERE status = 'ok' GROUP BY script)
   ORDER BY r.script, v.unit_kind;")"

J_BACKLOG="$(jarr "SELECT unit_kind, reason, hits FROM v_llm_backlog LIMIT 25;")"

# ---- adoption curve: aggregate, no names, with small-cohort suppression -----
POPULATION="$(dxm_sql1 "
  SELECT COUNT(*) FROM agg_adoption_timeline t
    JOIN v_human_identities i ON i.identity_id = t.identity_id
   WHERE t.scope = $QSCOPE AND t.scope_key = $QKEY;")"
POPULATION="${POPULATION:-0}"

if [ "$POPULATION" -ge "$MIN_COHORT" ] && [ "$POPULATION" -gt 0 ]; then
  # A point of {date, n:1} IS one person's adoption date — the exact datum that
  # is supposed to be gated behind --include-individuals. The old floor tested
  # the POPULATION, never the size of each published bucket, so a 29-person org
  # published three n=1 dates that re-identified trivially against git log.
  # Two changes: bucket the dates to the report period so an exact day is never
  # published, and drop any bucket that is still under the cohort floor. What
  # was dropped is stated, because a silently shorter curve is its own lie.
  case "$PERIOD" in
    day)   PBUCKET="date(t.first_ai_trailer_at)" ;;
    week)  PBUCKET="date(t.first_ai_trailer_at,'-6 days','weekday 1')" ;;
    month) PBUCKET="strftime('%Y-%m-01', t.first_ai_trailer_at)" ;;
    *)     PBUCKET="strftime('%Y-%m-01', t.first_ai_trailer_at)" ;;
  esac
  CURVE_SUB="SELECT $PBUCKET AS d, COUNT(*) AS n
               FROM agg_adoption_timeline t
               JOIN v_human_identities i ON i.identity_id = t.identity_id
              WHERE t.scope = $QSCOPE AND t.scope_key = $QKEY
                AND t.first_ai_trailer_at IS NOT NULL
              GROUP BY 1"
  CURVE_POINTS="$(jarr "SELECT d, n FROM ($CURVE_SUB) WHERE n >= $MIN_COHORT ORDER BY d;")"
  CURVE_WITHHELD="$(dxm_sql1 "SELECT COALESCE(SUM(n),0) FROM ($CURVE_SUB) WHERE n < $MIN_COHORT;")"
  CURVE_WITHHELD="${CURVE_WITHHELD:-0}"
  [ "$CURVE_WITHHELD" -gt 0 ] && dxm_log "adoption curve: $CURVE_WITHHELD adopter(s) withheld — their bucket was under min-cohort $MIN_COHORT"
  J_CURVE="{\"population\":$POPULATION,\"min_cohort\":$MIN_COHORT,\"suppressed\":false,\"bucket\":\"$PERIOD\",\"withheld\":$CURVE_WITHHELD,\"points\":$CURVE_POINTS}"
else
  # A cumulative adoption curve over one or two people is a per-person report
  # wearing a chart. Suppress by default; the operator has to raise the floor on
  # purpose and can see in the page that something was withheld.
  J_CURVE="{\"population\":$POPULATION,\"min_cohort\":$MIN_COHORT,\"suppressed\":true,\"bucket\":\"$PERIOD\",\"withheld\":$POPULATION,\"points\":[]}"
  [ "$POPULATION" -gt 0 ] && dxm_log "adoption curve suppressed: population $POPULATION < min-cohort $MIN_COHORT"
fi

# ---- individuals: opt-in, adoption timing only -----------------------------
if [ "$INCLUDE_INDIVIDUALS" -eq 1 ]; then
  dxm_warn "--include-individuals: this render will contain contributor logins. Do not circulate it."
  J_INDIVIDUALS="$(jarr "
    SELECT i.login, t.first_ai_trailer_at, t.first_agent_key
      FROM agg_adoption_timeline t
      JOIN v_human_identities i ON i.identity_id = t.identity_id
     WHERE t.scope = $QSCOPE AND t.scope_key = $QKEY
     ORDER BY (t.first_ai_trailer_at IS NULL), t.first_ai_trailer_at, i.login;")"
else
  J_INDIVIDUALS="[]"
fi

# ---------------------------------------------------------------------------
# Coverage logging. Unit of output = one rendered metric card. The detail string
# is the evidence for how the card got its value; on a card that shows nothing
# it is the reason there was nothing to show.
# ---------------------------------------------------------------------------
{
  dxm_sql "
    SELECT 'metric' || char(9)
        || mc.metric_key || '@' || $QKEY || char(9)
        || 'script' || char(9)
        || CASE
             WHEN mc.computable = 0
               THEN 'catalog computable=0; rendered as explicitly unavailable with its reason'
             WHEN EXISTS (SELECT 1 FROM agg_metric m
                           WHERE m.metric_key = mc.metric_key AND m.scope = $QSCOPE
                             AND m.scope_key = $QKEY AND m.period_kind = $QPERIOD
                             AND m.period_start >= $QSINCE AND m.period_start <= $QUNTIL)
               THEN 'rendered from agg_metric rows joined to its metric_catalog row'
             ELSE 'metric_catalog row present but no agg_metric rows in window; rendered as not computed'
           END
      FROM metric_catalog mc;"
  # The one thing this renderer derives itself, declared as the degradation it is.
  printf 'metric\tadoption.agent_mix.breakdown@%s\tscript-with-fallback\t%s\n' \
    "$SCOPE_KEY" \
    "per-agent breakdown computed in the renderer from ai_trailers; agg_metric has no per-agent dimension"
} | dxm_coverage_batch "$RUN_ID"

# ---------------------------------------------------------------------------
# Assemble the payload.
# ---------------------------------------------------------------------------
GENERATED_AT="$(dxm_utc_now)"
INC_BOOL="false"; [ "$INCLUDE_INDIVIDUALS" -eq 1 ] && INC_BOOL="true"

# Strip the outer braces off the scalar object so unsafe_repos can be folded in.
INTEG_INNER="${J_INTEGRITY_SCALARS#\{}"; INTEG_INNER="${INTEG_INNER%\}}"

TMPDIR_RUN="$(mktemp -d "${TMPDIR:-/tmp}/dxm-dashboard.XXXXXX")"
# $? must be captured FIRST — rm would otherwise overwrite the script's real
# exit status and every failed run would close its row as 'ok'.
trap 'dxm_rc=$?; rm -rf "$TMPDIR_RUN"; dxm_run_trap '"$RUN_ID"' "$dxm_rc"' EXIT

DATA_RAW="$TMPDIR_RUN/data.json"
{
  printf '{'
  printf '"meta":{"scope":%s,"scope_key":%s,"period_kind":%s,"since":%s,"until":%s,' \
    "$(dxm_json_str "$SCOPE")" "$(dxm_json_str "$SCOPE_KEY")" "$(dxm_json_str "$PERIOD")" \
    "$(dxm_json_str "$SINCE")" "$(dxm_json_str "$UNTIL")"
  # db_path is deliberately NOT emitted: it carries the operator's username and
  # home-directory layout, and this file is meant to be handed to a client.
  printf '"current_bucket":%s,"generated_at":%s,"skill_version":%s,"pr_floor":%s,"run_id":%s,"include_individuals":%s},' \
    "$(dxm_json_str "$CUR_BUCKET")" "$(dxm_json_str "$GENERATED_AT")" \
    "$(dxm_json_str "$DXM_SKILL_VERSION")" "$(dxm_json_str "$PR_FLOOR")" "$RUN_ID" "$INC_BOOL"
  printf '"catalog":%s,'        "$J_CATALOG"
  printf '"metrics":%s,'        "$J_METRICS"
  printf '"org_periods":%s,'    "$J_ORGPER"
  printf '"agents":%s,'         "$J_AGENTS"
  printf '"adoption_curve":%s,' "$J_CURVE"
  printf '"individuals":{"enabled":%s,"adoption":%s},' "$INC_BOOL" "$J_INDIVIDUALS"
  printf '"attribution":%s,' "$J_PAIR"
  printf '"integrity":{%s,"unsafe_repos":%s},' "$INTEG_INNER" "$J_UNSAFE"
  printf '"coverage":{"by_run":%s,"backlog":%s}' "$J_COVERAGE" "$J_BACKLOG"
  printf '}\n'
} > "$DATA_RAW"

# `</` inside a <script> block ends the element early, whatever the JSON says.
# `\/` is a legal JSON escape, so this is a no-op for any parser and a hard stop
# for the HTML tokeniser. Same for the comment opener, which can flip the
# tokeniser into the double-escaped script state.
DATA_SAFE="$TMPDIR_RUN/data.safe.json"
sed -e 's|</|<\\/|g' -e 's|<!--|<\\u0021--|g' "$DATA_RAW" > "$DATA_SAFE"

# ---------------------------------------------------------------------------
# Inject into the template. Split on the marker line and concatenate — no sed
# substitution, so the payload can contain any character without escaping games.
# ---------------------------------------------------------------------------
awk -v pre="$TMPDIR_RUN/pre.html" -v post="$TMPDIR_RUN/post.html" '
  index($0, "__DXM_DATA__") && !seen { seen = 1; next }
  { print > (seen ? post : pre) }
  END { exit(seen ? 0 : 1) }
' "$TEMPLATE" || fail 2 "template $TEMPLATE has no __DXM_DATA__ marker"

if [ -z "$OUT_PATH" ]; then
  SAFE_KEY="$(printf '%s' "$SCOPE_KEY" | tr '/ ' '--' | tr -cd 'A-Za-z0-9._-')"
  # The individuals render MUST NOT be able to overwrite the shareable one. They
  # used to share a filename, so whoever held the file could not tell which of
  # the two they had, and a second run with the flag silently replaced the
  # no-PII copy in place.
  SUFFIX=""; [ "$INCLUDE_INDIVIDUALS" -eq 1 ] && SUFFIX="-INDIVIDUALS-do-not-circulate"
  OUT_PATH="$DXM_OUT/dx-metrics-${SAFE_KEY}-${PERIOD}-${UNTIL}${SUFFIX}.html"
fi

HTML_TMP="$TMPDIR_RUN/out.html"
cat "$TMPDIR_RUN/pre.html" "$DATA_SAFE" "$TMPDIR_RUN/post.html" > "$HTML_TMP"
BYTES="$(wc -c < "$HTML_TMP" | tr -d ' ')"

if [ "$DRY_RUN" -eq 1 ]; then
  dxm_log "dry run: would write $BYTES bytes to $OUT_PATH"
  OUT_REPORTED=""
else
  mkdir -p "$(dirname "$OUT_PATH")"
  cp "$HTML_TMP" "$OUT_PATH"          # cp, not mv: $TMPDIR may be another device
  chmod 600 "$OUT_PATH"               # it may name people; do not world-read it
  OUT_REPORTED="$OUT_PATH"
  dxm_log "wrote $BYTES bytes to $OUT_PATH"
fi

# ---------------------------------------------------------------------------
# Envelope. Counts only — no repo lists, no logins, no titles. Under ~2 KB.
# ---------------------------------------------------------------------------
n_metrics_rendered="$(dxm_sql1 "SELECT COUNT(DISTINCT metric_key) FROM agg_metric
                                 WHERE scope=$QSCOPE AND scope_key=$QKEY AND period_kind=$QPERIOD
                                   AND period_start >= $QSINCE AND period_start <= $QUNTIL;")"
n_catalog="$(dxm_sql1 "SELECT COUNT(*) FROM metric_catalog;")"
n_uncomputable="$(dxm_sql1 "SELECT COUNT(*) FROM metric_catalog WHERE computable=0;")"
n_buckets="$(dxm_sql1 "SELECT COUNT(*) FROM agg_org_period
                        WHERE scope=$QSCOPE AND scope_key=$QKEY AND period_kind=$QPERIOD
                          AND period_start >= $QSINCE AND period_start <= $QUNTIL;")"
n_unsafe="$(dxm_sql1 "SELECT COUNT(*) FROM v_unsafe_repos v
                       WHERE v.full_name IN (SELECT r.full_name FROM repos r WHERE $F_REPOS);")"
# The run's own quality signal, in the envelope, so a caller that never opens
# the HTML still learns whether the trend on it is presentable.
UNK_PCT="$(dxm_sql1 "
  SELECT printf('%.1f', 100.0*SUM(c.steerer_state='unknown')/NULLIF(COUNT(*),0))
    FROM v_commits_enriched c
   WHERE $F_COMMITS AND $W_COMMITS AND c.is_merge=0 AND c.steerer_state<>'machine';")"
[ -n "$UNK_PCT" ] || UNK_PCT=null

dxm_run_finish "$RUN_ID" ok 0
dxm_emit true "$SELF" "$RUN_ID" "$(printf '"scope":%s,"scope_key":%s,"period":%s,"since":%s,"until":%s,"buckets":%s,"metrics_with_data":%s,"metrics_in_catalog":%s,"metrics_not_computable":%s,"unsafe_repos":%s,"include_individuals":%s,"suppressed_adoption_curve":%s,"unknown_steerer_pct":'"$UNK_PCT"',"bytes":%s,"out":%s' \
  "$(dxm_json_str "$SCOPE")" "$(dxm_json_str "$SCOPE_KEY")" "$(dxm_json_str "$PERIOD")" \
  "$(dxm_json_str "$SINCE")" "$(dxm_json_str "$UNTIL")" \
  "${n_buckets:-0}" "${n_metrics_rendered:-0}" "${n_catalog:-0}" "${n_uncomputable:-0}" "${n_unsafe:-0}" \
  "$INC_BOOL" \
  "$([ "$POPULATION" -ge "$MIN_COHORT" ] && [ "$POPULATION" -gt 0 ] && echo false || echo true)" \
  "$BYTES" "$(dxm_json_str "$OUT_REPORTED")")"
