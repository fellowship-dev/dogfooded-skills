#!/usr/bin/env bash
# dxm-identity.sh — build the identity map.
#
# WHAT IT DOES
#   1. Syncs every distinct commit author email into identity_emails.
#   2. Optionally (--resolve) asks GitHub, server-side, which login owns an
#      email — via `gh api repos/{owner}/{repo}/commits/{sha}` -> .author.login.
#      This resolves corporate emails, not just @users.noreply.github.com.
#      There is NO regex email-mining path. An email GitHub cannot resolve stays
#      unresolved and VISIBLE, rather than being silently attached to a person.
#   3. Groups by login into `identities`.
#   4. Flags bots from the `bot_patterns` table (data, not code).
#   5. Applies a human-editable override file (confirm / alias / bot / human /
#      exclude / name) so a wrong mapping is fixed with a text editor.
#   6. Emits a git .mailmap file and a human-review queue for the emails that
#      GitHub could not resolve.
#
# OWNERSHIP (CONTRACT §10 deviation, declared loudly)
#   The contract assigns `identities` / `identity_emails` to W2. This module was
#   commissioned to own the identity map, so it writes both — idempotently, with
#   ON CONFLICT DO UPDATE, so running it before or after W2's ingest converges to
#   the same state. `commits.author_identity_id` remains W2's, and is only
#   touched behind the explicit --backfill-commits flag (default OFF).
#
# PRIVACY (CONTRACT §8)
#   This script handles the most personally-identifying data in the whole skill.
#   Therefore: STDOUT NEVER CONTAINS AN EMAIL, A LOGIN OR A NAME — with or
#   without --include-individuals. Counts and file paths only. The mailmap and
#   the review queue are operational state under $DXM_HOME (they are inputs to
#   git and to a human editor), never under $DXM_OUT, which is the export
#   surface. --include-individuals only lets the operator see the review table
#   printed to stderr.
#
# shellcheck shell=bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/dxm-common.sh
. "$SCRIPT_DIR/../lib/dxm-common.sh"

SELF="$(basename "$0")"
US=$'\037'   # ASCII unit separator: never appears in an email, name or login

# ---------------------------------------------------------------------------
# usage
# ---------------------------------------------------------------------------
usage() {
  cat <<'EOF'
dxm-identity.sh — build the identity map (email -> GitHub login), flag bots,
emit a .mailmap and a human-review queue.

USAGE
  dxm-identity.sh [options]

OPTIONS
  --repo owner/name       Limit API resolution and the review queue to this repo.
                          Repeatable. Default: every repo in the DB.
  --org owner             Same, expanded from the repos already in the DB.
  --resolve               Ask GitHub to resolve emails that have no login yet
                          (one `gh api` call per unresolved email, not per
                          commit). Without this flag the script only reorganises
                          what has already been ingested.
  --overrides FILE        Override/confirmation data file.
                          Default: $DXM_HOME/identity/identity-overrides.tsv
  --mailmap-out FILE      Where to write the .mailmap.
                          Default: $DXM_HOME/identity/mailmap
  --review-out FILE       Where to write the unresolved-email review queue.
                          Default: $DXM_HOME/identity/identity-review.tsv
  --backfill-commits      Also set commits.author_identity_id from the map.
                          OFF by default: CONTRACT §10 gives that column to W2.
  --include-individuals   Print the review table to stderr for the operator.
                          Does NOT put personal data on stdout. Ever.
  --rebuild               Re-derive bot flags and re-apply overrides from
                          scratch. Never deletes a resolved email->login link.
  --no-coverage           Do not write identity_resolution coverage rows.
                          Pass this when dxm-ingest-github.sh already resolved
                          identities in the same pipeline: BOTH scripts write
                          identity_resolution units, and logging both double-
                          counts the denominator that meta.script_coverage_pct
                          reads. The orchestrator (dxm-run.sh) passes it.
  --dry-run               Make no changes to identity data. Still logs coverage
                          and still emits the envelope.
  --help                  This text.

OUTPUT
  One line of JSON on stdout. Counts and paths only — no emails, no logins.

OVERRIDE FILE
  Tab-separated, '#' comments. See references/identity-overrides.md.
    email    someone@corp.com    their-login    optional note
    alias    old-login           canonical-login
    bot      some-service        why it is a bot
    human    claudel             real person, matched ^claude(-|$) by accident
    exclude  shared-deploy-acct  shared account, not a person
    name     their-login         Their Display Name

EXIT CODES
  0 ok · 1 usage · 2 precondition · 3 partial (rate limited; nothing lost)
  4 data error (bad override file)
EOF
}

# ---------------------------------------------------------------------------
# args
# ---------------------------------------------------------------------------
REPOS=()
ORGS=()
DO_RESOLVE=0
DO_BACKFILL=0
INCLUDE_INDIVIDUALS=0
REBUILD=0
DRY_RUN=0
NO_COVERAGE=0
OVERRIDES_FILE=""
MAILMAP_OUT=""
REVIEW_OUT=""

