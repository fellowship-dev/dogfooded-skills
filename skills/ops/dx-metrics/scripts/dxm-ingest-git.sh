#!/usr/bin/env bash
# dxm-ingest-git.sh — W1. Local git -> commits + ai_trailers.
#
# Owns (write): repos (clone_path, is_shallow, default_branch, commit bounds),
#               commits (except author_identity_id / pr_number, which W2 fills),
#               ai_trailers.
#
# What it does NOT do, deliberately:
#   * no identity guessing — commit email is stored verbatim and lowercased;
#     resolving it to a GitHub login is W2's job, done server-side.
#   * no AI detection from PR/commit prose — AI attribution is Co-Authored-By
#     trailers and nothing else.
#
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/../lib/dxm-common.sh"
. "$SCRIPT_DIR/../lib/dxm-ingest-common.sh"

dxmi_usage() {
  cat <<'USAGE'
dxm-ingest-git.sh — ingest git history (commits + Co-Authored-By trailers) into the dx-metrics DB.

SYNOPSIS
  dxm-ingest-git.sh --repo owner/name [--repo owner/name ...] [options]
  dxm-ingest-git.sh --org owner [options]

TARGETS
  --repo owner/name   Repository to ingest. Repeatable.
  --org owner         Ingest every non-archived, non-fork, non-empty repo in the org.
                      (If gh is shimmed, export GH_REPO=owner/<any-repo> first.)

OPTIONS
  --since YYYY-MM-DD  Backfill floor. Only applied on a first/refetch pass.
  --until YYYY-MM-DD  Ceiling. Note: git filters these on COMMITTER date; the
                      time axis for every metric is AUTHOR date.
  --refetch           Ignore the stored watermark and re-scan full history.
                      Idempotent (upserts), so this repairs rather than duplicates.
  --rebuild           Accepted; git ingest writes only raw rows, so it re-scans
                      exactly like --refetch.
  --no-stats          Skip --shortstat. Much faster on a first backfill of a large
                      repo, but leaves insertions/deletions/files_changed NULL.
  --cache-dir DIR     Override the mirror cache (default $DXM_HOME/cache).
  --max-repos N       Cap on repos returned per --org (default 200).
  --dry-run           Read and parse, write nothing.
  --json              Default and implicit.
  --help              This text.

  --period, --include-individuals are accepted for flag-surface parity and have
  no effect here: bucketing lives in the views, and git ingest emits no personal
  data to stdout under any flag.

OUTPUT
  One line of JSON on stdout. Everything else goes to stderr.

EXIT CODES
  0 ok · 1 usage · 2 precondition (shallow clone, missing tool) · 3 partial
USAGE
}

DXMI_EXTRA_FLAGS="no-stats"
dxmi_parse_args "$@"

dxm_require_cmd git sqlite3 awk
dxm_init_db

RUN_ID=$(dxm_run_start "$(basename "$0")" "$*" "${DXMI_REPOS[0]:-${DXMI_ORGS[0]:-}}")
TMP="$(dxmi_tmpdir)"
trap 'rc=$?; rm -rf "$TMP"; dxm_run_trap '"$RUN_ID"' $rc' EXIT

# ---------------------------------------------------------------------------
# ai_agents patterns, newest-registered last so the 'other-ai' catch-all is only
# reached when no specific agent matched.
# ---------------------------------------------------------------------------
PATFILE="$TMP/agents.tsv"
# char(9) rather than sqlite3's default '|' separator: a regex pattern may well
# contain a pipe (alternation), and every seeded pattern does.
dxm_sql "SELECT agent_key || char(9) || pattern FROM ai_agents
         WHERE enabled=1 ORDER BY (agent_key='other-ai'), agent_id;" >"$PATFILE" 2>/dev/null || : >"$PATFILE"
[ -s "$PATFILE" ] || dxm_warn "no enabled ai_agents rows — every trailer will be recorded as a human co-author"

