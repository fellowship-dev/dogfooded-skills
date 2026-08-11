#!/usr/bin/env bash
# dxm-classify.sh -- classify merged pull requests into change types using
# deterministic rules, and report honestly on what the rules could not decide.
#
# OWNERSHIP: W3. Writes exactly one table: pr_classifications.
# Reads: pull_requests, repos, identities (bot flag), v_unsafe_repos.
# Needs NO network and NO `gh` -- it works entirely on what W2 already ingested.
#
# The headline output is not the classes. It is the COVERAGE PERCENTAGE: the
# share of PRs a script could decide on its own. Everything it could not decide
# is written back as class='unclassified' with a machine-readable reason, which
# is the specification for the rule that does not exist yet.
#
# See references/classification-rules.md for the rule table and the rationale.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/dxm-common.sh
. "$SCRIPT_DIR/../lib/dxm-common.sh"
set -euo pipefail   # re-assert: the lib sets -uo pipefail for sourcing safety

DXM_CLASSIFIER_VERSION="1.0.0"
RULES_AWK="$SCRIPT_DIR/dxm-classify-rules.awk"
SELF="$(basename "$0")"

# Proxy declaration. CONTRACT.md Sec.9: a proxy says so in its own output, every
# time. This string is emitted in the envelope on every single run.
PROXY_NOTE="Proxy. PR class is a classifier's opinion read from titles, labels and branch names -- not a defect tracker. Unclassified PRs are reported, never silently dropped from the denominator."

TAB="$(printf '\t')"

usage() {
  cat <<'EOF'
dxm-classify.sh -- deterministic classification of merged pull requests.

USAGE
  dxm-classify.sh [--repo owner/name]... [--org owner] [options]

SELECTION
  --repo owner/name     Repo to classify. Repeatable. Must already be ingested.
  --org owner           All ingested repos owned by `owner`.
                        With neither flag, every repo in the database is used.
  --since YYYY-MM-DD    Floor on the PR's merge date (falls back to created_at).
  --until YYYY-MM-DD    Ceiling on the same. Default: today, UTC.
  --limit N             Classify at most N pull requests this run.

SCOPE
  --all-states          Also classify OPEN and CLOSED-unmerged PRs.
                        Default is merged-only, which is the universe every
                        Core 4 metric actually counts.
  --include-bots        Also classify bot-authored PRs. Default excludes them,
                        so the coverage percentage is measured over the PRs that
                        feed the metrics rather than being inflated by
                        trivially-classifiable Dependabot noise.
  --no-heuristics       Disable the low-confidence leading-verb rules
                        (`Fix ...` -> bugfix, `Add ...` -> feature). Coverage
                        drops; precision rises. Use it to see the honest floor.

WRITE BEHAVIOUR
  --rebuild             Re-classify everything in scope, discarding existing
                        rows. Improving the classifier is a re-run, never a
                        re-fetch of GitHub.
  --dry-run             Decide everything, write nothing. The envelope reports
                        the numbers it would have written in
                        `classification_coverage_pct`; the standard `coverage`
                        block stays at zero because no coverage_log rows were
                        written. That asymmetry is deliberate -- a dry run must
                        not move a number anyone else reads.

OUTPUT
  --emit-unresolved P   Write the undecided PRs to path P as TSV
                        (repo, number, title, labels, head_ref, base_ref,
                        reason). This is the LLM-fallback work queue. It never
                        contains an author login, name or email.
  --dump-rules          Print the rule table as one line of JSON and exit.
                        Needs no database.
  --help                This text.

ACCEPTED BUT NOT USED
  --period, --include-individuals, --json
                        Accepted so an orchestrator can pass a uniform flag set.
                        Reported back in the envelope as `ignored_flags` --
                        never swallowed silently.

EXIT CODES
  0 ok   1 usage   2 precondition (no DB / unknown repo)   4 data error

THIS SCRIPT NEVER CALLS AN LLM. It emits the unresolved list and the coverage
percentage; the fallback step is somebody else's turn.
EOF
}

