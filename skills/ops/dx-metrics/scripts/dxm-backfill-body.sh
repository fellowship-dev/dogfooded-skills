#!/usr/bin/env bash
# dxm-backfill-body.sh — populate commits.has_body / commits.body_chars from the
# cached bare clones. NO NETWORK: it reads clones that are already on disk and
# fails rather than fetching one.
#
# WHAT IT MEASURES, and why the definition is the whole point
# ----------------------------------------------------------
# Take the commit message. Drop the subject (line 1). Drop every TRAILER-SHAPED
# line — `^[ \t]*[A-Za-z-]+:[ \t]` — and drop blank lines. If anything at all
# remains, has_body = 1.
#
# STRIPPING TRAILERS IS MANDATORY. `Co-Authored-By: …` is the line that DEFINES
# executor_state='agent'. Leave it in and "multi-line commits predict
# AI-trailered commits" is not a finding, it is the same column twice.
#
# The trailer regex is deliberately broader than git's own interpretation: it
# also eats prose that happens to start `Note: `, `Fixes: `, `Ref: `. That
# biases has_body DOWN, never up, which is the safe direction for a signal whose
# failure mode is over-claiming AI usage.
#
# WHAT IT IS A PROXY FOR — read this before quoting any number derived from it:
#   Multi-line is a proxy for AGENTIC AI use, where the agent writes the commit
#   message. It is BLIND to assistive use (Copilot autocomplete, pasted ChatGPT
#   output) where the human writes the message. It is not "AI usage".
#
# NULL is a real third state. A commit whose SHA is not reachable in the cached
# clone (force-push, history rewrite) stays NULL and must be excluded from a
# ratio denominator. The envelope reports how many.
#
# OWNERSHIP: this script owns commits.has_body / commits.body_chars, which are
# additive columns declared in CONTRACT.md §10b. It writes nothing else.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/../lib/dxm-common.sh"

SELF="$(basename "$0")"

usage() {
  cat <<'EOF'
dxm-backfill-body.sh — populate commits.has_body / commits.body_chars from the
cached bare clones. Reads git only; never touches the network or the GitHub API.

USAGE
  dxm-backfill-body.sh [--org OWNER | --repo OWNER/NAME]... [options]

SCOPE
  --org OWNER            Every repo of this org that has a cached clone. Repeatable.
  --repo OWNER/NAME      One repo. Repeatable.
  (neither)              Every repo in the database that has a cached clone.

OPTIONS
  --rebuild              Recompute every commit, not only the ones still NULL.
  --dry-run              Compute and report; write nothing.
  --json                 Accepted and ignored; JSON on stdout is the only mode.
  --help                 This text.

DEFINITION
  has_body = 1 when, after dropping the subject line, dropping every
  trailer-shaped line (^\s*[A-Za-z-]+:\s) and dropping blanks, anything remains.
  body_chars = characters retained by the same filter.
  Trailer stripping is mandatory: without it Co-Authored-By leaks into the
  feature and any correlation with AI attribution is circular.

  has_body IS NULL means the commit's SHA is not reachable in the cached clone
  and the signal is NOT MEASURABLE for it. Never read NULL as 0.

OUTPUT CONTRACT
  Exactly one line of JSON on stdout. Everything else on stderr.
  Exit 0 ok · 1 usage · 2 precondition · 3 partial · 4 data error.
EOF
}

ORGS=(); REPOS=(); REBUILD=0; DRY_RUN=0
while [ $# -gt 0 ]; do
  case "$1" in
    --help|-h) usage; exit 0 ;;
    --org)     ORGS+=("${2:-}");  shift 2 ;;
    --repo)    REPOS+=("${2:-}"); shift 2 ;;
    --rebuild) REBUILD=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --json)    shift ;;
    *) dxm_die "unknown flag: $1 (try --help)" 1 ;;
  esac