while [ $# -gt 0 ]; do
  case "$1" in
    --help|-h)              usage; exit 0 ;;
    --repo)                 REPOS+=("${2:?--repo needs owner/name}"); shift 2 ;;
    --org)                  ORGS+=("${2:?--org needs an owner}"); shift 2 ;;
    --overrides)            OVERRIDES_FILE="${2:?--overrides needs a path}"; shift 2 ;;
    --mailmap-out)          MAILMAP_OUT="${2:?--mailmap-out needs a path}"; shift 2 ;;
    --review-out)           REVIEW_OUT="${2:?--review-out needs a path}"; shift 2 ;;
    --resolve)              DO_RESOLVE=1; shift ;;
    --backfill-commits)     DO_BACKFILL=1; shift ;;
    --include-individuals)  INCLUDE_INDIVIDUALS=1; shift ;;
    --rebuild)              REBUILD=1; shift ;;
    --no-coverage)          NO_COVERAGE=1; shift ;;
    --dry-run)              DRY_RUN=1; shift ;;
    --json)                 shift ;;   # implicit and only mode; accepted, ignored
    # Flags the orchestrator passes to every script but that mean nothing here.
    # Accepted and ignored deliberately, not swallowed silently — see stderr.
    --since|--until|--period)
        dxm_log "note: $1 has no effect on the identity map (it is not time-bucketed)"
        [ $# -ge 2 ] || dxm_die "$1 needs a value" 1
        shift 2 ;;
    *) printf 'ERROR: unknown flag: %s\n\n' "$1" >&2; usage >&2; exit 1 ;;
  esac
done

# ---------------------------------------------------------------------------
# preconditions
# ---------------------------------------------------------------------------
dxm_require_cmd sqlite3 awk grep
[ "$DO_RESOLVE" -eq 1 ] && dxm_gh_check
dxm_init_db

IDENTITY_DIR="$DXM_HOME/identity"
mkdir -p "$IDENTITY_DIR"
: "${OVERRIDES_FILE:=$IDENTITY_DIR/identity-overrides.tsv}"
: "${MAILMAP_OUT:=$IDENTITY_DIR/mailmap}"
: "${REVIEW_OUT:=$IDENTITY_DIR/identity-review.tsv}"

TMPDIR_RUN="$(mktemp -d "${TMPDIR:-/tmp}/dxm-identity.XXXXXX")"
cleanup() { rm -rf "$TMPDIR_RUN"; }

RUN_ID="$(dxm_run_start "$SELF" "$*" "")"
trap 'rc=$?; cleanup; dxm_run_trap '"$RUN_ID"' $rc' EXIT

# ---------------------------------------------------------------------------
# local sql helpers — a US-separated reader, because emails and display names
# can and do contain the default '|' separator.
# ---------------------------------------------------------------------------
_id_rows() { sqlite3 -separator "$US" -cmd ".timeout 10000" -cmd "PRAGMA foreign_keys=ON" "$DXM_DB" "$1"; }
_id_exec() { if [ "$DRY_RUN" -eq 1 ]; then cat >/dev/null; else dxm_sql_stdin; fi; }

