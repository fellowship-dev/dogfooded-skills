#!/usr/bin/env bash
# dxm-ingest-common.sh — plumbing shared by the two ingest scripts ONLY.
#
# WHY THIS FILE EXISTS (and why it is not in dxm-common.sh):
#   lib/dxm-common.sh is frozen and is deliberately scoped to run bookkeeping,
#   watermarks, coverage and the stdout envelope. It explicitly forbids adding
#   repo-fetching logic to itself. But dxm-ingest-git.sh and dxm-ingest-github.sh
#   both need: the same flag parser, the same org->repo expansion, the same
#   clone/fetch/shallow-assert, and the same rate-limit classifier. Implementing
#   those twice is how two ingest scripts stop agreeing on what "--since" means.
#
# OWNERSHIP: the ingest workstream (W1 + W2). Nothing outside scripts/dxm-ingest-*
# may source this. It contains no metric logic and no classification logic.
#
# Sourced AFTER lib/dxm-common.sh:
#     . "$SCRIPT_DIR/../lib/dxm-common.sh"
#     . "$SCRIPT_DIR/../lib/dxm-ingest-common.sh"
#
# shellcheck shell=bash

set -uo pipefail

# ---------------------------------------------------------------------------
# Parsed-flag globals. Every ingest script reads these, never argv directly.
# ---------------------------------------------------------------------------
DXMI_REPOS=()              # explicit --repo values, owner/name
DXMI_ORGS=()               # --org values
DXMI_SINCE=""              # backfill floor, YYYY-MM-DD
DXMI_UNTIL=""              # analysis ceiling, YYYY-MM-DD
DXMI_REBUILD=0
DXMI_REFETCH=0
DXMI_DRY_RUN=0
DXMI_INCLUDE_INDIVIDUALS=0 # accepted for flag-surface parity; ingest emits no
                           # personal data to stdout with or without it.
DXMI_PERIOD="week"         # accepted, unused by ingest (bucketing lives in views)
DXMI_PAGE_SIZE=50
DXMI_MAX_REPOS=200
DXMI_NO_STATS=0
DXMI_EXTRA_FLAGS=""        # space-separated extra long flags a script accepts

# Set by dxmi_ensure_clone
DXMI_CLONE_PATH=""

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
# A flag this script does not know about is a USAGE ERROR (exit 1), never a
# warning. Silently swallowing an unknown flag is how two runs quietly stop
# being comparable — the contract is explicit about this.
_dxmi_extra_ok() {
  local want="$1" f
  for f in $DXMI_EXTRA_FLAGS; do [ "$f" = "$want" ] && return 0; done
  return 1
}

_dxmi_need_value() {
  [ -n "${2:-}" ] || dxm_die "flag $1 requires a value" 1
}

_dxmi_check_date() {
  case "$2" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;;
    *) dxm_die "$1 must be YYYY-MM-DD, got: $2" 1 ;;
  esac
}

