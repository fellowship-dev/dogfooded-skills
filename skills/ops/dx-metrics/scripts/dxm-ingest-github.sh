#!/usr/bin/env bash
# dxm-ingest-github.sh — W2. GitHub API -> pull requests, PR commits, identities.
#
# Owns (write): pull_requests, pr_commits, identities, identity_emails, and the
#               backfill of commits.author_identity_id / commits.pr_number.
#
# Two ideas do the heavy lifting here:
#
#   1. IDENTITY IS RESOLVED SERVER-SIDE. GitHub already knows which account owns
#      a commit email — including corporate ones — so we ask it, per DISTINCT
#      EMAIL rather than per commit. A repo with 20k commits usually has ~40
#      distinct emails, which is one or two GraphQL calls instead of 200 REST
#      pages. Emails GitHub cannot resolve stay unresolved and visible in
#      v_unresolved_emails; nothing is guessed from the email text.
#
#   2. THE SQUASH-MERGE TRAP. A squash-merged PR's branch commits never reach the
#      default branch, so git ingest never sees them and their AI trailers would
#      vanish. We therefore record the merge/squash commit SHA in pr_commits
#      alongside the branch SHAs — the squash commit IS on the default branch and
#      GitHub concatenates the trailers into it.
#
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/../lib/dxm-common.sh"
. "$SCRIPT_DIR/../lib/dxm-ingest-common.sh"

dxmi_usage() {
  cat <<'HELPTEXT'
dxm-ingest-github.sh — ingest pull requests and resolve commit identities into the dx-metrics DB.

SYNOPSIS
  dxm-ingest-github.sh --repo owner/name [--repo owner/name ...] [options]
  dxm-ingest-github.sh --org owner [options]

TARGETS
  --repo owner/name   Repository to ingest. Repeatable.
  --org owner         Every non-archived, non-fork, non-empty repo in the org.
                      (If gh is shimmed, export GH_REPO=owner/<any-repo> first.)

OPTIONS
  --since YYYY-MM-DD  Floor for a first/refetch PR pull. Ignored once a watermark
                      exists unless --refetch is given.
  --until YYYY-MM-DD  Ceiling on PR updated-at.
  --refetch           Ignore the PR watermark and re-pull everything (upserts).
  --rebuild           Re-run identity resolution for emails GitHub previously
                      could not resolve, re-apply bot patterns from scratch, and
                      re-run every backfill over all rows rather than new ones.
  --page-size N       PRs per GraphQL page, 1..100 (default 50). Lower it if a
                      repo's PRs carry enough commits to time the query out.
  --max-repos N       Cap on repos returned per --org (default 200).
  --dry-run           Fetch and parse, write nothing.
  --json              Default and implicit.
  --help              This text.

  --period, --include-individuals are accepted for flag-surface parity. This
  script never writes a login, name or email to stdout under any flag: the
  envelope carries counts only.

RUN ORDER
  Run dxm-ingest-git.sh FIRST. Identity resolution reads the commit emails that
  git ingest wrote; with an empty commits table there is nothing to resolve and
  the run will report identities_resolved=0.

OUTPUT
  One line of JSON on stdout. Everything else goes to stderr.

EXIT CODES
  0 ok · 1 usage · 2 precondition · 3 partial (rate limited — watermarks held) · 4 data
HELPTEXT
}

dxmi_parse_args "$@"

dxm_require_cmd gh jq sqlite3 awk
dxm_init_db
dxm_gh_check

RUN_ID=$(dxm_run_start "$(basename "$0")" "$*" "${DXMI_REPOS[0]:-${DXMI_ORGS[0]:-}}")
TMP="$(dxmi_tmpdir)"
trap 'rc=$?; rm -rf "$TMP"; dxm_run_trap '"$RUN_ID"' $rc' EXIT

MAX_PAGES=200          # 200 * page-size PRs. A repo past this is a --since problem.
ID_BATCH=40            # distinct emails per identity-resolution GraphQL call
                       # (2 candidate SHAs each -> ~80 aliases, well inside limits)

# Optional column, added by a later contract change. Populate it only if it
# exists, so this script works against schema v1 and against a v1+review_count
# without a second code path.
HAS_REVIEW_COL=0
if dxm_sql "PRAGMA table_info(pull_requests);" | grep -q '|review_count|'; then
  HAS_REVIEW_COL=1
else
  dxm_log "pull_requests has no review_count column in this schema version; review counts are fetched but not stored"
fi