# ---------------------------------------------------------------------------
# scope: which repos the API resolution and the review queue cover.
# The identity MAP itself is always global — a person is the same person across
# repos, and scoping commit_count to a subset would silently understate how much
# is at stake behind a wrong mapping.
# ---------------------------------------------------------------------------
SCOPE_SQL="1=1"
scope_terms=()
for r in "${REPOS[@]:-}"; do
  [ -n "$r" ] || continue
  case "$r" in */*) ;; *) dxm_die "--repo must be owner/name, got: $r" 1 ;; esac
  scope_terms+=("full_name=$(dxm_q "$r")")
done
for o in "${ORGS[@]:-}"; do
  [ -n "$o" ] || continue
  scope_terms+=("owner=$(dxm_q "$o")")
done
if [ "${#scope_terms[@]}" -gt 0 ]; then
  SCOPE_SQL="$(printf '%s OR ' "${scope_terms[@]}")"
  SCOPE_SQL="${SCOPE_SQL% OR }"
fi
SCOPE_IDS="SELECT repo_id FROM repos WHERE $SCOPE_SQL"

n_scope_repos="$(dxm_sql1 "SELECT COUNT(*) FROM ($SCOPE_IDS);")"
if [ "${n_scope_repos:-0}" -eq 0 ]; then
  dxm_warn "no repos in the DB match the requested scope; run an ingest first"
fi

# ---------------------------------------------------------------------------
# STEP 1 — sync every distinct commit author email into identity_emails.
#
# commit_count is recomputed globally on every run: it is the "how much is at
# stake if this mapping is wrong" number, and a stale one is worse than none.
# sample_sha prefers a non-merge commit, because merge commits are frequently
# authored by web-flow and resolve to the wrong thing.
# ---------------------------------------------------------------------------
if [ "$DRY_RUN" -eq 0 ]; then
  dxm_sql "
    INSERT INTO identity_emails(email, resolution_source, sample_repo_id, sample_sha, commit_count)
    SELECT lower(c.author_email),
           'unresolved',
           (SELECT c2.repo_id FROM commits c2
             WHERE lower(c2.author_email)=lower(c.author_email)
             ORDER BY c2.is_merge ASC, c2.authored_at DESC LIMIT 1),
           (SELECT c2.sha FROM commits c2
             WHERE lower(c2.author_email)=lower(c.author_email)
             ORDER BY c2.is_merge ASC, c2.authored_at DESC LIMIT 1),
           COUNT(*)
      FROM commits c
     WHERE c.author_email IS NOT NULL AND TRIM(c.author_email) <> ''
     GROUP BY lower(c.author_email)
    ON CONFLICT(email) DO UPDATE SET
      commit_count   = excluded.commit_count,
      sample_repo_id = COALESCE(identity_emails.sample_repo_id, excluded.sample_repo_id),
      sample_sha     = COALESCE(identity_emails.sample_sha,     excluded.sample_sha),
      updated_at     = strftime('%Y-%m-%dT%H:%M:%SZ','now');
  "
fi

# ---------------------------------------------------------------------------
# STEP 2 — seed identities from data other workstreams already resolved.
# PR authors come back from the GraphQL pull with a login attached; that login is
# a person we know about even if none of their emails resolved.
# ---------------------------------------------------------------------------
if [ "$DRY_RUN" -eq 0 ]; then
  dxm_sql "
    INSERT OR IGNORE INTO identities(login)
    SELECT DISTINCT author_login FROM pull_requests
     WHERE author_login IS NOT NULL AND TRIM(author_login) <> '';
  "
fi

# ---------------------------------------------------------------------------
# STEP 3 — --resolve: ask GitHub who owns the still-unresolved emails.
#
# One call per unresolved EMAIL (using its sample commit), not per commit. The
# work set shrinks to zero as emails get resolved, which is why this step needs
# no watermark of its own: it is self-limiting and idempotent.
# ---------------------------------------------------------------------------
REASONS="$TMPDIR_RUN/reasons.tsv"   # email <TAB> why the script could not decide
: > "$REASONS"
resolved_now=0
api_calls=0
PARTIAL=0

if [ "$DO_RESOLVE" -eq 1 ]; then
  _id_rows "
    SELECT e.email, r.full_name, e.sample_sha
      FROM identity_emails e
      JOIN repos r ON r.repo_id = e.sample_repo_id
     WHERE e.identity_id IS NULL
       AND e.sample_sha IS NOT NULL
       AND e.sample_repo_id IN ($SCOPE_IDS)
     ORDER BY e.commit_count DESC;
  " > "$TMPDIR_RUN/toresolve.tsv" || true

  writes="$TMPDIR_RUN/resolve-writes.sql"
  : > "$writes"

  while IFS="$US" read -r email full sha; do
    [ -n "${email:-}" ] || continue
    [ "$PARTIAL" -eq 1 ] && break

    gh_err="$TMPDIR_RUN/gh.err"
    if ! out="$(dxm_gh api "repos/$full/commits/$sha" \
                 --jq '[(.author.login // ""), (.author.type // ""), (.commit.author.name // "")] | @tsv' \
                 2>"$gh_err")"; then
      if grep -Eqi 'rate limit|API rate|secondary rate|HTTP 429|HTTP 403' "$gh_err"; then
        dxm_warn "GitHub rate limit hit while resolving identities; stopping cleanly"
        PARTIAL=1
        break
      fi
      # Deliberately NO sha in the reason string: v_llm_backlog ranks by reason,
      # and a per-commit reason fragments one real problem into N rows of 1.
      # The sha is in identity_emails.sample_sha if anyone needs it.
      printf '%s\t%s\n' "$email" "sample commit not retrievable from the GitHub API (deleted branch, force-push, or private fork)" >> "$REASONS"
      api_calls=$((api_calls + 1))
      continue
    fi
    api_calls=$((api_calls + 1))

    login="$(printf '%s' "$out" | awk -F'\t' '{print $1}')"
    atype="$(printf '%s' "$out" | awk -F'\t' '{print $2}')"
    cname="$(printf '%s' "$out" | awk -F'\t' '{print $3}')"

    if [ -z "$login" ]; then
      printf '%s\t%s\n' "$email" "GitHub returned author.login = null for this commit email (email not attached to any GitHub account); needs an 'email' line in the override file" >> "$REASONS"
      continue
    fi

    {
      printf "INSERT INTO identities(login, display_name, account_type) VALUES(%s,%s,%s)\n" \
        "$(dxm_q "$login")" "$(dxm_q "$cname")" "$(dxm_q "$atype")"
      printf "  ON CONFLICT(login) DO UPDATE SET display_name=COALESCE(identities.display_name, excluded.display_name), account_type=COALESCE(excluded.account_type, identities.account_type);\n"
      printf "UPDATE identity_emails SET identity_id=(SELECT identity_id FROM identities WHERE login=%s), resolution_source='github_api', resolved_at=strftime('%%Y-%%m-%%dT%%H:%%M:%%SZ','now'), updated_at=strftime('%%Y-%%m-%%dT%%H:%%M:%%SZ','now') WHERE email=%s;\n" \
        "$(dxm_q "$login")" "$(dxm_q "$email")"
    } >> "$writes"
    resolved_now=$((resolved_now + 1))
  done < "$TMPDIR_RUN/toresolve.tsv"

  if [ -s "$writes" ]; then
    { echo "BEGIN;"; cat "$writes"; echo "COMMIT;"; } | _id_exec
  fi
fi

# ---------------------------------------------------------------------------
# STEP 4 — bot classification from the bot_patterns TABLE.
#
# The rule set is data so it can be edited without a code change. Matching runs
# in grep because macOS sqlite3 has no REGEXP function; the RESULT is written to
# identities.is_bot so every downstream query joins one column instead of
# re-implementing the regex (which is how two dashboards start disagreeing).
#
# Two passes: a combined alternation answers "is this a bot?" in one grep, and
# only a positive result pays for the loop that names WHICH rule fired. The rule
# name is stored as evidence — a human disputing "why is X excluded" gets an
# answer, not a shrug.
# ---------------------------------------------------------------------------
_id_rows "SELECT pattern, COALESCE(note,'') FROM bot_patterns WHERE enabled=1;" > "$TMPDIR_RUN/patterns.tsv" || true

COMBINED=""
while IFS="$US" read -r pat note; do
  [ -n "${pat:-}" ] || continue
  COMBINED="${COMBINED}${COMBINED:+|}(${pat})"
done < "$TMPDIR_RUN/patterns.tsv"

bots_flagged=0
if [ "$REBUILD" -eq 1 ] && [ "$DRY_RUN" -eq 0 ]; then
  # Rebuild clears only DERIVED fields. It never drops a resolved email->login
  # link: that came from GitHub and re-fetching it costs API budget for nothing.
  dxm_sql "UPDATE identities SET is_bot=0, bot_reason=NULL, is_excluded=0, exclude_reason=NULL;"
fi

# flag_bots <extra-SQL-predicate> — match the pattern set against every login
# satisfying the predicate and write the result to identities.is_bot.
flag_bots() {
  local extra="$1" login atype reason
  _id_rows "SELECT login, COALESCE(account_type,'') FROM identities WHERE $extra;" \
    > "$TMPDIR_RUN/logins.tsv" || true
  botwrites="$TMPDIR_RUN/bots.sql"
  : > "$botwrites"
  while IFS="$US" read -r login atype; do
    [ -n "${login:-}" ] || continue
    reason=""
    if [ "$atype" = "Bot" ]; then
      reason="github_account_type=Bot"
    elif [ -n "$COMBINED" ] && printf '%s\n' "$login" | grep -Eiq -- "$COMBINED"; then
      while IFS="$US" read -r pat note; do
        [ -n "${pat:-}" ] || continue
        if printf '%s\n' "$login" | grep -Eiq -- "$pat"; then
          reason="bot_patterns:${pat}${note:+ (${note})}"
          break
        fi
      done < "$TMPDIR_RUN/patterns.tsv"
    fi
    if [ -n "$reason" ]; then
      printf "UPDATE identities SET is_bot=1, bot_reason=%s WHERE login=%s AND (is_bot=0 OR bot_reason IS NULL OR bot_reason NOT LIKE 'override:%%');\n" \
        "$(dxm_q "$reason")" "$(dxm_q "$login")" >> "$botwrites"
      bots_flagged=$((bots_flagged + 1))
    fi
  done < "$TMPDIR_RUN/logins.tsv"

  if [ -s "$botwrites" ]; then
    { echo "BEGIN;"; cat "$botwrites"; echo "COMMIT;"; } | _id_exec
  fi
}

flag_bots "1=1"

# ---------------------------------------------------------------------------
# STEP 5 — the override file. Applied LAST so a human always beats a regex.
#
# This is the escape hatch that keeps the bot regex safe to be aggressive: a
# real person called `claudel` is fixed with one line in a text file, not a
# patch. Strict parsing on purpose — a typo'd directive that is silently
# ignored is how a mapping "that I definitely fixed" quietly stops applying.
# ---------------------------------------------------------------------------
ov_applied=0
ov_email=0 ov_alias=0 ov_bot=0 ov_human=0 ov_exclude=0 ov_name=0

SEED_FILE="$DXM_SKILL_DIR/references/identity-overrides.seed.tsv"
if [ ! -f "$OVERRIDES_FILE" ] && [ "$DRY_RUN" -eq 0 ]; then
  # Seeded, not blank. An empty template is why nobody ever filled one in: the
  # addresses that pollute the unknown-steerer bucket are the same handful of
  # devbox and automation families on every run, and leaving them for the
  # operator to rediscover is how 25% of an org's commits ended up counted as
  # human on no evidence. The seed is COPIED, never merged into an existing
  # file — silently appending to something a human edited is worse than useless.
  if [ -f "$SEED_FILE" ]; then
    cp "$SEED_FILE" "$OVERRIDES_FILE"
    dxm_log "created override file from the seed: $OVERRIDES_FILE"
  else
    cat > "$OVERRIDES_FILE" <<'EOF'
# dx-metrics — identity overrides. Tab-separated. Edit freely; never edit code.
#
# SENSITIVE: this file contains commit author emails and GitHub logins.
# It is operational state, not an export. Do not commit it, do not paste it
# into a ticket, and do not use anything derived from it to evaluate a person.
#
# Columns:  directive <TAB> key <TAB> value <TAB> note(optional)
#
#   email    <commit-email>   <github-login>     confirm an email GitHub could not resolve
#                                                (the key may be a GLOB: * and ?)
#   alias    <other-login>    <canonical-login>  two accounts, one human
#   bot      <login>          <why>              force-classify as a bot / machine
#   human    <login>          <why>              force-classify as a human (beats the regex)
#   exclude  <login>          <why>              a real account that is not a person (shared/service)
#   name     <login>          <Display Name>     canonical name for the .mailmap
#
# Map a machine with no identifiable human behind it to a dxm-machine-* login:
# anything matching ^dxm-machine- is auto-flagged as a bot by schema.sql.
#
# Overrides are applied AFTER the automatic rules, so a line here always wins.
EOF
    dxm_log "created override template: $OVERRIDES_FILE"
  fi
fi
# Emails and logins live here; the rendered dashboard is 600 and holds no names.
[ -f "$OVERRIDES_FILE" ] && chmod 600 "$OVERRIDES_FILE" 2>/dev/null || true

if [ -f "$OVERRIDES_FILE" ]; then
  ovwrites="$TMPDIR_RUN/overrides.sql"
  : > "$ovwrites"
  lineno=0
  while IFS=$'\t' read -r directive key value note || [ -n "${directive:-}" ]; do
    lineno=$((lineno + 1))
    case "${directive:-}" in ''|'#'*) continue ;; esac
    directive="$(printf '%s' "$directive" | tr -d '[:space:]')"
    [ -n "$directive" ] || continue
    key="${key:-}"; value="${value:-}"; note="${note:-}"
    if [ -z "$key" ]; then
      dxm_die "override file $OVERRIDES_FILE line $lineno: directive '$directive' has no key (is the file tab-separated?)" 4
    fi
    case "$directive" in
      email)
        [ -n "$value" ] || dxm_die "override line $lineno: 'email' needs a github login in column 3" 4
        # A key containing * or ? is a GLOB, not a literal address. Machine
        # addresses come in families -- ubuntu@ip-10-0-0-1.ec2.internal is
        # one of an unbounded set minted by whichever box happened to run the
        # job -- and enumerating them by hand means the file is stale the next
        # time a devbox is replaced. GLOB matches the family once.
        #
        # A glob deliberately does NOT pre-seed a row: there is no single email
        # to insert, and inserting the pattern itself would put a fake address
        # into identity_emails and into the mailmap.
        case "$key" in
          *'*'*|*'?'*)
            {
              printf "INSERT OR IGNORE INTO identities(login) VALUES(%s);\n" "$(dxm_q "$value")"
              printf "UPDATE identity_emails SET identity_id=(SELECT identity_id FROM identities WHERE login=%s), resolution_source='manual', resolved_at=strftime('%%Y-%%m-%%dT%%H:%%M:%%SZ','now'), updated_at=strftime('%%Y-%%m-%%dT%%H:%%M:%%SZ','now') WHERE email GLOB lower(%s);\n" \
                "$(dxm_q "$value")" "$(dxm_q "$key")"
            } >> "$ovwrites" ;;
          *)
            {
              printf "INSERT OR IGNORE INTO identities(login) VALUES(%s);\n" "$(dxm_q "$value")"
              printf "UPDATE identity_emails SET identity_id=(SELECT identity_id FROM identities WHERE login=%s), resolution_source='manual', resolved_at=strftime('%%Y-%%m-%%dT%%H:%%M:%%SZ','now'), updated_at=strftime('%%Y-%%m-%%dT%%H:%%M:%%SZ','now') WHERE email=lower(%s);\n" \
                "$(dxm_q "$value")" "$(dxm_q "$key")"
              # An email the ingest has not seen yet still gets recorded, so a
              # pre-seeded override survives being applied before the commit lands.
              printf "INSERT OR IGNORE INTO identity_emails(email, identity_id, resolution_source, resolved_at) VALUES(lower(%s),(SELECT identity_id FROM identities WHERE login=%s),'manual',strftime('%%Y-%%m-%%dT%%H:%%M:%%SZ','now'));\n" \
                "$(dxm_q "$key")" "$(dxm_q "$value")"
            } >> "$ovwrites" ;;
        esac
        ov_email=$((ov_email + 1)) ;;
      alias)
        [ -n "$value" ] || dxm_die "override line $lineno: 'alias' needs a canonical login in column 3" 4
        # Repoint the alias's emails at the canonical identity and retire the
        # alias row. identities.login is UNIQUE and is referenced by FKs, so the
        # alias is excluded rather than deleted — no orphaned commits.
        {
          printf "INSERT OR IGNORE INTO identities(login) VALUES(%s);\n" "$(dxm_q "$value")"
          printf "UPDATE identity_emails SET identity_id=(SELECT identity_id FROM identities WHERE login=%s), resolution_source='manual', updated_at=strftime('%%Y-%%m-%%dT%%H:%%M:%%SZ','now') WHERE identity_id=(SELECT identity_id FROM identities WHERE login=%s);\n" \
            "$(dxm_q "$value")" "$(dxm_q "$key")"
          printf "UPDATE identities SET is_excluded=1, exclude_reason=%s WHERE login=%s;\n" \
            "$(dxm_q "override: alias of $value")" "$(dxm_q "$key")"
        } >> "$ovwrites"
        ov_alias=$((ov_alias + 1)) ;;
      bot)
        printf "UPDATE identities SET is_bot=1, bot_reason=%s WHERE login=%s;\n" \
          "$(dxm_q "override: ${value:-manually classified as a bot}")" "$(dxm_q "$key")" >> "$ovwrites"
        ov_bot=$((ov_bot + 1)) ;;
      human)
        printf "UPDATE identities SET is_bot=0, is_excluded=0, bot_reason=%s, exclude_reason=NULL WHERE login=%s;\n" \
          "$(dxm_q "override: ${value:-manually confirmed human}")" "$(dxm_q "$key")" >> "$ovwrites"
        ov_human=$((ov_human + 1)) ;;
      exclude)
        printf "UPDATE identities SET is_excluded=1, exclude_reason=%s WHERE login=%s;\n" \
          "$(dxm_q "override: ${value:-manually excluded}")" "$(dxm_q "$key")" >> "$ovwrites"
        ov_exclude=$((ov_exclude + 1)) ;;
      name)
        [ -n "$value" ] || dxm_die "override line $lineno: 'name' needs a display name in column 3" 4
        {
          printf "INSERT OR IGNORE INTO identities(login) VALUES(%s);\n" "$(dxm_q "$key")"
          printf "UPDATE identities SET display_name=%s WHERE login=%s;\n" "$(dxm_q "$value")" "$(dxm_q "$key")"
        } >> "$ovwrites"
        ov_name=$((ov_name + 1)) ;;
      *)
        dxm_die "override file $OVERRIDES_FILE line $lineno: unknown directive '$directive' (expected one of: email alias bot human exclude name)" 4 ;;
    esac
    ov_applied=$((ov_applied + 1))
  done < "$OVERRIDES_FILE"

  if [ -s "$ovwrites" ]; then
    { echo "BEGIN;"; cat "$ovwrites"; echo "COMMIT;"; } | _id_exec
  fi

  # An `email` or `alias` line can CREATE an identity that did not exist when
  # the pattern pass above ran — which is exactly what happens the first time a
  # devbox address is mapped to a dxm-machine-* login. Left here, that login is
  # a brand-new "human contributor" until the next run, and it inflates the
  # contributor count and the leverage denominator for a whole reporting cycle.
  #
  # Re-run the pattern pass over identities the override file did NOT decide
  # (bot_reason IS NULL). Anything an override touched has a reason starting
  # 'override:' and is left alone, so a human always still beats the regex.
  flag_bots "bot_reason IS NULL AND is_bot = 0 AND is_excluded = 0"
fi

# ---------------------------------------------------------------------------
# STEP 6 — first/last seen, from the commits we actually have.
# ---------------------------------------------------------------------------
if [ "$DRY_RUN" -eq 0 ]; then
  dxm_sql "
    UPDATE identities SET
      first_seen_at = (SELECT MIN(c.authored_at) FROM commits c
                        JOIN identity_emails e ON lower(c.author_email)=e.email
                       WHERE e.identity_id = identities.identity_id),
      last_seen_at  = (SELECT MAX(c.authored_at) FROM commits c
                        JOIN identity_emails e ON lower(c.author_email)=e.email
                       WHERE e.identity_id = identities.identity_id)
     WHERE EXISTS (SELECT 1 FROM identity_emails e WHERE e.identity_id = identities.identity_id);
  "
fi

# ---------------------------------------------------------------------------
# STEP 7 — optional commits backfill (CONTRACT §10 says this column is W2's).
# ---------------------------------------------------------------------------
backfilled=0
if [ "$DO_BACKFILL" -eq 1 ]; then
  if [ "$DRY_RUN" -eq 0 ]; then
    dxm_sql "
      UPDATE commits SET author_identity_id = (
        SELECT e.identity_id FROM identity_emails e
         WHERE e.email = lower(commits.author_email) AND e.identity_id IS NOT NULL)
      WHERE author_email IS NOT NULL
        AND EXISTS (SELECT 1 FROM identity_emails e
                     WHERE e.email = lower(commits.author_email) AND e.identity_id IS NOT NULL);
    "
  fi
  backfilled="$(dxm_sql1 "SELECT COUNT(*) FROM commits WHERE author_identity_id IS NOT NULL;")"
fi

# ---------------------------------------------------------------------------
# STEP 8 — emit the .mailmap.
#
# Form used:  Proper Name <canonical@email> <commit@email>
# which rewrites BOTH the name and the email of any commit made with
# <commit@email>. The canonical email is the identity's highest-volume address,
# because that is the one a reader will recognise.
#
# Written under $DXM_HOME, never $DXM_OUT: it is an input to `git -c
# mailmap.file=...`, not something anybody exports.
# ---------------------------------------------------------------------------
mailmap_lines=0
if [ "$DRY_RUN" -eq 0 ]; then
  {
    printf '# Generated by dx-metrics dxm-identity.sh at %s — do not hand-edit.\n' "$(dxm_utc_now)"
    printf '# Edit %s instead and re-run.\n' "$OVERRIDES_FILE"
    printf '# SENSITIVE: contains contributor names and email addresses.\n#\n'
    printf '# Use with:  git -c mailmap.file=%s shortlog -sn HEAD\n#\n' "$MAILMAP_OUT"
  } > "$MAILMAP_OUT.tmp"

  _id_rows "
    SELECT REPLACE(REPLACE(COALESCE(i.display_name, i.login),'<',''),'>','') AS nm,
           (SELECT e2.email FROM identity_emails e2
             WHERE e2.identity_id = i.identity_id
             ORDER BY e2.commit_count DESC, e2.email LIMIT 1) AS canon,
           e.email
      FROM identities i
      JOIN identity_emails e ON e.identity_id = i.identity_id
     WHERE i.is_excluded = 0
     ORDER BY i.login, e.commit_count DESC;
  " 2>/dev/null \
  | awk -F"$US" '
      NF>=3 && $2!="" && $3!="" {
        # Form 2 (Name <email>) when the address is already canonical — it still
        # normalises the NAME, which is the case where one human commits as both
        # "alice" and "Alice A". Form 4 (Name <canon> <other>) folds the address.
        if ($2 == $3) printf "%s <%s>\n", $1, $2
        else          printf "%s <%s> <%s>\n", $1, $2, $3
      }' \
    >> "$MAILMAP_OUT.tmp" || true

  mv "$MAILMAP_OUT.tmp" "$MAILMAP_OUT"
  # `grep -c` PRINTS 0 and EXITS 1 when nothing matches, so `$(grep -c ... ||
  # echo 0)` captures "0\n0" and the envelope emits `"mailmap_entries":00` —
  # which jq accepts and every strict JSON parser rejects. Take the first line
  # and only then default it.
  mailmap_lines="$(grep -cv '^#' "$MAILMAP_OUT" 2>/dev/null | head -n1 || true)"
  mailmap_lines="${mailmap_lines//[^0-9]/}"
  : "${mailmap_lines:=0}"
fi

# ---------------------------------------------------------------------------
# STEP 9 — the human-review queue.
#
# Every line is already a valid override line: fixing one is copy, paste the
# login, append to the override file. The gap is quantified (commit_count) so a
# reader can tell "3 stragglers" from "40% of the history is unattributed".
# ---------------------------------------------------------------------------
unresolved_total="$(dxm_sql1 "SELECT COUNT(*) FROM v_unresolved_emails;")"
unresolved_commits="$(dxm_sql1 "SELECT COALESCE(SUM(commit_count),0) FROM v_unresolved_emails;")"
total_commits="$(dxm_sql1 "SELECT COUNT(*) FROM commits;")"

if [ "$DRY_RUN" -eq 0 ]; then
  {
    printf '# dx-metrics — emails GitHub could not resolve to a login. %s of them, %s commits at stake.\n' \
      "${unresolved_total:-0}" "${unresolved_commits:-0}"
    printf '# Generated %s. SENSITIVE: contains commit author email addresses.\n' "$(dxm_utc_now)"
    printf '#\n# Fill in <GITHUB_LOGIN> and append the line to:\n#   %s\n' "$OVERRIDES_FILE"
    printf '# Leave a line here if the author genuinely has no GitHub account — the\n'
    printf '# commits stay counted in totals and reported as unattributed, never guessed.\n#\n'
    printf '# directive\tkey\tvalue\tnote\n'
    _id_rows "SELECT email, commit_count, COALESCE(sample_repo,'?'), COALESCE(sample_sha,'?') FROM v_unresolved_emails LIMIT 500;" 2>/dev/null \
      | awk -F"$US" '{ printf "email\t%s\t<GITHUB_LOGIN>\t%s commits, sample %s@%.7s\n", $1, $2, $3, $4 }' || true
  } > "$REVIEW_OUT"
fi

# Both of these hold real names and real email addresses. The rendered dashboard
# is chmod 600 and contains no names; these were world-readable and full of
# them, which is exactly backwards.
[ -f "$REVIEW_OUT" ]  && chmod 600 "$REVIEW_OUT"  2>/dev/null || true
[ -f "$MAILMAP_OUT" ] && chmod 600 "$MAILMAP_OUT" 2>/dev/null || true

# The unresolved-email list is a file, deliberately. Echoing it to stderr puts
# every contributor's address into the calling agent's context and its
# transcript, which is well outside what --include-individuals is documented to
# unlock (adoption timing and ownership risk). Point at the file instead.
if [ "$INCLUDE_INDIVIDUALS" -eq 1 ] && [ -f "$REVIEW_OUT" ]; then
  dxm_log "unresolved emails: see $REVIEW_OUT (chmod 600; contains contributor email addresses)"
fi

# ---------------------------------------------------------------------------
# STEP 10 — coverage. One row per email in the map.
#
# Deliberately NOT logged: the bot-pattern decisions. Every one of them would be
# a `script` row, and padding the denominator with free wins is how a coverage
# number stops meaning anything. The unit here is the hard question — "whose
# commit is this?" — and nothing else.
# ---------------------------------------------------------------------------
COVTSV="$TMPDIR_RUN/coverage.tsv"
_id_rows "
  SELECT e.email,
         COALESCE(r.full_name,'-'),
         e.resolution_source,
         CASE WHEN e.identity_id IS NULL THEN 0 ELSE 1 END,
         CASE WHEN e.sample_sha IS NULL THEN 0 ELSE 1 END,
         CASE WHEN e.sample_repo_id IN ($SCOPE_IDS) THEN 1 ELSE 0 END
    FROM identity_emails e
    LEFT JOIN repos r ON r.repo_id = e.sample_repo_id;
" 2>/dev/null > "$TMPDIR_RUN/covsrc.tsv" || true

# NOTE: the join below keys off FILENAME, not the usual `NR==FNR`. With an empty
# first file — which is the normal case, when nothing needed a give-up reason —
# NR==FNR stays true into the second file and silently swallows every row. That
# bug cost this script its entire coverage log once already.
awk -v US="$US" -v resolve_ran="$DO_RESOLVE" -v partial="$PARTIAL" -v RF="$REASONS" '
  BEGIN { FS="\t" }
  FILENAME == RF { reason[$1]=$2; next }
  {
    n = split($0, f, US)
    if (n < 6) next
    email=f[1]; repo=f[2]; src=f[3]; have=f[4]; has_sha=f[5]; in_scope=f[6]
    key = repo ":" email
    if (have == 1) {
      if (src == "github_api")      { m="script";               d="github-api:author.login" }
      else if (src == "manual")     { m="script-with-fallback"; d="override-file:manual confirmation" }
      else if (src == "mailmap")    { m="script-with-fallback"; d="mailmap" }
      else                          { m="script-with-fallback"; d="pre-existing link, source=" src }
    } else {
      m="llm"
      # The order below matters: each branch must name the ACTUAL reason this
      # run could not decide. A backlog entry is a specification for the rule
      # that should have existed, so a plausible-but-wrong one is worse than
      # none -- e.g. a rate-limited run must not claim the email is unresolvable.
      if (email in reason)          { d=reason[email] }
      else if (partial == 1)        { d="resolution interrupted by a GitHub rate limit before this email was tried; re-run to continue" }
      else if (resolve_ran == 0)    { d="identity not resolved yet: re-run dxm-identity.sh --resolve" }
      else if (has_sha == 0)        { d="no sample commit recorded for this email; ingest its commits first" }
      else if (in_scope == 0)       { d="sample commit lives in a repo outside this run'"'"'s --repo/--org scope; re-run unscoped" }
      else                          { d="GitHub returned no author.login for this email; needs an email override" }
    }
    printf "identity_resolution\t%s\t%s\t%s\n", key, m, d
  }
' "$REASONS" "$TMPDIR_RUN/covsrc.tsv" > "$COVTSV" || true

if [ -s "$COVTSV" ] && [ "$NO_COVERAGE" -eq 0 ]; then
  dxm_coverage_batch "$RUN_ID" < "$COVTSV"
elif [ "$NO_COVERAGE" -eq 1 ]; then
  dxm_log "--no-coverage: identity_resolution units were logged by dxm-ingest-github.sh in this pipeline; not logging them twice"
fi

# ---------------------------------------------------------------------------
# envelope — counts and paths only. No email, no login, no name. Ever.
# ---------------------------------------------------------------------------
emails_total="$(dxm_sql1 "SELECT COUNT(*) FROM identity_emails;")"
emails_resolved="$(dxm_sql1 "SELECT COUNT(*) FROM identity_emails WHERE identity_id IS NOT NULL;")"
ident_total="$(dxm_sql1 "SELECT COUNT(*) FROM identities;")"
ident_human="$(dxm_sql1 "SELECT COUNT(*) FROM v_human_identities;")"
ident_bot="$(dxm_sql1 "SELECT COUNT(*) FROM identities WHERE is_bot=1;")"
ident_excl="$(dxm_sql1 "SELECT COUNT(*) FROM identities WHERE is_excluded=1 AND is_bot=0;")"

unattributed_pct="null"
if [ "${total_commits:-0}" -gt 0 ]; then
  unattributed_pct="$(dxm_sql1 "SELECT printf('%.1f', 100.0*${unresolved_commits:-0}/${total_commits});")"
fi

PAYLOAD="$(printf '"repos_in_scope":%s,"identities":%s,"humans":%s,"bots":%s,"excluded":%s,"emails":%s,"emails_resolved":%s,"emails_unresolved":%s,"unattributed_commits":%s,"unattributed_commit_pct":%s,"resolved_this_run":%s,"api_calls":%s,"overrides_applied":%s,"mailmap":%s,"mailmap_entries":%s,"review_queue":%s,"overrides_file":%s,"backfilled_commits":%s,"dry_run":%s,"note":"proxy: identity is grouped by GitHub login; commits whose email GitHub cannot resolve are counted in totals and reported as unattributed, never guessed"' \
  "${n_scope_repos:-0}" "${ident_total:-0}" "${ident_human:-0}" "${ident_bot:-0}" "${ident_excl:-0}" \
  "${emails_total:-0}" "${emails_resolved:-0}" "${unresolved_total:-0}" \
  "${unresolved_commits:-0}" "$unattributed_pct" \
  "$resolved_now" "$api_calls" "$ov_applied" \
  "$(dxm_json_str "$MAILMAP_OUT")" "${mailmap_lines:-0}" \
  "$(dxm_json_str "$REVIEW_OUT")" "$(dxm_json_str "$OVERRIDES_FILE")" \
  "${backfilled:-0}" "$([ "$DRY_RUN" -eq 1 ] && echo true || echo false)")"

if [ "$PARTIAL" -eq 1 ]; then
  dxm_run_finish "$RUN_ID" partial 3 "GitHub rate limit during identity resolution"
  dxm_emit false "$SELF" "$RUN_ID" "\"partial\":true,\"error\":\"github rate limit; re-run to continue\",$PAYLOAD"
  exit 3
fi

dxm_run_finish "$RUN_ID" ok 0
dxm_emit true "$SELF" "$RUN_ID" "$PAYLOAD"
