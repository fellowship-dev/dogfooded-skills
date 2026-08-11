#!/usr/bin/env bash
# dxm-aggregate.test.sh — standalone test suite for dxm-aggregate.sh.       [W4]
#
# Self-contained: builds its own SQLite fixture with hand-computable answers in
# a throwaway DXM_HOME, so it touches neither the real database nor the network
# and needs nothing from the other workstreams.
#
#   ./dxm-aggregate.test.sh          # run everything, exit non-zero on failure
#
# The fixture is small on purpose. Every expected number below was worked out by
# hand from the INSERTs at the bottom of this file, so a failure means the
# aggregation changed — not that a golden file drifted.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
AGG="$SCRIPT_DIR/dxm-aggregate.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/dxm-agg-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
export DXM_HOME="$TMP/home"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf 'PASS  %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf 'FAIL  %s  -- %s\n' "$1" "${2:-}"; }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$3] got [$2]"; fi; }
Q()   { sqlite3 "$DXM_HOME/dxm.db" "$1"; }
fresh() {
  rm -rf "$DXM_HOME"; mkdir -p "$DXM_HOME"
  sqlite3 "$DXM_HOME/dxm.db" < "$SKILL_DIR/schema.sql" >/dev/null
  sqlite3 "$DXM_HOME/dxm.db" < "$TMP/fixture.sql"
}
sed -n '/^# ---8<--- FIXTURE ---8<---$/,$p' "${BASH_SOURCE[0]}" | tail -n +2 | sed 's/^# \{0,1\}//' > "$TMP/fixture.sql"

echo "== 1. interface =="
OUT="$("$AGG" --help 2>/dev/null)"; eq "--help exits 0"          "$?" "0"
case "$OUT" in *"must not be used to measure individual performance"*) ok "--help states the privacy rule";; *) bad "--help states the privacy rule";; esac
"$AGG" --bogus >/dev/null 2>&1; eq "unknown flag exits 1"        "$?" "1"
"$AGG" --period fortnight >/dev/null 2>&1; eq "bad --period exits 1" "$?" "1"
"$AGG" --since 06-01-2026 >/dev/null 2>&1; eq "bad --since exits 1" "$?" "1"
"$AGG" --adoption-window-days x >/dev/null 2>&1; eq "bad window exits 1" "$?" "1"

echo
echo "== 2. preconditions =="
fresh
OUT="$("$AGG" --repo acme/legacy --until 2026-06-20 2>/dev/null)"; RC=$?
eq "shallow repo exits 2" "$RC" "2"
case "$OUT" in *'"ok":false'*) ok "shallow emits ok:false envelope";; *) bad "shallow emits ok:false envelope" "$OUT";; esac
"$AGG" --repo acme/nope --until 2026-06-20 >/dev/null 2>&1; eq "unknown repo exits 2" "$?" "2"

echo
echo "== 3. stdout discipline =="
fresh
OUT="$("$AGG" --repo acme/api --repo acme/web --until 2026-06-20 --adoption-window-days 3 2>/dev/null)"
eq "stdout is exactly one line" "$(printf '%s' "$OUT" | wc -l | tr -d ' ')" "0"
python3 -c "import json,sys; json.loads(sys.argv[1])" "$OUT" 2>/dev/null && ok "stdout is valid JSON" || bad "stdout is valid JSON" "$OUT"
SZ=$(printf '%s' "$OUT" | wc -c | tr -d ' ')
if [ "$SZ" -lt 2048 ]; then ok "envelope under 2KB ($SZ bytes)"; else bad "envelope under 2KB" "$SZ bytes"; fi
# privacy: no login may appear on stdout or in DXM_OUT
LEAK=0
for name in alice bob carol dependabot; do
  case "$OUT" in *"$name"*) LEAK=1;; esac
done
eq "no login on stdout" "$LEAK" "0"