dump_rules() {
  printf '%s\n' '{"ok":true,"script":"dxm-classify.sh","classifier_version":"'"$DXM_CLASSIFIER_VERSION"'","classes":["feature","bugfix","refactor","chore","docs","test","revert","deps","unclassified"],"subtypes":["hotfix","release"],"precedence":[{"stage":1,"family":"revert","rules":["revert:head-branch","revert:cc-prefix","revert:title","revert:reapply-rollforward","revert:head-prefix","revert:label"],"method":"script|script-with-fallback"},{"stage":2,"family":"deps","rules":["deps:bot-author","deps:head-branch","deps:cc-scope","deps:bump-title","deps:label"],"method":"script|script-with-fallback"},{"stage":3,"family":"conventional-commit","rules":["cc:<type>"],"method":"script"},{"stage":4,"family":"release","rules":["release:title","release:head-branch"],"method":"script-with-fallback"},{"stage":5,"family":"label","rules":["label:<name>"],"method":"script-with-fallback","note":"conflicting labels decide nothing"},{"stage":6,"family":"branch","rules":["branch:<segment>"],"method":"script-with-fallback"},{"stage":7,"family":"release-promotion","rules":["release:promotion"],"method":"script-with-fallback"},{"stage":7.5,"family":"backport","rules":["backport:cherry-pick"],"method":"script-with-fallback","note":"chore, not bugfix: the original PR was already counted"},{"stage":8,"family":"leading-verb","rules":["verb:release","verb:bump","verb:docs","verb:test","verb:fix","verb:refactor","verb:add"],"method":"script-with-fallback","note":"tried in this order; disabled by --no-heuristics"},{"stage":9,"family":"give-up","rules":["needs-llm"],"method":"llm"}],"never_calls_an_llm":true}'
}

# ---------------------------------------------------------------------------
# argument parsing. Unknown flags are a usage error (CONTRACT.md Sec.4).
# ---------------------------------------------------------------------------
REPOS=(); ORG=""; SINCE=""; UNTIL=""; LIMIT=""
ALL_STATES=0; INCLUDE_BOTS=0; HEUR=1; REBUILD=0; DRYRUN=0
UNRES_PATH=""; IGNORED=()

while [ $# -gt 0 ]; do
  case "$1" in
    --repo)             [ $# -ge 2 ] || dxm_die "--repo needs a value" 1; REPOS+=("$2"); shift 2 ;;
    --org)              [ $# -ge 2 ] || dxm_die "--org needs a value" 1; ORG="$2"; shift 2 ;;
    --since)            [ $# -ge 2 ] || dxm_die "--since needs a value" 1; SINCE="$2"; shift 2 ;;
    --until)            [ $# -ge 2 ] || dxm_die "--until needs a value" 1; UNTIL="$2"; shift 2 ;;
    --limit)            [ $# -ge 2 ] || dxm_die "--limit needs a value" 1; LIMIT="$2"; shift 2 ;;
    --emit-unresolved)  [ $# -ge 2 ] || dxm_die "--emit-unresolved needs a path" 1; UNRES_PATH="$2"; shift 2 ;;
    --all-states)       ALL_STATES=1; shift ;;
    --include-bots)     INCLUDE_BOTS=1; shift ;;
    --no-heuristics)    HEUR=0; shift ;;
    --rebuild)          REBUILD=1; shift ;;
    --dry-run)          DRYRUN=1; shift ;;
    --json)             shift ;;                                  # implicit, always
    --period)           [ $# -ge 2 ] || dxm_die "--period needs a value" 1; IGNORED+=("--period"); shift 2 ;;
    --include-individuals) IGNORED+=("--include-individuals"); shift ;;
    --dump-rules)       dump_rules; exit 0 ;;
    --help|-h)          usage; exit 0 ;;
    *)                  dxm_die "unknown flag: $1 (see --help)" 1 ;;
  esac
done

for d in "$SINCE" "$UNTIL"; do
  [ -z "$d" ] && continue
  case "$d" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;;
    *) dxm_die "date must be YYYY-MM-DD, got: $d" 1 ;;
  esac