done
for r in ${REPOS+"${REPOS[@]}"}; do
  case "$r" in */*) ;; *) dxm_die "--repo must be owner/name, got: $r" 1 ;; esac
done

dxm_require_cmd git awk sqlite3
dxm_init_db
RUN_ID="$(dxm_run_start "$SELF" "$*" "")"
trap 'dxm_run_trap '"$RUN_ID"' $?' EXIT

fail() { dxm_run_finish "$RUN_ID" error "$1" "$2"; dxm_emit false "$SELF" "$RUN_ID" "\"error\":$(dxm_json_str "$2")"; exit "$1"; }

# commits.has_body / commits.body_chars are additive columns (CONTRACT.md §10b).
# The migration lives in dxm_init_db (lib/dxm-common.sh) because schema.sql's own
# index and view reference the columns and would fail to apply without them; by
# the time this line runs they exist. Asserted rather than assumed.
for col in has_body body_chars; do
  n="$(dxm_sql1 "SELECT COUNT(*) FROM pragma_table_info('commits') WHERE name='$col';")"
  [ "${n:-0}" = "1" ] || fail 2 "commits.$col missing after dxm_init_db; the migration in lib/dxm-common.sh did not run"
done

# ---------------------------------------------------------------------------
# Repo selection. A repo with no cached clone is skipped and COUNTED, never
# silently dropped: "0% of this repo is multi-line" and "this repo was never
# measured" must not look the same downstream.
# ---------------------------------------------------------------------------
WHERE="1=1"
if [ "${#REPOS[@]}" -gt 0 ] || [ "${#ORGS[@]}" -gt 0 ]; then
  clauses=""
  for r in ${REPOS+"${REPOS[@]}"}; do clauses="$clauses OR full_name=$(dxm_q "$r")"; done
  for o in ${ORGS+"${ORGS[@]}"};  do clauses="$clauses OR owner=$(dxm_q "$o")";     done
  WHERE="(0=1${clauses})"
fi

REPO_ROWS="$(dxm_sql "SELECT repo_id || char(9) || full_name || char(9) || COALESCE(clone_path,'') FROM repos WHERE $WHERE ORDER BY full_name;")"
[ -n "$REPO_ROWS" ] || fail 4 "no repos matched the requested scope"

TMPD="$(mktemp -d "${TMPDIR:-/tmp}/dxm-body.XXXXXX")"
trap 'dxm_rc=$?; rm -rf "$TMPD"; dxm_run_trap '"$RUN_ID"' "$dxm_rc"' EXIT

N_REPOS=0; N_SKIPPED=0; N_UPDATED=0; N_SEEN=0
COV="$TMPD/coverage.tsv"; : > "$COV"

while IFS=$'\t' read -r repo_id full_name clone_path; do
  [ -n "${repo_id:-}" ] || continue
  [ -n "$clone_path" ] || clone_path="$DXM_CACHE/$(printf '%s' "$full_name" | tr '/' '_' | sed 's/_/__/')"
  if [ ! -d "$clone_path" ]; then
    # Second chance on the documented cache naming, then give up on this repo.
    alt="$DXM_CACHE/${full_name%%/*}__${full_name#*/}.git"
    if [ -d "$alt" ]; then clone_path="$alt"; else
      dxm_warn "no cached clone for $full_name (looked in $clone_path) — skipped"
      N_SKIPPED=$((N_SKIPPED+1))
      printf 'commit_body\t%s\tllm\tno cached clone on disk; commit bodies are not measurable for this repo without a fetch, and this script never fetches\n' "$full_name" >> "$COV"
      continue
    fi
  fi

  # Only work that is needed. --rebuild forces the full pass.
  if [ "$REBUILD" -eq 0 ]; then
    pending="$(dxm_sql1 "SELECT COUNT(*) FROM commits WHERE repo_id=$repo_id AND has_body IS NULL;")"
    if [ "${pending:-0}" = "0" ]; then
      dxm_log "$full_name: already complete, skipping (use --rebuild to force)"
      printf 'commit_body\t%s\tscript\talready backfilled; no commit rows with has_body IS NULL\n' "$full_name" >> "$COV"
      N_REPOS=$((N_REPOS+1))
      continue
    fi
  fi

  # ONE git process per repo, streamed through ONE awk. --all so a commit that
  # left the default branch is still readable; the DB decides which SHAs matter.
  # \x1e separates records, \x1f separates sha from message, so a message
  # containing any newline, tab or quote is handled without escaping games.
  TSV="$TMPD/bodies.tsv"
  if ! git -C "$clone_path" log --all --format=$'\036%H\037%B' 2>/dev/null \
     | awk -v RS=$'\036' -v FS=$'\037' '
         NR == 1 && $0 == "" { next }
         {
           sha = $1
           if (sha !~ /^[0-9a-f]{7,40}$/) next
           n = split($2, L, "\n")
           chars = 0
           # i starts at 2: line 1 is the subject and is never body.
           for (i = 2; i <= n; i++) {
             line = L[i]
             sub(/[ \t\r]+$/, "", line)
             if (line ~ /^[ \t]*$/) continue                      # blank
             if (line ~ /^[ \t]*[A-Za-z-]+:[ \t]/) continue       # trailer-shaped
             chars += length(line)
           }
           printf "%s\t%d\t%d\n", sha, (chars > 0 ? 1 : 0), chars
         }' > "$TSV"; then
    dxm_warn "git log failed for $full_name — skipped"
    N_SKIPPED=$((N_SKIPPED+1))
    printf 'commit_body\t%s\tllm\tgit log failed against the cached clone\n' "$full_name" >> "$COV"
    continue
  fi

  seen="$(wc -l < "$TSV" | tr -d ' ')"
  N_SEEN=$((N_SEEN + seen))

  if [ "$DRY_RUN" -eq 1 ]; then
    dxm_log "$full_name: dry run, $seen commit messages read, nothing written"
    N_REPOS=$((N_REPOS+1))
    continue
  fi

  # Load into a TEMP table and update by join. One sqlite3 process per repo, one
  # transaction — not one UPDATE per commit.
  {
    echo "BEGIN;"
    echo "CREATE TEMP TABLE _bodies(sha TEXT PRIMARY KEY, hb INTEGER, bc INTEGER);"
    awk -F'\t' '{ printf "INSERT OR REPLACE INTO _bodies VALUES('\''%s'\'',%s,%s);\n", $1, $2, $3 }' "$TSV"
    cat <<SQL