echo
echo "== 4. arithmetic (hand-computed fixture) =="
eq "week A commits"            "$(Q "SELECT commits FROM agg_org_period WHERE scope_key='acme/api' AND period_start='2026-06-01'")" "7"
eq "week A ai_commits"         "$(Q "SELECT ai_commits FROM agg_org_period WHERE scope_key='acme/api' AND period_start='2026-06-01'")" "2"
eq "week A merged PRs"         "$(Q "SELECT prs_merged FROM agg_org_period WHERE scope_key='acme/api' AND period_start='2026-06-01'")" "3"
eq "week A opened PRs"         "$(Q "SELECT prs_opened FROM agg_org_period WHERE scope_key='acme/api' AND period_start='2026-06-01'")" "3"
eq "week B opened PRs"         "$(Q "SELECT prs_opened FROM agg_org_period WHERE scope_key='acme/api' AND period_start='2026-06-08'")" "4"
eq "week A cycle p50 = 60h"    "$(Q "SELECT round(cycle_time_p50_h,1) FROM agg_org_period WHERE scope_key='acme/api' AND period_start='2026-06-01'")" "60.0"
eq "week A cycle p75 = 96h"    "$(Q "SELECT round(cycle_time_p75_h,1) FROM agg_org_period WHERE scope_key='acme/api' AND period_start='2026-06-01'")" "96.0"
eq "week B cycle p50 = 51h"    "$(Q "SELECT round(cycle_time_p50_h,1) FROM agg_org_period WHERE scope_key='acme/api' AND period_start='2026-06-08'")" "51.0"
eq "org rolls up both repos"   "$(Q "SELECT commits FROM agg_org_period WHERE scope='org' AND period_start='2026-06-01'")" "8"
eq "throughput 3/2 = 1.5"      "$(Q "SELECT round(value,2) FROM agg_metric WHERE metric_key='speed.pr_throughput_per_contributor_week' AND scope_key='acme/api' AND period_start='2026-06-01'")" "1.5"
eq "defect ratio 1/2 = 50%"    "$(Q "SELECT round(value,1) FROM agg_metric WHERE metric_key='quality.defect_ratio' AND scope_key='acme/api' AND period_start='2026-06-01'")" "50.0"
eq "innovation 1/2 = 50%"      "$(Q "SELECT round(value,1) FROM agg_metric WHERE metric_key='impact.innovation_ratio' AND scope_key='acme/api' AND period_start='2026-06-01'")" "50.0"
eq "week B revert rate 50%"    "$(Q "SELECT round(value,1) FROM agg_metric WHERE metric_key='quality.revert_rate' AND scope_key='acme/api' AND period_start='2026-06-08'")" "50.0"
eq "ai commit share 2/7"       "$(Q "SELECT round(value,2) FROM agg_metric WHERE metric_key='adoption.ai_commit_share' AND scope_key='acme/api' AND period_start='2026-06-01'")" "28.57"
eq "identity resolution 6/7"   "$(Q "SELECT round(value,2) FROM agg_metric WHERE metric_key='meta.identity_resolution_pct' AND scope_key='acme/api' AND period_start='2026-06-01'")" "85.71"
eq "bus factor = 1"            "$(Q "SELECT CAST(value AS INT) FROM agg_metric WHERE metric_key='risk.bus_factor' AND scope_key='acme/api' AND period_start='2026-06-01'")" "1"
eq "top contributor 4/6"       "$(Q "SELECT round(value,2) FROM agg_metric WHERE metric_key='risk.top_contributor_commit_share' AND scope_key='acme/api' AND period_start='2026-06-01'")" "66.67"
eq "commit volume delta +50%"  "$(Q "SELECT round(value,1) FROM agg_metric WHERE metric_key='adoption.commit_volume_delta_pct_after_adoption' AND scope_key='acme/api'")" "50.0"
eq "alice before/after 2/3"    "$(Q "SELECT commits_before||'/'||commits_after FROM agg_adoption_timeline t JOIN identities i USING(identity_id) WHERE i.login='alice' AND t.scope_key='acme/api'")" "2/3"
eq "alice first agent"         "$(Q "SELECT first_agent_key FROM agg_adoption_timeline t JOIN identities i USING(identity_id) WHERE i.login='alice' AND t.scope_key='acme/api'")" "claude"