# ---------------------------------------------------------------------------
# GraphQL documents (mirrored, with the reasoning, in references/github-queries.md)
# ---------------------------------------------------------------------------
PR_QUERY='query($owner:String!,$name:String!,$n:Int!,$cursor:String){
  repository(owner:$owner,name:$name){
    pullRequests(first:$n, after:$cursor, orderBy:{field:UPDATED_AT,direction:DESC}, states:[OPEN,CLOSED,MERGED]){
      pageInfo{ hasNextPage endCursor }
      nodes{
        number title state isDraft
        createdAt mergedAt closedAt updatedAt
        additions deletions changedFiles
        baseRefName headRefName
        bodyText
        author{ login __typename }
        mergedBy{ login }
        mergeCommit{ oid }
        labels(first:20){ nodes{ name } }
        reviews{ totalCount }
        commits(first:100){ totalCount nodes{ commit{ oid authoredDate } } }
      }
    }
  }
}'

# ---------------------------------------------------------------------------
# jq: GraphQL PR page -> SQL
# ---------------------------------------------------------------------------
cat >"$TMP/prs.jq" <<'JQPROG'
def sq: if . == null or . == "" then "NULL" else "'" + (tostring | gsub("'"; "''")) + "'" end;
def nq: if . == null then "NULL" else (tostring) end;
def bq: if . == true then "1" else "0" end;