# dxmi_parse_args "$@" — fills the DXMI_* globals.
dxmi_parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --repo)   _dxmi_need_value "$1" "${2:-}"
                case "$2" in */*) ;; *) dxm_die "--repo must be owner/name, got: $2" 1 ;; esac
                DXMI_REPOS+=("$2"); shift 2 ;;
      --org)    _dxmi_need_value "$1" "${2:-}"; DXMI_ORGS+=("$2"); shift 2 ;;
      --since)  _dxmi_need_value "$1" "${2:-}"; _dxmi_check_date "$1" "$2"; DXMI_SINCE="$2"; shift 2 ;;
      --until)  _dxmi_need_value "$1" "${2:-}"; _dxmi_check_date "$1" "$2"; DXMI_UNTIL="$2"; shift 2 ;;
      --period) _dxmi_need_value "$1" "${2:-}"
                case "$2" in day|week|month) DXMI_PERIOD="$2" ;; *) dxm_die "--period must be day|week|month" 1 ;; esac
                shift 2 ;;
      --page-size) _dxmi_need_value "$1" "${2:-}"
                case "$2" in ''|*[!0-9]*) dxm_die "--page-size must be a number" 1 ;; esac
                [ "$2" -ge 1 ] && [ "$2" -le 100 ] || dxm_die "--page-size must be 1..100" 1
                DXMI_PAGE_SIZE="$2"; shift 2 ;;
      --max-repos) _dxmi_need_value "$1" "${2:-}"
                case "$2" in ''|*[!0-9]*) dxm_die "--max-repos must be a number" 1 ;; esac
                DXMI_MAX_REPOS="$2"; shift 2 ;;
      --cache-dir) _dxmi_need_value "$1" "${2:-}"; DXM_CACHE="$2"; export DXM_CACHE; shift 2 ;;
      --rebuild)   DXMI_REBUILD=1; shift ;;
      --refetch)   DXMI_REFETCH=1; shift ;;
      --dry-run)   DXMI_DRY_RUN=1; shift ;;
      --json)      shift ;;   # default and implicit; accepted so callers can be explicit
      --include-individuals) DXMI_INCLUDE_INDIVIDUALS=1; shift ;;
      --no-stats)  _dxmi_extra_ok no-stats || dxm_die "unknown flag: $1" 1
                   DXMI_NO_STATS=1; shift ;;
      --help|-h)   dxmi_usage; exit 0 ;;
      --)          shift ;;
      -*)          dxm_die "unknown flag: $1 (long flags only, --flag value)" 1 ;;
      *)           dxm_die "unexpected positional argument: $1" 1 ;;
    esac
  done
  [ ${#DXMI_REPOS[@]} -gt 0 ] || [ ${#DXMI_ORGS[@]} -gt 0 ] || \
    dxm_die "nothing to ingest: pass --repo owner/name and/or --org owner" 1
}

# ---------------------------------------------------------------------------
# gh wrappers
# ---------------------------------------------------------------------------
# The gh in this environment is a shim that cannot resolve the target repo from
# cwd and will silently run UNAUTHENTICATED without one. Every call therefore
# carries GH_REPO. Never export a token to "fix" this.
dxmi_gh() { local repo="$1"; shift; GH_REPO="$repo" dxm_gh_run "$@"; }

# dxmi_gh_json <owner/repo> <outfile> <gh args...>
#   0  ok
#   77 rate limited / secondary limit  -> caller must exit 3 and NOT advance a watermark
#   78 the query was too expensive for GitHub to answer (HTTP 502/504, timeout)
#      -> RETRYABLE: ask for less per page and try the same cursor again
#   4  API returned something unusable
#   1  other failure
# GraphQL is the trap here: it answers HTTP 200 with an "errors" array, so a
# non-zero exit code alone is not a sufficient error check.
#
# 77 vs 78 matters. A rate limit means "come back later" and nothing smaller
# would have helped. A 504 means "that query was too big" — retrying it
# unchanged loops forever, and treating it as a hard failure made the largest
# repo in the first real run (1702 PRs) permanently unmeasurable. It is the page
# size that is wrong, not the request.
dxmi_gh_json() {
  local repo="$1" out="$2"; shift 2
  local errf rc=0
  errf="$(mktemp "${TMPDIR:-/tmp}/dxmi-err.XXXXXX")"
  GH_REPO="$repo" dxm_gh_run "$@" >"$out" 2>"$errf" || rc=$?
  if [ "$rc" -ne 0 ]; then
    if grep -qiE 'rate limit|secondary rate|abuse detection|HTTP 429|HTTP 403' "$errf"; then
      dxm_warn "$repo: rate limited by GitHub"
      rc=77
    elif grep -qiE "HTTP 50[234]|couldn't respond to your request in time|timeout|timed out|unexpected end of JSON input|unexpected EOF|connection reset|EOF$" "$errf"; then
      # "unexpected end of JSON input" is gh's message for a TRUNCATED response
      # body. Same cause as a 504 (GitHub gave up mid-serialisation) and the
      # same remedy: ask for less. It does not name a status code, which is why
      # the first version of this classifier missed it and turned a 1702-PR repo
      # into a permanent hard failure.
      dxm_warn "$repo: GitHub did not return a complete response (too expensive or truncated) — retryable"
      rc=78
    else
      dxm_warn "$repo: gh failed (rc=$rc): $(tr '\n' ' ' <"$errf" | cut -c1-300)"
    fi
    rm -f "$errf"; return "$rc"
  fi
  rm -f "$errf"
  if jq -e 'has("errors") and (.errors|length>0)' "$out" >/dev/null 2>&1; then
    if jq -e '[.errors[].type?] | index("RATE_LIMITED")' "$out" >/dev/null 2>&1; then
      dxm_warn "$repo: GraphQL RATE_LIMITED"
      return 77
    fi
    # GraphQL also reports its own execution timeout as a 200 with an errors
    # array. Same remedy as a 504: ask for less.
    if jq -e '[.errors[].message?] | join(" ") | test("timeout|timed out"; "i")' "$out" >/dev/null 2>&1; then
      dxm_warn "$repo: GraphQL query timed out — will retry smaller"
      return 78
    fi
    # Partial data with errors is common (e.g. one null object). Only fail hard
    # when there is no data at all.
    if ! jq -e '.data != null' "$out" >/dev/null 2>&1; then
      dxm_warn "$repo: GraphQL errors: $(jq -rc '[.errors[].message]|join("; ")' "$out" | cut -c1-300)"
      return 4
    fi
    dxm_warn "$repo: GraphQL partial errors: $(jq -rc '[.errors[].message]|join("; ")' "$out" | cut -c1-200)"
  fi
  return 0
}

dxmi_rate_remaining() {
  local repo="$1" out rc=0
  out="$(GH_REPO="$repo" dxm_gh_run api rate_limit --jq '.resources.core.remaining' 2>/dev/null)" || rc=$?
  [ "$rc" -eq 0 ] && [ -n "$out" ] && printf '%s' "$out" || printf '%s' "unknown"
}

# ---------------------------------------------------------------------------
# Target expansion
# ---------------------------------------------------------------------------
# Emits TSV: owner/name<TAB>default_branch
# Archived repos, forks and empty repos are skipped — they are not delivery
# signal, and a fork's inherited history would double-count upstream commits.
dxmi_list_targets() {
  local tmp r org
  tmp="$(mktemp "${TMPDIR:-/tmp}/dxmi-targets.XXXXXX")"
  : >"$tmp"

  # bash 3.2 (the macOS system bash) expands an EMPTY array under "${a[@]}" to a
  # single empty word instead of nothing, which silently produced a target row
  # with an empty repo name. Gate both loops on the element count.
  for org in ${DXMI_ORGS[@]+"${DXMI_ORGS[@]}"}; do
    [ -n "$org" ] || continue
    local raw rc=0 orgerr
    raw="$(mktemp "${TMPDIR:-/tmp}/dxmi-org.XXXXXX")"
    orgerr="$(mktemp "${TMPDIR:-/tmp}/dxmi-orgerr.XXXXXX")"
    # gh repo list already understands --no-archived/--source; the jq filter is
    # belt-and-braces so a gh version without those flags still behaves.
    if ! GH_REPO="${GH_REPO:-}" dxm_gh_run repo list "$org" \
          --limit "$DXMI_MAX_REPOS" --no-archived --source \
          --json nameWithOwner,isArchived,isFork,isEmpty,defaultBranchRef \
          >"$raw" 2>"$orgerr"; then
      rc=1
    fi
    if [ "$rc" -ne 0 ] || ! jq -e 'type=="array"' "$raw" >/dev/null 2>&1; then
      rm -f "$raw" "$orgerr" "$tmp"
      dxm_die "could not enumerate org '$org' via gh repo list. If gh is shimmed, export GH_REPO=$org/<any-repo> first, or pass --repo explicitly." 2
    fi
    # A shimmed gh mints a token scoped to $GH_REPO. With no GH_REPO it may run
    # UNAUTHENTICATED and return only the org's PUBLIC repos while exiting 0 —
    # a silently truncated population that would look like a successful run.
    # Refuse it. (Verified: 6 repos anchored on one repo, 5 on another, 27
    # unauthenticated, on the same org, on the same day.)
    if grep -qi 'running gh unauthenticated' "$orgerr"; then
      rm -f "$raw" "$orgerr" "$tmp"
      dxm_die "refusing org '$org': gh fell back to an UNAUTHENTICATED listing, which sees only public repos and silently omits every private one. Export GH_REPO=$org/<a-repo-you-can-read> and re-run, or pass --repo explicitly." 2
    fi
    rm -f "$orgerr"
    jq -r '.[]
           | select((.isArchived // false) | not)
           | select((.isFork // false) | not)
           | select((.isEmpty // false) | not)
           | select(.defaultBranchRef != null)
           | [.nameWithOwner, .defaultBranchRef.name] | @tsv' "$raw" >>"$tmp"
    local n_org; n_org="$(wc -l <"$tmp" | tr -d ' ')"
    dxm_log "org $org: $n_org repo(s) after skipping archived/forks/empty"
    rm -f "$raw"
    # An EMPTY org enumeration exits 0 and produces a dashboard full of zeros
    # that reads as "this team ships nothing" rather than "the tool could not
    # see the org". Measured: `gh repo list <org>` under a per-repo token shim
    # returned 0 repos, exit 0, no error text. Never proceed on it.
    if [ "$n_org" -eq 0 ]; then
      rm -f "$tmp"
      dxm_die "org '$org' enumerated to ZERO repositories. That is not a small org, it is a broken read: a token scoped to something else, or an org this account cannot see. gh binary: $DXM_GH$(l="$(dxm_gh_login)"; [ -n "$l" ] && printf ' (as %s)' "$l"). Set DXM_GH to a gh authenticated as a member, or pass --repo explicitly." 2
    fi
    if [ -n "${DXMI_MIN_ORG_REPOS:-}" ] && [ "$n_org" -lt "$DXMI_MIN_ORG_REPOS" ]; then
      rm -f "$tmp"
      dxm_die "org '$org' enumerated to $n_org repo(s), below the asserted floor of $DXMI_MIN_ORG_REPOS. Refusing a partial view of an org rather than publishing numbers computed from an unknown subset." 2
    fi
  done

  for r in ${DXMI_REPOS[@]+"${DXMI_REPOS[@]}"}; do
    [ -n "$r" ] || continue
    local meta
    meta="$(dxmi_gh "$r" api "repos/$r" --jq '[.default_branch, (.archived|tostring), (.fork|tostring), (.size|tostring)] | @tsv' 2>/dev/null)" || meta=""
    if [ -z "$meta" ]; then
      dxm_warn "$r: could not read repo metadata from GitHub; assuming default branch 'HEAD'"
      printf '%s\t%s\n' "$r" "HEAD" >>"$tmp"
      continue
    fi
    local db arch fork
    db="$(printf '%s' "$meta" | cut -f1)"
    arch="$(printf '%s' "$meta" | cut -f2)"
    fork="$(printf '%s' "$meta" | cut -f3)"
    if [ "$arch" = "true" ]; then dxm_warn "$r: archived — skipped"; continue; fi
    if [ "$fork" = "true" ]; then dxm_warn "$r: fork — skipped"; continue; fi
    printf '%s\t%s\n' "$r" "${db:-HEAD}" >>"$tmp"
  done

  sort -u "$tmp"
  rm -f "$tmp"
}

# ---------------------------------------------------------------------------
# Clone / fetch, and the shallow assertion
# ---------------------------------------------------------------------------
# A shallow clone silently truncates history and produces a CONFIDENT, WRONG
# time series — every "adoption started in March" conclusion would be an
# artefact of the clone depth. We therefore mirror-clone (never --depth), record
# the check as data in repos.is_shallow, and refuse to ingest when it is true.
#
# Sets DXMI_CLONE_PATH. Returns:
#   0  ready
#   2  shallow / unusable
#   1  clone or fetch failed
dxmi_ensure_clone() {
  local repo="$1" repo_id="$2" path
  # '__' not '_': owner and name are both allowed to contain single underscores,
  # so a single-char separator can collide two different repos onto one cache dir.
  path="$DXM_CACHE/$(printf '%s' "$repo" | sed 's|/|__|g').git"
  DXMI_CLONE_PATH="$path"

  mkdir -p "$DXM_CACHE"

  if [ -d "$path" ]; then
    if ! git --git-dir="$path" rev-parse --git-dir >/dev/null 2>&1; then
      dxm_warn "$repo: cache at $path exists but is not a git dir"
      return 1
    fi
    if [ "$DXMI_DRY_RUN" -eq 1 ]; then
      dxm_log "$repo: --dry-run, skipping fetch (analysing cached history)"
    else
      dxm_log "$repo: fetching into existing mirror"
      # shellcheck disable=SC2015
      # A failed fetch is not fatal: cached history is still internally
      # consistent, it is just stale. Say so loudly rather than aborting a
      # multi-repo run because one remote was unreachable.
      GIT_TERMINAL_PROMPT=0 git --git-dir="$path" fetch --prune --quiet origin \
        '+refs/heads/*:refs/heads/*' >/dev/null 2>&1 \
        || dxm_warn "$repo: fetch failed — continuing against CACHED history, which may be stale"
    fi
  else
    # --dry-run still clones. The mirror cache is not the database: "do
    # everything except write" means the DB, and a dry run that cannot read any
    # history would be unable to tell you anything about what a real run would do.
    dxm_log "$repo: cloning full mirror (no --depth: shallow history would falsify the time series)"
    # gh repo clone carries auth for private repos without any token plumbing.
    if ! GIT_TERMINAL_PROMPT=0 dxm_gh_run repo clone "$repo" "$path" -- --mirror --quiet >/dev/null 2>&1; then
      dxm_warn "$repo: gh repo clone failed"
      rm -rf "$path"
      return 1
    fi
    # Delegate future auth to gh as well. This is not token plumbing: no token
    # is ever read, stored or printed — gh is asked for credentials on demand.
    git --git-dir="$path" config credential.helper "!$DXM_GH auth git-credential" || true
  fi

  # THE assertion.
  local shallow
  shallow="$(git --git-dir="$path" rev-parse --is-shallow-repository 2>/dev/null || echo true)"
  local is_shallow=1
  [ "$shallow" = "false" ] && is_shallow=0

  if [ "$DXMI_DRY_RUN" -eq 0 ]; then
    dxm_sql "UPDATE repos SET clone_path=$(dxm_q "$path"),
               is_shallow=$is_shallow,
               shallow_checked_at=strftime('%Y-%m-%dT%H:%M:%SZ','now')
             WHERE repo_id=$repo_id;"
  fi

  if [ "$is_shallow" -eq 1 ]; then
    dxm_warn "$repo: SHALLOW clone — refusing to ingest. Delete $path and re-run."
    return 2
  fi
  return 0
}

# dxmi_default_branch <clone_path> <hint>
# The mirror's HEAD is authoritative; the GitHub hint is the fallback.
dxmi_default_branch() {
  local path="$1" hint="${2:-}" b
  b="$(git --git-dir="$path" symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
  if [ -z "$b" ] || ! git --git-dir="$path" rev-parse --verify --quiet "$b" >/dev/null 2>&1; then
    b="$hint"
  fi
  if [ -z "$b" ] || [ "$b" = "HEAD" ] || ! git --git-dir="$path" rev-parse --verify --quiet "$b" >/dev/null 2>&1; then
    for b in main master trunk develop; do
      git --git-dir="$path" rev-parse --verify --quiet "$b" >/dev/null 2>&1 && break
      b=""
    done
  fi
  printf '%s' "$b"
}

# ---------------------------------------------------------------------------
# SQL streaming
# ---------------------------------------------------------------------------
# Bulk writes go through ONE sqlite3 process reading a generated SQL file, with
# BEGIN/COMMIT already embedded by the generator. One process per row would make
# a 20k-commit backfill take minutes and would defeat the transaction.
dxmi_apply_sql() {
  local file="$1"
  [ -s "$file" ] || return 0
  if [ "$DXMI_DRY_RUN" -eq 1 ]; then
    dxm_log "--dry-run: would apply $(grep -c ';' "$file" 2>/dev/null || echo '?') statement(s) from $file"
    return 0
  fi
  dxm_sql_stdin <"$file"
}

# dxmi_tmpdir — one scratch dir per run; caller traps its removal.
dxmi_tmpdir() { mktemp -d "${TMPDIR:-/tmp}/dxm-ingest.XXXXXX"; }