echo
echo "== 4b. the attribution pair (hand-computed) =="
# Week A of acme/api holds 7 non-merge commits: alice 4, bob 2, and ONE whose
# author email resolves to nobody. Under the old model that seventh commit was
# counted as human. Under the pair model it is an execution with an UNKNOWN
# STEERER: still in every execution denominator, never in a human numerator.
#
#   steerers            = 2                 (alice, bob)
#   commits_known       = 6                 -> leverage 6/2 = 3.0 commits/steerer
#   merged PRs known    = 3, PR steerers 2  -> leverage 3/2 = 1.5 PRs/steerer
#   unknown steerer     = 1 of 7            = 14.29%
#   agent executor      = 2 of 7            = 28.57%  (the headline AI floor)
#   unknown executor    = 5 of 7            = 71.43%  (NOT a human share)
#   agent executor over known steerers only = 2 of 6 = 33.33%
# The last two lines are the point: 28.57 vs 33.33 is the attribution artifact,
# published as two series instead of argued about.
A_W="scope_key='acme/api' AND period_start='2026-06-01'"
eq "steerers = 2"                  "$(Q "SELECT CAST(value AS INT) FROM agg_metric WHERE metric_key='leverage.steerers' AND $A_W")" "2"
eq "leverage 6 commits / 2 = 3.0"  "$(Q "SELECT round(value,2) FROM agg_metric WHERE metric_key='leverage.commits_per_steerer' AND $A_W")" "3.0"
eq "leverage 3 PRs / 2 = 1.5"      "$(Q "SELECT round(value,2) FROM agg_metric WHERE metric_key='leverage.merged_prs_per_steerer' AND $A_W")" "1.5"
eq "leverage numerator excludes the unknown steerer" \
   "$(Q "SELECT CAST(numerator AS INT) FROM agg_metric WHERE metric_key='leverage.commits_per_steerer' AND $A_W")" "6"
eq "leverage says so in its note" \
   "$(Q "SELECT note LIKE '%no identifiable steerer%UNDERSTATES%' FROM agg_metric WHERE metric_key='leverage.commits_per_steerer' AND $A_W")" "1"
eq "unknown-steerer share 1/7"     "$(Q "SELECT round(value,2) FROM agg_metric WHERE metric_key='meta.unknown_steerer_share' AND $A_W")" "14.29"
eq "unknown-EXECUTOR share 5/7"    "$(Q "SELECT round(value,2) FROM agg_metric WHERE metric_key='adoption.executor_unknown_share' AND $A_W")" "71.43"
eq "unknown executor is not called human" \
   "$(Q "SELECT note LIKE '%UNKNOWN EXECUTOR IS NOT HUMAN EXECUTOR%' FROM agg_metric WHERE metric_key='adoption.executor_unknown_share' AND $A_W")" "1"
eq "AI floor over all executions 2/7"        "$(Q "SELECT round(value,2) FROM agg_metric WHERE metric_key='adoption.ai_commit_share' AND $A_W")" "28.57"
eq "AI floor over known steerers only 2/6"   "$(Q "SELECT round(value,2) FROM agg_metric WHERE metric_key='adoption.ai_commit_share_known_steerer' AND $A_W")" "33.33"
eq "the AI share declares itself a FLOOR"    "$(Q "SELECT note LIKE 'FLOOR of agent-executed share%' FROM agg_metric WHERE metric_key='adoption.ai_commit_share' AND $A_W")" "1"
eq "the AI share is LABELLED a floor in the catalog" \
   "$(Q "SELECT label LIKE '%FLOOR%' FROM metric_catalog WHERE metric_key='adoption.ai_commit_share'")" "1"
eq "unknown steerers are never in v_human_identities" \
   "$(Q "SELECT COUNT(*) FROM v_commits_enriched c JOIN v_human_identities i ON i.identity_id=c.author_identity_id WHERE c.steerer_state='unknown'")" "0"
eq "no commit can have a 'human' executor" \
   "$(Q "SELECT COUNT(*) FROM v_commits_enriched WHERE executor_state NOT IN ('agent','unknown')")" "0"
eq "every leverage metric has a catalog row" \
   "$(Q "SELECT COUNT(*) FROM agg_metric m LEFT JOIN metric_catalog c USING(metric_key) WHERE m.metric_key LIKE 'leverage.%' AND c.metric_key IS NULL")" "0"