# ---------------------------------------------------------------------------
# The parser. Reads git log's record stream, writes SQL + a coverage TSV.
#
# Record framing: %x1e (RS) starts each record, %x1f (US) separates fields,
# %x1d (GS) separates trailer values. These bytes cannot occur in a commit
# subject or an email, so no quoting scheme is needed on the way in.
#
# The last field carries the trailers AND the --shortstat lines that git prints
# after the pretty output, hence the line walk.
#
# Q is built with sprintf(39) rather than written literally so the whole program
# can stay inside a single-quoted shell string.
# ---------------------------------------------------------------------------
AWK_COMMITS='
BEGIN {
  FS = "\037"
  Q = sprintf("%c", 39)
  na = 0
  # RS must still be "\n" HERE. getline honours the CURRENT RS, so setting
  # RS="\036" before this loop makes the whole newline-delimited pattern file
  # read back as ONE record: na==1, the first agent key wins every commit, and
  # every other agent silently disappears from the report. That produced a
  # fabricated "100% of AI commits are Claude" on a real client dashboard.
  # RS is consulted when the NEXT record is read, so assigning it after the
  # loop is both safe and required.
  while ((getline line < PATFILE) > 0) {
    if (line == "") continue
    p = index(line, "\t"); if (p == 0) continue
    na++; akey[na] = substr(line, 1, p-1); apat[na] = tolower(substr(line, p+1))
  }
  close(PATFILE)
  if (na == 0) { print "-- WARNING: no AI agent patterns loaded" > "/dev/stderr" }
  RS = "\036"
  print "PRAGMA foreign_keys=ON;"
  print "BEGIN;"
  nstmt = 0; ncommits = 0; nmerge = 0; ntrailers = 0; nai = 0; newest = ""
}
function sq(s) { if (s == "") return "NULL"; gsub(Q, Q Q, s); return Q s Q }
function num(s) { if (s == "") return "NULL"; return s+0 }
function tick() { nstmt++; if (nstmt % 2000 == 0) print "COMMIT;\nBEGIN;" }