.data.repository.pullRequests.nodes[]
| . as $p
| (([ (($p.commits.nodes // [])[] | .commit.authoredDate) ] | sort | first) // null) as $first
| ([ (($p.labels.nodes // [])[] | .name) ] | join(",")) as $labels
| (($p.bodyText // "")[0:500]) as $body
| ($p.author.login // null) as $login
| ($p.author["__typename"] // null) as $atype
| (
  ( "INSERT INTO pull_requests(repo_id,number,title,state,author_login,merged_by_login,"
    + "created_at,merged_at,closed_at,first_commit_at,github_updated_at,"
    + "additions,deletions,changed_files,commit_count,base_ref,head_ref,is_draft,label_csv,body_excerpt) VALUES("
    + ($rid|nq) + "," + ($p.number|nq) + "," + ($p.title|sq) + "," + ($p.state|sq) + ","
    + ($login|sq) + "," + (($p.mergedBy.login // null)|sq) + ","
    + ($p.createdAt|sq) + "," + ($p.mergedAt|sq) + "," + ($p.closedAt|sq) + ","
    + ($first|sq) + "," + ($p.updatedAt|sq) + ","
    + ($p.additions|nq) + "," + ($p.deletions|nq) + "," + ($p.changedFiles|nq) + ","
    + (($p.commits.totalCount // null)|nq) + ","
    + ($p.baseRefName|sq) + "," + ($p.headRefName|sq) + "," + ($p.isDraft|bq) + ","
    + ($labels|sq) + "," + ($body|sq) + ")"
    + " ON CONFLICT(repo_id,number) DO UPDATE SET title=excluded.title,state=excluded.state,"
    + "author_login=excluded.author_login,merged_by_login=excluded.merged_by_login,"
    + "created_at=excluded.created_at,merged_at=excluded.merged_at,closed_at=excluded.closed_at,"
    + "first_commit_at=COALESCE(excluded.first_commit_at,pull_requests.first_commit_at),"
    + "github_updated_at=excluded.github_updated_at,additions=excluded.additions,"
    + "deletions=excluded.deletions,changed_files=excluded.changed_files,"
    + "commit_count=excluded.commit_count,base_ref=excluded.base_ref,head_ref=excluded.head_ref,"
    + "is_draft=excluded.is_draft,label_csv=excluded.label_csv,body_excerpt=excluded.body_excerpt;" ),

  ( if $login == null then empty else
      "INSERT INTO identities(login,account_type) VALUES(" + ($login|sq) + "," + ($atype|sq) + ")"
      + " ON CONFLICT(login) DO UPDATE SET account_type=COALESCE(excluded.account_type,identities.account_type);"
    end ),

  # __typename=Bot is GitHub telling us directly. Stronger evidence than any
  # regex, so it is recorded with its own bot_reason.
  ( if $atype == "Bot" and $login != null then
      "UPDATE identities SET is_bot=1,bot_reason='github:author.__typename=Bot' WHERE login=" + ($login|sq) + ";"
    else empty end ),

  # Branch commits AND the merge/squash commit. The latter is the only one that
  # exists on the default branch for a squash-merged PR.
  ( [ (($p.commits.nodes // [])[] | .commit.oid), ($p.mergeCommit.oid // empty) ]
    | unique | .[]
    | "INSERT OR IGNORE INTO pr_commits(pr_id,repo_id,sha) SELECT pr_id," + ($rid|nq) + "," + (.|sq)
      + " FROM pull_requests WHERE repo_id=" + ($rid|nq) + " AND number=" + ($p.number|nq) + ";" ),

  # Written only when the schema has the column. See HAS_REVIEW_COL.
  ( if $rev == 1 then
      "UPDATE pull_requests SET review_count=" + (($p.reviews.totalCount // 0)|nq)
      + " WHERE repo_id=" + ($rid|nq) + " AND number=" + ($p.number|nq) + ";"
    else empty end )
)
JQPROG

# jq: identity-resolution GraphQL response -> "alias<TAB>login<TAB>displayname"
cat >"$TMP/ident.jq" <<'JQPROG'
(.data.repository // {}) | to_entries[]
| [ .key, ((.value.author.user.login) // ""), ((.value.author.name) // "") ] | @tsv
JQPROG

# ---------------------------------------------------------------------------
# Bot flagging. Patterns are POSIX ERE in the DB; SQLite has no REGEXP, so the
# match happens in awk and the RESULT is stored — the regex runs once per login
# per run, never inside a metric query.
# ---------------------------------------------------------------------------
apply_bot_patterns() {
  local out="$TMP/bots.sql" pats="$TMP/botpats.tsv" logins="$TMP/logins.txt"
  dxm_sql "SELECT pattern_id || char(9) || pattern FROM bot_patterns WHERE enabled=1 ORDER BY pattern_id;" >"$pats" || : >"$pats"
  dxm_sql "SELECT login FROM identities;" >"$logins" || : >"$logins"
  [ -s "$pats" ] && [ -s "$logins" ] || { : >"$out"; return 0; }

  awk -v PATFILE="$pats" '
    BEGIN {
      Q = sprintf("%c", 39)
      while ((getline line < PATFILE) > 0) {
        p = index(line, "\t"); if (p == 0) continue
        n++; pid[n] = substr(line, 1, p-1); pat[n] = tolower(substr(line, p+1))
      }
      close(PATFILE)
      print "BEGIN;"
    }
    function sq(s) { gsub(Q, Q Q, s); return Q s Q }
    {
      if ($0 == "") next
      l = tolower($0)
      for (i = 1; i <= n; i++) {
        if (l ~ pat[i]) {
          printf "UPDATE identities SET is_bot=1,bot_reason=%s WHERE login=%s AND is_bot=0;\n", \
            sq("bot_patterns:" pid[i] " " pat[i]), sq($0)
          break
        }
      }
    }
    END { print "COMMIT;" }
  ' "$logins" >"$out"
  dxmi_apply_sql "$out"
}

# ---------------------------------------------------------------------------
# Per-repo: pull requests
# ---------------------------------------------------------------------------
# Returns 0 ok, 3 rate limited (caller must not advance the watermark), 4 data.
# Sets PR_NEW_CURSOR / PR_PAGES / PR_SEEN / PR_TRUNC.
fetch_prs() {
  local repo="$1" rid="$2" owner name wm cursor page rc=0
  owner="${repo%%/*}"; name="${repo#*/}"
  PR_NEW_CURSOR=""; PR_PAGES=0; PR_SEEN=0; PR_TRUNC=0; PR_PAGE_SIZE_FINAL="$DXMI_PAGE_SIZE"

  # --since is compared against updatedAt, NOT against merged_at. That is the
  # only thing the GraphQL PR connection can order by, but it means a bounded
  # first pull does not produce "all PRs merged after X" — it produces "all PRs
  # TOUCHED after X", a self-selecting subset of older PRs (whatever got a late
  # comment, label or reopen). Every bucket before the bound is therefore
  # partially populated by an arbitrary rule, and partially-populated buckets
  # that render as flat numbers are how a baseline gets fabricated.
  #
  # Measured on one repo with --since 2026-01-01: 2024-09 held 14 merged PRs on
  # GitHub and 0 in the DB; 2025-08 held 12 and 5. Neither bucket carried any
  # indication that it was incomplete.
  #
  # The remedy is not to fix the filter — updatedAt is what the API offers — it
  # is to REMEMBER the bound so every downstream reader can refuse to present
  # pre-bound buckets as complete. The floor is stored as a pseudo-source in
  # ingest_watermarks so no migration is needed on an existing database.
  local bounded=0
  wm=""
  if [ "$DXMI_REFETCH" -eq 0 ]; then
    wm="$(dxm_watermark_get "$rid" github_prs)"
    if [ -z "$wm" ] && [ -n "$DXMI_SINCE" ]; then wm="${DXMI_SINCE}T00:00:00Z"; bounded=1; fi
  elif [ -n "$DXMI_SINCE" ]; then
    wm="${DXMI_SINCE}T00:00:00Z"; bounded=1
  fi
  [ -n "$wm" ] && dxm_log "$repo: PRs updated after $wm"

  # Record (or lower) this repo's PR-completeness floor. Lower, never raise: a
  # later re-pull with an earlier --since genuinely improves completeness, but a
  # narrower re-pull on top of an existing full history must not retroactively
  # declare the old rows incomplete.
  if [ "$bounded" -eq 1 ]; then
    dxm_sql "INSERT INTO ingest_watermarks(repo_id,source,cursor_kind,cursor_value,last_attempt_at)
             VALUES($rid,'github_prs_floor','timestamp',$(dxm_q "$DXMI_SINCE"),strftime('%Y-%m-%dT%H:%M:%SZ','now'))
             ON CONFLICT(repo_id,source) DO UPDATE SET
               cursor_value=MIN(ingest_watermarks.cursor_value, excluded.cursor_value),
               last_attempt_at=excluded.last_attempt_at;"
    dxm_warn "$repo: PR history is bounded at $DXMI_SINCE — buckets before that date are PARTIAL and will be marked as such"
  elif [ -z "$wm" ]; then
    # An unbounded full pull: this repo's PR history is complete, so any floor
    # left over from an earlier bounded run is now wrong and must go.
    dxm_sql "DELETE FROM ingest_watermarks WHERE repo_id=$rid AND source='github_prs_floor';"
  fi

  cursor=""
  local sqlall="$TMP/prs.sql"; : >"$sqlall"
  echo "BEGIN;" >>"$sqlall"

  # Page size is per-repo state, not a constant: a 504 means this repo's PRs are
  # too heavy at the current size and the remedy is to ask for less. It never
  # grows back within a run — a repo that timed out once at 50 will do it again.
  local page_n="$DXMI_PAGE_SIZE"
  PR_PAGE_SIZE_FINAL="$page_n"

  while :; do
    page="$TMP/page.json"
    rc=0
    # Retry ladder for "GitHub did not return a complete response" only.
    # First retry is at the SAME size — most of these are transient and a repo
    # that shrinks its page on every blip ends up crawling at n=1 for no reason.
    # After that: 50 -> 25 -> 12 -> 6 -> 3 -> 1. A page that cannot be fetched
    # at n=1 is a real data error, not a sizing problem, and must not be
    # retried forever.
    local same_size_retries=0
    while :; do
      local args=( api graphql -f "query=$PR_QUERY" -F "owner=$owner" -F "name=$name" -F "n=$page_n" )
      [ -n "$cursor" ] && args+=( -F "cursor=$cursor" )
      rc=0
      dxmi_gh_json "$repo" "$page" "${args[@]}" || rc=$?
      [ "$rc" -eq 78 ] || break
      if [ "$same_size_retries" -lt 2 ]; then
        same_size_retries=$((same_size_retries + 1))
        dxm_warn "$repo: transient — retrying the same cursor at page-size $page_n (attempt $same_size_retries/2)"
        sleep 3
        continue
      fi
      if [ "$page_n" -le 1 ]; then
        dxm_warn "$repo: GitHub still cannot answer at page-size 1; giving up on the rest of this repo's PRs"
        rc=3; break
      fi
      page_n=$(( page_n / 2 )); [ "$page_n" -lt 1 ] && page_n=1
      same_size_retries=0
      PR_PAGE_SIZE_FINAL="$page_n"
      dxm_warn "$repo: shrinking to page-size $page_n and retrying the same cursor"
    done

    # Exit 3 is a first-class outcome. Whatever we already parsed is valid and
    # gets committed; only the watermark is held back, so the next run re-walks
    # the overlap instead of leaving a hole.
    if [ "$rc" -ne 0 ]; then
      echo "COMMIT;" >>"$sqlall"
      dxmi_apply_sql "$sqlall"
      if [ "$rc" -eq 77 ] || [ "$rc" -eq 3 ]; then return 3; fi
      return 4
    fi

    PR_PAGES=$((PR_PAGES + 1))

    local n_nodes
    n_nodes="$(jq '[.data.repository.pullRequests.nodes[]?] | length' "$page")"
    [ "$n_nodes" -eq 0 ] && break

    # Page 1 node 1 is the newest updatedAt in the whole repo — the next cursor.
    if [ -z "$PR_NEW_CURSOR" ]; then
      PR_NEW_CURSOR="$(jq -r '.data.repository.pullRequests.nodes[0].updatedAt // ""' "$page")"
    fi

    # Trim to the nodes that are actually new. Ordering is UPDATED_AT desc, so
    # the first node at-or-before the watermark ends the walk for good.
    local keep="$TMP/keep.json" stop=0
    if [ -n "$wm" ]; then
      jq --arg wm "$wm" '.data.repository.pullRequests.nodes |= [ .[] | select(.updatedAt > $wm) ]' "$page" >"$keep"
      local kept; kept="$(jq '[.data.repository.pullRequests.nodes[]?] | length' "$keep")"
      [ "$kept" -lt "$n_nodes" ] && stop=1
    else
      cp "$page" "$keep"
    fi
    if [ -n "$DXMI_UNTIL" ]; then
      jq --arg u "${DXMI_UNTIL}T23:59:59Z" \
         '.data.repository.pullRequests.nodes |= [ .[] | select(.updatedAt <= $u) ]' "$keep" >"$keep.2"
      mv "$keep.2" "$keep"
    fi

    local kept2; kept2="$(jq '[.data.repository.pullRequests.nodes[]?] | length' "$keep")"
    PR_SEEN=$((PR_SEEN + kept2))
    if [ "$kept2" -gt 0 ]; then
      jq -r --argjson rid "$rid" --argjson rev "$HAS_REVIEW_COL" -f "$TMP/prs.jq" "$keep" >>"$sqlall"
      local trunc
      trunc="$(jq '[.data.repository.pullRequests.nodes[] | select(.commits.totalCount > (.commits.nodes|length))] | length' "$keep")"
      PR_TRUNC=$((PR_TRUNC + trunc))
    fi

    [ "$stop" -eq 1 ] && break
    [ "$(jq -r '.data.repository.pullRequests.pageInfo.hasNextPage' "$page")" = "true" ] || break
    cursor="$(jq -r '.data.repository.pullRequests.pageInfo.endCursor' "$page")"
    if [ "$PR_PAGES" -ge "$MAX_PAGES" ]; then
      dxm_warn "$repo: hit the $MAX_PAGES-page cap; treating the run as partial. Narrow it with --since."
      echo "COMMIT;" >>"$sqlall"
      dxmi_apply_sql "$sqlall"
      return 3
    fi
  done

  echo "COMMIT;" >>"$sqlall"
  dxmi_apply_sql "$sqlall"
  [ "$PR_TRUNC" -gt 0 ] && dxm_warn "$repo: $PR_TRUNC PR(s) have >100 commits; only the oldest 100 are linked (first_commit_at is still correct)"
  return 0
}

# ---------------------------------------------------------------------------
# Per-repo: identity resolution
# ---------------------------------------------------------------------------
# Returns 0 ok, 3 rate limited. Sets ID_RESOLVED / ID_UNRESOLVED / ID_CALLS.
resolve_identities() {
  local repo="$1" rid="$2" owner name
  owner="${repo%%/*}"; name="${repo#*/}"
  ID_RESOLVED=0; ID_UNRESOLVED=0; ID_CALLS=0

  local cand="$TMP/cand.tsv" retry_clause=""
  # Default: emails never asked about. That means BOTH "no row at all" and "a
  # row that no API call ever produced".
  #
  # dxm-identity.sh writes a placeholder row with resolution_source='unresolved'
  # for every email it sees. Treating "a row exists" as "we already asked" let
  # those placeholders mask all 29 of one repo's distinct emails from this resolver
  # permanently — 718 commits stuck unattributed, and no way to notice except by
  # reading the table. A row is not evidence of an attempt; a resolution_source
  # other than 'unresolved' is.
  #
  # --rebuild additionally retries emails GitHub genuinely could not resolve
  # (resolved_at IS NOT NULL) — a person may have linked that address since.
  if [ "$DXMI_REBUILD" -eq 1 ]; then
    retry_clause="OR e.identity_id IS NULL"
  else
    retry_clause="OR (e.identity_id IS NULL AND e.resolved_at IS NULL)"
  fi
  dxm_sql "SELECT c.author_email || char(9) || MIN(c.sha) || char(9) || MAX(c.sha)
             FROM commits c
             LEFT JOIN identity_emails e ON e.email = c.author_email
            WHERE c.repo_id = $rid
              AND c.author_email IS NOT NULL AND c.author_email <> ''
              AND (e.email IS NULL $retry_clause)
            GROUP BY c.author_email;" >"$cand" || : >"$cand"

  local total; total="$(wc -l <"$cand" | tr -d ' ')"
  [ "$total" -eq 0 ] && { dxm_log "$repo: no new commit emails to resolve"; return 0; }
  dxm_log "$repo: resolving $total distinct commit email(s)"

  local sqlall="$TMP/ident.sql" covall="$TMP/ident.cov"
  : >"$sqlall"; : >"$covall"
  echo "BEGIN;" >>"$sqlall"

  local i=0 q="" map="$TMP/map.tsv"
  : >"$map"
  flush_batch() {
    [ "$i" -eq 0 ] && return 0
    local doc="query(\$owner:String!,\$name:String!){repository(owner:\$owner,name:\$name){${q}}}"
    local resp="$TMP/ident.json" rc=0
    rc=0
    dxmi_gh_json "$repo" "$resp" api graphql -f "query=$doc" -F "owner=$owner" -F "name=$name" || rc=$?
    ID_CALLS=$((ID_CALLS + 1))
    [ "$rc" -eq 77 ] && return 3
    [ "$rc" -ne 0 ] && return 4

    # alias -> login, keeping the first non-empty answer per email index.
    jq -r -f "$TMP/ident.jq" "$resp" >"$TMP/resolved.tsv" 2>/dev/null || : >"$TMP/resolved.tsv"
    awk -v MAP="$map" -v RID="$rid" -v REPO="$repo" -v COV="$COVFILE_ID" '
      BEGIN {
        FS = "\t"; Q = sprintf("%c", 39)
        while ((getline line < MAP) > 0) {
          nf = split(line, m, "\t")
          if (nf < 3) continue
          email[m[1]] = m[2]; sample[m[1]] = m[3]
        }
        close(MAP)
      }
      function sq(s) { if (s == "") return "NULL"; gsub(Q, Q Q, s); return Q s Q }
      {
        idx = $1; sub(/^[ab]/, "", idx)
        if (!(idx in email)) next
        if ($2 == "") next
        if (idx in login) next
        login[idx] = $2; dname[idx] = $3
      }
      END {
        for (idx in email) {
          e = email[idx]; s = sample[idx]
          if (idx in login) {
            l = login[idx]
            printf "INSERT INTO identities(login,display_name,account_type) VALUES(%s,%s,%s) ON CONFLICT(login) DO UPDATE SET display_name=COALESCE(identities.display_name,excluded.display_name);\n", sq(l), sq(dname[idx]), sq("User")
            # SQLite requires the SELECT to carry a WHERE clause before ON
            # CONFLICT, otherwise the upsert clause is ambiguous. WHERE login=..
            # is that clause; do not add a second one.
            printf "INSERT INTO identity_emails(email,identity_id,resolution_source,sample_repo_id,sample_sha,resolved_at) SELECT %s,identity_id,%s,%d,%s,strftime(%s,%s) FROM identities WHERE login=%s ON CONFLICT(email) DO UPDATE SET identity_id=excluded.identity_id,resolution_source=excluded.resolution_source,sample_repo_id=excluded.sample_repo_id,sample_sha=excluded.sample_sha,resolved_at=excluded.resolved_at,updated_at=strftime(%s,%s);\n", sq(e), sq("github_api"), RID, sq(s), sq("%Y-%m-%dT%H:%M:%SZ"), sq("now"), sq(l), sq("%Y-%m-%dT%H:%M:%SZ"), sq("now")
            printf "%s\t%s\t%s\t%s\n", "identity_resolution", REPO ":" e, "script", "github-api:commit.author.user.login" > COV
          } else {
            printf "INSERT INTO identity_emails(email,identity_id,resolution_source,sample_repo_id,sample_sha) VALUES(%s,NULL,%s,%d,%s) ON CONFLICT(email) DO UPDATE SET resolution_source=excluded.resolution_source,sample_repo_id=excluded.sample_repo_id,sample_sha=excluded.sample_sha,updated_at=strftime(%s,%s) WHERE identity_emails.identity_id IS NULL;\n", sq(e), sq("unresolved"), RID, sq(s), sq("%Y-%m-%dT%H:%M:%SZ"), sq("now")
            # method="llm", NOT "script-with-fallback". This branch is the script
            # FAILING to decide — the email stays unattributed and a human has
            # to map it. Scoring it as covered made identity_resolution report
            # 100% coverage while a quarter of all commits had no author, which
            # is precisely the hole the coverage metric exists to expose.
            # SKILL.md defines llm as "no script could decide it — the backlog",
            # and that is exactly what this is.
            printf "%s\t%s\t%s\t%s\n", "identity_resolution", REPO ":" e, "llm", "github-api returned no linked account for this commit email (deleted user, a devbox/local address like user@host.local, or an email not attached to any GitHub account); needs a manual override in the identity review queue" > COV
          }
        }
      }
    ' "$TMP/resolved.tsv" >>"$sqlall"

    q=""; i=0; : >"$map"
    return 0
  }

  COVFILE_ID="$covall"
  local rcb=0
  # fd 4, not stdin: gh runs inside this loop via flush_batch.
  while IFS=$'\t' read -r -u 4 email s1 s2; do
    [ -n "${email:-}" ] || continue
    q="$q a${i}: object(oid:\"$s1\"){... on Commit{ author{ email name user{ login } } }}"
    if [ -n "${s2:-}" ] && [ "$s2" != "$s1" ]; then
      q="$q b${i}: object(oid:\"$s2\"){... on Commit{ author{ email name user{ login } } }}"
    fi
    printf '%s\t%s\t%s\n' "$i" "$email" "$s1" >>"$map"
    i=$((i + 1))
    if [ "$i" -ge "$ID_BATCH" ]; then
      rcb=0; flush_batch || rcb=$?
      if [ "$rcb" -ne 0 ]; then break; fi
    fi
  done 4<"$cand"
  if [ "$rcb" -eq 0 ]; then flush_batch || rcb=$?; fi

  echo "COMMIT;" >>"$sqlall"
  dxmi_apply_sql "$sqlall"
  if [ -s "$covall" ]; then
    dxm_coverage_batch "$RUN_ID" <"$covall"
    ID_RESOLVED="$(awk -F'\t' '$3=="script"{n++} END{print n+0}' "$covall")"
    ID_UNRESOLVED="$(awk -F'\t' '$3=="llm"{n++} END{print n+0}' "$covall")"
  fi
  if [ "$rcb" -eq 3 ]; then return 3; fi
  if [ "$rcb" -ne 0 ]; then return 4; fi
  return 0
}

# ---------------------------------------------------------------------------
# Backfills. These are the joins the views cannot do cheaply at read time.
# ---------------------------------------------------------------------------
backfill() {
  local rid="$1" only_null_c="AND commits.author_identity_id IS NULL" only_null_p="AND pull_requests.author_identity_id IS NULL"
  [ "$DXMI_REBUILD" -eq 1 ] && { only_null_c=""; only_null_p=""; }
  local f="$TMP/backfill.sql"
  cat >"$f" <<SQL
BEGIN;
UPDATE commits
   SET author_identity_id = (SELECT e.identity_id FROM identity_emails e WHERE e.email = commits.author_email)
 WHERE repo_id = $rid $only_null_c;

UPDATE pull_requests
   SET author_identity_id = (SELECT i.identity_id FROM identities i WHERE i.login = pull_requests.author_login)
 WHERE repo_id = $rid AND author_login IS NOT NULL $only_null_p;

UPDATE commits
   SET pr_number = (SELECT p.number FROM pr_commits pc JOIN pull_requests p ON p.pr_id = pc.pr_id
                     WHERE pc.repo_id = commits.repo_id AND pc.sha = commits.sha
                     ORDER BY p.number LIMIT 1)
 WHERE repo_id = $rid
   AND EXISTS (SELECT 1 FROM pr_commits pc WHERE pc.repo_id = commits.repo_id AND pc.sha = commits.sha);

UPDATE identity_emails
   SET commit_count = (SELECT COUNT(*) FROM commits c WHERE c.author_email = identity_emails.email);

UPDATE identities
   SET first_seen_at = (SELECT MIN(authored_at) FROM commits c WHERE c.author_identity_id = identities.identity_id),
       last_seen_at  = (SELECT MAX(authored_at) FROM commits c WHERE c.author_identity_id = identities.identity_id)
 WHERE EXISTS (SELECT 1 FROM commits c WHERE c.author_identity_id = identities.identity_id);
COMMIT;
SQL
  dxmi_apply_sql "$f"
}

# ---------------------------------------------------------------------------
# Main loop
# ---------------------------------------------------------------------------
TARGETS="$TMP/targets.tsv"
dxmi_list_targets >"$TARGETS"
[ -s "$TARGETS" ] || dxm_die "no ingestable repos resolved from the given targets" 1

n_ok=0; n_partial=0; n_failed=0
tot_prs=0; tot_res=0; tot_unres=0; tot_calls=0; tot_trunc=0; tot_orphans=0
min_page=$DXMI_PAGE_SIZE   # smallest page size any repo had to fall back to

if [ "$DXMI_REBUILD" -eq 1 ] && [ "$DXMI_DRY_RUN" -eq 0 ]; then
  dxm_log "--rebuild: clearing pattern-derived bot flags before re-applying them"
  dxm_sql "UPDATE identities SET is_bot=0, bot_reason=NULL
            WHERE is_excluded=0 AND (bot_reason IS NULL OR bot_reason LIKE 'bot_patterns:%');"
fi

while IFS=$'\t' read -r -u 3 REPO _BRANCH; do
  [ -n "${REPO:-}" ] || continue
  REPO_ID="$(dxm_repo_id "$REPO")"
  repo_partial=0

  dxm_watermark_touch "$REPO_ID" github_prs timestamp
  rc=0; fetch_prs "$REPO" "$REPO_ID" || rc=$?
  if [ "$rc" -eq 3 ]; then
    dxm_warn "$REPO: PR pull incomplete — watermark held at its previous value"
    repo_partial=1
  elif [ "$rc" -ne 0 ]; then
    # Count what actually landed BEFORE bailing out. fetch_prs commits every
    # page it managed to parse, so skipping this line reported "prs_ingested:0"
    # for a repo that had just written 350 rows — an envelope that understates
    # its own database is worse than one that reports a failure honestly.
    tot_prs=$((tot_prs + PR_SEEN)); tot_trunc=$((tot_trunc + PR_TRUNC))
    dxm_warn "$REPO: PR pull failed after $PR_SEEN PR(s); watermark held"
    n_failed=$((n_failed + 1)); continue
  fi
  tot_prs=$((tot_prs + PR_SEEN)); tot_trunc=$((tot_trunc + PR_TRUNC))
  [ "${PR_PAGE_SIZE_FINAL:-$DXMI_PAGE_SIZE}" -lt "$min_page" ] && min_page="$PR_PAGE_SIZE_FINAL"

  dxm_watermark_touch "$REPO_ID" github_identities timestamp
  rc=0; resolve_identities "$REPO" "$REPO_ID" || rc=$?
  if [ "$rc" -ne 0 ]; then
    dxm_warn "$REPO: identity resolution incomplete — watermark held"
    repo_partial=1
  fi
  tot_res=$((tot_res + ID_RESOLVED)); tot_unres=$((tot_unres + ID_UNRESOLVED))
  tot_calls=$((tot_calls + ID_CALLS))

  apply_bot_patterns
  if [ "$DXMI_DRY_RUN" -eq 0 ]; then backfill "$REPO_ID"; fi

  # A merged PR whose linked SHAs are all absent from the ingested commits is
  # invisible to AI attribution: v_prs_enriched joins pr_commits -> ai_trailers,
  # and there is nothing to join to. This happens when the default branch was
  # rewritten after the merge (force-push, history rewrite), so GitHub's
  # mergeCommit oid no longer exists on the branch we ingest.
  #
  # This is measured rather than repaired. Guessing the replacement commit from
  # a title or a timestamp is exactly the kind of inference this skill refuses
  # to make; a count the reader can see beats a number quietly biased downwards.
  ORPHANS="$(dxm_sql1 "SELECT COUNT(*) FROM pull_requests p
                        WHERE p.repo_id=$REPO_ID AND p.state='MERGED'
                          AND NOT EXISTS (SELECT 1 FROM pr_commits pc
                                            JOIN commits c ON c.repo_id=pc.repo_id AND c.sha=pc.sha
                                           WHERE pc.pr_id=p.pr_id);")"
  ORPHANS="${ORPHANS:-0}"
  if [ "$ORPHANS" -gt 0 ]; then
    dxm_warn "$REPO: $ORPHANS merged PR(s) have no commit present on the ingested branch (history rewritten after merge). Their AI attribution reads as 'not AI-assisted' and understates adoption."
  fi
  tot_orphans=$((tot_orphans + ORPHANS))

  # Watermarks move ONLY on a clean, complete pass for that source.
  if [ "$DXMI_DRY_RUN" -eq 0 ] && [ "$repo_partial" -eq 0 ]; then
    [ -n "${PR_NEW_CURSOR:-}" ] && \
      dxm_watermark_set "$REPO_ID" github_prs timestamp "$PR_NEW_CURSOR" "$RUN_ID" "$PR_SEEN"
    dxm_watermark_set "$REPO_ID" github_identities timestamp "$(dxm_utc_now)" "$RUN_ID" "$ID_RESOLVED"
  fi

  dxm_log "$REPO: prs=$PR_SEEN emails_resolved=$ID_RESOLVED unresolved=$ID_UNRESOLVED gh_calls=$((PR_PAGES + ID_CALLS))"
  if [ "$repo_partial" -eq 1 ]; then n_partial=$((n_partial + 1)); else n_ok=$((n_ok + 1)); fi
done 3<"$TARGETS"

RATE="$(dxmi_rate_remaining "$(head -n1 "$TARGETS" | cut -f1)")"
PAYLOAD="\"repos_ok\":$n_ok,\"repos_partial\":$n_partial,\"repos_failed\":$n_failed"
PAYLOAD="$PAYLOAD,\"prs_ingested\":$tot_prs,\"prs_commit_list_truncated\":$tot_trunc"
# A page size below the requested one means GitHub 504d on the bigger query and
# the script backed off. Surfaced so a slow run has a visible cause.
[ "$min_page" -lt "$DXMI_PAGE_SIZE" ] && PAYLOAD="$PAYLOAD,\"pr_page_size_reduced_to\":$min_page"
PAYLOAD="$PAYLOAD,\"merged_prs_with_no_git_commit\":$tot_orphans"
PAYLOAD="$PAYLOAD,\"emails_resolved\":$tot_res,\"emails_unresolved\":$tot_unres"
PAYLOAD="$PAYLOAD,\"gh_rate_remaining\":$( [ "$RATE" = "unknown" ] && echo null || echo "$RATE" )"
PAYLOAD="$PAYLOAD,\"dry_run\":$([ "$DXMI_DRY_RUN" -eq 1 ] && echo true || echo false)"

if [ "$n_partial" -gt 0 ] || [ "$n_failed" -gt 0 ]; then
  dxm_run_finish "$RUN_ID" partial 3 "$n_partial partial, $n_failed failed; watermarks held"
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