echo
echo "== 5. exclusions =="
eq "no bot rows in agg_author_period" "$(Q "SELECT COUNT(*) FROM agg_author_period a JOIN identities i USING(identity_id) WHERE i.is_bot=1")" "0"
eq "bot PR not counted"        "$(Q "SELECT SUM(prs_merged) FROM agg_org_period WHERE scope_key='acme/api'")" "5"
eq "shallow repo absent"       "$(Q "SELECT COUNT(*) FROM agg_org_period WHERE scope_key='acme/legacy'")" "0"
eq "merge commit excluded"     "$(Q "SELECT SUM(commits) FROM agg_org_period WHERE scope_key='acme/api'")" "17"

echo
echo "== 6. honesty rules =="
eq "DXI value is NULL everywhere" "$(Q "SELECT COUNT(*) FROM agg_metric WHERE metric_key='effectiveness.dxi' AND value IS NOT NULL")" "0"
eq "DXI row exists per bucket"    "$(Q "SELECT COUNT(*) FROM agg_metric WHERE metric_key='effectiveness.dxi' AND scope_key='acme/api'")" "4"
eq "DXI note says unavailable"    "$(Q "SELECT note LIKE '%UNAVAILABLE%' FROM agg_metric WHERE metric_key='effectiveness.dxi' AND scope_key='acme/api' LIMIT 1")" "1"
eq "ownership_concentration NULL" "$(Q "SELECT COUNT(*) FROM agg_metric WHERE metric_key='risk.ownership_concentration' AND value IS NOT NULL")" "0"
eq "every metric has a catalog row" "$(Q "SELECT COUNT(*) FROM agg_metric m LEFT JOIN metric_catalog c USING(metric_key) WHERE c.metric_key IS NULL")" "0"
eq "every proxy declares itself"    "$(Q "SELECT COUNT(*) FROM agg_metric m JOIN metric_catalog c USING(metric_key) WHERE c.is_proxy=1 AND (c.proxy_statement IS NULL OR c.cannot_see IS NULL)")" "0"
eq "unclassified gap noted"    "$(Q "SELECT note LIKE '%unclassified%' FROM agg_metric WHERE metric_key='quality.defect_ratio' AND scope_key='acme/api' AND period_start='2026-06-01'")" "1"
eq "current bucket marked partial" "$(Q "SELECT COUNT(DISTINCT period_start) FROM agg_metric WHERE scope_key='acme/api' AND note LIKE 'partial period%'")" "1"
eq "partial is the last bucket"    "$(Q "SELECT DISTINCT period_start FROM agg_metric WHERE scope_key='acme/api' AND note LIKE 'partial period%'")" "2026-06-15"
eq "org rows carry shallow caveat" "$(Q "SELECT COUNT(*)>0 FROM agg_metric WHERE scope='org' AND note LIKE '%truncated%'")" "1"

echo
echo "== 7. coverage logging =="
eq "coverage rows written"     "$(Q "SELECT COUNT(*)>0 FROM coverage_log WHERE unit_kind='metric'")" "1"
eq "no coverage row lacks detail" "$(Q "SELECT COUNT(*) FROM coverage_log WHERE detail IS NULL OR detail=''")" "0"
eq "classifier weakness inherited" "$(Q "SELECT method FROM coverage_log WHERE unit_key='acme/api:quality.defect_ratio'")" "script-with-fallback"

echo
echo "== 8. idempotency / rebuild / incremental =="
SNAP1="$(Q "SELECT group_concat(scope||scope_key||period_start||commits||prs_merged||COALESCE(cycle_time_p50_h,'')) FROM (SELECT * FROM agg_org_period ORDER BY scope,scope_key,period_start)")"
M1="$(Q "SELECT COUNT(*)||':'||COALESCE(ROUND(SUM(value),6),'') FROM agg_metric")"
"$AGG" --repo acme/api --repo acme/web --until 2026-06-20 --adoption-window-days 3 >/dev/null 2>&1
SNAP2="$(Q "SELECT group_concat(scope||scope_key||period_start||commits||prs_merged||COALESCE(cycle_time_p50_h,'')) FROM (SELECT * FROM agg_org_period ORDER BY scope,scope_key,period_start)")"
M2="$(Q "SELECT COUNT(*)||':'||COALESCE(ROUND(SUM(value),6),'') FROM agg_metric")"
eq "re-run: agg_org_period identical" "$SNAP2" "$SNAP1"
eq "re-run: agg_metric identical"     "$M2" "$M1"
eq "re-run reported incremental"      "$("$AGG" --repo acme/api --until 2026-06-20 --adoption-window-days 3 2>/dev/null | python3 -c 'import json,sys;print(json.load(sys.stdin)["mode"])')" "incremental"
"$AGG" --repo acme/api --repo acme/web --until 2026-06-20 --adoption-window-days 3 --rebuild >/dev/null 2>&1
SNAP3="$(Q "SELECT group_concat(scope||scope_key||period_start||commits||prs_merged||COALESCE(cycle_time_p50_h,'')) FROM (SELECT * FROM agg_org_period ORDER BY scope,scope_key,period_start)")"
eq "--rebuild reproduces the same numbers" "$SNAP3" "$SNAP1"