done
if [ -n "$LIMIT" ]; then
  case "$LIMIT" in ''|*[!0-9]*) dxm_die "--limit must be a positive integer" 1 ;; esac
  [ "$LIMIT" -gt 0 ] || dxm_die "--limit must be a positive integer" 1
fi
for r in "${REPOS[@]+"${REPOS[@]}"}"; do
  case "$r" in */*) ;; *) dxm_die "repo must be owner/name, got: $r" 1 ;; esac
done
[ -f "$RULES_AWK" ] || dxm_die "rule engine not found: $RULES_AWK" 2
[ -z "$UNTIL" ] && UNTIL="$(date -u +%Y-%m-%d)"

# ---------------------------------------------------------------------------
# database + run bookkeeping
# ---------------------------------------------------------------------------
dxm_require_cmd sqlite3 awk
dxm_init_db

TMPD="$(mktemp -d "${TMPDIR:-/tmp}/dxm-classify.XXXXXX")"
RUN_ID="$(dxm_run_start "$SELF" "$*" "${REPOS[0]:-${ORG:-}}")"
_dxmc_cleanup() { local c="$1"; dxm_run_trap "$RUN_ID" "$c"; rm -rf "$TMPD"; }
trap '_dxmc_cleanup $?' EXIT

# A local sqlite3 wrapper: the shared one cannot do a custom column separator,
# and TSV is what the rule engine eats.
_dxmc_tsv() { sqlite3 -cmd ".timeout 10000" -noheader -separator "$TAB" "$DXM_DB" "$@"; }

# --- repo scope ------------------------------------------------------------
REPO_FILTER="1=1"
if [ "${#REPOS[@]}" -gt 0 ]; then
  list=""
  for r in "${REPOS[@]}"; do
    found="$(dxm_sql1 "SELECT COUNT(*) FROM repos WHERE full_name=$(dxm_q "$r");")"
    [ "$found" = "1" ] || dxm_die "repo not in database (ingest it first): $r" 2
    list="${list:+$list,}$(dxm_q "$r")"
  done
  REPO_FILTER="r.full_name IN ($list)"
elif [ -n "$ORG" ]; then
  found="$(dxm_sql1 "SELECT COUNT(*) FROM repos WHERE owner=$(dxm_q "$ORG");")"
  [ "${found:-0}" -gt 0 ] || dxm_die "no ingested repos for org: $ORG" 2
  REPO_FILTER="r.owner=$(dxm_q "$ORG")"
fi

# Shallow repos: W1 refuses to ingest them, but if one slipped through, say so
# loudly rather than quietly producing classifications nobody can trust.
# repos.is_shallow defaults to 1 -- "unsafe until W1 proves otherwise" -- so
# distinguish "never checked" from "checked and shallow" or the warning cries
# wolf on every fresh database.
UNSAFE="$(dxm_sql1 "SELECT COUNT(*) FROM repos r WHERE $REPO_FILTER AND r.is_shallow=1 AND r.shallow_checked_at IS NOT NULL;")"
UNCHECKED="$(dxm_sql1 "SELECT COUNT(*) FROM repos r WHERE $REPO_FILTER AND r.shallow_checked_at IS NULL;")"
[ "${UNSAFE:-0}" -eq 0 ] || dxm_warn "$UNSAFE repo(s) in scope are CONFIRMED shallow; their history is truncated and any metric built on these classifications will be wrong"
[ "${UNCHECKED:-0}" -eq 0 ] || dxm_warn "$UNCHECKED repo(s) in scope have not had their clone depth verified by the git ingest step yet"

STATE_FILTER="p.state='MERGED' AND p.merged_at IS NOT NULL"
[ "$ALL_STATES" -eq 1 ] && STATE_FILTER="1=1"

BOT_FILTER="COALESCE(i.is_bot,0)=0"
[ "$INCLUDE_BOTS" -eq 1 ] && BOT_FILTER="1=1"

DATE_EXPR="date(COALESCE(p.merged_at,p.created_at))"
DATE_FILTER="($DATE_EXPR IS NULL OR $DATE_EXPR <= $(dxm_q "$UNTIL"))"
[ -n "$SINCE" ] && DATE_FILTER="$DATE_FILTER AND ($DATE_EXPR IS NULL OR $DATE_EXPR >= $(dxm_q "$SINCE"))"

FRESH_FILTER="AND (c.pr_id IS NULL OR c.classifier_version <> $(dxm_q "$DXM_CLASSIFIER_VERSION"))"
[ "$REBUILD" -eq 1 ] && FRESH_FILTER=""

BASE_FROM="FROM pull_requests p
  JOIN repos r ON r.repo_id = p.repo_id
  LEFT JOIN identities i ON i.identity_id = p.author_identity_id
  LEFT JOIN pr_classifications c ON c.pr_id = p.pr_id
 WHERE $REPO_FILTER AND $STATE_FILTER AND $BOT_FILTER AND $DATE_FILTER"

# --- accounting the reader deserves: what was left out, and why -------------
TOT_PRS="$(dxm_sql1 "SELECT COUNT(*) FROM pull_requests p JOIN repos r ON r.repo_id=p.repo_id WHERE $REPO_FILTER;")"
SKIP_UNMERGED=0
[ "$ALL_STATES" -eq 0 ] && SKIP_UNMERGED="$(dxm_sql1 "SELECT COUNT(*) FROM pull_requests p JOIN repos r ON r.repo_id=p.repo_id WHERE $REPO_FILTER AND NOT (p.state='MERGED' AND p.merged_at IS NOT NULL);")"
SKIP_BOTS=0
[ "$INCLUDE_BOTS" -eq 0 ] && SKIP_BOTS="$(dxm_sql1 "SELECT COUNT(*) FROM pull_requests p JOIN repos r ON r.repo_id=p.repo_id LEFT JOIN identities i ON i.identity_id=p.author_identity_id WHERE $REPO_FILTER AND $STATE_FILTER AND COALESCE(i.is_bot,0)=1;")"
IN_SCOPE="$(dxm_sql1 "SELECT COUNT(*) FROM pull_requests p JOIN repos r ON r.repo_id=p.repo_id LEFT JOIN identities i ON i.identity_id=p.author_identity_id WHERE $REPO_FILTER AND $STATE_FILTER AND $BOT_FILTER AND $DATE_FILTER;")"
# A COUNT() can only come back empty if the query itself failed. Default them
# rather than letting an empty string reach $(( )) and abort the run there,
# where the cause would be invisible.
TOT_PRS="${TOT_PRS:-0}"; SKIP_UNMERGED="${SKIP_UNMERGED:-0}"
SKIP_BOTS="${SKIP_BOTS:-0}"; IN_SCOPE="${IN_SCOPE:-0}"

# ---------------------------------------------------------------------------
# extract the universe as TSV.
#
# Every text column is flattened in SQL (tabs/newlines -> space) so the TSV
# cannot be corrupted by a PR title. The dependency-bot test is done here, in
# SQL, and only its BOOLEAN leaves the database -- no author login is ever
# written to a temp file (CONTRACT.md Sec.8).
# ---------------------------------------------------------------------------
flat() { printf "replace(replace(replace(COALESCE(%s,''),char(9),' '),char(10),' '),char(13),' ')" "$1"; }

SQL_UNIVERSE="SELECT p.pr_id, r.full_name, p.number,
  $(flat p.title),
  lower($(flat p.label_csv)),
  $(flat p.head_ref),
  $(flat p.base_ref),
  CASE WHEN lower(COALESCE(p.body_excerpt,'')) LIKE '%fix #%'
         OR lower(COALESCE(p.body_excerpt,'')) LIKE '%fixes #%'
         OR lower(COALESCE(p.body_excerpt,'')) LIKE '%fixed #%'
         OR lower(COALESCE(p.body_excerpt,'')) LIKE '%close #%'
         OR lower(COALESCE(p.body_excerpt,'')) LIKE '%closes #%'
         OR lower(COALESCE(p.body_excerpt,'')) LIKE '%resolve #%'
         OR lower(COALESCE(p.body_excerpt,'')) LIKE '%resolves #%'
       THEN 1 ELSE 0 END,
  CASE WHEN lower(COALESCE(p.author_login,'')) LIKE 'dependabot%'
         OR lower(COALESCE(p.author_login,'')) LIKE 'renovate%'
         OR lower(COALESCE(p.author_login,'')) LIKE 'snyk-%'
         OR lower(COALESCE(p.author_login,'')) LIKE 'greenkeeper%'
         OR lower(COALESCE(p.author_login,'')) LIKE 'depfu%'
         OR lower(COALESCE(p.author_login,'')) LIKE 'pyup%'
         OR lower(COALESCE(p.author_login,'')) LIKE 'whitesource%'
         OR lower(COALESCE(p.author_login,'')) LIKE 'mend-%'
       THEN 1 ELSE 0 END
  $BASE_FROM $FRESH_FILTER
 ORDER BY p.pr_id"
[ -n "$LIMIT" ] && SQL_UNIVERSE="$SQL_UNIVERSE LIMIT $LIMIT"

# How many PRs are stale-or-new BEFORE --limit truncates. Without this,
# `already_current` would silently absorb the PRs that --limit deferred, and a
# limited run would look like a complete one.
DUE="$(dxm_sql1 "SELECT COUNT(*) $BASE_FROM $FRESH_FILTER;")"; DUE="${DUE:-0}"

_dxmc_tsv "$SQL_UNIVERSE;" > "$TMPD/universe.tsv" || dxm_die "failed to read pull_requests" 4
CANDIDATES="$(wc -l < "$TMPD/universe.tsv" | tr -d ' ')"
dxm_log "classify: $CANDIDATES candidate PR(s) of $IN_SCOPE in scope (repo total $TOT_PRS)"

# ---------------------------------------------------------------------------
# run the rule engine
# ---------------------------------------------------------------------------
: > "$TMPD/rows.sql"; : > "$TMPD/coverage.tsv"; : > "$TMPD/counts.tsv"
UNRES_TMP=""
if [ -n "$UNRES_PATH" ]; then
  UNRES_TMP="$TMPD/unresolved.tsv"; : > "$UNRES_TMP"
fi

if [ "$CANDIDATES" -gt 0 ]; then
  awk -v ver="$DXM_CLASSIFIER_VERSION" \
      -v heur="$HEUR" \
      -v sqlfile="$TMPD/rows.sql" \
      -v covfile="$TMPD/coverage.tsv" \
      -v cntfile="$TMPD/counts.tsv" \
      -v unresfile="$UNRES_TMP" \
      -f "$RULES_AWK" < "$TMPD/universe.tsv" \
    || dxm_die "rule engine failed" 4
fi

cnt() { awk -F'\t' -v b="$1" -v k="$2" '$1==b && $2==k {print $3; f=1} END{if(!f) print 0}' "$TMPD/counts.tsv"; }

DECIDED="$(cnt tot rows)"
WEAK="$(cnt tot weak)"
REVERTS="$(cnt tot reverts)"
N_UNCLASS="$(cnt class unclassified)"
N_SCRIPT="$(cnt method script)"
N_SWF="$(cnt method script-with-fallback)"
N_LLM="$(cnt method llm)"

# ---------------------------------------------------------------------------
# write
# ---------------------------------------------------------------------------
if [ "$DRYRUN" -eq 0 ] && [ "$DECIDED" -gt 0 ]; then
  if [ "$REBUILD" -eq 1 ]; then
    dxm_sql "DELETE FROM pr_classifications WHERE pr_id IN (SELECT p.pr_id $BASE_FROM);" \
      || dxm_die "failed to clear existing classifications" 4
  fi
  { echo "BEGIN;"; cat "$TMPD/rows.sql"; echo "COMMIT;"; } | dxm_sql_stdin \
    || dxm_die "failed to write pr_classifications" 4
  dxm_coverage_batch "$RUN_ID" < "$TMPD/coverage.tsv" \
    || dxm_die "failed to write coverage_log" 4
  if [ -n "$UNRES_PATH" ]; then
    mkdir -p "$(dirname "$UNRES_PATH")"
    { printf 'repo\tnumber\ttitle\tlabels\thead_ref\tbase_ref\treason\n'; cat "$UNRES_TMP"; } > "$UNRES_PATH"
  fi
elif [ "$DRYRUN" -eq 1 ]; then
  dxm_log "classify: --dry-run, nothing written"
fi

# ---------------------------------------------------------------------------
# envelope
# ---------------------------------------------------------------------------
json_kv_from_counts() {   # <bucket> -> "key":n,"key":n
  awk -F'\t' -v b="$1" '$1==b {gsub(/"/,"\\\"",$2); printf "%s\"%s\":%d", (n++?",":""), $2, $3}' "$TMPD/counts.tsv"
}
top_gaps() {
  awk -F'\t' '$1=="gap" {print}' "$TMPD/counts.tsv" \
    | sort -t"$TAB" -k3,3nr -k2,2 \
    | head -n 3 \
    | awk -F'\t' '{gsub(/"/,"\\\"",$2); printf "%s{\"reason\":\"%s\",\"hits\":%d}", (n++?",":""), $2, $3}'
}

COV_PCT="null"
if [ "$DECIDED" -gt 0 ]; then
  COV_PCT="$(awk -v s="$N_SCRIPT" -v f="$N_SWF" -v t="$DECIDED" 'BEGIN{printf "%.1f", 100.0*(s+f)/t}')"
fi

PAYLOAD="\"classifier_version\":\"$DXM_CLASSIFIER_VERSION\""
PAYLOAD="$PAYLOAD,\"repos_in_scope\":$(dxm_sql1 "SELECT COUNT(*) FROM repos r WHERE $REPO_FILTER;")"
PAYLOAD="$PAYLOAD,\"prs_total\":$TOT_PRS,\"prs_in_scope\":$IN_SCOPE,\"prs_examined\":$DECIDED"
PAYLOAD="$PAYLOAD,\"classified\":$((DECIDED - N_UNCLASS)),\"unclassified\":$N_UNCLASS"
PAYLOAD="$PAYLOAD,\"classification_coverage_pct\":$COV_PCT"
PAYLOAD="$PAYLOAD,\"weak_decisions\":$WEAK,\"reverts\":$REVERTS"
PAYLOAD="$PAYLOAD,\"by_class\":{$(json_kv_from_counts class)}"
PAYLOAD="$PAYLOAD,\"by_method\":{$(json_kv_from_counts method)}"
PAYLOAD="$PAYLOAD,\"subtypes\":{$(json_kv_from_counts subtype)}"
PAYLOAD="$PAYLOAD,\"top_gaps\":[$(top_gaps)]"
PAYLOAD="$PAYLOAD,\"skipped\":{\"bots\":$SKIP_BOTS,\"unmerged\":$SKIP_UNMERGED,\"already_current\":$((IN_SCOPE - DUE)),\"deferred_by_limit\":$((DUE - CANDIDATES))}"
PAYLOAD="$PAYLOAD,\"heuristics\":$([ "$HEUR" -eq 1 ] && echo true || echo false)"
PAYLOAD="$PAYLOAD,\"dry_run\":$([ "$DRYRUN" -eq 1 ] && echo true || echo false)"
[ -n "$UNRES_PATH" ] && PAYLOAD="$PAYLOAD,\"unresolved_file\":$(dxm_json_str "$UNRES_PATH")"
if [ "${#IGNORED[@]}" -gt 0 ]; then
  ig=""; for f in "${IGNORED[@]}"; do ig="${ig:+$ig,}$(dxm_json_str "$f")"; done
  PAYLOAD="$PAYLOAD,\"ignored_flags\":[$ig]"
fi
PAYLOAD="$PAYLOAD,\"proxy_note\":$(dxm_json_str "$PROXY_NOTE")"

dxm_run_finish "$RUN_ID" ok 0
dxm_emit true "$SELF" "$RUN_ID" "$PAYLOAD"
exit 0