NF < 8 { next }
{
  sha = $1; email = tolower($2); aname = $3; adate = $4; cdate = $5
  parents = $6; subj = $7
  rest = $8; for (i = 9; i <= NF; i++) rest = rest FS $i

  if (newest == "") newest = sha           # git log is newest-first
  np = split(parents, P, " ")
  is_merge = (np > 1) ? 1 : 0
  if (is_merge) nmerge++

  # --- split trailers from the trailing --shortstat lines -------------------
  nl = split(rest, L, "\n")
  trailers = (nl >= 1) ? L[1] : ""
  files = ""; ins = ""; del = ""; sawstat = 0
  for (j = 2; j <= nl; j++) {
    if (L[j] !~ /changed/) continue
    m = L[j]; sawstat = 1
    if (match(m, /[0-9]+ file/))      { t = substr(m, RSTART, RLENGTH); sub(/ file.*/, "", t);      files = t }
    if (match(m, /[0-9]+ insertion/)) { t = substr(m, RSTART, RLENGTH); sub(/ insertion.*/, "", t); ins = t }
    if (match(m, /[0-9]+ deletion/))  { t = substr(m, RSTART, RLENGTH); sub(/ deletion.*/, "", t);  del = t }
  }
  # NULL and 0 are different claims. A deletion-only commit really did add 0
  # lines and we know it; a merge commit (git prints no shortstat for one) is
  # genuinely unknown and must stay NULL so no aggregate treats it as zero work.
  if (sawstat) { if (files == "") files = "0"; if (ins == "") ins = "0"; if (del == "") del = "0" }

  # author_identity_id and pr_number are deliberately absent from the upsert:
  # they belong to W2 and must survive a git re-ingest.
  printf "INSERT INTO commits(repo_id,sha,author_email,author_name,authored_at,committed_at,is_merge,subject,files_changed,insertions,deletions,on_default_branch) VALUES(%d,%s,%s,%s,%s,%s,%d,%s,%s,%s,%s,1) ON CONFLICT(repo_id,sha) DO UPDATE SET author_email=excluded.author_email,author_name=excluded.author_name,authored_at=excluded.authored_at,committed_at=excluded.committed_at,is_merge=excluded.is_merge,subject=excluded.subject,files_changed=excluded.files_changed,insertions=excluded.insertions,deletions=excluded.deletions;\n", \
    REPO_ID, sq(sha), sq(email), sq(aname), sq(adate), sq(cdate), is_merge, sq(subj), num(files), num(ins), num(del)
  tick(); ncommits++

  if (trailers == "") next

  # --- trailers -------------------------------------------------------------
  best = ""; bestkey = ""; sawtrailer = 0; unmatched_domain = ""
  nt = split(trailers, T, "\035")
  for (k = 1; k <= nt; k++) {
    v = T[k]
    gsub(/^[ \t]+/, "", v); gsub(/[ \t]+$/, "", v)
    if (v == "") continue
    sawtrailer++; ntrailers++
    tname = v; temail = ""
    if (match(v, /<[^>]*>/)) {
      temail = tolower(substr(v, RSTART + 1, RLENGTH - 2))
      tname = substr(v, 1, RSTART - 1)
      gsub(/[ \t]+$/, "", tname)
    }
    subject_l = tolower(v)
    # UNIQUE(repo_id,sha,raw_email) treats NULLs as distinct, so a malformed
    # trailer with no <email> gets the whole lowercased value as its key rather
    # than being allowed to duplicate on every re-run.
    key = (temail != "") ? temail : subject_l

    agent = ""; isai = 0
    for (i = 1; i <= na; i++) { if (subject_l ~ apat[i]) { agent = akey[i]; isai = 1; break } }
    if (isai) {
      nai++
      if (best == "" || (bestkey == "other-ai" && agent != "other-ai")) { best = agent; bestkey = agent }
    } else if (unmatched_domain == "") {
      unmatched_domain = temail; sub(/^[^@]*@/, "", unmatched_domain)
      if (unmatched_domain == "") unmatched_domain = "(no-email)"
    }

    printf "INSERT INTO ai_trailers(repo_id,sha,raw_name,raw_email,agent_key,is_ai) VALUES(%d,%s,%s,%s,%s,%d) ON CONFLICT(repo_id,sha,raw_email) DO UPDATE SET raw_name=excluded.raw_name,agent_key=excluded.agent_key,is_ai=excluded.is_ai;\n", \
      REPO_ID, sq(sha), sq(tname), sq(key), sq(agent), isai
    tick()
  }

  # One coverage row per COMMIT THAT HAD TRAILERS — that is the unit where an
  # attribution decision was actually made. Commits with no trailer are not
  # logged: there was nothing to decide, and the "AI without a trailer is
  # invisible" blind spot is already declared in metric_catalog, not here.
  if (sawtrailer > 0) {
    if (bestkey != "" && bestkey != "other-ai")
      printf "%s\t%s\t%s\t%s\n", "ai_attribution", REPO "@" substr(sha,1,10), "script", "ai_agents:" bestkey > COVFILE
    else if (bestkey == "other-ai")
      printf "%s\t%s\t%s\t%s\n", "ai_attribution", REPO "@" substr(sha,1,10), "script-with-fallback", "ai_agents:other-ai generic catch-all matched; specific agent not identified" > COVFILE
    else
      printf "%s\t%s\t%s\t%s\n", "ai_attribution", REPO "@" substr(sha,1,10), "script-with-fallback", "no ai_agents pattern matched co-author domain " unmatched_domain "; assumed human. Add an ai_agents row if this is an agent." > COVFILE
  }
}
END {
  print "COMMIT;"
  printf "%d\t%d\t%d\t%d\t%s\n", ncommits, nmerge, ntrailers, nai, newest > STATFILE
}
'

# ---------------------------------------------------------------------------
# Main loop
# ---------------------------------------------------------------------------
TARGETS="$TMP/targets.tsv"
dxmi_list_targets >"$TARGETS"
[ -s "$TARGETS" ] || dxm_die "no ingestable repos resolved from the given targets" 1

n_ok=0; n_shallow=0; n_failed=0
tot_scanned=0; tot_new=0; tot_merges=0; tot_trailers=0; tot_ai=0