echo
echo "== 9. dry run =="
fresh
OUT="$("$AGG" --repo acme/api --until 2026-06-20 --dry-run 2>/dev/null)"
eq "dry run writes no agg_org_period" "$(Q "SELECT COUNT(*) FROM agg_org_period")" "0"
eq "dry run writes no agg_metric"     "$(Q "SELECT COUNT(*) FROM agg_metric")" "0"
eq "dry run writes no coverage"       "$(Q "SELECT COUNT(*) FROM coverage_log")" "0"
eq "dry run still reports buckets"    "$(printf '%s' "$OUT" | python3 -c 'import json,sys;print(json.load(sys.stdin)["buckets"]>0)')" "True"

echo
echo "== 10. period kinds =="
fresh
for p in day week month; do
  "$AGG" --repo acme/api --period $p --until 2026-06-20 >/dev/null 2>&1
  eq "--period $p ran" "$?" "0"
done
eq "day buckets present"   "$(Q "SELECT COUNT(*)>0 FROM agg_org_period WHERE period_kind='day'")" "1"
eq "month bucket is the 1st" "$(Q "SELECT COUNT(*) FROM agg_org_period WHERE period_kind='month' AND period_start NOT LIKE '%-01'")" "0"
eq "week metric absent for month" "$(Q "SELECT COUNT(*) FROM agg_metric WHERE metric_key='speed.pr_throughput_per_contributor_week' AND period_kind='month'")" "0"
eq "monthly totals equal weekly totals" \
   "$(Q "SELECT SUM(commits) FROM agg_org_period WHERE period_kind='month' AND scope_key='acme/api'")" \
   "$(Q "SELECT SUM(commits) FROM agg_org_period WHERE period_kind='week' AND scope_key='acme/api'")"
eq "daily totals equal weekly totals" \
   "$(Q "SELECT SUM(commits) FROM agg_org_period WHERE period_kind='day' AND scope_key='acme/api'")" \
   "$(Q "SELECT SUM(commits) FROM agg_org_period WHERE period_kind='week' AND scope_key='acme/api'")"

echo
echo "== 11. version-driven self-heal =="
Q "UPDATE agg_org_period SET agg_version='0-stale' WHERE period_kind='week';" >/dev/null
eq "stale agg_version forces rebuild" \
   "$("$AGG" --repo acme/api --period week --until 2026-06-20 2>/dev/null | python3 -c 'import json,sys;print(json.load(sys.stdin)["mode"])')" "version-change"
eq "no stale rows survive" "$(Q "SELECT COUNT(*) FROM agg_org_period WHERE agg_version='0-stale' AND scope_key='acme/api'")" "0"

echo
echo "== 13. --org expansion and late-arriving data =="
fresh
"$AGG" --org acme --until 2026-06-20 >/dev/null 2>&1
eq "--org tolerates a shallow member repo" "$?" "0"
eq "--org still excludes the shallow repo" "$(Q "SELECT COUNT(*) FROM agg_org_period WHERE scope_key='acme/legacy'")" "0"
eq "--org discloses the exclusion"         "$(Q "SELECT COUNT(*)>0 FROM agg_metric WHERE scope='org' AND note LIKE '%truncated%'")" "1"
eq "coverage metric populated"             "$(Q "SELECT value>0 FROM agg_metric WHERE metric_key='meta.script_coverage_pct' AND scope_key='acme/api'")" "1"
Q "INSERT INTO commits(repo_id,sha,author_email,author_name,author_identity_id,authored_at,is_merge,subject,insertions,deletions,files_changed)
   VALUES (1,'late01','bob@acme.com','Bob',2,'2026-06-02T11:00:00Z',0,'late',5,0,1);" >/dev/null