UPDATE commits
   SET has_body   = (SELECT b.hb FROM _bodies b WHERE b.sha = commits.sha),
       body_chars = (SELECT b.bc FROM _bodies b WHERE b.sha = commits.sha)
 WHERE repo_id = $repo_id
   AND sha IN (SELECT sha FROM _bodies)
   AND ($REBUILD = 1 OR has_body IS NULL);
DROP TABLE _bodies;
COMMIT;
SQL
  } | dxm_sql_stdin || fail 4 "failed writing bodies for $full_name"

  done_n="$(dxm_sql1 "SELECT COUNT(*) FROM commits WHERE repo_id=$repo_id AND has_body IS NOT NULL;")"
  miss_n="$(dxm_sql1 "SELECT COUNT(*) FROM commits WHERE repo_id=$repo_id AND has_body IS NULL;")"
  N_UPDATED=$((N_UPDATED + ${done_n:-0}))
  N_REPOS=$((N_REPOS+1))
  dxm_log "$full_name: $seen messages read, $done_n commits measured, $miss_n unmeasurable"
  if [ "${miss_n:-0}" -gt 0 ]; then
    printf 'commit_body\t%s\tscript-with-fallback\tsubject+trailer-strip rule applied to %s commits; %s DB commits have no reachable SHA in the clone (history rewrite) and stay NULL\n' \
      "$full_name" "${done_n:-0}" "${miss_n:-0}" >> "$COV"
  else
    printf 'commit_body\t%s\tscript\tsubject+trailer-strip rule applied to all %s commits of this repo\n' \
      "$full_name" "${done_n:-0}" >> "$COV"
  fi
done <<EOF
$REPO_ROWS
EOF

[ -s "$COV" ] && dxm_coverage_batch "$RUN_ID" < "$COV"

TOT="$(dxm_sql1  "SELECT COUNT(*) FROM commits;")"
MEAS="$(dxm_sql1 "SELECT COUNT(*) FROM commits WHERE has_body IS NOT NULL;")"
UNMEAS=$(( ${TOT:-0} - ${MEAS:-0} ))

dxm_run_finish "$RUN_ID" ok 0
dxm_emit true "$SELF" "$RUN_ID" "$(printf '"repos":%s,"repos_skipped":%s,"messages_read":%s,"commits_measured_total":%s,"commits_unmeasurable_total":%s,"rebuild":%s,"dry_run":%s' \
  "$N_REPOS" "$N_SKIPPED" "$N_SEEN" "${MEAS:-0}" "$UNMEAS" \
  "$([ "$REBUILD" -eq 1 ] && echo true || echo false)" \
  "$([ "$DRY_RUN" -eq 1 ] && echo true || echo false)")"