# The target list is read on fd 3, not stdin: gh and sqlite3 both run inside this
# loop and either would happily eat the remaining targets off stdin.
while IFS=$'\t' read -r -u 3 REPO BRANCH_HINT; do
  [ -n "${REPO:-}" ] || continue
  REPO_ID="$(dxm_repo_id "$REPO")"

  dxm_watermark_touch "$REPO_ID" git_commits sha
  dxm_watermark_touch "$REPO_ID" git_trailers sha

  # `rc=0; cmd || rc=$?` rather than toggling `set -e` around the call:
  # `set -e` is global, not function-scoped, so a callee that re-enables it
  # silently disarms the caller's guard and turns a handled `return 3` into an
  # abort. This bit once, in exactly that way.
  clone_rc=0
  dxmi_ensure_clone "$REPO" "$REPO_ID" || clone_rc=$?
  if [ "$clone_rc" -eq 2 ]; then n_shallow=$((n_shallow + 1)); continue; fi
  if [ "$clone_rc" -ne 0 ]; then n_failed=$((n_failed + 1)); continue; fi

  GITDIR="$DXMI_CLONE_PATH"
  BRANCH="$(dxmi_default_branch "$GITDIR" "$BRANCH_HINT")"
  if [ -z "$BRANCH" ]; then
    dxm_warn "$REPO: no resolvable default branch — skipped"
    n_failed=$((n_failed + 1)); continue
  fi

  CURSOR=""
  if [ "$DXMI_REFETCH" -eq 0 ] && [ "$DXMI_REBUILD" -eq 0 ]; then
    CURSOR="$(dxm_watermark_get "$REPO_ID" git_commits)"
    # A force-push or history rewrite can strand the cursor. Falling back to a
    # full re-scan is safe (the writes are upserts) and is the only way to avoid
    # a permanent, invisible hole in the series.
    if [ -n "$CURSOR" ] && ! git --git-dir="$GITDIR" cat-file -e "${CURSOR}^{commit}" 2>/dev/null; then
      dxm_warn "$REPO: watermark commit $CURSOR is gone (rewritten history?) — full re-scan"
      CURSOR=""
    fi
  fi

  RANGE="$BRANCH"
  [ -n "$CURSOR" ] && RANGE="${CURSOR}..${BRANCH}"

  LOGARGS=( "$RANGE" --date=format-local:%Y-%m-%dT%H:%M:%SZ
            --pretty=format:'%x1e%H%x1f%ae%x1f%an%x1f%ad%x1f%cd%x1f%P%x1f%s%x1f%(trailers:key=Co-authored-by,valueonly,separator=%x1d)' )
  [ "$DXMI_NO_STATS" -eq 0 ] && LOGARGS+=( --shortstat )
  # Only bound a full scan. On an incremental pass the cursor is the floor, and
  # re-applying --since would silently drop commits authored before it that
  # landed after it.
  if [ -z "$CURSOR" ] && [ -n "$DXMI_SINCE" ]; then LOGARGS+=( "--since=${DXMI_SINCE}T00:00:00Z" ); fi
  [ -n "$DXMI_UNTIL" ] && LOGARGS+=( "--until=${DXMI_UNTIL}T23:59:59Z" )

  SQLF="$TMP/commits.sql"; COVF="$TMP/cov.tsv"; STATF="$TMP/stat.tsv"
  : >"$COVF"; : >"$STATF"

  before="$(dxm_sql1 "SELECT COUNT(*) FROM commits WHERE repo_id=$REPO_ID;")"

  # pipefail is on, so the pipeline's status is git's if git fails.
  pipe_rc=0
  TZ=UTC git --git-dir="$GITDIR" log "${LOGARGS[@]}" 2>"$TMP/git.err" \
    | awk -v REPO_ID="$REPO_ID" -v REPO="$REPO" -v PATFILE="$PATFILE" \
          -v COVFILE="$COVF" -v STATFILE="$STATF" "$AWK_COMMITS" >"$SQLF" || pipe_rc=$?
  if [ "$pipe_rc" -ne 0 ]; then
    dxm_warn "$REPO: git log failed: $(tr '\n' ' ' <"$TMP/git.err" | cut -c1-200)"
    n_failed=$((n_failed + 1)); continue
  fi

  dxmi_apply_sql "$SQLF"
  [ -s "$COVF" ] && dxm_coverage_batch "$RUN_ID" <"$COVF"

  IFS=$'\t' read -r c_scanned c_merge c_trail c_ai c_newest <"$STATF" || true
  c_scanned="${c_scanned:-0}"; c_merge="${c_merge:-0}"; c_trail="${c_trail:-0}"
  c_ai="${c_ai:-0}"; c_newest="${c_newest:-}"

  after="$(dxm_sql1 "SELECT COUNT(*) FROM commits WHERE repo_id=$REPO_ID;")"
  added=$(( after - before ))

  if [ "$DXMI_DRY_RUN" -eq 0 ]; then
    dxm_sql "UPDATE repos SET default_branch=$(dxm_q "$BRANCH"),
               first_commit_at=(SELECT MIN(authored_at) FROM commits WHERE repo_id=$REPO_ID),
               last_commit_at =(SELECT MAX(authored_at) FROM commits WHERE repo_id=$REPO_ID)
             WHERE repo_id=$REPO_ID;"

    # Watermarks advance ONLY here, after a complete pass. Both sources move
    # together because a single scan produced both.
    NEWCUR=""
    if [ -n "$c_newest" ]; then NEWCUR="$c_newest"
    elif [ -n "$CURSOR" ];  then NEWCUR="$CURSOR"; fi
    if [ -n "$NEWCUR" ]; then
      dxm_watermark_set "$REPO_ID" git_commits  sha "$NEWCUR" "$RUN_ID" "$added"
      dxm_watermark_set "$REPO_ID" git_trailers sha "$NEWCUR" "$RUN_ID" "$c_trail"
    fi
  fi

  dxm_log "$REPO: scanned=$c_scanned new=$added merges=$c_merge trailers=$c_trail ai_trailers=$c_ai branch=$BRANCH"
  n_ok=$((n_ok + 1))
  tot_scanned=$((tot_scanned + c_scanned)); tot_new=$((tot_new + added))
  tot_merges=$((tot_merges + c_merge)); tot_trailers=$((tot_trailers + c_trail))
  tot_ai=$((tot_ai + c_ai))