"$AGG" --org acme --until 2026-06-20 >/dev/null 2>&1
eq "backdated commit reopens its old bucket" "$(Q "SELECT commits FROM agg_org_period WHERE scope_key='acme/api' AND period_start='2026-06-01'")" "8"
Q "INSERT INTO pr_classifications(pr_id,class,is_revert,confidence,method,rule,classifier_version) VALUES (3,'bugfix',0,0.8,'script','title:fix','t2');" >/dev/null
"$AGG" --org acme --until 2026-06-20 >/dev/null 2>&1
eq "re-classification reopens its old bucket" "$(Q "SELECT prs_unclassified FROM agg_org_period WHERE scope_key='acme/api' AND period_start='2026-06-01'")" "0"
eq "defect ratio follows the reclassify"      "$(Q "SELECT round(value,2) FROM agg_metric WHERE metric_key='quality.defect_ratio' AND scope_key='acme/api' AND period_start='2026-06-01'")" "66.67"
B="$(Q "SELECT group_concat(scope_key||period_start||commits||prs_merged) FROM (SELECT * FROM agg_org_period WHERE period_kind='week' ORDER BY scope,scope_key,period_start)")"
"$AGG" --org acme --until 2026-06-20 --rebuild >/dev/null 2>&1
eq "incremental result == full rebuild" "$(Q "SELECT group_concat(scope_key||period_start||commits||prs_merged) FROM (SELECT * FROM agg_org_period WHERE period_kind='week' ORDER BY scope,scope_key,period_start)")" "$B"

echo
echo "== 14. degenerate inputs =="
rm -rf "$DXM_HOME"; mkdir -p "$DXM_HOME"; sqlite3 "$DXM_HOME/dxm.db" < "$SKILL_DIR/schema.sql" >/dev/null
"$AGG" --until 2026-06-20 >/dev/null 2>&1; eq "empty database exits 2" "$?" "2"
fresh
# a repo whose only activity is a bot: no contributors, no division by zero
Q "INSERT INTO repos(repo_id,owner,name,full_name,is_shallow) VALUES (9,'acme','botonly','acme/botonly',0);
   INSERT INTO commits(repo_id,sha,author_email,author_name,author_identity_id,authored_at,is_merge,subject)
   VALUES (9,'z1','dep@bot','dependabot[bot]',3,'2026-06-02T00:00:00Z',0,'bump');" >/dev/null
"$AGG" --repo acme/botonly --until 2026-06-20 >/dev/null 2>&1
eq "bot-only repo aggregates cleanly" "$?" "0"
eq "bot-only repo has zero commits"   "$(Q "SELECT SUM(commits) FROM agg_org_period WHERE scope_key='acme/botonly'")" "0"
eq "no ratio invented from a zero denominator" "$(Q "SELECT COUNT(*) FROM agg_metric WHERE scope_key='acme/botonly' AND metric_key='adoption.ai_commit_share' AND value IS NOT NULL")" "0"

echo
echo "== 12. no dangling runs =="
eq "every run closed" "$(Q "SELECT COUNT(*) FROM runs WHERE status='running'")" "0"

echo
printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]

# ---8<--- FIXTURE ---8<---
# -- Synthetic fixture with hand-computable expected values.
# PRAGMA foreign_keys=ON;
# BEGIN;
# 
# INSERT INTO repos(repo_id,owner,name,full_name,default_branch,is_shallow,shallow_checked_at,first_commit_at,last_commit_at)
# VALUES (1,'acme','api','acme/api','main',0,'2026-06-20T00:00:00Z','2026-05-30T10:00:00Z','2026-06-13T08:00:00Z'),
#        (2,'acme','web','acme/web','main',0,'2026-06-20T00:00:00Z','2026-06-02T10:00:00Z','2026-06-02T10:00:00Z'),
#        (3,'acme','legacy','acme/legacy','main',1,'2026-06-20T00:00:00Z',NULL,NULL);
# 
# INSERT INTO identities(identity_id,login,display_name,account_type,is_bot,bot_reason)
# VALUES (1,'alice','Alice','User',0,NULL),
#        (2,'bob','Bob','User',0,NULL),
#        (3,'dependabot[bot]','Dependabot','Bot',1,'\[bot\]$'),
#        (4,'carol','Carol','User',0,NULL);
# 
# INSERT INTO identity_emails(email,identity_id,resolution_source,commit_count)
# VALUES ('alice@acme.com',1,'github_api',8),
#        ('bob@acme.com',2,'github_api',8),
#        ('nobody@example.com',NULL,'unresolved',1);
# 
# -- ---- commits: acme/api ----------------------------------------------------
# -- alice: 1 pre-window, 4 in week A (2 AI), 3 in week B (3 AI)
# INSERT INTO commits(repo_id,sha,author_email,author_name,author_identity_id,authored_at,is_merge,subject,insertions,deletions,files_changed) VALUES
#  (1,'a00','alice@acme.com','Alice',1,'2026-05-30T10:00:00Z',0,'pre',10,1,1),
#  (1,'a01','alice@acme.com','Alice',1,'2026-06-01T09:00:00Z',0,'wA1',10,1,2),
#  (1,'a02','alice@acme.com','Alice',1,'2026-06-01T10:00:00Z',0,'wA2 ai',20,2,3),
#  (1,'a03','alice@acme.com','Alice',1,'2026-06-02T10:00:00Z',0,'wA3 ai',30,3,1),
#  (1,'a04','alice@acme.com','Alice',1,'2026-06-03T10:00:00Z',0,'wA4',5,0,1),
#  (1,'a05','alice@acme.com','Alice',1,'2026-06-09T10:00:00Z',0,'wB1 ai',10,0,1),
#  (1,'a06','alice@acme.com','Alice',1,'2026-06-10T10:00:00Z',0,'wB2 ai',10,0,1),
#  (1,'a07','alice@acme.com','Alice',1,'2026-06-11T10:00:00Z',0,'wB3 ai',10,0,1),
# -- bob: 2 in week A, 6 in week B, no AI
#  (1,'b01','bob@acme.com','Bob',2,'2026-06-01T08:00:00Z',0,'wA',1,1,1),
#  (1,'b02','bob@acme.com','Bob',2,'2026-06-04T08:00:00Z',0,'wA',1,1,1),
#  (1,'b03','bob@acme.com','Bob',2,'2026-06-08T08:00:00Z',0,'wB',1,1,1),
#  (1,'b04','bob@acme.com','Bob',2,'2026-06-09T08:00:00Z',0,'wB',1,1,1),
#  (1,'b05','bob@acme.com','Bob',2,'2026-06-10T08:00:00Z',0,'wB',1,1,1),
#  (1,'b06','bob@acme.com','Bob',2,'2026-06-11T08:00:00Z',0,'wB',1,1,1),
#  (1,'b07','bob@acme.com','Bob',2,'2026-06-12T08:00:00Z',0,'wB',1,1,1),
#  (1,'b08','bob@acme.com','Bob',2,'2026-06-13T08:00:00Z',0,'wB',1,1,1),
# -- dependabot: 5 in week A, must be excluded everywhere
#  (1,'d01','dep@bot','dependabot[bot]',3,'2026-06-01T01:00:00Z',0,'bump',1,1,1),
#  (1,'d02','dep@bot','dependabot[bot]',3,'2026-06-02T01:00:00Z',0,'bump',1,1,1),
#  (1,'d03','dep@bot','dependabot[bot]',3,'2026-06-03T01:00:00Z',0,'bump',1,1,1),
#  (1,'d04','dep@bot','dependabot[bot]',3,'2026-06-04T01:00:00Z',0,'bump',1,1,1),
#  (1,'d05','dep@bot','dependabot[bot]',3,'2026-06-05T01:00:00Z',0,'bump',1,1,1),
# -- one merge commit in week A: excluded from counts
#  (1,'m01','alice@acme.com','Alice',1,'2026-06-05T12:00:00Z',1,'Merge pull request #1',0,0,0),
# -- one unattributed commit in week A
#  (1,'u01','nobody@example.com','Nobody',NULL,'2026-06-05T13:00:00Z',0,'orphan',7,0,1);
# 
# -- acme/web: one commit by carol, week A, so the org rollup differs from the repo
# INSERT INTO commits(repo_id,sha,author_email,author_name,author_identity_id,authored_at,is_merge,subject,insertions,deletions,files_changed)
# VALUES (2,'c01','carol@acme.com','Carol',4,'2026-06-02T10:00:00Z',0,'web',3,0,1);
# 
# -- ---- AI trailers ----------------------------------------------------------
# INSERT INTO ai_trailers(repo_id,sha,raw_name,raw_email,agent_key,is_ai) VALUES
#  (1,'a02','Claude','noreply@anthropic.com','claude',1),
#  (1,'a03','Claude','noreply@anthropic.com','claude',1),
#  (1,'a05','Claude','noreply@anthropic.com','claude',1),
#  (1,'a06','Claude','noreply@anthropic.com','claude',1),
#  (1,'a07','Codex','codex@openai.com','codex',1),
#  (1,'b01','Bob Human','bob2@acme.com',NULL,0);   -- human co-author: recorded, not AI
# 
# -- ---- pull requests: acme/api ---------------------------------------------
# INSERT INTO pull_requests(pr_id,repo_id,number,title,state,author_login,author_identity_id,created_at,merged_at,first_commit_at,github_updated_at,additions,deletions,changed_files,commit_count) VALUES
#  (1,1,1,'feat: thing','MERGED','alice',1,'2026-06-01T09:00:00Z','2026-06-02T09:00:00Z','2026-06-01T09:00:00Z','2026-06-02T09:00:00Z',30,3,5,2),
#  (2,1,2,'fix: bug','MERGED','bob',2,'2026-06-01T00:00:00Z','2026-06-05T00:00:00Z','2026-06-01T00:00:00Z','2026-06-05T00:00:00Z',2,2,2,1),
#  (3,1,3,'chore: mystery','MERGED','alice',1,'2026-06-03T00:00:00Z','2026-06-06T00:00:00Z',NULL,'2026-06-06T00:00:00Z',1,1,1,1),
#  (4,1,4,'chore(deps): bump','MERGED','dependabot[bot]',3,'2026-06-02T00:00:00Z','2026-06-03T00:00:00Z','2026-06-02T00:00:00Z','2026-06-03T00:00:00Z',1,1,1,1),
#  (5,1,5,'Revert "feat: thing"','MERGED','alice',1,'2026-06-09T00:00:00Z','2026-06-10T00:00:00Z','2026-06-09T10:00:00Z','2026-06-10T00:00:00Z',1,1,1,1),
#  (6,1,6,'feat: other','MERGED','bob',2,'2026-06-08T00:00:00Z','2026-06-12T00:00:00Z','2026-06-08T08:00:00Z','2026-06-12T00:00:00Z',1,1,1,1),
#  (7,1,7,'feat: never landed','CLOSED','bob',2,'2026-06-08T00:00:00Z',NULL,'2026-06-08T08:00:00Z','2026-06-09T00:00:00Z',1,1,1,1),
#  (8,1,8,'feat: still open','OPEN','alice',1,'2026-06-11T00:00:00Z',NULL,'2026-06-11T10:00:00Z','2026-06-11T00:00:00Z',1,1,1,1);
# 
# INSERT INTO pr_commits(pr_id,repo_id,sha) VALUES
#  (1,1,'a01'),(1,1,'a02'),
#  (2,1,'b01'),(2,1,'b02'),
#  (3,1,'a04'),
#  (4,1,'d01'),
#  (5,1,'a05'),
#  (6,1,'b03');
# 
# INSERT INTO pr_classifications(pr_id,class,is_revert,confidence,method,rule,classifier_version) VALUES
#  (1,'feature',0,0.95,'script','conventional-commit:feat','t1'),
#  (2,'bugfix', 0,0.95,'script','conventional-commit:fix','t1'),
#  -- PR 3 deliberately left unclassified: it is the denominator gap
#  (4,'deps',   0,0.99,'script','conventional-commit:chore(deps)','t1'),
#  (5,'revert', 1,0.99,'llm','model-decided:revert','t1'),
#  (6,'feature',0,0.70,'script-with-fallback','label:enhancement','t1');
# 
# COMMIT;