done 3<"$TARGETS"

# ---------------------------------------------------------------------------
# Outcome. A shallow repo is a precondition failure and must be loud: silently
# analysing one produces a confident, wrong answer.
# ---------------------------------------------------------------------------
PAYLOAD="\"repos_ok\":$n_ok,\"repos_shallow\":$n_shallow,\"repos_failed\":$n_failed"
PAYLOAD="$PAYLOAD,\"commits_scanned\":$tot_scanned,\"commits_new\":$tot_new"
PAYLOAD="$PAYLOAD,\"merge_commits\":$tot_merges,\"trailers\":$tot_trailers,\"ai_trailers\":$tot_ai"
PAYLOAD="$PAYLOAD,\"dry_run\":$([ "$DXMI_DRY_RUN" -eq 1 ] && echo true || echo false)"

if [ "$n_shallow" -gt 0 ]; then
  dxm_run_finish "$RUN_ID" error 2 "$n_shallow shallow clone(s); refused to ingest"
  dxm_emit false "$(basename "$0")" "$RUN_ID" \
    "$PAYLOAD,\"error\":\"$n_shallow repo(s) have a shallow clone; history is truncated and the time series would be wrong. Delete the cache dir and re-run.\""
  exit 2
fi
if [ "$n_failed" -gt 0 ]; then
  dxm_run_finish "$RUN_ID" partial 3 "$n_failed repo(s) failed; watermarks left in place"
  dxm_emit false "$(basename "$0")" "$RUN_ID" "$PAYLOAD,\"partial\":true"
  exit 3
fi
if [ "$n_ok" -eq 0 ]; then
  dxm_run_finish "$RUN_ID" error 4 "no repo produced any data"
  dxm_emit false "$(basename "$0")" "$RUN_ID" "$PAYLOAD,\"error\":\"no repo produced any data\""
  exit 4
fi

dxm_run_finish "$RUN_ID" ok 0
dxm_emit true "$(basename "$0")" "$RUN_ID" "$PAYLOAD"
